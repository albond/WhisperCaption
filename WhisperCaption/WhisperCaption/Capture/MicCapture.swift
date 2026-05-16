@preconcurrency import AVFoundation
import Foundation
import OSLog

/// Captures the microphone via AVAudioEngine and emits 16 kHz mono Float32
/// PCM chunks — exactly the format WhisperKit expects on `transcribe(audioArray:)`.
///
/// Native input format is whatever the device provides (often 48 kHz Float32).
/// We resample to 16 kHz mono Float32 on the fly via AVAudioConverter.
enum MicCaptureError: Error {
    case voiceProcessingUnavailable(underlying: Error)
    case engineStartFailed(underlying: Error)
    case converterUnavailable
    case alreadyRunning
}

enum MicCaptureEvent: Sendable {
    case samples([Float], rms: Float)      // 16 kHz mono Float32 + RMS for VU meter
    case error(MicCaptureError)
}

nonisolated final class MicCapture: @unchecked Sendable {

    private let log = Log.MicCapture
    private let stateQueue = DispatchQueue(label: "whispercaption.mic-capture.state")

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var continuation: AsyncStream<MicCaptureEvent>.Continuation?
    private var isRunning = false
    private var emitCount: Int = 0
    private var inputSink: AVAudioSinkNode?

    let events: AsyncStream<MicCaptureEvent>

    init() {
        var localContinuation: AsyncStream<MicCaptureEvent>.Continuation!
        self.events = AsyncStream(MicCaptureEvent.self, bufferingPolicy: .unbounded) { c in
            localContinuation = c
        }
        self.continuation = localContinuation
    }

    /// Optional UID of the audio input device the user picked from the dropdown.
    /// nil = follow system default.
    private var preferredInputUID: String?

    func setPreferredInput(uid: String?) {
        stateQueue.sync { self.preferredInputUID = uid }
    }

    func start() throws {
        try stateQueue.sync {
            guard !isRunning else { throw MicCaptureError.alreadyRunning }

            let input = engine.inputNode

            // Pin the input device to the user's choice if one was set.
            // If `preferredInputUID` is nil, AVAudioEngine uses the system default.
            if let uid = preferredInputUID, !uid.isEmpty {
                if let deviceID = AudioDevices.deviceID(forUID: uid, direction: .input),
                   let inputAU = input.audioUnit {
                    var dev = deviceID
                    let err = AudioUnitSetProperty(
                        inputAU,
                        kAudioOutputUnitProperty_CurrentDevice,
                        kAudioUnitScope_Global,
                        0,
                        &dev,
                        UInt32(MemoryLayout<AudioDeviceID>.size)
                    )
                    if err != noErr {
                        log.error("could not set mic device to \(uid, privacy: .public): \(err)")
                    } else {
                        log.info("mic pinned to user-selected device: \(uid, privacy: .public)")
                    }
                }
            }

            // Voice processing on macOS 26 produces a 3-channel input that
            // appears to silently break tap delivery on some devices.
            // Disabled here for stability; speaker bleed-through into mic
            // is accepted until VP can be re-introduced with proper multi-
            // channel handling.
            log.info("voice processing: DISABLED")

            // For non-VP path, we tap the bus's output format directly.
            // Note: do NOT use `inputFormat(forBus:)` — after voice processing
            // the two diverge and a tap installed with the input format
            // silently swallows every buffer.
            let tapFormat = input.outputFormat(forBus: 0)
            log.info("mic input format(0)=\(input.inputFormat(forBus: 0)) outputFormat(0)=\(tapFormat)")

            // Whisper wants 16 kHz mono Float32 (non-interleaved is fine; one channel).
            guard let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            ), let conv = AVAudioConverter(from: tapFormat, to: targetFormat) else {
                throw MicCaptureError.converterUnavailable
            }
            // Do NOT switch to `AVSampleRateConverterAlgorithm_Mastering` here.
            // Mic taps deliver one buffer per callback with a one-shot
            // input block (we supply that buffer, then return `.noDataNow`).
            // Mastering has multi-buffer look-ahead and never accumulates
            // enough input under that pattern — every `convert(...)` returns
            // 0 frames and the VU stays dead. The default algorithm is
            // low-latency and is what we want for real-time mic capture.
            // `SystemCapture` can use Mastering because its CoreAudio path
            // pumps a continuous PCM stream where the converter sees enough
            // forward input to flush.
            self.converter = conv

            let cont = self.continuation
            let tapLog = self.log
            var tapCallCount = 0
            input.installTap(
                onBus: 0,
                bufferSize: 4096,
                format: tapFormat
            ) { [weak self] buffer, _ in
                tapCallCount += 1
                if tapCallCount == 1 {
                    tapLog.info("mic TAP first call: frames=\(buffer.frameLength) format=\(buffer.format)")
                }
                guard let self else { return }
                self.convertAndEmit(buffer: buffer, converter: conv, target: targetFormat, continuation: cont)
            }

            // Without a node connected downstream of inputNode, AVAudioEngine
            // on macOS keeps the input HAL bus dormant: `engine.start()` returns
            // success, the tap is installed, but its callback never fires.
            // A no-op AVAudioSinkNode anchors the graph so the engine engages
            // the HAL input. The sink swallows samples and produces no output
            // (no speaker feedback).
            let sink = AVAudioSinkNode { _, _, _ in noErr }
            engine.attach(sink)
            engine.connect(input, to: sink, format: tapFormat)
            self.inputSink = sink

            engine.prepare()
            do {
                try engine.start()
                isRunning = true
                log.info("mic capture started, tap format = \(tapFormat)")
            } catch {
                input.removeTap(onBus: 0)
                throw MicCaptureError.engineStartFailed(underlying: error)
            }
        }
    }

    func stop() {
        stateQueue.sync {
            guard isRunning else { return }
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            if let sink = inputSink {
                engine.detach(sink)
                inputSink = nil
            }
            isRunning = false
            log.info("mic capture stopped")
        }
        continuation?.finish()
    }

    deinit {
        stop()
    }

    // MARK: - Conversion

    private func convertAndEmit(
        buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        target: AVAudioFormat,
        continuation: AsyncStream<MicCaptureEvent>.Continuation?
    ) {
        let ratio = target.sampleRate / buffer.format.sampleRate
        let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCapacity) else {
            return
        }

        var supplied = false
        var convError: NSError?
        let status = converter.convert(to: outBuffer, error: &convError) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return buffer
        }

        if status == .error {
            if let convError {
                continuation?.yield(.error(.engineStartFailed(underlying: convError)))
            }
            return
        }

        let frames = Int(outBuffer.frameLength)
        guard frames > 0, let floatChannel = outBuffer.floatChannelData?[0] else {
            log.error("mic conversion produced 0 frames")
            return
        }

        let samples = Array(UnsafeBufferPointer(start: floatChannel, count: frames))
        let rms = computeRMS(samples)
        emitCount &+= 1
        if emitCount == 1 {
            log.info("mic first emit: \(frames) frames, rms=\(rms)")
        } else if emitCount % 100 == 0 {
            log.info("mic emit tick: count=\(self.emitCount) rms=\(rms)")
        }
        continuation?.yield(.samples(samples, rms: rms))
    }

    private func computeRMS(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }
}
