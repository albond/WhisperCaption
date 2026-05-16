import Foundation
import OSLog

/// Centralised OSLog entry points. Add a category here before logging from a new module —
/// keeping all subsystem strings in one file prevents accidental drift.
///
/// `nonisolated` so any actor, capture callback, or background task can read
/// these without hopping to the main actor.
nonisolated enum Log {
    static let subsystem = "com.albond.WhisperCaption"

    static let MicCapture = Logger(subsystem: subsystem, category: "MicCapture")
    static let SystemCapture = Logger(subsystem: subsystem, category: "SystemCapture")
    static let WhisperEngine = Logger(subsystem: subsystem, category: "WhisperEngine")
    static let DeepgramEngine = Logger(subsystem: subsystem, category: "DeepgramEngine")
    static let ElevenLabsEngine = Logger(subsystem: subsystem, category: "ElevenLabsEngine")
    static let CaptionStream = Logger(subsystem: subsystem, category: "CaptionStream")
    static let HotkeyManager = Logger(subsystem: subsystem, category: "HotkeyManager")
    static let ScreenshotCapture = Logger(subsystem: subsystem, category: "ScreenshotCapture")
    static let ChatHistoryStore = Logger(subsystem: subsystem, category: "ChatHistoryStore")
    static let ChatImageStore = Logger(subsystem: subsystem, category: "ChatImageStore")
    static let CaptionTranslator = Logger(subsystem: subsystem, category: "CaptionTranslator")
    static let HUD = Logger(subsystem: subsystem, category: "HUD")
    static let Permissions = Logger(subsystem: subsystem, category: "Permissions")
    static let Settings = Logger(subsystem: subsystem, category: "Settings")
    static let App = Logger(subsystem: subsystem, category: "App")
}
