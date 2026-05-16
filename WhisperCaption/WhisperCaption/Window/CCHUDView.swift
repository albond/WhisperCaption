import SwiftUI

/// SwiftUI body of the closed-caption HUD — a movie-style caption strip
/// docked to the bottom of the active display. Shows the LAST two
/// system-side captions:
///
///   Row 1  ← previous caption, dimmed
///   Row 2  ← current caption (may still be interim), bright
///
/// Background plate is solid black with user-tunable opacity. A soft
/// inner outline keeps the strip looking like a finished UI element
/// rather than a black rectangle painted on the desktop.
///
/// The view is owned by `CCHUDController`, which decides what to show
/// and when. The view itself is a dumb reader of two arrays + opacity.
struct CCHUDView: View {

    /// Captions to render. The controller passes 0–2 entries:
    ///   - 0  → controller will hide the panel before the view ever
    ///          renders (we still bail to nothing as a safety net).
    ///   - 1  → render as the "current" row, no previous row.
    ///   - 2  → previous (older) at index 0, current at index 1.
    let captions: [Caption]

    /// 0.0 ... 1.0 — applied to the background fill so the user
    /// can dial how much of the page bleeds through. Multiplied with the
    /// background colour's own alpha.
    let backgroundOpacity: Double

    /// User-configurable colours. Defaulted so the SwiftUI previews and
    /// any callers that haven't been updated still compile / render.
    let backgroundColor: Color
    let previousLineColor: Color
    let currentLineColor: Color
    let translationColor: Color

    init(
        captions: [Caption],
        backgroundOpacity: Double,
        backgroundColor: Color = .black,
        previousLineColor: Color = .white,
        currentLineColor: Color = .white,
        translationColor: Color = Color(red: 1.00, green: 0.85, blue: 0.40)
    ) {
        self.captions = captions
        self.backgroundOpacity = backgroundOpacity
        self.backgroundColor = backgroundColor
        self.previousLineColor = previousLineColor
        self.currentLineColor = currentLineColor
        self.translationColor = translationColor
    }

    var body: some View {
        ZStack(alignment: .center) {
            background

            content
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    // MARK: - Background

    private var background: some View {
        ZStack {
            // User-tinted plate with user-controlled opacity — sells the
            // "movie subtitles" feel and stays legible on any page.
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(backgroundColor.opacity(backgroundOpacity))

            // Hair-thin inner highlight (top edge). Keeps the strip from
            // reading as a flat black slab.
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.10), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.7
                )
                .blendMode(.plusLighter)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if captions.isEmpty {
            // User toggled the CC HUD on a chat with no system-side
            // captions yet. Show a tiny "waveform-at-rest" placeholder so
            // the panel feels alive.
            VStack(spacing: 4) {
                Text("░░░ ▁▁ ▂▂ ▃▃ ▂▂ ▁▁ ░░░")
                    .font(.system(.title3, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
                    .tracking(2)
                Text("waiting for system audio…")
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .frame(maxWidth: .infinity, alignment: .center)
        } else {
            // Auto-fit: `ViewThatFits` walks the size ladder top → bottom
            // and picks the FIRST variant whose laid-out body fits the
            // strip's vertical content area. Long captions shrink the
            // font instead of disappearing behind "…".
            //
            // `.clipped()` is the safety net: if even the minimum size
            // still overflows we trim at the strip boundary rather than
            // painting over surrounding chrome.
            ViewThatFits(in: .vertical) {
                ForEach(Self.currentSizeStops, id: \.self) { size in
                    captionsBody(currentSize: size)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
        }
    }

    /// One `ViewThatFits` candidate — both caption rows (and their
    /// translations, if any) laid out at sizes derived from a single
    /// `currentSize` anchor. All four font sizes scale together so the
    /// "current line bigger than previous, translation a bit smaller
    /// than its source" hierarchy stays consistent at every step.
    private func captionsBody(currentSize: CGFloat) -> some View {
        let sizes = LineSizes(current: currentSize)
        return VStack(alignment: .leading, spacing: 6) {
            if captions.count >= 2 {
                captionLine(captions[0], style: .previous, sizes: sizes)
            }
            captionLine(captions.last!, style: .current, sizes: sizes)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Top of the ladder.
    private static let currentSizeMax: CGFloat = 22

    /// Floor of the ladder. Below this glance-distance legibility falls
    /// off; we'd rather clip at the strip boundary than render text the
    /// user can't read in passing.
    private static let currentSizeMin: CGFloat = 10

    /// 4pt step — perceptual difference between adjacent sizes is small,
    /// but `ViewThatFits` has to lay every candidate out before picking
    /// one, so coarser = cheaper first-render.
    private static let currentSizeStops: [CGFloat] = {
        let step: CGFloat = 4
        var stops: [CGFloat] = []
        var s = currentSizeMax
        while s >= currentSizeMin {
            stops.append(s)
            s -= step
        }
        if stops.last != currentSizeMin {
            stops.append(currentSizeMin)
        }
        return stops
    }()

    /// One caption rendered with the four font sizes derived from the
    /// current `ViewThatFits` candidate. No `lineLimit` / `truncationMode`
    /// — the size ladder above is what handles overflow.
    @ViewBuilder
    private func captionLine(_ caption: Caption, style: LineStyle, sizes: LineSizes) -> some View {
        let isCurrent = style == .current
        let lineColor = isCurrent ? currentLineColor : previousLineColor
        VStack(alignment: .leading, spacing: 2) {
            Text(caption.text)
                .font(.system(size: style.fontSize(sizes), weight: style.weight, design: .rounded))
                .foregroundStyle(lineColor)
                .opacity(isCurrent ? 1.0 : 0.55)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let translation = caption.translation, !translation.isEmpty {
                Text(translation)
                    .font(.system(size: style.translationSize(sizes), weight: .regular, design: .rounded))
                    .foregroundStyle(translationColor)
                    .opacity(isCurrent ? 0.95 : 0.55)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Bundle of the four font sizes derived from one anchor. Keeping
    /// them in one place means the visual hierarchy is preserved at
    /// every step of the size ladder without per-step constants.
    private struct LineSizes {
        let current: CGFloat
        var previous: CGFloat            { current * 0.73 }
        var currentTranslation: CGFloat  { current * 0.82 }
        var previousTranslation: CGFloat { previous * 0.81 }
    }

    private enum LineStyle {
        case previous, current

        /// Pick the source row's size out of the bundle.
        func fontSize(_ s: LineSizes) -> CGFloat {
            switch self {
            case .previous: return s.previous
            case .current:  return s.current
            }
        }

        /// Pick the translation row's size out of the bundle.
        func translationSize(_ s: LineSizes) -> CGFloat {
            switch self {
            case .previous: return s.previousTranslation
            case .current:  return s.currentTranslation
            }
        }

        /// Current row gets a heavier face so the user's eye lands there
        /// first regardless of the chosen size step.
        var weight: Font.Weight {
            switch self {
            case .previous: return .regular
            case .current:  return .semibold
            }
        }
    }
}

#Preview("CC HUD — single caption") {
    CCHUDView(
        captions: [
            Caption(
                source: .system,
                text: "We used Redis with a 60-second TTL on hot keys.",
                language: .en,
                isFinal: false
            )
        ],
        backgroundOpacity: 0.7
    )
    .frame(width: 800, height: 110)
    .padding()
    .background(.green.gradient)
}

#Preview("CC HUD — two captions") {
    CCHUDView(
        captions: [
            Caption(
                source: .system,
                text: "And tell me how the cache layer is set up in your backend.",
                language: .en,
                isFinal: true
            ),
            Caption(
                source: .system,
                text: "We used Redis with a 60-second TTL on hot keys and a cron job that refreshed them every minute.",
                language: .en,
                isFinal: false
            )
        ],
        backgroundOpacity: 0.7
    )
    .frame(width: 800, height: 130)
    .padding()
    .background(.green.gradient)
}
