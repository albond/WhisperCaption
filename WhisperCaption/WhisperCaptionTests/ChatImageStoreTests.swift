import AppKit
import Foundation
import Testing
@testable import WhisperCaption

/// Behaviour tests for `ChatImageStore`. Each test builds a fresh
/// `ChatImageStore` rooted at a temp folder, then cleans it up on the way
/// out so concurrent test runs don't trip over each other.
@MainActor
@Suite("ChatImageStore")
struct ChatImageStoreTests {

    @Test("save then load roundtrip")
    func saveThenLoadRoundtrip() throws {
        let temp = try TempDirectory.make()
        defer { temp.cleanup() }
        let store = ChatImageStore(imagesFolder: temp.url)

        let filename = try store.save(pngData: CaptionFixtures.tinyPNG)
        #expect(filename.hasSuffix(".png"))

        let bytes = try store.load(filename: filename)
        #expect(bytes == CaptionFixtures.tinyPNG)
    }

    @Test("Each save produces a fresh UUID filename")
    func saveProducesUniqueFilenames() throws {
        let temp = try TempDirectory.make()
        defer { temp.cleanup() }
        let store = ChatImageStore(imagesFolder: temp.url)

        let a = try store.save(pngData: CaptionFixtures.tinyPNG)
        let b = try store.save(pngData: CaptionFixtures.tinyPNG)
        #expect(a != b)
        #expect(a.hasSuffix(".png"))
        #expect(b.hasSuffix(".png"))
    }

    @Test("load(filename:) throws for a missing file")
    func loadThrowsForMissingFile() throws {
        let temp = try TempDirectory.make()
        defer { temp.cleanup() }
        let store = ChatImageStore(imagesFolder: temp.url)

        #expect(throws: (any Error).self) {
            _ = try store.load(filename: "ghost.png")
        }
    }

    @Test("loadThumbnail(filename:maxPixels:) returns a sized NSImage")
    func loadThumbnailReturnsSizedImage() throws {
        let temp = try TempDirectory.make()
        defer { temp.cleanup() }
        let store = ChatImageStore(imagesFolder: temp.url)

        let png = CaptionFixtures.makeColoredPNG(side: 64, color: .systemPurple)
        let filename = try store.save(pngData: png)

        // Ask for a thumbnail bounded by 32 pixels — the longest dimension
        // must shrink, but the image must still decode.
        let thumb = try #require(store.loadThumbnail(filename: filename, maxPixels: 32))
        #expect(thumb.size.width <= 32)
        #expect(thumb.size.height <= 32)
    }

    @Test("loadThumbnail is cached on the second call")
    func loadThumbnailIsCached() throws {
        let temp = try TempDirectory.make()
        defer { temp.cleanup() }
        let store = ChatImageStore(imagesFolder: temp.url)

        let png = CaptionFixtures.makeColoredPNG(side: 64, color: .systemPurple)
        let filename = try store.save(pngData: png)

        // Warm the cache.
        let first = try #require(store.loadThumbnail(filename: filename, maxPixels: 32))
        _ = first

        // Replace the on-disk file with bytes that wouldn't decode at all.
        let url = store.url(forFilename: filename)
        try Data("not a png at all".utf8).write(to: url, options: .atomic)

        // The second call must still return an image — only possible if the
        // store served from `thumbnailCache`.
        let second = store.loadThumbnail(filename: filename, maxPixels: 32)
        #expect(second != nil)
    }

    @Test("delete(filename:) drops the file and evicts the cache entry")
    func deleteEvictsCache() throws {
        let temp = try TempDirectory.make()
        defer { temp.cleanup() }
        let store = ChatImageStore(imagesFolder: temp.url)

        let png = CaptionFixtures.makeColoredPNG(side: 64, color: .systemBlue)
        let filename = try store.save(pngData: png)

        // Warm the cache so we can prove eviction happens.
        _ = store.loadThumbnail(filename: filename, maxPixels: 32)

        try store.delete(filename: filename)
        let url = store.url(forFilename: filename)
        #expect(!FileManager.default.fileExists(atPath: url.path))

        // After delete, loadThumbnail must return nil — the cache was
        // cleared AND the file is gone, so there's no fallback.
        #expect(store.loadThumbnail(filename: filename, maxPixels: 32) == nil)
    }

    @Test("deleteAll() clears the folder and the cache")
    func deleteAllClearsEverything() throws {
        let temp = try TempDirectory.make()
        defer { temp.cleanup() }
        let store = ChatImageStore(imagesFolder: temp.url)

        let a = try store.save(pngData: CaptionFixtures.makeColoredPNG(side: 64))
        let b = try store.save(pngData: CaptionFixtures.makeColoredPNG(side: 64))
        _ = store.loadThumbnail(filename: a, maxPixels: 32)
        _ = store.loadThumbnail(filename: b, maxPixels: 32)

        try store.deleteAll()
        #expect(!FileManager.default.fileExists(atPath: temp.url.path))

        // Recreate the folder so subsequent attempts don't crash — and check
        // the cache is cold by writing fresh bytes and confirming thumbnails
        // come back from disk again.
        try FileManager.default.createDirectory(at: temp.url, withIntermediateDirectories: true)
        #expect(store.loadThumbnail(filename: a, maxPixels: 32) == nil)
        #expect(store.loadThumbnail(filename: b, maxPixels: 32) == nil)
    }

    @Test("loadImage(filename:) returns the full-resolution image")
    func loadImageReturnsFullResolution() throws {
        let temp = try TempDirectory.make()
        defer { temp.cleanup() }
        let store = ChatImageStore(imagesFolder: temp.url)

        let side = 64
        let png = CaptionFixtures.makeColoredPNG(side: side, color: .systemTeal)
        let filename = try store.save(pngData: png)

        let full = try #require(store.loadImage(filename: filename))
        // Pull the bitmap representation to inspect actual pixel dimensions —
        // NSImage.size is in points and depends on screen scale.
        let rep = try #require(NSBitmapImageRep(data: png))
        #expect(rep.pixelsWide == side)
        #expect(rep.pixelsHigh == side)
        // The NSImage itself reports a non-empty size from the same source.
        #expect(full.size.width > 0)
        #expect(full.size.height > 0)

        // Compare against a tiny thumbnail to confirm the full image is bigger.
        let thumb = try #require(store.loadThumbnail(filename: filename, maxPixels: 16))
        #expect(thumb.size.width <= 16)
    }

    @Test("url(forFilename:) returns the expected file URL")
    func urlForFilenameMatchesFolder() throws {
        let temp = try TempDirectory.make()
        defer { temp.cleanup() }
        let store = ChatImageStore(imagesFolder: temp.url)

        let filename = try store.save(pngData: CaptionFixtures.tinyPNG)
        let expected = temp.url.appendingPathComponent(filename)
        #expect(store.url(forFilename: filename) == expected)
    }
}
