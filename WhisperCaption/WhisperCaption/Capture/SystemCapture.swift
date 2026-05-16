import AudioToolbox
@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import OSLog

/// Captures system audio (everything other apps are playing) using
/// CoreAudio Process Taps (`AudioHardwareCreateProcessTap`), available on
/// macOS 14.4+. ScreenCaptureKit's audio path is broken on macOS 15+:
/// callbacks just never fire. The Process Tap API works, doesn't require
/// Screen Recording permission (uses `NSAudioCaptureUsageDescription`), and
/// is the basis of the `AudioCap-pattern` capture used elsewhere in macOS.
///
/// Pipeline:
///   1. Build a `CATapDescription` for a system-wide stereo tap, excluding
///      our own process so we don't loopback ourselves.
///   2. `AudioHardwareCreateProcessTap` → tap object.
///   3. `AudioHardwareCreateAggregateDevice` referencing the tap.
///   4. `AudioDeviceCreateIOProcIDWithBlock` to get realtime input callbacks.
///   5. In the callback: wrap the AudioBufferList in an AVAudioPCMBuffer
///      (no copy), convert to 16 kHz mono Float32, emit through AsyncStream.
enum SystemCaptureError: Error {
    case tapCreationFailed(OSStatus)
    case aggregateDeviceCreationFailed(OSStatus)
    case ioProcCreationFailed(OSStatus)
    case startFailed(OSStatus)
    case alreadyRunning
    case formatUnavailable
    case streamDescriptionUnavailable(OSStatus)
    case defaultOutputUnavailable(OSStatus)
    case ourProcessIDUnavailable(OSStatus)
}

enum SystemCaptureEvent: Sendable {
    case samples([Float], rms: Float)
    case error(SystemCaptureError)
}

nonisolated final class SystemCapture: @unchecked Sendable {

    private let log = Log.SystemCapture
    private let stateQueue = DispatchQueue(label: "whispercaption.system-capture.state")
    private let ioQueue = DispatchQueue(label: "whispercaption.system-capture.io", qos: .userInitiated)
    private let listenerQueue = DispatchQueue(label: "whispercaption.system-capture.listener")

    // CoreAudio handles
    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var tapUUIDString: String = ""
    private var aggregateID: AudioObjectID = kAudioObjectUnknown
    private var procID: AudioDeviceIOProcID?
    private var defaultOutputListener: AudioObjectPropertyListenerBlock?

    /// Optional UID of an output device the user selected from the dropdown.
    /// nil = follow system default (and auto-rebuild on switch via the listener).
    private var preferredOutputUID: String?

    func setPreferredOutput(uid: String?) {
        stateQueue.sync { self.preferredOutputUID = uid }
    }

    // Audio conversion
    private var sourceFormat: AVAudioFormat?              // raw mono from the tap (we ask for mono)
    private var converter: AVAudioConverter?              // mono@sourceRate → mono@16k
    private var targetFormat: AVAudioFormat?

    private var continuation: AsyncStream<SystemCaptureEvent>.Continuation?
    private var isRunning = false
    private var firstCallback = true

    let events: AsyncStream<SystemCaptureEvent>

    init() {
        var localContinuation: AsyncStream<SystemCaptureEvent>.Continuation!
        self.events = AsyncStream(SystemCaptureEvent.self, bufferingPolicy: .unbounded) { c in
            localContinuation = c
        }
        self.continuation = localContinuation
    }

    func start() async throws {
        let alreadyRunning: Bool = stateQueue.sync { self.isRunning }
        guard !alreadyRunning else { throw SystemCaptureError.alreadyRunning }

        // 1) Build the tap description.
        // We use the global stereo tap and exclude OUR process so the captions
        // for system audio don't include our own (silent) playback.
        let myPID = ProcessInfo.processInfo.processIdentifier
        let myAudioObjectID = (try? Self.translatePIDToAudioObject(pid: myPID)) ?? kAudioObjectUnknown
        let excludeList: [AudioObjectID] = myAudioObjectID != kAudioObjectUnknown ? [myAudioObjectID] : []

        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: excludeList)
        let tapUUID = UUID()
        tapDescription.uuid = tapUUID
        // Force mono mixdown at the tap level. AVAudioConverter does NOT do a
        // proper L+R average for stereo→mono on its own — it tends to pick
        // one channel. By asking the tap itself for mono we avoid that pitfall
        // entirely; it produces a single L+R mixed channel.
        tapDescription.isMono = true
        tapDescription.isMixdown = true
        // muteBehavior left at default (unmuted) — system audio keeps playing
        // for the user normally while we tap it.

        // 2) Create the tap.
        var tapID: AudioObjectID = kAudioObjectUnknown
        let tapErr = AudioHardwareCreateProcessTap(tapDescription, &tapID)
        guard tapErr == noErr else {
            throw SystemCaptureError.tapCreationFailed(tapErr)
        }
        log.info("created system process tap id=\(tapID)")

        // 3) Read the format the tap will deliver.
        let asbd: AudioStreamBasicDescription
        do {
            asbd = try Self.readAudioTapStreamFormat(tapID: tapID)
        } catch let error as SystemCaptureError {
            AudioHardwareDestroyProcessTap(tapID)
            throw error
        }

        var sourceASBD = asbd
        guard let sourceFormat = AVAudioFormat(streamDescription: &sourceASBD) else {
            AudioHardwareDestroyProcessTap(tapID)
            throw SystemCaptureError.formatUnavailable
        }
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            AudioHardwareDestroyProcessTap(tapID)
            throw SystemCaptureError.formatUnavailable
        }
        // Whisper is allergic to cheap polyphase artifacts. Use the highest-
        // quality resampler the converter offers — costs more CPU but the
        // 48k→16k path produces clean audio instead of muddled phase smear.
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering

        // 4) Create the aggregate device that owns the tap.
        // Preferred device wins; otherwise we follow the system default.
        let outputUID = try resolveOutputUID()
        let clockUID = Self.stableClockUID(forOutputUID: outputUID)
        let aggregateUID = UUID().uuidString

        var description: [String: Any] = [
            kAudioAggregateDeviceNameKey:           "WhisperCaption-Tap",
            kAudioAggregateDeviceUIDKey:            aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey:  outputUID,
            kAudioAggregateDeviceIsPrivateKey:      true,
            kAudioAggregateDeviceIsStackedKey:      false,
            kAudioAggregateDeviceTapAutoStartKey:   true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [
                    kAudioSubDeviceUIDKey: outputUID,
                    // Without drift compensation on the sub-device side,
                    // Bluetooth output (which has its own jitter / async
                    // clock) makes the aggregate go silent — the tap's
                    // produced samples pile up but never get pulled.
                    kAudioSubDeviceDriftCompensationKey: 1
                ]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey:               tapUUID.uuidString
                ]
            ]
        ]
        // For Bluetooth outputs, force a stable on-device clock so the
        // aggregate doesn't try to use the BT codec clock as master.
        if let clockUID {
            description[kAudioAggregateDeviceClockDeviceKey] = clockUID
        }

        var aggregateID: AudioObjectID = kAudioObjectUnknown
        let aggErr = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID)
        guard aggErr == noErr else {
            AudioHardwareDestroyProcessTap(tapID)
            throw SystemCaptureError.aggregateDeviceCreationFailed(aggErr)
        }
        log.info("created aggregate device id=\(aggregateID), clock=\(clockUID ?? "default", privacy: .public)")

        // 5) Hook the IOProc.
        var procID: AudioDeviceIOProcID?
        let procErr = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) { [weak self] _, inInputData, _, _, _ in
            self?.handleAudioBuffer(inInputData)
        }
        guard procErr == noErr, let procID else {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            throw SystemCaptureError.ioProcCreationFailed(procErr)
        }

        // 6) Start.
        let startErr = AudioDeviceStart(aggregateID, procID)
        guard startErr == noErr else {
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            throw SystemCaptureError.startFailed(startErr)
        }

        stateQueue.sync {
            self.tapID = tapID
            self.tapUUIDString = tapUUID.uuidString
            self.aggregateID = aggregateID
            self.procID = procID
            self.sourceFormat = sourceFormat
            self.converter = converter
            self.targetFormat = targetFormat
            self.firstCallback = true
            self.isRunning = true
        }
        log.info("system capture started, source format = \(sourceFormat)")

        // Watch for default output device changes (user switches speakers
        // <-> headphones). The aggregate device pins to whatever output was
        // current at start time; we need to tear it down and rebuild it
        // around the new device, otherwise the tap goes silent.
        installDefaultOutputListener()
    }

    func stop() async {
        // Stop listening for output changes BEFORE we tear stuff down.
        removeDefaultOutputListener()

        let snapshot: (AudioObjectID, AudioObjectID, AudioDeviceIOProcID?) = stateQueue.sync {
            guard self.isRunning else { return (kAudioObjectUnknown, kAudioObjectUnknown, nil) }
            self.isRunning = false
            let t = self.tapID
            let a = self.aggregateID
            let p = self.procID
            self.tapID = kAudioObjectUnknown
            self.tapUUIDString = ""
            self.aggregateID = kAudioObjectUnknown
            self.procID = nil
            return (t, a, p)
        }
        let (tapID, aggregateID, procID) = snapshot

        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }

        continuation?.finish()
        log.info("system capture stopped")
    }

    deinit {
        // Best effort — actor-less teardown. If the user forgot to stop,
        // CoreAudio releases the tap when the process exits anyway.
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
    }

    // MARK: - Output device resolution

    /// User-pinned device if the UID still resolves to a real output device,
    /// otherwise the current system default. Falls back to system default on
    /// any failure to look up the pinned UID (e.g. headphones disconnected).
    private func resolveOutputUID() throws -> String {
        if let uid = preferredOutputUID, !uid.isEmpty,
           let _ = AudioDevices.deviceID(forUID: uid, direction: .output) {
            return uid
        }
        let deviceID = try Self.defaultSystemOutputDeviceID()
        return try Self.deviceUID(for: deviceID)
    }

    /// If the chosen output is a Bluetooth device, return the UID of the
    /// built-in speaker so the aggregate can use it as a stable clock master.
    /// For non-Bluetooth outputs we return nil — the aggregate will default
    /// to the sub-device's own clock, which is fine for wired devices.
    private static func stableClockUID(forOutputUID outputUID: String) -> String? {
        guard let outputDeviceID = AudioDevices.deviceID(forUID: outputUID, direction: .output) else {
            return nil
        }
        let transport = AudioDevices.transportType(for: outputDeviceID)
        guard AudioDevices.isBluetooth(transport) else { return nil }

        guard let builtInID = AudioDevices.builtInOutputDeviceID(),
              let uid = try? Self.deviceUID(for: builtInID)
        else { return nil }
        return uid
    }

    // MARK: - Default-output device watcher

    private static var defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
        mScope:    kAudioObjectPropertyScopeGlobal,
        mElement:  kAudioObjectPropertyElementMain
    )

    private func installDefaultOutputListener() {
        var address = Self.defaultOutputAddress
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleDefaultOutputChange()
        }
        let err = AudioObjectAddPropertyListenerBlock(Self.systemObject, &address, listenerQueue, block)
        if err == noErr {
            self.defaultOutputListener = block
        } else {
            log.error("could not install default-output listener: \(err)")
        }
    }

    private func removeDefaultOutputListener() {
        guard let block = defaultOutputListener else { return }
        var address = Self.defaultOutputAddress
        AudioObjectRemovePropertyListenerBlock(Self.systemObject, &address, listenerQueue, block)
        self.defaultOutputListener = nil
    }

    /// Triggered when the user switches output (e.g. speakers ↔ headphones).
    /// We tear down the aggregate device and rebuild it around the new output.
    /// The tap itself is global and doesn't need recreation.
    private func handleDefaultOutputChange() {
        stateQueue.async { [weak self] in
            guard let self else { return }
            guard self.isRunning else { return }
            do {
                try self.rebuildAggregate()
            } catch {
                self.log.error("rebuild aggregate failed: \(error)")
            }
        }
    }

    /// Must run on stateQueue. Recreates the aggregate device and IO proc
    /// around the *current* default output device, keeping the tap.
    private func rebuildAggregate() throws {
        log.info("rebuilding aggregate for new default output")

        // 1) Tear down current aggregate + IO proc.
        if let p = procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, p)
            AudioDeviceDestroyIOProcID(aggregateID, p)
            procID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }

        // 2) Resolve the output device to bind the aggregate to.
        let outputUID = try resolveOutputUID()
        let clockUID = Self.stableClockUID(forOutputUID: outputUID)

        // 3) Build a fresh aggregate referencing the same tap UUID.
        let aggregateUID = UUID().uuidString
        var description: [String: Any] = [
            kAudioAggregateDeviceNameKey:           "WhisperCaption-Tap",
            kAudioAggregateDeviceUIDKey:            aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey:  outputUID,
            kAudioAggregateDeviceIsPrivateKey:      true,
            kAudioAggregateDeviceIsStackedKey:      false,
            kAudioAggregateDeviceTapAutoStartKey:   true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [
                    kAudioSubDeviceUIDKey: outputUID,
                    kAudioSubDeviceDriftCompensationKey: 1
                ]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey:               tapUUIDString
                ]
            ]
        ]
        if let clockUID {
            description[kAudioAggregateDeviceClockDeviceKey] = clockUID
        }

        var newAggregateID: AudioObjectID = kAudioObjectUnknown
        let aggErr = AudioHardwareCreateAggregateDevice(description as CFDictionary, &newAggregateID)
        guard aggErr == noErr else {
            throw SystemCaptureError.aggregateDeviceCreationFailed(aggErr)
        }

        // 4) Re-install IO proc on the new aggregate.
        var newProcID: AudioDeviceIOProcID?
        let procErr = AudioDeviceCreateIOProcIDWithBlock(&newProcID, newAggregateID, ioQueue) { [weak self] _, inInputData, _, _, _ in
            self?.handleAudioBuffer(inInputData)
        }
        guard procErr == noErr, let newProcID else {
            AudioHardwareDestroyAggregateDevice(newAggregateID)
            throw SystemCaptureError.ioProcCreationFailed(procErr)
        }

        let startErr = AudioDeviceStart(newAggregateID, newProcID)
        guard startErr == noErr else {
            AudioDeviceDestroyIOProcID(newAggregateID, newProcID)
            AudioHardwareDestroyAggregateDevice(newAggregateID)
            throw SystemCaptureError.startFailed(startErr)
        }

        aggregateID = newAggregateID
        procID = newProcID
        firstCallback = true   // log fresh format on next callback
        log.info("aggregate rebuilt around output \(outputUID, privacy: .public)")
    }

    // MARK: - Realtime IO

    /// Called on `ioQueue` for every audio chunk the tap delivers.
    private func handleAudioBuffer(_ inputData: UnsafePointer<AudioBufferList>) {
        guard let sourceFormat, let converter, let targetFormat else { return }

        // Wrap the incoming AudioBufferList in an AVAudioPCMBuffer (no copy).
        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, bufferListNoCopy: inputData, deallocator: nil) else {
            return
        }
        let inputFrames = inBuffer.frameLength

        if firstCallback {
            firstCallback = false
            let asbd = sourceFormat.streamDescription.pointee
            log.info("""
                system tap first callback:
                  source format: \(sourceFormat)
                  isInterleaved: \(sourceFormat.isInterleaved)
                  channelCount: \(sourceFormat.channelCount)
                  sampleRate: \(sourceFormat.sampleRate)
                  ASBD.mFormatID: \(asbd.mFormatID)
                  ASBD.mFormatFlags: \(asbd.mFormatFlags)
                  ASBD.mBytesPerFrame: \(asbd.mBytesPerFrame)
                  ASBD.mBytesPerPacket: \(asbd.mBytesPerPacket)
                  ASBD.mFramesPerPacket: \(asbd.mFramesPerPacket)
                  ASBD.mBitsPerChannel: \(asbd.mBitsPerChannel)
                  inBuffer.frameLength: \(inputFrames)
                """)
            // Dump first 8 sample values
            if let chData = inBuffer.floatChannelData?[0] {
                let preview = (0..<min(8, Int(inputFrames))).map { String(format: "%.4f", chData[$0]) }.joined(separator: ", ")
                log.info("first samples: [\(preview)]")
            }
        }

        guard inputFrames > 0 else { return }

        // Output capacity scaled by sample-rate ratio.
        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(inputFrames) * ratio + 1024)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else { return }

        var supplied = false
        var convError: NSError?
        let status = converter.convert(to: outBuffer, error: &convError) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return inBuffer
        }

        if status == .error {
            if let convError {
                log.error("conversion error: \(convError.localizedDescription)")
            }
            return
        }

        let outFrames = Int(outBuffer.frameLength)
        guard outFrames > 0, let floatChannel = outBuffer.floatChannelData?[0] else { return }

        let samples = Array(UnsafeBufferPointer(start: floatChannel, count: outFrames))
        let rms = computeRMS(samples)
        continuation?.yield(.samples(samples, rms: rms))
    }

    private func computeRMS(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }

    // MARK: - CoreAudio property helpers

    private static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    private static func translatePIDToAudioObject(pid: pid_t) throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        var inPID = pid
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        var result: AudioObjectID = kAudioObjectUnknown
        let qualifierSize = UInt32(MemoryLayout<pid_t>.size)
        let err = withUnsafePointer(to: &inPID) { qualifierPtr in
            AudioObjectGetPropertyData(systemObject, &address, qualifierSize, qualifierPtr, &dataSize, &result)
        }
        guard err == noErr else { throw SystemCaptureError.ourProcessIDUnavailable(err) }
        return result
    }

    private static func defaultSystemOutputDeviceID() throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        let err = AudioObjectGetPropertyData(systemObject, &address, 0, nil, &dataSize, &deviceID)
        guard err == noErr else { throw SystemCaptureError.defaultOutputUnavailable(err) }
        return deviceID
    }

    private static func deviceUID(for deviceID: AudioDeviceID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        var uid: CFString? = nil
        let err = withUnsafeMutablePointer(to: &uid) { ptr in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, ptr)
        }
        guard err == noErr, let result = uid as String? else {
            throw SystemCaptureError.defaultOutputUnavailable(err)
        }
        return result
    }

    private static func readAudioTapStreamFormat(tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var asbd = AudioStreamBasicDescription()
        let err = AudioObjectGetPropertyData(tapID, &address, 0, nil, &dataSize, &asbd)
        guard err == noErr else { throw SystemCaptureError.streamDescriptionUnavailable(err) }
        return asbd
    }
}
