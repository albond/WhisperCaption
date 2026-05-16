import Foundation
import Observation

/// User-selected audio sources, persisted to UserDefaults.
///
/// - `preferredMicUID == nil`    → use the system's current default input.
/// - `preferredOutputUID == nil` → tap the system's current default output
///   (with auto-rebuild on switch — see SystemCapture).
///
/// When set to a specific UID, capture pins to that device regardless of the
/// system default until the user changes it.
@Observable
final class AudioRoutingSettings {

    private let micKey = "WhisperCaption.routing.preferredMicUID"
    private let outputKey = "WhisperCaption.routing.preferredOutputUID"

    var preferredMicUID: String? {
        didSet { persist(value: preferredMicUID, key: micKey) }
    }

    var preferredOutputUID: String? {
        didSet { persist(value: preferredOutputUID, key: outputKey) }
    }

    init() {
        self.preferredMicUID    = UserDefaults.standard.string(forKey: micKey)
        self.preferredOutputUID = UserDefaults.standard.string(forKey: outputKey)
    }

    private func persist(value: String?, key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
