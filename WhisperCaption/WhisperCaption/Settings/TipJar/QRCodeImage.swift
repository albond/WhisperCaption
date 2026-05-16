import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Render a QR code for an arbitrary string payload using Core Image's
/// built-in generator. Pure Swift / Foundation / Core Image — no external
/// dependencies.
///
/// The generator returns a tiny image (one CI pixel per QR module), so
/// we scale it up with a nearest-neighbour transform to keep the bars
/// crisp at display size instead of letting the system bilinear-blur it.
enum QRCodeImage {

    /// Generate an `NSImage` for `payload` sized for a display side of
    /// roughly `targetPoints` points. Caller should still apply
    /// `.interpolation(.none)` on the SwiftUI side as a belt-and-braces
    /// against accidental smoothing inside SwiftUI's rendering pipeline.
    static func make(payload: String, targetPoints: CGFloat = 220) -> NSImage? {
        guard !payload.isEmpty else { return nil }
        guard let data = payload.data(using: .utf8) else { return nil }

        let generator = CIFilter.qrCodeGenerator()
        generator.message = data
        // "H" = ~30% recoverable error — most forgiving level. Slightly
        // denser code, but it survives camera glare / partial occlusion
        // far better than the default "M".
        generator.correctionLevel = "H"

        guard let base = generator.outputImage else { return nil }

        // Scale up by an integer factor so each module maps to N×N
        // pixels with no blending — produces sharp edges at any
        // reasonable display size.
        let baseSize = base.extent.size
        let scale = max(1, ceil(targetPoints / max(baseSize.width, 1)))
        let transformed = base.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let context = CIContext()
        guard let cgImage = context.createCGImage(transformed, from: transformed.extent) else { return nil }

        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: targetPoints, height: targetPoints))
        return nsImage
    }
}
