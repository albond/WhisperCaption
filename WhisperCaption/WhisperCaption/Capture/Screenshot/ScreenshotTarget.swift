import Foundation

/// What the user wants the screenshot hot key to capture.
///
/// Three modes:
///   - `.systemDefault` — first display reported by ScreenCaptureKit
///     (whatever macOS calls "main"). Survives display reconnects.
///   - `.display(uuid:)` — a specific monitor by stable UUID. We use the
///     same UUID scheme as `Displays` (CGDisplayCreateUUIDFromDisplayID)
///     so a hot-plug picker stays meaningful between sessions.
///   - `.app(bundleID:)` — first frontmost window owned by the given app.
///     Falls back to a clearly-labelled error bubble when the app isn't
///     running or has no on-screen windows.
enum ScreenshotTarget: Codable, Sendable, Equatable {
    case systemDefault
    case display(uuid: String)
    case app(bundleID: String)

    /// One-line description for the Settings UI ("Display: Studio Display",
    /// "App: Google Chrome", etc). Pretty-name lookups happen at the
    /// caller because they need NSWorkspace / Displays helpers we don't
    /// want to pull into this value type.
    var rawTag: String {
        switch self {
        case .systemDefault:        return "default"
        case .display(let uuid):    return "display:\(uuid)"
        case .app(let bundleID):    return "app:\(bundleID)"
        }
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey { case kind, value }
    private enum Kind: String, Codable { case systemDefault, display, app }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .systemDefault: self = .systemDefault
        case .display:       self = .display(uuid: try c.decode(String.self, forKey: .value))
        case .app:           self = .app(bundleID: try c.decode(String.self, forKey: .value))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .systemDefault:
            try c.encode(Kind.systemDefault, forKey: .kind)
        case .display(let uuid):
            try c.encode(Kind.display, forKey: .kind)
            try c.encode(uuid, forKey: .value)
        case .app(let bundleID):
            try c.encode(Kind.app, forKey: .kind)
            try c.encode(bundleID, forKey: .value)
        }
    }
}
