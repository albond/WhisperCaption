import AppKit
import CoreGraphics
import Foundation

/// Stable identification of physical displays.
///
/// `NSScreen.localizedName` is human-readable but NOT unique (two
/// identical Studio Displays both report the same name) and changes
/// across system updates. Apple's stable identifier is the UUID derived
/// from the `CGDirectDisplayID` via `CGDisplayCreateUUIDFromDisplayID`.
/// This file isolates that conversion so other modules treat
/// "target display" as just a String UUID.
struct DisplayInfo: Sendable, Identifiable, Hashable {
    let uuid: String        // stable across reboots / sleep / re-plug
    let name: String        // user-facing label
    let isMain: Bool
    let frame: CGRect       // global coordinate frame at the moment we read

    var id: String { uuid }
}

enum Displays: Sendable {

    /// All currently-connected displays in the user's order.
    static func all() -> [DisplayInfo] {
        return NSScreen.screens.compactMap { info(for: $0) }
    }

    /// The NSScreen whose UUID matches `uuid`, if it's still connected.
    static func screen(forUUID uuid: String) -> NSScreen? {
        NSScreen.screens.first { info(for: $0)?.uuid == uuid }
    }

    /// Convenience: friendly name for a UUID, or a fallback string when
    /// the chosen display isn't currently plugged in.
    static func name(forUUID uuid: String?) -> String {
        guard let uuid else { return "Default (current display)" }
        if let screen = screen(forUUID: uuid), let info = info(for: screen) {
            return info.name
        }
        return "Disconnected"
    }

    // MARK: - Internals

    private static func info(for screen: NSScreen) -> DisplayInfo? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let raw = screen.deviceDescription[key] as? NSNumber else { return nil }
        let displayID = CGDirectDisplayID(raw.uint32Value)
        guard let cfUUID = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return nil }
        guard let cfStr = CFUUIDCreateString(nil, cfUUID) else { return nil }
        let uuid = cfStr as String
        let name = screen.localizedName.isEmpty ? "Display \(displayID)" : screen.localizedName
        let isMain = (screen == NSScreen.main)
        return DisplayInfo(uuid: uuid, name: name, isMain: isMain, frame: screen.frame)
    }
}

extension NSScreen {
    /// Stable UUID identifying the underlying display. Survives sleep,
    /// cable reconnect, and resolution changes; differs per-monitor so we
    /// can key per-display settings (HUD width, HUD height) by it.
    var wc_displayUUID: String? {
        guard let raw = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        let displayID = CGDirectDisplayID(raw.uint32Value)
        guard let cf = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, cf) as String?
    }
}
