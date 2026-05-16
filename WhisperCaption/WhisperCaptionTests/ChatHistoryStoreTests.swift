import Foundation
import Testing
@testable import WhisperCaption

/// Behaviour tests for `ChatHistoryStore`. Every test uses `TempHistory` to
/// point the store at a fresh temp directory, so test runs are hermetic and
/// never touch the user's real Application Support folder.
@MainActor
@Suite("ChatHistoryStore")
struct ChatHistoryStoreTests {

    // MARK: - Save / load

    @Test("Save and reload roundtrip preserves every caption field")
    func roundtripPreservesCaptionFields() throws {
        let temp = try TempHistory.make()
        defer { temp.cleanup() }

        let startedAt = Date(timeIntervalSinceReferenceDate: 100)
        let updatedAt = Date(timeIntervalSinceReferenceDate: 101)
        let captionID = UUID()
        let caption = Caption(
            id: captionID,
            source: .system,
            text: "hello, captions",
            language: .en,
            isFinal: true,
            startedAt: startedAt,
            updatedAt: updatedAt,
            imageFilename: "abc.png",
            translation: "hola, captions",
            translationLanguage: .es
        )

        var session = ChatSession(id: "roundtrip-1", createdAt: startedAt)
        session.captions = [caption]
        temp.store.save(session)

        let reloaded = try #require(temp.store.load(id: "roundtrip-1"))
        #expect(reloaded.id == session.id)
        #expect(reloaded.captions.count == 1)

        let got = reloaded.captions[0]
        #expect(got.id == captionID)
        #expect(got.source == .system)
        #expect(got.text == "hello, captions")
        #expect(got.language == .en)
        #expect(got.isFinal)
        #expect(got.startedAt == startedAt)
        #expect(got.updatedAt == updatedAt)
        #expect(got.imageFilename == "abc.png")
        #expect(got.translation == "hola, captions")
        #expect(got.translationLanguage == .es)
    }

    // MARK: - Index

    @Test("Empty store has empty index")
    func emptyStoreHasEmptyIndex() throws {
        let temp = try TempHistory.make()
        defer { temp.cleanup() }
        #expect(temp.store.index.isEmpty)
    }

    @Test("Index is sorted newest first")
    func indexSortedNewestFirst() throws {
        let temp = try TempHistory.make()
        defer { temp.cleanup() }

        let d1 = Date(timeIntervalSinceReferenceDate: 1_000)
        let d2 = Date(timeIntervalSinceReferenceDate: 2_000)
        let d3 = Date(timeIntervalSinceReferenceDate: 3_000)

        // Save in an out-of-order sequence to prove the index sorts, not just
        // preserves insertion order.
        temp.store.save(ChatSession(id: "session-mid", createdAt: d2))
        temp.store.save(ChatSession(id: "session-old", createdAt: d1))
        temp.store.save(ChatSession(id: "session-new", createdAt: d3))

        let ids = temp.store.index.map(\.id)
        #expect(ids == ["session-new", "session-mid", "session-old"])
    }

    @Test("SessionMeta.captionCount matches the underlying session")
    func indexCountsCaptionsCorrectly() throws {
        let temp = try TempHistory.make()
        defer { temp.cleanup() }

        let a = CaptionFixtures.session(id: "session-a", captionCount: 3)
        let b = CaptionFixtures.session(id: "session-b", captionCount: 7)
        temp.store.save(a)
        temp.store.save(b)

        let metaA = try #require(temp.store.index.first { $0.id == "session-a" })
        let metaB = try #require(temp.store.index.first { $0.id == "session-b" })
        #expect(metaA.captionCount == 3)
        #expect(metaB.captionCount == 7)
    }

    // MARK: - IDs

    @Test("newSessionID(at:) avoids collision with an existing folder")
    func newSessionIDIsCollisionResistant() throws {
        let temp = try TempHistory.make()
        defer { temp.cleanup() }

        let date = Date(timeIntervalSinceReferenceDate: 0)
        let base = ChatSession.idFormatter.string(from: date)
        let baseFolder = temp.store.sessionFolderURL(for: base)
        try FileManager.default.createDirectory(at: baseFolder, withIntermediateDirectories: true)

        let next = temp.store.newSessionID(at: date)
        #expect(next == "\(base)-1")
    }

    @Test("exists(id:) returns true only after a save")
    func existsReturnsTrueOnlyAfterSave() throws {
        let temp = try TempHistory.make()
        defer { temp.cleanup() }

        #expect(!temp.store.exists(id: "ghost"))

        let session = ChatSession(id: "ghost")
        temp.store.save(session)
        #expect(temp.store.exists(id: "ghost"))
    }

    // MARK: - Deletion

    @Test("delete(id:) removes the entire folder and prunes the index")
    func deleteRemovesFolderAndPrunesIndex() throws {
        let temp = try TempHistory.make()
        defer { temp.cleanup() }

        let session = ChatSession(id: "doomed", createdAt: Date(timeIntervalSinceReferenceDate: 0))
        temp.store.save(session)
        let folder = temp.store.sessionFolderURL(for: "doomed")
        #expect(FileManager.default.fileExists(atPath: folder.path))

        temp.store.delete(id: "doomed")
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(temp.store.index.allSatisfy { $0.id != "doomed" })
    }

    @Test("delete(id:) on unknown id is a no-op")
    func deleteUnknownIsNoOp() throws {
        let temp = try TempHistory.make()
        defer { temp.cleanup() }

        // No throw expected — and the index should remain empty afterwards.
        temp.store.delete(id: "does-not-exist")
        #expect(temp.store.index.isEmpty)
    }

    // MARK: - Atomic write

    @Test("Atomic save under rapid mutation keeps the file readable")
    func atomicSaveSurvivesRapidMutation() throws {
        let temp = try TempHistory.make()
        defer { temp.cleanup() }

        var session = ChatSession(id: "rapid", createdAt: Date(timeIntervalSinceReferenceDate: 0))
        for i in 0..<50 {
            session.updatedAt = Date(timeIntervalSinceReferenceDate: TimeInterval(i))
            session.captions.append(CaptionFixtures.caption(text: "caption #\(i)"))
            temp.store.save(session)
            let reloaded = try #require(temp.store.load(id: "rapid"))
            #expect(reloaded.captions.count == i + 1)
            #expect(reloaded.captions.last?.text == "caption #\(i)")
        }
    }

    // MARK: - Image store factory

    @Test("imageStore(forSessionID:) points at <session>/images")
    func imageStoreForSessionIDIsScoped() throws {
        let temp = try TempHistory.make()
        defer { temp.cleanup() }

        let sessionID = "image-host"
        temp.store.save(ChatSession(id: sessionID))

        let images = temp.store.imageStore(forSessionID: sessionID)
        let filename = try images.save(pngData: CaptionFixtures.tinyPNG)

        let expected = temp.store.imagesFolderURL(for: sessionID).appendingPathComponent(filename)
        #expect(FileManager.default.fileExists(atPath: expected.path))
    }

    // MARK: - Forward-compat decode

    @Test("Forward-compat decode tolerates missing optional fields")
    func forwardCompatDecodeMissingOptionalFields() throws {
        let temp = try TempHistory.make()
        defer { temp.cleanup() }

        // Hand-written JSON missing translation, translationLanguage and
        // imageFilename — these all use decodeIfPresent so the decode
        // should still succeed.
        let sessionID = "legacy-session"
        let folder = temp.store.sessionFolderURL(for: sessionID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let json = """
        {
          "id": "\(sessionID)",
          "createdAt": "2026-01-01T00:00:00Z",
          "updatedAt": "2026-01-01T00:00:00Z",
          "captions": [
            {
              "id": "1A1A1A1A-2B2B-3C3C-4D4D-5E5E5E5E5E5E",
              "source": "microphone",
              "text": "legacy caption",
              "isFinal": true,
              "startedAt": "2026-01-01T00:00:00Z",
              "updatedAt": "2026-01-01T00:00:00Z"
            }
          ]
        }
        """
        try json.write(
            to: folder.appendingPathComponent("session.json"),
            atomically: true,
            encoding: .utf8
        )

        let reloaded = try #require(temp.store.load(id: sessionID))
        let caption = try #require(reloaded.captions.first)
        #expect(caption.translation == nil)
        #expect(caption.translationLanguage == nil)
        #expect(caption.imageFilename == nil)
        #expect(caption.language == nil)
    }

    // MARK: - On-disk bytes

    @Test("SessionMeta.onDiskBytes sums JSON plus PNGs")
    func onDiskBytesSumsJSONAndPNGs() throws {
        let temp = try TempHistory.make()
        defer { temp.cleanup() }

        let sessionID = "weight-watch"
        var session = ChatSession(id: sessionID, createdAt: Date(timeIntervalSinceReferenceDate: 0))
        session.captions = [CaptionFixtures.caption(text: "hello")]
        temp.store.save(session)

        let images = temp.store.imageStore(forSessionID: sessionID)
        let png = CaptionFixtures.makeColoredPNG(side: 32)
        _ = try images.save(pngData: png)

        // Bump updatedAt to force re-index after the PNG hit disk.
        temp.store.save(session)

        let meta = try #require(temp.store.index.first { $0.id == sessionID })
        let jsonURL = temp.store.sessionFolderURL(for: sessionID).appendingPathComponent("session.json")
        let jsonSize = try #require(try jsonURL.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        #expect(meta.onDiskBytes >= Int64(jsonSize + png.count))
    }

    // MARK: - Corruption tolerance

    @Test("refreshIndex() silently skips a corrupted session.json")
    func refreshIndexSurvivesCorruptedSession() throws {
        let temp = try TempHistory.make()
        defer { temp.cleanup() }

        // One healthy session that should appear in the index.
        let healthy = ChatSession(id: "healthy", createdAt: Date(timeIntervalSinceReferenceDate: 1_000))
        temp.store.save(healthy)

        // One folder with garbage instead of valid JSON.
        let badFolder = temp.store.sessionFolderURL(for: "broken")
        try FileManager.default.createDirectory(at: badFolder, withIntermediateDirectories: true)
        try "garbage".write(
            to: badFolder.appendingPathComponent("session.json"),
            atomically: true,
            encoding: .utf8
        )

        temp.store.refreshIndex()

        let ids = temp.store.index.map(\.id)
        #expect(ids.contains("healthy"))
        #expect(!ids.contains("broken"))
    }
}
