import AudioToolbox
import CoreAudio
import Foundation

struct AudioDevice: Sendable, Identifiable, Hashable {
    /// Stable UID we persist to disk to remember the user's choice.
    let uid: String
    /// Human-readable name shown in the dropdown.
    let name: String
    /// Live CoreAudio object id (changes between launches; for in-memory use).
    let objectID: AudioObjectID

    var id: String { uid }
}

/// Pure CoreAudio queries — must NOT be MainActor-isolated, otherwise
/// non-actor-isolated capture code (MicCapture, SystemCapture) can't call
/// these helpers without async hops.
nonisolated enum AudioDevices: Sendable {

    enum Direction: Sendable { case input, output }

    static func devices(for direction: Direction) -> [AudioDevice] {
        let allIDs = (try? listAllDeviceIDs()) ?? []
        let scope: AudioObjectPropertyScope = direction == .input
            ? kAudioObjectPropertyScopeInput
            : kAudioObjectPropertyScopeOutput

        return allIDs.compactMap { deviceID -> AudioDevice? in
            // A device is "input"-capable if it has at least one input stream
            // (similarly for output). Without this filter aggregate / virtual
            // devices show up in both lists, which is confusing.
            guard hasStreams(deviceID: deviceID, scope: scope) else { return nil }
            guard let uid = try? readString(deviceID, kAudioDevicePropertyDeviceUID) else { return nil }
            // Hide aggregate devices (our own tap aggregate and macOS's
            // CADefaultDeviceAggregate-*) and "virtual" loopback devices
            // (Background Music, eqMac, Zoom/Teams audio devices) — none of
            // those are useful as physical sources to the user.
            let transport = readUInt32(deviceID, kAudioDevicePropertyTransportType) ?? 0
            if transport == kAudioDeviceTransportTypeAggregate { return nil }
            if transport == kAudioDeviceTransportTypeVirtual { return nil }
            let name = (try? readString(deviceID, kAudioObjectPropertyName)) ?? "Unnamed"
            return AudioDevice(uid: uid, name: name, objectID: deviceID)
        }
    }

    /// Looks up a device whose transport type is `BuiltIn`. Used as a stable
    /// clock source for aggregate devices that include flaky Bluetooth subs.
    static func builtInOutputDeviceID() -> AudioDeviceID? {
        let allIDs = (try? listAllDeviceIDs()) ?? []
        for id in allIDs {
            guard hasStreams(deviceID: id, scope: kAudioObjectPropertyScopeOutput) else { continue }
            let transport = readUInt32(id, kAudioDevicePropertyTransportType) ?? 0
            if transport == kAudioDeviceTransportTypeBuiltIn { return id }
        }
        return nil
    }

    static func transportType(for deviceID: AudioDeviceID) -> UInt32 {
        readUInt32(deviceID, kAudioDevicePropertyTransportType) ?? 0
    }

    static func isBluetooth(_ transport: UInt32) -> Bool {
        transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    /// Just the device id of the system's *current* default for either direction.
    static func defaultDeviceID(for direction: Direction) -> AudioDeviceID? {
        let selector: AudioObjectPropertySelector = direction == .input
            ? kAudioHardwarePropertyDefaultInputDevice
            : kAudioHardwarePropertyDefaultSystemOutputDevice
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        let err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &dataSize, &deviceID
        )
        return err == noErr ? deviceID : nil
    }

    static func deviceID(forUID uid: String, direction: Direction) -> AudioDeviceID? {
        devices(for: direction).first(where: { $0.uid == uid })?.objectID
    }

    // MARK: - Internals

    private static func listAllDeviceIDs() throws -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        var err = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &dataSize
        )
        guard err == noErr else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: kAudioObjectUnknown, count: count)
        err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &dataSize, &ids
        )
        guard err == noErr else { return [] }
        return ids
    }

    private static func hasStreams(deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope:    scope,
            mElement:  kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let err = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        guard err == noErr else { return false }
        return dataSize > 0
    }

    private static func readUInt32(_ deviceID: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        var value: UInt32 = 0
        let err = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &value)
        return err == noErr ? value : nil
    }

    private static func readString(_ deviceID: AudioDeviceID, _ selector: AudioObjectPropertySelector) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        var cfStr: CFString? = nil
        let err = withUnsafeMutablePointer(to: &cfStr) { ptr in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, ptr)
        }
        guard err == noErr, let s = cfStr as String? else {
            throw NSError(domain: "AudioDevices", code: Int(err), userInfo: nil)
        }
        return s
    }
}
