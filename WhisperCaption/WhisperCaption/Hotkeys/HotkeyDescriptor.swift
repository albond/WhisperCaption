import Foundation
import Carbon.HIToolbox
import AppKit

/// Plain value type describing a global keyboard shortcut. Persisted in
/// UserDefaults via JSON. Two parallel APIs because macOS's two relevant
/// layers use incompatible encodings:
///   - NSEvent (the recorder receives this) uses `NSEvent.ModifierFlags`
///     bitmask and 16-bit virtual key codes.
///   - Carbon (`RegisterEventHotKey` expects this) uses cmdKey/optionKey/
///     controlKey/shiftKey constants and 32-bit key codes.
/// We store the Carbon flavour because it's what the registration call
/// ultimately consumes; we convert from NSEvent at recording time.
struct HotkeyDescriptor: Codable, Equatable, Sendable {
    /// Carbon virtual key code (`kVK_ANSI_*`). Same numeric value as
    /// `NSEvent.keyCode`, widened to 32 bits to match Carbon's API.
    var keyCode: UInt32

    /// Carbon modifier mask (`cmdKey | optionKey | controlKey | shiftKey`).
    /// NOT `NSEvent.ModifierFlags` — translate via `init?(nsEvent:)`.
    var modifiers: UInt32

    // MARK: - Conversions

    /// Build from an NSEvent captured by the recorder. Drops keys that
    /// have no modifier (we never want a single-letter global hotkey).
    init?(nsEvent event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon: UInt32 = 0
        if flags.contains(.command)  { carbon |= UInt32(cmdKey) }
        if flags.contains(.option)   { carbon |= UInt32(optionKey) }
        if flags.contains(.control)  { carbon |= UInt32(controlKey) }
        if flags.contains(.shift)    { carbon |= UInt32(shiftKey) }
        guard carbon != 0 else { return nil }
        self.keyCode = UInt32(event.keyCode)
        self.modifiers = carbon
    }

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    // MARK: - Display

    /// Human-readable form like "⌃⌥⌘ L". Used in Settings and in any
    /// future tooltip. Falls back to a hex code when the key has no
    /// glyph mapping (e.g. F-keys without their own symbol).
    var displayString: String {
        if isEmpty { return "None" }
        var parts: [String] = []
        if modifiers & UInt32(controlKey)  != 0 { parts.append("⌃") }
        if modifiers & UInt32(optionKey)   != 0 { parts.append("⌥") }
        if modifiers & UInt32(shiftKey)    != 0 { parts.append("⇧") }
        if modifiers & UInt32(cmdKey)      != 0 { parts.append("⌘") }
        let modifierGlyphs = parts.joined()
        let key = Self.keyGlyph(for: keyCode)
        return modifierGlyphs.isEmpty ? key : "\(modifierGlyphs) \(key)"
    }

    /// "Not bound" state. `modifiers == 0` is rejected by `init?(nsEvent:)`,
    /// so it can never be produced by recording — we use it as a sentinel
    /// for "no hotkey assigned". Registration code must skip empty
    /// descriptors instead of trying to bind them.
    var isEmpty: Bool { modifiers == 0 }

    static let empty = HotkeyDescriptor(keyCode: 0, modifiers: 0)

    /// Maps a Carbon virtual key code to its display character or symbolic
    /// name. Lookup table covers what a developer typically binds — top-row,
    /// arrows, function keys, common punctuation. Anything else shows its
    /// numeric code, which is enough for debugging.
    private static func keyGlyph(for code: UInt32) -> String {
        switch Int(code) {
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_Space:           return "Space"
        case kVK_Return:          return "↩"
        case kVK_Tab:             return "⇥"
        case kVK_Escape:          return "⎋"
        case kVK_Delete:          return "⌫"
        case kVK_ForwardDelete:   return "⌦"
        case kVK_LeftArrow:       return "←"
        case kVK_RightArrow:      return "→"
        case kVK_UpArrow:         return "↑"
        case kVK_DownArrow:       return "↓"
        case kVK_F1:  return "F1"
        case kVK_F2:  return "F2"
        case kVK_F3:  return "F3"
        case kVK_F4:  return "F4"
        case kVK_F5:  return "F5"
        case kVK_F6:  return "F6"
        case kVK_F7:  return "F7"
        case kVK_F8:  return "F8"
        case kVK_F9:  return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        case kVK_ANSI_Comma:      return ","
        case kVK_ANSI_Period:     return "."
        case kVK_ANSI_Slash:      return "/"
        case kVK_ANSI_Semicolon:  return ";"
        case kVK_ANSI_Quote:      return "'"
        case kVK_ANSI_LeftBracket:  return "["
        case kVK_ANSI_RightBracket: return "]"
        case kVK_ANSI_Backslash:    return "\\"
        case kVK_ANSI_Minus:        return "-"
        case kVK_ANSI_Equal:        return "="
        case kVK_ANSI_Grave:        return "`"
        default: return "key#\(code)"
        }
    }

    // MARK: - Defaults

    /// Every shortcut ships unbound by default. Users opt-in from
    /// Settings → Hotkeys. App Intent / Shortcuts triggers always work
    /// regardless of whether a global hotkey is also set.
    static let defaultScreenshot      = HotkeyDescriptor.empty
    static let defaultMainHUDToggle   = HotkeyDescriptor.empty
    static let defaultCCHUDToggle     = HotkeyDescriptor.empty
}
