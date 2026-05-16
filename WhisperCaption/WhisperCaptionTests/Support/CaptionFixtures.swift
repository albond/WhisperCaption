import AppKit
import Foundation
@testable import WhisperCaption

/// Test data factories. Keeping them in one place makes test bodies short
/// and avoids the "copy a Caption literal across 40 tests, then evolve
/// the type" problem.
enum CaptionFixtures {

    static func caption(
        id: UUID = UUID(),
        source: CaptionSource = .microphone,
        text: String = "hello world",
        language: Language? = .en,
        isFinal: Bool = true,
        startedAt: Date = Date(),
        updatedAt: Date = Date(),
        imageFilename: String? = nil,
        translation: String? = nil,
        translationLanguage: Language? = nil
    ) -> Caption {
        Caption(
            id: id,
            source: source,
            text: text,
            language: language,
            isFinal: isFinal,
            startedAt: startedAt,
            updatedAt: updatedAt,
            imageFilename: imageFilename,
            translation: translation,
            translationLanguage: translationLanguage
        )
    }

    /// Synthesise N captions, alternating sources to mimic a real
    /// two-column chat.
    static func captions(count: Int, withImagesEvery imageEvery: Int = 0) -> [Caption] {
        var out: [Caption] = []
        out.reserveCapacity(count)
        let start = Date(timeIntervalSinceReferenceDate: 0)
        for i in 0..<count {
            let source: CaptionSource = (i % 2 == 0) ? .system : .microphone
            let withImage = imageEvery > 0 && (i % imageEvery == 0)
            out.append(Caption(
                id: UUID(),
                source: source,
                text: "Fixture caption #\(i) — \(source.rawValue) — \(Self.bodySample(i))",
                language: .en,
                isFinal: true,
                startedAt: start.addingTimeInterval(TimeInterval(i)),
                updatedAt: start.addingTimeInterval(TimeInterval(i) + 0.4),
                imageFilename: withImage ? "fixture-\(i).png" : nil
            ))
        }
        return out
    }

    /// Build a session pre-filled with N captions.
    static func session(id: String = "fixture-session", captionCount: Int = 0) -> ChatSession {
        var s = ChatSession(id: id)
        s.captions = captions(count: captionCount)
        return s
    }

    /// 1×1 PNG (~70 bytes) used for image-store tests that don't care
    /// about the pixel content.
    static let tinyPNG: Data = {
        let bytes: [UInt8] = [
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // PNG signature
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, // IHDR chunk header
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
            0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41,
            0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
            0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
            0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
            0x42, 0x60, 0x82
        ]
        return Data(bytes)
    }()

    /// Slightly larger PNG (a `side` × `side` solid colour) for thumbnail
    /// tests where decoder behaviour matters. Constructs the bitmap
    /// directly so the resulting PNG has EXACT pixel dimensions — using
    /// `NSImage(size:)` + `lockFocus` would retina-double on Macs with
    /// a 2× backing store, leading to surprise 128-px PNGs from a
    /// `side=64` request.
    static func makeColoredPNG(side: Int = 64, color: NSColor = .systemPurple) -> Data {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: side,
            pixelsHigh: side,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: side * 4,
            bitsPerPixel: 32
        ) else {
            return tinyPNG
        }
        let prev = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color.setFill()
        NSRect(x: 0, y: 0, width: CGFloat(side), height: CGFloat(side)).fill()
        NSGraphicsContext.current = prev
        guard let png = rep.representation(using: .png, properties: [:]) else {
            return tinyPNG
        }
        return png
    }

    /// Stub audio chunk — 100 ms of 16 kHz mono silence. Enough samples
    /// to verify ingest() bookkeeping; cheap to allocate in tight loops.
    static func silenceChunk(durationMs: Int = 100) -> [Float] {
        Array(repeating: Float(0), count: 16 * durationMs)
    }

    /// Stub audio chunk — sine wave at 440 Hz. Used where a non-zero RMS
    /// matters (level-meter or VAD-related plumbing).
    static func toneChunk(durationMs: Int = 100, frequency: Float = 440) -> [Float] {
        let count = 16 * durationMs
        var out: [Float] = []
        out.reserveCapacity(count)
        let step = 2 * Float.pi * frequency / 16_000
        for i in 0..<count {
            out.append(sin(Float(i) * step) * 0.5)
        }
        return out
    }

    private static func bodySample(_ i: Int) -> String {
        let words = ["hello", "world", "captions", "live", "audio", "test", "engine", "scroll", "fixture", "chat"]
        let n = 4 + (i % 6)
        return (0..<n).map { words[($0 + i) % words.count] }.joined(separator: " ")
    }
}

/// A canned Error usable anywhere a test needs to fail an async call
/// without inventing its own type.
struct TestError: Error, Equatable, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { "TestError(\(message))" }
}
