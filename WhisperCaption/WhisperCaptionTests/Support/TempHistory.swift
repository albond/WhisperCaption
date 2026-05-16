import Foundation
@testable import WhisperCaption

/// Builds a `ChatHistoryStore` rooted at a fresh temp directory per test,
/// so concurrent test runs (and parallel test cases) don't fight over
/// the user's real Application Support folder.
///
/// Usage:
///     let temp = try TempHistory.make()
///     defer { temp.cleanup() }
///     let store = temp.store
///
/// The directory is removed by `cleanup()` — call it from a `defer` block
/// so it runs even if the test throws.
@MainActor
struct TempHistory {
    let directory: URL
    let store: ChatHistoryStore

    static func make(suffix: String = "history") throws -> TempHistory {
        let base = FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("WhisperCaptionTest-\(suffix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = ChatHistoryStore(directory: dir)
        return TempHistory(directory: dir, store: store)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Builds a fresh temp directory not tied to any store — used by tests
/// that exercise `ChatImageStore` in isolation.
struct TempDirectory {
    let url: URL

    static func make(suffix: String = "images") throws -> TempDirectory {
        let base = FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("WhisperCaptionTest-\(suffix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return TempDirectory(url: dir)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: url)
    }
}
