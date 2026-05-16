import Foundation
import OSLog

/// Persists chat sessions on disk and exposes an @Observable index so
/// Settings and the main-window picker react when sessions are created,
/// updated or deleted.
///
/// Layout (under `~/Library/Application Support/WhisperCaption/Chats/`):
///   2026-05-12-14-30-22/
///     session.json
///     images/
///       <uuid>.png
///       <uuid>.png
///
/// Why split text from PNGs: a single session can include 30+ screenshots
/// at ~1–5 MB each; base64-inlining them inside the JSON pushes file sizes
/// well past 100 MB and breaks the "user can read this with TextEdit" goal.
@MainActor
@Observable
final class ChatHistoryStore {

    /// Lightweight row shown by the Settings list and the TopBar picker.
    /// Doesn't carry caption bodies — those are loaded on demand by
    /// `load(id:)` when the user actually opens the chat.
    struct SessionMeta: Identifiable, Hashable, Sendable {
        let id: String
        let createdAt: Date
        let updatedAt: Date
        let captionCount: Int
        let screenshotCount: Int
        let onDiskBytes: Int64

        var displayName: String { id }
    }

    /// Sorted newest-first. SwiftUI observes this — mutate only on
    /// MainActor via `refreshIndex()`.
    private(set) var index: [SessionMeta] = []

    /// Root folder containing every `<id>/` session sub-folder.
    let directory: URL

    private let log = Log.ChatHistoryStore

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        directory = appSupport.appendingPathComponent("WhisperCaption/Chats", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        refreshIndex()
    }

    /// Test- and fixture-friendly initialiser. Points the store at an
    /// arbitrary directory instead of Application Support, so test
    /// scaffolding can build a clean history root per run and UI tests
    /// can seed a temp folder with prebuilt sessions + screenshots.
    /// Production code does not call this — the `init()` overload resolves
    /// the canonical Application Support path.
    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        refreshIndex()
    }

    // MARK: - URLs

    /// Folder URL for the given session id.
    func sessionFolderURL(for id: String) -> URL {
        directory.appendingPathComponent(id, isDirectory: true)
    }

    private func sessionJSONURL(for id: String) -> URL {
        sessionFolderURL(for: id).appendingPathComponent("session.json")
    }

    /// `images/` sub-folder for the given session.
    func imagesFolderURL(for id: String) -> URL {
        sessionFolderURL(for: id).appendingPathComponent("images", isDirectory: true)
    }

    /// Convenience: image store scoped to the session.
    func imageStore(forSessionID id: String) -> ChatImageStore {
        let folder = imagesFolderURL(for: id)
        return ChatImageStore(imagesFolder: folder)
    }

    // MARK: - Index

    /// Rebuilds `index` from disk. Cheap: decodes only the captions array
    /// of each `session.json` to count entries; doesn't slurp PNG bytes.
    func refreshIndex() {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var metas: [SessionMeta] = []
        let decoder = Self.makeDecoder()

        for folder in items {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            let jsonURL = folder.appendingPathComponent("session.json")
            guard let data = try? Data(contentsOf: jsonURL),
                  let session = try? decoder.decode(ChatSession.self, from: data) else {
                continue
            }
            let jsonSize = (try? jsonURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) } ?? 0
            let imgFolder = folder.appendingPathComponent("images")
            let imgSize = Self.folderByteSize(at: imgFolder)
            let pngCount = (try? FileManager.default.contentsOfDirectory(atPath: imgFolder.path))?
                .filter { $0.hasSuffix(".png") }
                .count ?? 0

            metas.append(SessionMeta(
                id: session.id,
                createdAt: session.createdAt,
                updatedAt: session.updatedAt,
                captionCount: session.captions.count,
                screenshotCount: pngCount,
                onDiskBytes: jsonSize + imgSize
            ))
        }
        index = metas.sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: - CRUD

    /// Loads a full session. PNG bytes are NOT loaded eagerly — UI code
    /// reads them on demand through `ChatImageStore`.
    func load(id: String) -> ChatSession? {
        let url = sessionJSONURL(for: id)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let session = try? Self.makeDecoder().decode(ChatSession.self, from: data) else {
            log.error("failed to decode chat session at \(url.path, privacy: .public)")
            return nil
        }
        return session
    }

    /// Atomically writes `session.json`. PNG payloads are written by
    /// `ChatImageStore` at the moment the caption is created — this method
    /// doesn't touch the images folder.
    func save(_ session: ChatSession) {
        let folder = sessionFolderURL(for: session.id)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = sessionJSONURL(for: session.id)
        do {
            let data = try Self.makeEncoder().encode(session)
            try data.write(to: url, options: .atomic)
        } catch {
            log.error("failed to write chat session \(session.id, privacy: .public): \(String(describing: error), privacy: .public)")
            return
        }
        refreshIndex()
    }

    /// Removes the entire session folder (JSON + images/). Idempotent:
    /// calling on an unknown id is a no-op.
    func delete(id: String) {
        let folder = sessionFolderURL(for: id)
        try? FileManager.default.removeItem(at: folder)
        refreshIndex()
    }

    // MARK: - IDs

    /// Picks an unused id derived from `date`. The base form is
    /// `yyyy-MM-dd-HH-mm-ss`; if a folder with that name already exists
    /// (rapid double-press of "New chat") `-1`, `-2`, … are appended
    /// until we find a free slot.
    func newSessionID(at date: Date = Date()) -> String {
        let base = ChatSession.idFormatter.string(from: date)
        var candidate = base
        var suffix = 1
        while FileManager.default.fileExists(atPath: sessionFolderURL(for: candidate).path) {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }
        return candidate
    }

    /// True if a session with that id exists on disk.
    func exists(id: String) -> Bool {
        FileManager.default.fileExists(atPath: sessionJSONURL(for: id).path)
    }

    // MARK: - Internals

    private static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// Sum of all file sizes inside `folder`. Returns 0 if the folder
    /// doesn't exist. Non-recursive — the images folder is one level deep
    /// by design.
    private static func folderByteSize(at folder: URL) -> Int64 {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        return entries.reduce(into: Int64(0)) { sum, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) } ?? 0
            sum += size
        }
    }
}
