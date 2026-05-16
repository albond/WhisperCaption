import AppKit
import Foundation
import ImageIO
import OSLog

/// Read/write access to a single session's `images/` folder. PNG payloads
/// are stored as one file per caption keyed by UUID filename — the parent
/// `Caption.imageFilename` field records the filename only.
///
/// In-memory `thumbnailCache` keeps the chat scroll responsive: full PNGs
/// can be multi-megabyte and re-reading them on every Bubble re-render
/// (which fires constantly while captions stream) was the source of the
/// chat-tearing-itself-apart slowdown after a few screenshots. Thumbnails
/// are generated through CGImageSource so the decoder reads only as many
/// pixels as we need.
@MainActor
final class ChatImageStore {

    /// `images/` folder for one session. Created lazily on first save.
    let imagesFolder: URL

    private let log = Log.ChatImageStore

    /// filename → cached low-res NSImage. Filled by `loadThumbnail`,
    /// dropped on delete. Memory budget is small — each entry is a tiny
    /// CGImage scaled to a max ~800 px dimension.
    private var thumbnailCache: [String: NSImage] = [:]

    init(imagesFolder: URL) {
        self.imagesFolder = imagesFolder
    }

    /// Writes `pngData` to `<uuid>.png` inside the images folder. Returns
    /// the filename (no path) for storage in `Caption.imageFilename`.
    @discardableResult
    func save(pngData: Data) throws -> String {
        try FileManager.default.createDirectory(at: imagesFolder, withIntermediateDirectories: true)
        let filename = "\(UUID().uuidString).png"
        let url = imagesFolder.appendingPathComponent(filename)
        try pngData.write(to: url, options: .atomic)
        log.info("saved screenshot \(filename, privacy: .public) (\(pngData.count) bytes)")
        return filename
    }

    /// Reads the PNG bytes for a stored filename. Throws if the file is
    /// missing — callers can fall back to a placeholder.
    func load(filename: String) throws -> Data {
        let url = imagesFolder.appendingPathComponent(filename)
        return try Data(contentsOf: url)
    }

    /// Convenience for UI: returns `NSImage` or nil if loading fails.
    /// Loads the FULL-resolution image. Reserve this for one-shot uses
    /// like "Copy image" or QuickLook fallback — the chat list should
    /// call `loadThumbnail` instead.
    func loadImage(filename: String) -> NSImage? {
        let url = imagesFolder.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return NSImage(data: data)
    }

    /// File URL of the stored PNG. Used by QuickLook so previews don't
    /// have to round-trip through a temp copy.
    func url(forFilename filename: String) -> URL {
        imagesFolder.appendingPathComponent(filename)
    }

    /// Decoded small-pixel preview, cached in memory. `maxPixels` is the
    /// upper bound on the longest dimension; the aspect ratio is
    /// preserved. Returns nil if the file is missing or undecodable.
    func loadThumbnail(filename: String, maxPixels: Int = 800) -> NSImage? {
        if let cached = thumbnailCache[filename] {
            return cached
        }
        let url = imagesFolder.appendingPathComponent(filename)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let nsImage = NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
        thumbnailCache[filename] = nsImage
        return nsImage
    }

    /// Removes the entire images folder. Used when a session is deleted.
    func deleteAll() throws {
        thumbnailCache.removeAll()
        guard FileManager.default.fileExists(atPath: imagesFolder.path) else { return }
        try FileManager.default.removeItem(at: imagesFolder)
    }

    /// Removes a single PNG by filename. Silent no-op if the file is
    /// already gone — callers (notably `CaptionStream.deleteCaption`) treat
    /// missing files as "already cleaned" rather than an error.
    func delete(filename: String) throws {
        thumbnailCache[filename] = nil
        let url = imagesFolder.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
        log.info("deleted screenshot \(filename, privacy: .public)")
    }
}
