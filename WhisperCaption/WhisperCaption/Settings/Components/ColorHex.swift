import SwiftUI
import AppKit

/// SwiftUI `Color` ↔ `#RRGGBBAA` hex string. Used for color settings that
/// persist to UserDefaults — `Color` itself isn't directly Codable in a way
/// that survives round-tripping, so we serialise to/from sRGB hex.
///
/// Always resolves through `NSColor.usingColorSpace(.sRGB)` so the same
/// stored hex renders identically on every display profile.
extension Color {

    /// Parse a `#RRGGBB` or `#RRGGBBAA` hex string (leading `#` optional).
    /// Returns nil for malformed input — caller is expected to fall back
    /// to a sensible default.
    init?(hex: String) {
        let trimmed = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard let value = UInt32(trimmed, radix: 16) else { return nil }

        let r, g, b, a: Double
        switch trimmed.count {
        case 6:
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8)  & 0xFF) / 255
            b = Double( value        & 0xFF) / 255
            a = 1.0
        case 8:
            r = Double((value >> 24) & 0xFF) / 255
            g = Double((value >> 16) & 0xFF) / 255
            b = Double((value >> 8)  & 0xFF) / 255
            a = Double( value        & 0xFF) / 255
        default:
            return nil
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    /// Serialise to `#RRGGBBAA` in sRGB. Returns nil only if the colour
    /// can't be converted to sRGB at all (shouldn't happen for user-picked
    /// colours).
    func toHexRGBA() -> String? {
        guard let ns = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        let r = Int((ns.redComponent   * 255).rounded())
        let g = Int((ns.greenComponent * 255).rounded())
        let b = Int((ns.blueComponent  * 255).rounded())
        let a = Int((ns.alphaComponent * 255).rounded())
        return String(format: "#%02X%02X%02X%02X", r, g, b, a)
    }
}
