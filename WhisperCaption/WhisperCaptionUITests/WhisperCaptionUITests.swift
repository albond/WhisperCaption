import AppKit
import XCTest

/// UI / end-to-end tests. Two purposes:
///
///   * Smoke: confirm the app launches with a known fixture and the
///     Main HUD shows the expected chat content. Catches "the app
///     crashes on launch" / "permissions hang the bootstrap" regressions.
///
///   * Scroll performance: render 200 captions, ~20 of which carry
///     PNG screenshot bubbles, and measure clock + memory + CPU while
///     scrolling. The chat-with-images path is the one the user
///     specifically flagged as feeling sluggish.
///
/// Fixture mode is enabled by three launch arguments parsed in
/// `WhisperCaptionAppDelegate`:
///   * `-WCFixtureUIMode`              — force `.regular` activation policy
///                                       + `mainHUDVisible = true`
///   * `-WCFixtureHistoryDir <path>`   — redirect `ChatHistoryStore` at
///                                       the given temp folder
///   * `-WCFixtureChatID <id>`         — pre-activate that chat
///
/// The fixture (a `session.json` plus PNG files in `images/`) is built
/// in `setUpWithError` so each test gets fresh, deterministic content.
final class WhisperCaptionUITests: XCTestCase {

    private var fixtureRoot: URL!
    private let chatID = "ui-fixture-2026-05-16-12-00-00"

    /// Caption count for the loaded session. Tunable per test (subclass
    /// or override in a specific test if needed). 200 is enough to make
    /// scroll work non-trivial without ballooning launch time.
    private let captionCount = 200

    /// Insert a screenshot bubble every Nth caption.
    private let screenshotEvery = 10

    override func setUpWithError() throws {
        continueAfterFailure = false

        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperCaptionUITest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fixtureRoot = base

        try buildFixture()
    }

    override func tearDownWithError() throws {
        if let url = fixtureRoot {
            try? FileManager.default.removeItem(at: url)
        }
        // Best-effort: scrub the keys we set so the next dev launch
        // doesn't open straight to the fixture chat.
        if let d = UserDefaults(suiteName: "albond.WhisperCaption") {
            d.removeObject(forKey: "WhisperCaption.settings.activeChatID")
            d.removeObject(forKey: "WhisperCaption.settings.mainHUDVisible")
        }
    }

    // MARK: - Smoke

    @MainActor
    func testLaunchesInFixtureMode() throws {
        let app = launchInFixtureMode()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 30), "Main HUD did not appear")
        app.terminate()
    }

    @MainActor
    func testLaunchPerformance() throws {
        // `XCTApplicationLaunchMetric` measures cold launch wall time.
        // We launch in fixture mode so the bootstrap cost includes
        // loading the fixture chat from disk — the metric we actually
        // care about.
        let options = XCTMeasureOptions()
        options.iterationCount = 3

        let args = makeFixtureLaunchArguments()
        measure(metrics: [XCTApplicationLaunchMetric()], options: options) {
            let app = XCUIApplication()
            app.launchArguments = args
            app.launch()
            _ = app.windows.firstMatch.waitForExistence(timeout: 10)
            app.terminate()
        }
    }

    // MARK: - Scroll performance

    @MainActor
    func testChatScrollPerformanceWithImages() throws {
        let app = launchInFixtureMode()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 15), "Main HUD did not appear")

        let scrollView = window.scrollViews.firstMatch
        XCTAssertTrue(scrollView.waitForExistence(timeout: 5), "Chat scroll view not found")

        // Performance proxy: wall-clock time + memory pressure + CPU
        // while scrolling. The XCTOSSignpostMetric/scrollingAndDecelerationMetric
        // pair is iOS-only; on macOS these three together do a decent
        // job of flagging a regression in the scroll path.
        let options = XCTMeasureOptions()
        options.iterationCount = 3

        measure(
            metrics: [XCTClockMetric(), XCTMemoryMetric(), XCTCPUMetric()],
            options: options
        ) {
            for _ in 0..<10 {
                scrollView.scroll(byDeltaX: 0, deltaY: -300)
            }
            // Decelerate phase: also flip back to the top so subsequent
            // iterations start from the same scroll offset.
            for _ in 0..<10 {
                scrollView.scroll(byDeltaX: 0, deltaY: 300)
            }
        }

        app.terminate()
    }

    // MARK: - Fixture helpers

    private func launchInFixtureMode() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = makeFixtureLaunchArguments()
        app.launch()
        return app
    }

    private func makeFixtureLaunchArguments() -> [String] {
        [
            "-WCFixtureUIMode",
            "-WCFixtureHistoryDir", fixtureRoot.path,
            "-WCFixtureChatID", chatID
        ]
    }

    /// Write `<fixtureRoot>/<chatID>/session.json` + PNGs under
    /// `<fixtureRoot>/<chatID>/images/`. The JSON shape mirrors what
    /// `ChatHistoryStore.save(_:)` writes in production.
    private func buildFixture() throws {
        let sessionDir = fixtureRoot.appendingPathComponent(chatID, isDirectory: true)
        let imagesDir = sessionDir.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)

        let png = try makeColoredPNG(side: 256, color: .systemPurple)
        let iso = ISO8601DateFormatter()
        let baseTime = Date(timeIntervalSince1970: 1_700_000_000)

        var captions: [[String: Any]] = []
        captions.reserveCapacity(captionCount)
        for i in 0..<captionCount {
            let isSystem = (i % 2 == 0)
            let started = baseTime.addingTimeInterval(TimeInterval(i))
            let updated = started.addingTimeInterval(0.4)
            var caption: [String: Any] = [
                "id": UUID().uuidString,
                "source": isSystem ? "system" : "microphone",
                "text": "Fixture caption #\(i) — \(loremForIndex(i))",
                "isFinal": true,
                "startedAt": iso.string(from: started),
                "updatedAt": iso.string(from: updated)
            ]
            if screenshotEvery > 0, i % screenshotEvery == 0 {
                let filename = "fixture-\(i).png"
                try png.write(to: imagesDir.appendingPathComponent(filename))
                caption["imageFilename"] = filename
            }
            captions.append(caption)
        }

        let session: [String: Any] = [
            "id": chatID,
            "createdAt": iso.string(from: baseTime),
            "updatedAt": iso.string(from: baseTime.addingTimeInterval(TimeInterval(captionCount))),
            "captions": captions
        ]
        let data = try JSONSerialization.data(
            withJSONObject: session,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: sessionDir.appendingPathComponent("session.json"))
    }

    /// Generate a deterministic-size solid-color PNG. Big enough that
    /// `CGImageSource` does real decode work; small enough that 20 of
    /// them don't dominate fixture build time.
    private func makeColoredPNG(side: Int, color: NSColor) throws -> Data {
        let size = NSSize(width: CGFloat(side), height: CGFloat(side))
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            struct PNGEncodeError: Error {}
            throw PNGEncodeError()
        }
        return png
    }

    private func loremForIndex(_ i: Int) -> String {
        let bank = [
            "captures the room",
            "running stable",
            "live transcription",
            "long phrase with a comma, then another clause",
            "short",
            "the quick brown fox jumps over the lazy dog several times",
            "checking scroll performance",
            "image bubble follows",
            "system audio bubble",
            "microphone bubble"
        ]
        let n = 3 + (i % 5)
        return (0..<n).map { bank[($0 + i) % bank.count] }.joined(separator: " — ")
    }
}
