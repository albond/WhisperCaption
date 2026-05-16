import Foundation

/// A persisted chat = one session of the live-caption feed. Sessions are
/// identified by a human-readable timestamp string ("2026-05-12-14-30-22")
/// which doubles as the on-disk folder name, so the user can browse the
/// `~/Library/Application Support/WhisperCaption/Chats/` folder with Finder
/// and recognise each session by its creation time.
struct ChatSession: Codable, Identifiable, Sendable, Hashable {

    /// Stable identifier: timestamp formatted as `yyyy-MM-dd-HH-mm-ss`.
    /// Doubles as the on-disk folder name. If two sessions are created in
    /// the same wall-clock second `ChatHistoryStore` resolves the collision
    /// by appending `-N`.
    let id: String

    /// The moment the user pressed "New chat" (or app launched with no
    /// prior session). Immutable for the life of the session — the
    /// display name in the picker derives from this.
    let createdAt: Date

    /// Last time any caption was added or updated. Used for the "modified"
    /// column in the history editor and to break ties in the picker when
    /// `createdAt` is equal.
    var updatedAt: Date

    /// The same timeline `CaptionStream.captions` exposes. Screenshot
    /// payloads referenced by `Caption.imageFilename` live in a sibling
    /// `images/` folder on disk and are loaded via `ChatImageStore`.
    var captions: [Caption]

    init(id: String, createdAt: Date = Date(), captions: [Caption] = []) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.captions = captions
    }

    /// `yyyy-MM-dd-HH-mm-ss` formatter, POSIX locale so it's stable
    /// regardless of the user's regional settings.
    static let idFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        f.timeZone = TimeZone.current
        return f
    }()

    /// String the picker / sidebar display: equal to the id.
    var displayName: String { id }
}
