import Foundation
import Carbon.HIToolbox
import OSLog

/// Thin wrapper over Carbon's `RegisterEventHotKey`. Carbon hot keys are
/// the only documented way to grab a global system shortcut on macOS that
/// doesn't require Accessibility permissions, and they keep working under
/// App Sandbox if we ever turn it on. The API is deprecated but remains
/// fully functional through current macOS versions — there is no Cocoa
/// replacement.
///
/// Each registration is identified by a string `id` so we can replace it
/// when the user re-binds the shortcut: register("foo", oldDescriptor) →
/// later register("foo", newDescriptor) silently unregisters the old one.
@MainActor
final class HotkeyManager {

    private let log = Log.HotkeyManager

    nonisolated private struct Entry {
        let id: String
        let descriptor: HotkeyDescriptor
        let hotKeyID: UInt32          // Carbon ID — used as key in actionsByHotKeyID
        let hotKeyRef: EventHotKeyRef?
        let action: () -> Void
    }

    private var entries: [String: Entry] = [:]

    /// Carbon hands us back a numeric ID in the event payload; we use it
    /// to look up which entry's action to fire. Monotonic, never reused.
    private var nextHotKeyID: UInt32 = 1
    private var actionsByHotKeyID: [UInt32: () -> Void] = [:]

    private var handlerInstalled = false

    init() {
        installHandlerIfNeeded()
    }

    deinit {
        // Best-effort cleanup on shutdown. macOS reclaims everything on
        // process exit, but unregistering keeps the system tidy if the
        // process lingers (e.g. during reload in Xcode).
        for entry in entries.values {
            if let ref = entry.hotKeyRef { UnregisterEventHotKey(ref) }
        }
    }

    /// Register or replace a global hot key. `action` is invoked on the
    /// main actor on every press. Throws if `RegisterEventHotKey` fails
    /// (typically because another app holds the same combo system-wide).
    func register(id: String, descriptor: HotkeyDescriptor, action: @escaping () -> Void) throws {
        // Replace an existing binding with the same id atomically.
        unregister(id: id)

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: nextHotKeyID)
        nextHotKeyID &+= 1

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            descriptor.keyCode,
            descriptor.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            log.error("RegisterEventHotKey failed for \(id, privacy: .public) status=\(status)")
            throw HotkeyError.registrationFailed(osStatus: status)
        }

        actionsByHotKeyID[hotKeyID.id] = action
        entries[id] = Entry(
            id: id,
            descriptor: descriptor,
            hotKeyID: hotKeyID.id,
            hotKeyRef: ref,
            action: action
        )

        log.info("registered hotkey id=\(id, privacy: .public) combo=\(descriptor.displayString, privacy: .public)")
    }

    func unregister(id: String) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        if let ref = entry.hotKeyRef { UnregisterEventHotKey(ref) }
        actionsByHotKeyID.removeValue(forKey: entry.hotKeyID)
        log.info("unregistered hotkey id=\(id, privacy: .public)")
    }

    // MARK: - Carbon event handler

    /// Four-character signature embedded in `EventHotKeyID`. Lets us tell
    /// our registrations apart from any third-party Carbon hotkey handlers
    /// that might also be installed in the same target.
    private static let signature: OSType = OSType(0x5743_5054) // "WCPT"

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.eventHandlerCallback,
            1,
            &spec,
            userData,
            nil
        )
        if status != noErr {
            log.error("InstallEventHandler failed status=\(status)")
        }
    }

    /// C-style callback. Carbon calls this on the main thread (event
    /// loop), so we can hop into our @MainActor world directly.
    private static let eventHandlerCallback: EventHandlerUPP = { _, eventRef, userData in
        guard let eventRef, let userData else { return noErr }
        var hotKeyID = EventHotKeyID()
        let getStatus = GetEventParameter(
            eventRef,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        if getStatus != noErr { return getStatus }

        let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
        // We're already on the main thread (Carbon dispatches there),
        // but assumeIsolated keeps Swift's actor checker happy.
        MainActor.assumeIsolated {
            manager.actionsByHotKeyID[hotKeyID.id]?()
        }
        return noErr
    }
}

extension HotkeyManager {
    enum HotkeyError: Error, LocalizedError {
        case registrationFailed(osStatus: OSStatus)
        var errorDescription: String? {
            switch self {
            case .registrationFailed(let s):
                return "RegisterEventHotKey failed (OSStatus \(s)). The combination may already be in use system-wide."
            }
        }
    }
}
