import Foundation
import ScreenCaptureKit
import AppKit
import OSLog

/// Single-shot screen capture via ScreenCaptureKit. Returns PNG `Data`
/// ready to drop into a screenshot caption. Reuses the Screen Recording TCC
/// permission already granted for system-audio capture.
enum ScreenshotError: Error, LocalizedError {
    case noDisplays
    case displayNotFound(uuid: String)
    case appNotRunning(bundleID: String)
    case noWindowFound(bundleID: String)
    case encodingFailed
    case system(any Error)

    var errorDescription: String? {
        switch self {
        case .noDisplays:                   return "No displays available."
        case .displayNotFound(let uuid):    return "Display \(uuid) is not currently connected."
        case .appNotRunning(let bid):       return "\(bid) is not running."
        case .noWindowFound(let bid):       return "\(bid) has no on-screen windows."
        case .encodingFailed:               return "Failed to encode screenshot as PNG."
        case .system(let e):                return "Screen Recording error: \(e.localizedDescription)"
        }
    }
}

enum ScreenshotCapture {

    private static let log = Log.ScreenshotCapture

    /// Capture and return a PNG-encoded screenshot of `target`. Always
    /// async because SCShareableContent enumeration and SCScreenshotManager
    /// are both async.
    static func capture(target: ScreenshotTarget) async -> Result<Data, ScreenshotError> {
        do {
            // We want every visible window in the screenshot, including
            // ones owned by other apps (Zoom share, browser, etc).
            // Excluding desktop windows keeps wallpaper-mounted widgets
            // out of the picture; on-screen-only filters out minimized.
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )

            let filter: SCContentFilter
            let pixelWidth: Int
            let pixelHeight: Int

            switch target {
            case .systemDefault:
                guard let display = content.displays.first else {
                    return .failure(.noDisplays)
                }
                filter = SCContentFilter(display: display, excludingWindows: [])
                pixelWidth  = display.width
                pixelHeight = display.height

            case .display(let uuid):
                let match = content.displays.first { d in
                    Self.uuidString(forDisplayID: d.displayID) == uuid
                }
                guard let display = match else {
                    return .failure(.displayNotFound(uuid: uuid))
                }
                filter = SCContentFilter(display: display, excludingWindows: [])
                pixelWidth  = display.width
                pixelHeight = display.height

            case .app(let bundleID):
                // Pick the front-most on-screen window owned by this app.
                let candidates = content.windows.filter {
                    $0.owningApplication?.bundleIdentifier == bundleID && $0.isOnScreen
                }
                guard !candidates.isEmpty else {
                    // Distinguish "app isn't running at all" vs "running
                    // but minimized/hidden" so the bubble message is
                    // accurate.
                    let running = NSWorkspace.shared.runningApplications
                        .contains { $0.bundleIdentifier == bundleID }
                    return .failure(running ? .noWindowFound(bundleID: bundleID)
                                            : .appNotRunning(bundleID: bundleID))
                }
                // SCWindow has no obvious "frontmost" flag in this API
                // surface — the array order from SCShareableContent is
                // already top-to-bottom z-order, so first is frontmost.
                let window = candidates[0]
                filter = SCContentFilter(desktopIndependentWindow: window)
                pixelWidth  = Int(window.frame.width)
                pixelHeight = Int(window.frame.height)
            }

            let config = SCStreamConfiguration()
            // Native pixel resolution. Without this SCK silently
            // downsamples to ~1/2 resolution on Retina displays.
            config.width  = max(pixelWidth,  16)
            config.height = max(pixelHeight, 16)
            config.showsCursor = false
            config.scalesToFit = true

            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )

            guard let png = encodePNG(cgImage) else {
                return .failure(.encodingFailed)
            }
            log.info("captured screenshot bytes=\(png.count) target=\(target.rawTag, privacy: .public)")
            return .success(png)
        } catch {
            return .failure(.system(error))
        }
    }

    // MARK: - Helpers

    private static func encodePNG(_ cgImage: CGImage) -> Data? {
        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        return bitmapRep.representation(using: .png, properties: [:])
    }

    /// Stable UUID string for a CGDirectDisplayID. Same scheme used by
    /// `Displays` so settings persisted there can drive screenshot too.
    static func uuidString(forDisplayID id: CGDirectDisplayID) -> String? {
        guard let cfUUID = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else {
            return nil
        }
        return CFUUIDCreateString(nil, cfUUID) as String
    }
}
