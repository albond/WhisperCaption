import Foundation
import OSLog
import AppKit
import UniformTypeIdentifiers

/// Exports a `ChatSession` as a self-contained ZIP archive that the user
/// can hand off to a colleague, post to a notes app, or archive on disk.
///
/// Archive layout (one ZIP per session):
///
///     <session-id>.zip
///     └── <session-id>/
///         ├── chat.md         ← human-readable transcript, Markdown
///         └── media/
///             ├── <filename>.png
///             └── …
///
/// The Markdown links to the screenshots via relative paths
/// (`media/<filename>.png`), so opening the unzipped folder in any
/// Markdown viewer (Obsidian, Typora, GitHub preview, VS Code) renders
/// the chat with inline screenshots out of the box.
///
/// ZIPping uses `NSFileCoordinator.coordinate(readingItemAt:options:.forUploading)`,
/// the same Foundation primitive AirDrop / Share extensions use to bundle
/// a folder into a single transferable file — no third-party zip
/// dependency, works under sandbox.
@MainActor
enum ChatExporter {

    private static let log = Log.ChatHistoryStore

    // MARK: - Public API

    /// Material for one session — the session record plus the image store
    /// it was loaded from (so we can re-read PNG bytes from disk).
    struct Payload {
        let session: ChatSession
        let imageStore: ChatImageStore
    }

    /// Bundles the given session into a temporary ZIP, then copies the ZIP
    /// to `destination`. Overwrites if `destination` already exists.
    static func export(_ payload: Payload, to destination: URL) throws {
        let temp = try makeStagingDirectory(sessionID: payload.session.id)
        defer { try? FileManager.default.removeItem(at: temp.root) }

        try writeMarkdown(payload.session, to: temp.markdownURL)
        try writeMedia(payload.session, imageStore: payload.imageStore, to: temp.mediaURL)
        try zipFolder(temp.bundle, to: destination)
        log.info("exported chat \(payload.session.id, privacy: .public) → \(destination.path, privacy: .public)")
    }

    /// Best-effort batch export. Each session is bundled separately and
    /// written into `directory` as `<session-id>.zip`. Returns the list of
    /// URLs that succeeded.
    @discardableResult
    static func exportAll(_ payloads: [Payload], into directory: URL) -> [URL] {
        var written: [URL] = []
        for payload in payloads {
            let dest = directory.appendingPathComponent("\(payload.session.id).zip")
            do {
                try export(payload, to: dest)
                written.append(dest)
            } catch {
                log.error("failed to export \(payload.session.id, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        return written
    }

    // MARK: - UI entry point

    /// Run the export flow: ask the user where to save, write the
    /// archive(s), reveal the result in Finder when done. Designed to be
    /// fired from a SwiftUI Button — does its own NSSavePanel / NSOpenPanel
    /// modal.
    static func run(payloads: [Payload]) {
        guard !payloads.isEmpty else { return }

        if payloads.count == 1, let payload = payloads.first {
            promptSingle(payload: payload)
        } else {
            promptBatch(payloads: payloads)
        }
    }

    private static func promptSingle(payload: Payload) {
        let panel = NSSavePanel()
        panel.title = "Save Chat"
        panel.nameFieldStringValue = "\(payload.session.id).zip"
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try export(payload, to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            presentError(error, sessionID: payload.session.id)
        }
    }

    private static func promptBatch(payloads: [Payload]) {
        let panel = NSOpenPanel()
        panel.title = "Save Chats"
        panel.message = "Choose a folder — one ZIP per chat will be written into it."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Save Here"
        guard panel.runModal() == .OK, let dir = panel.url else { return }

        let written = exportAll(payloads, into: dir)
        if let first = written.first {
            NSWorkspace.shared.activateFileViewerSelecting([first])
        }
    }

    // MARK: - Staging directory

    /// Directory tree used while assembling one ZIP.
    /// - `root`   — temp folder we own and clean up.
    /// - `bundle` — `root/<session-id>/` (the folder we actually zip).
    /// - `markdownURL`/`mediaURL` — `chat.md` and `media/` inside bundle.
    private struct Staging {
        let root: URL
        let bundle: URL
        let markdownURL: URL
        let mediaURL: URL
    }

    private static func makeStagingDirectory(sessionID: String) throws -> Staging {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("whispercaption-export-\(UUID().uuidString)", isDirectory: true)
        let bundle = root.appendingPathComponent(sessionID, isDirectory: true)
        let media = bundle.appendingPathComponent("media", isDirectory: true)

        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        return Staging(
            root: root,
            bundle: bundle,
            markdownURL: bundle.appendingPathComponent("chat.md"),
            mediaURL: media
        )
    }

    // MARK: - Markdown

    private static func writeMarkdown(_ session: ChatSession, to url: URL) throws {
        let md = markdown(for: session)
        try md.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Public so unit tests / previews can render without touching disk.
    static func markdown(for session: ChatSession) -> String {
        var out = ""

        // Header
        out += "# \(session.id)\n\n"
        out += "**Created:** \(formatLong(session.createdAt))  \n"
        out += "**Updated:** \(formatLong(session.updatedAt))  \n"
        out += "**Messages:** \(session.captions.count)\n\n"
        out += "---\n\n"

        // Chronological pass — same order the UI shows captions.
        let ordered = session.captions.sorted { $0.startedAt < $1.startedAt }
        for caption in ordered {
            out += renderCaption(caption)
            out += "\n"
        }
        return out
    }

    /// One bubble → a short headed section in the transcript. Examples:
    ///
    ///     ### 14:32:05 · System audio (RU)
    ///     Hello, how are you?
    ///
    ///     ### 14:32:11 · Screenshot
    ///     ![Snapshot · Studio Display · 12:56:43](media/<filename>.png)
    private static func renderCaption(_ caption: Caption) -> String {
        let time = formatTime(caption.startedAt)
        let sourceLabel = sourceLabel(for: caption)
        let langSuffix: String
        if let lang = caption.language {
            langSuffix = " (\(lang.badge))"
        } else {
            langSuffix = ""
        }

        var body = "### \(time) · \(sourceLabel)\(langSuffix)\n\n"

        if let filename = caption.imageFilename {
            let alt = escapeAlt(caption.text)
            body += "![\(alt)](media/\(filename))\n\n"
            // Repeat the caption label below the image — Markdown viewers
            // don't always render alt-text, and the label often carries
            // the screenshot timestamp / display name.
            if !caption.text.isEmpty {
                body += "_\(escapeInline(caption.text))_\n\n"
            }
        } else {
            body += escapeInline(caption.text) + "\n\n"
        }

        return body
    }

    private static func sourceLabel(for caption: Caption) -> String {
        if caption.imageFilename != nil {
            return "Screenshot"
        }
        switch caption.source {
        case .microphone: return "Microphone"
        case .system:     return "System audio"
        }
    }

    private static func escapeInline(_ s: String) -> String {
        // Minimal escaping — we keep newlines and most punctuation as the
        // user spoke them. Just neutralise the characters that would
        // otherwise turn into Markdown formatting commands at line start.
        s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
    }

    private static func escapeAlt(_ s: String) -> String {
        s
            .replacingOccurrences(of: "[", with: "(")
            .replacingOccurrences(of: "]", with: ")")
    }

    // MARK: - Media

    private static func writeMedia(_ session: ChatSession, imageStore: ChatImageStore, to mediaFolder: URL) throws {
        for caption in session.captions {
            guard let filename = caption.imageFilename else { continue }
            let url = mediaFolder.appendingPathComponent(filename)
            do {
                let bytes = try imageStore.load(filename: filename)
                try bytes.write(to: url, options: .atomic)
            } catch {
                log.warning("export: skipped missing image \(filename, privacy: .public)")
            }
        }
    }

    // MARK: - Zipping

    /// Uses NSFileCoordinator's `.forUploading` option, which Apple
    /// documents as "the coordinator zips the directory into a temporary
    /// file and hands you the URL". The temp URL is owned by the system
    /// and only valid inside the closure — we copy it to `destination`
    /// before returning.
    private static func zipFolder(_ folder: URL, to destination: URL) throws {
        // Make sure parent exists; SavePanel takes care of that for us
        // normally, but a hand-typed path under a missing dir would fail.
        try? FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // SavePanel only confirms overwrite for files that already exist,
        // so an existing destination is fine — but FileManager.copyItem
        // throws on a clobber. Remove first.
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }

        let coordinator = NSFileCoordinator()
        var coordinatorError: NSError?
        var copyError: Error?

        coordinator.coordinate(
            readingItemAt: folder,
            options: .forUploading,
            error: &coordinatorError
        ) { zipURL in
            do {
                try FileManager.default.copyItem(at: zipURL, to: destination)
            } catch {
                copyError = error
            }
        }

        if let error = coordinatorError { throw error }
        if let error = copyError { throw error }
    }

    // MARK: - Errors

    private static func presentError(_ error: Error, sessionID: String) {
        log.error("export of \(sessionID, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        let alert = NSAlert()
        alert.messageText = "Could Not Save Chat"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Formatting

    private static func formatLong(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: date)
    }

    private static func formatTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }
}
