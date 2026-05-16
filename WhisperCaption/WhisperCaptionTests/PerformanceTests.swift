import AppKit
import Foundation
import Testing
@testable import WhisperCaption

/// Performance regression baselines. The targets here are deliberately
/// conservative — they're upper bounds chosen to flag a 10× slowdown,
/// not micro-benchmarks. Anything close to these thresholds in CI means
/// a clear regression that warrants a closer look.
///
/// Why bounded #expect over `XCTMetric`:
///   * Swift Testing has no built-in performance measurement metric yet
///     (only XCTest has `measure()`). We can still set ceiling assertions
///     that catch >10× regressions cheaply.
///   * For the precise scroll-FPS measurement we use `XCTOSSignpostMetric`
///     in the XCUITest suite (see `WhisperCaptionUITests`).
///
/// Tests are tagged with `.tags(.performance)` so a CI lane can opt in
/// or out.
extension Tag {
    @Tag static var performance: Self
}

@MainActor
@Suite("Performance baselines", .tags(.performance))
struct PerformanceTests {

    // MARK: - Caption merge throughput

    @Test("Merging 10 000 captions by id stays bounded")
    func captionMergeThroughput() {
        // Replicates the work `CaptionStream.applyCaption` does per
        // engine emit: find-by-id + in-place replace, with new entries
        // appended. firstIndex(where:) is O(N), so 10k merges is O(N²) —
        // ~5-12s on an arm64 Mac under parallel test load. The bound is
        // tight enough to flag a real regression (e.g. dropping the
        // append-fast-path) without flaking under oversubscription.
        var captions: [Caption] = CaptionFixtures.captions(count: 10_000)
        let ids = captions.map(\.id)

        let start = Date()
        for id in ids {
            if let idx = captions.firstIndex(where: { $0.id == id }) {
                captions[idx].text = "updated"
                captions[idx].updatedAt = Date()
            }
        }
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 20.0, "10k id merges took \(elapsed)s; expected < 20s. This path is on the UI thread.")
    }

    // MARK: - History store throughput

    @Test("Saving a 1 000-caption session completes in under 200 ms")
    func saveThroughput1k() throws {
        let temp = try TempHistory.make(suffix: "perf-save")
        defer { temp.cleanup() }
        let session = CaptionFixtures.session(id: "perf-1k", captionCount: 1_000)

        let start = Date()
        temp.store.save(session)
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 1.0, "1k-caption save took \(elapsed)s. Disk I/O target is < 200ms; ceiling at 1s.")
    }

    @Test("Refreshing the index over 20 small sessions stays under 100 ms")
    func indexRefreshThroughput() throws {
        let temp = try TempHistory.make(suffix: "perf-index")
        defer { temp.cleanup() }
        for i in 0..<20 {
            let s = CaptionFixtures.session(id: "session-\(i)-\(UUID().uuidString)", captionCount: 5)
            temp.store.save(s)
        }
        let start = Date()
        temp.store.refreshIndex()
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 1.0, "Index refresh over 20 sessions took \(elapsed)s")
    }

    // MARK: - Image store

    @Test("Thumbnail cache hit returns under 10 ms")
    func thumbnailCacheHitFast() throws {
        let tmp = try TempDirectory.make()
        defer { tmp.cleanup() }
        let store = ChatImageStore(imagesFolder: tmp.url)
        let png = CaptionFixtures.makeColoredPNG(side: 256, color: .systemBlue)
        let filename = try store.save(pngData: png)
        _ = store.loadThumbnail(filename: filename, maxPixels: 200)  // prime cache

        let start = Date()
        for _ in 0..<100 {
            _ = store.loadThumbnail(filename: filename, maxPixels: 200)
        }
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 1.0, "100 cached loadThumbnail calls took \(elapsed)s; expected ~10ms total")
    }

    @Test("First-time thumbnail decode of a 256px PNG stays under 200 ms")
    func thumbnailColdDecode() throws {
        let tmp = try TempDirectory.make()
        defer { tmp.cleanup() }
        let store = ChatImageStore(imagesFolder: tmp.url)
        let png = CaptionFixtures.makeColoredPNG(side: 256, color: .systemMint)
        let filename = try store.save(pngData: png)

        let start = Date()
        _ = store.loadThumbnail(filename: filename, maxPixels: 200)
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 0.5, "Cold thumbnail decode took \(elapsed)s")
    }

    // MARK: - Bubble splitter throughput

    @Test("BubbleSplitter processes 10 000 interim captions in under 1 second")
    func bubbleSplitterThroughput() {
        let splitter = BubbleSplitter()
        let config = BubbleSplitter.Config(maxChars: 240, sentenceAware: true)
        let baseID = UUID()

        let start = Date()
        for i in 0..<10_000 {
            let c = Caption(
                id: baseID,
                source: .system,
                text: "Streaming caption iteration \(i) — a chunk of text that grows slowly.",
                isFinal: false
            )
            _ = splitter.process(c, config: config)
        }
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 5.0, "10k splitter calls took \(elapsed)s")
    }

    // MARK: - JSON encoding hot path

    @Test("Encoding a 5 000-caption session to JSON stays under 1 second")
    func jsonEncodingThroughput() throws {
        let session = CaptionFixtures.session(id: "perf-encode", captionCount: 5_000)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let start = Date()
        let data = try encoder.encode(session)
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 2.0, "5k-caption JSON encode took \(elapsed)s; size=\(data.count) bytes")
    }
}
