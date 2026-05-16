import Foundation
import AppKit

/// Snapshot of currently-running GUI applications, enough to populate a picker.
/// Used by Settings → Hotkeys when the user picks "Application" as the
/// screenshot target.
///
/// Filters:
///   - skip background-only apps (`activationPolicy != .regular`)
///   - skip ourselves (no point capturing our own window)
///   - drop entries with no bundle identifier (rare, but `.app(...)` target
///     keys on bundleID so missing → useless).
struct RunningApp: Identifiable, Hashable {
    let bundleID: String
    let name: String
    let icon: NSImage?

    var id: String { bundleID }
}

enum RunningApps {

    static func current() -> [RunningApp] {
        let mySelf = Bundle.main.bundleIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let bundleID = app.bundleIdentifier, bundleID != mySelf else { return nil }
                let name = app.localizedName ?? bundleID
                return RunningApp(bundleID: bundleID, name: name, icon: app.icon)
            }
            // Stable order: by display name, case-insensitive.
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Cheap lookup for a single app's display name — used when rendering
    /// a `ScreenshotTarget.app(bundleID:)` value in the UI without
    /// re-listing everything.
    static func displayName(forBundleID bundleID: String) -> String {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) {
            return app.localizedName ?? bundleID
        }
        return bundleID
    }
}
