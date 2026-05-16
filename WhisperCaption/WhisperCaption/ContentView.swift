import AppKit
import SwiftUI
import QuickLook

/// Live caption chat — single unified feed (messenger-style).
///   System bubbles  → LEFT, neutral purple — "the other side speaking"
///   Microphone      → RIGHT, blue accent  — "me speaking"
/// Both sources are recognized in PARALLEL; their bubbles intermix in a
/// single timeline sorted by `startedAt`. Screenshots ride on the system
/// side.
struct ContentView: View {

    @Environment(CaptionStream.self)     private var stream
    @Environment(SettingsStore.self)     private var settings
    @Environment(ChatHistoryStore.self)  private var history

    var body: some View {
        VStack(spacing: 0) {
            TopBar(stream: stream)
            UnifiedChat(stream: stream)
            BottomBar(stream: stream)
        }
        .frame(minWidth: 760, idealWidth: 920, minHeight: 600, idealHeight: 720)
        .background(BackgroundGradient())
        .containerBackground(.background.secondary, for: .window)
    }
}

// MARK: - Background

/// Soft accent-tinted vignette behind everything.
private struct BackgroundGradient: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)

            LinearGradient(
                colors: [
                    Color.accentColor.opacity(0.18),
                    Color.accentColor.opacity(0.04),
                    Color.clear
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .blendMode(.plusLighter)

            RadialGradient(
                colors: [Color.accentColor.opacity(0.10), .clear],
                center: .topLeading,
                startRadius: 20,
                endRadius: 380
            )
            .blendMode(.plusLighter)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Top bar

private struct TopBar: View {
    @Bindable var stream: CaptionStream
    @Environment(ChatHistoryStore.self) private var history

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                BrandMark()

                ChatPicker(stream: stream, history: history)

                LanguagePill(stream: stream)

                Spacer(minLength: 12)

                StatusPill(state: stream.state, elapsed: stream.elapsedSeconds)

                ControlButton(stream: stream)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)

            Divider()
                .opacity(0.25)
        }
        .background(.bar)
    }
}

/// App logo + wordmark.
private struct BrandMark: View {
    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.accentColor.opacity(0.95),
                                Color.accentColor.opacity(0.65)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.35), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.7
                    )

                Image(systemName: "waveform.badge.mic")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
            }
            .frame(width: 32, height: 32)
            .shadow(color: Color.accentColor.opacity(0.30), radius: 6, y: 3)

            Text("WhisperCaption")
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct ChatPicker: View {
    @Bindable var stream: CaptionStream
    let history: ChatHistoryStore

    var body: some View {
        Menu {
            Button {
                stream.newSession()
            } label: {
                Label("New chat", systemImage: "square.and.pencil")
            }
            .disabled(stream.state.isBusy)

            if !history.index.isEmpty {
                Divider()
                Section("History") {
                    ForEach(history.index) { meta in
                        Button {
                            stream.activate(sessionID: meta.id)
                        } label: {
                            if meta.id == stream.activeSession.id {
                                Label(meta.displayName, systemImage: "checkmark")
                            } else {
                                Text(meta.displayName)
                            }
                        }
                        .disabled(stream.state.isBusy && meta.id != stream.activeSession.id)
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(stream.activeSession.displayName)
                    .font(.system(.callout, design: .monospaced).weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.6)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Active chat. Open the menu to switch or start a new one.")
    }
}

/// Read-only pill that shows the language selection. Full editing
/// happens in Settings → Speech Recognition.
private struct LanguagePill: View {
    let stream: CaptionStream

    private var label: String {
        let langs = stream.languages.selectedLanguages
        if langs.isEmpty { return "Auto" }
        let badges = langs.map(\.badge).sorted()
        if badges.count <= 3 {
            return badges.joined(separator: "+")
        }
        return "\(badges.count) langs"
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "globe")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .help("Selected languages. Configure in Settings → Speech Recognition.")
    }
}

private struct StatusPill: View {
    let state: CaptionStream.State
    let elapsed: TimeInterval

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
                .shadow(color: dotColor.opacity(0.55), radius: 4)
                .symbolEffect(.pulse, options: .repeating, isActive: state.isRunning)
            Text(label)
                .font(.callout.weight(.medium))
                .foregroundStyle(.primary)
            if state.isRunning {
                Text(formatElapsed(elapsed))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            Capsule(style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(dotColor.opacity(0.25), lineWidth: 0.6)
        )
    }

    private var dotColor: Color {
        switch state {
        case .idle:                                   return .secondary
        case .checkingPermissions, .loadingModel,
             .starting, .stopping:                    return .orange
        case .running:                                return .red
        case .error:                                  return .pink
        }
    }

    private var label: String {
        switch state {
        case .idle:                                   return "Ready"
        case .checkingPermissions:                    return "Checking permissions…"
        case .loadingModel(_, let m):                 return m
        case .starting:                               return "Starting…"
        case .running:                                return "Live"
        case .stopping:                               return "Stopping…"
        case .error:                                  return "Error"
        }
    }

    private func formatElapsed(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

private struct ControlButton: View {
    @Bindable var stream: CaptionStream

    var body: some View {
        Button(action: { Task { await stream.toggle() } }) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .bold))
                Text(label)
                    .font(.callout.weight(.semibold))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(tint)
        .disabled(stream.state.isBusy)
        .shadow(color: tint.opacity(0.30), radius: 6, y: 3)
    }

    private var label: String {
        switch stream.state {
        case .idle, .error:               return "Start"
        case .running:                    return "Stop"
        case .checkingPermissions:        return "Permissions…"
        case .loadingModel:               return "Loading…"
        case .starting:                   return "Starting…"
        case .stopping:                   return "Stopping…"
        }
    }

    private var symbol: String {
        switch stream.state {
        case .running:                    return "stop.fill"
        case .error:                      return "arrow.clockwise"
        default:                          return "waveform"
        }
    }

    private var tint: Color {
        switch stream.state {
        case .running:                    return .red
        case .error:                      return .orange
        default:                          return .accentColor
        }
    }
}

// MARK: - Unified chat

private struct UnifiedChat: View {
    let stream: CaptionStream
    @Environment(SettingsStore.self) private var settings
    @Environment(ChatHistoryStore.self) private var history

    /// Captions sorted by `startedAt` for a stable cross-source timeline.
    private var orderedCaptions: [Caption] {
        stream.captions.sorted { $0.startedAt < $1.startedAt }
    }

    var body: some View {
        Group {
            switch stream.state {
            case .error(let message):
                ErrorView(message: message, onDismiss: { stream.dismissError() })
            case .loadingModel(_, let message):
                LoadingView(message: message)
            default:
                VStack(spacing: 12) {
                    SourceHeaderRow(stream: stream, micEnabled: settings.captureMicrophone)
                        .padding(.horizontal, 18)
                        .padding(.top, 14)
                    CaptionFeed(
                        captions: orderedCaptions,
                        imageStore: history.imageStore(forSessionID: stream.activeSession.id)
                    )
                }
            }
        }
        .frame(maxHeight: .infinity)
    }
}

/// Two-up header with system on the left, mic on the right. Both halves
/// stay visible at all times; toggling capture-microphone in Settings
/// dims the right half and disables its dropdown rather than removing it.
private struct SourceHeaderRow: View {
    let stream: CaptionStream
    let micEnabled: Bool
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        let systemTint = settings.systemBubbleColor.color
        let micTint    = settings.micBubbleColor.color
        HStack(spacing: 12) {
            SourceHeaderCard(
                title: "System audio",
                subtitle: "What macOS is playing",
                symbol: "speaker.wave.3.fill",
                tint: systemTint,
                level: stream.systemLevel,
                enabled: true,
                control: AnyView(
                    SourceMenu(
                        direction: .output,
                        selectedUID: Binding(
                            get: { stream.routing.preferredOutputUID },
                            set: { stream.routing.preferredOutputUID = $0 }
                        ),
                        tint: systemTint
                    )
                )
            )
            SourceHeaderCard(
                title: "Microphone",
                subtitle: "Me speaking",
                symbol: "mic.fill",
                tint: micTint,
                level: micEnabled ? stream.micLevel : 0,
                enabled: micEnabled,
                control: AnyView(
                    SourceMenu(
                        direction: .input,
                        selectedUID: Binding(
                            get: { stream.routing.preferredMicUID },
                            set: { stream.routing.preferredMicUID = $0 }
                        ),
                        tint: micTint
                    )
                    .disabled(!micEnabled)
                )
            )
        }
    }
}

private struct SourceHeaderCard: View {
    let title: String
    let subtitle: String
    let symbol: String
    let tint: Color
    let level: Float
    let enabled: Bool
    let control: AnyView

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [tint.opacity(0.95), tint.opacity(0.70)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.white.opacity(0.30), .clear],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.6
                        )

                    Image(systemName: symbol)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
                }
                .frame(width: 36, height: 36)
                .shadow(color: tint.opacity(0.35), radius: 5, y: 2)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                control
            }

            LevelMeter(level: level, tint: tint)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(tint.opacity(0.18), lineWidth: 0.8)
        )
        .overlay(alignment: .top) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .trim(from: 0.0, to: 0.5)
                .stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.22), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.7
                )
                .blendMode(.plusLighter)
                .allowsHitTesting(false)
        }
        .shadow(color: tint.opacity(0.10), radius: 8, y: 3)
        .opacity(enabled ? 1 : 0.55)
    }
}

/// Single ScrollView holding ALL captions in chronological order.
///
/// Auto-scroll is a single Bool: `SettingsStore.autoScrollMainHUD`, toggled
/// from a button next to "New chat" in the bottom bar. When on AND a stream
/// is running, every caption update jumps the feed to the latest. When off
/// (or when no stream is running), the viewport stays where the user put
/// it — so reading history isn't yanked away by the next partial.
///
/// We deliberately don't try to auto-detect "user scrolled up" via
/// `onScrollGeometryChange` — that produced a layout feedback loop with
/// `withAnimation` in earlier revisions. Explicit user-controlled toggle
/// is simpler and predictable.
private struct CaptionFeed: View {
    let captions: [Caption]
    let imageStore: ChatImageStore

    @Environment(SettingsStore.self) private var settings
    @Environment(CaptionStream.self) private var stream

    var body: some View {
        if captions.isEmpty {
            EmptyState(symbol: "waveform", tint: .secondary)
                .frame(maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(captions) { caption in
                            Bubble(caption: caption, imageStore: imageStore)
                                .id(caption.id)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id("bottom")
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: captions.last?.updatedAt) { _, _ in
                    // Streaming path — partial caption updates fire many
                    // times per second. Gated by `isRunning` so the
                    // viewport isn't dragged around when nothing's
                    // actively transcribing.
                    guard settings.autoScrollMainHUD, stream.state.isRunning else { return }
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
                .onChange(of: captions.count) { _, _ in
                    // Discrete-event path — any new bubble (engine
                    // utterance, screenshot, etc). Not gated by
                    // `isRunning` because screenshots happen outside the
                    // stream. The delayed re-scroll catches screenshot
                    // bubbles whose final height is only known once the
                    // image has loaded and laid out.
                    guard settings.autoScrollMainHUD else { return }
                    proxy.scrollTo("bottom", anchor: .bottom)
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 100_000_000)
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
                .onChange(of: settings.autoScrollMainHUD) { _, newValue in
                    // Just turned auto-scroll back on — jump to bottom once
                    // so the user lands on the latest message.
                    guard newValue else { return }
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
                .onAppear {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }
}

private struct LevelMeter: View {
    let level: Float    // raw RMS, 0...~1 (speech usually 0.01...0.3)
    let tint: Color

    /// Compress wide dynamic range: sqrt makes quiet speech actually visible.
    private var fillFraction: CGFloat {
        let normalized = min(max(Double(level) * 4.0, 0), 1)
        return CGFloat(normalized.squareRoot())
    }

    private var dB: String {
        // 20·log10(rms). Floor at -60 dB so the readout doesn't go to -inf.
        let l = max(Double(level), 0.000001)
        let value = 20 * log10(l)
        if value < -60 { return "—" }
        return String(format: "%.0f dB", value)
    }

    var body: some View {
        HStack(spacing: 10) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(tint.opacity(0.10))

                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    tint.opacity(0.55),
                                    tint,
                                    tint.opacity(0.85)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(3, geo.size.width * fillFraction))
                        .shadow(color: tint.opacity(0.45), radius: 4)
                        .animation(.linear(duration: 0.08), value: fillFraction)
                }
            }
            .frame(height: 8)

            Text(dB)
                .font(.system(.caption2, design: .monospaced).weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
                .contentTransition(.numericText())
        }
    }
}

/// Compact dropdown for picking an input or output device.
private struct SourceMenu: View {
    let direction: AudioDevices.Direction
    @Binding var selectedUID: String?
    let tint: Color

    @State private var devices: [AudioDevice] = []

    private var currentLabel: String {
        if let uid = selectedUID, let device = devices.first(where: { $0.uid == uid }) {
            return device.name
        }
        return "System"
    }

    var body: some View {
        Menu {
            Button {
                selectedUID = nil
            } label: {
                if selectedUID == nil {
                    Label("System default", systemImage: "checkmark")
                } else {
                    Text("System default")
                }
            }

            if !devices.isEmpty {
                Divider()
                ForEach(devices) { device in
                    Button {
                        selectedUID = device.uid
                    } label: {
                        if selectedUID == device.uid {
                            Label(device.name, systemImage: "checkmark")
                        } else {
                            Text(device.name)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(currentLabel)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.14))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(tint.opacity(0.30), lineWidth: 0.6)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(maxWidth: 170)
        .onAppear { devices = AudioDevices.devices(for: direction) }
        .onTapGesture { devices = AudioDevices.devices(for: direction) }
    }
}

private struct EmptyState: View {
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 88, height: 88)
                Image(systemName: symbol)
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(Color.accentColor.gradient)
            }
            Text("Waiting for audio…")
                .font(.title3.weight(.semibold))
            Text("Press Start to begin capturing and transcribing.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

private struct Bubble: View {
    let caption: Caption
    let imageStore: ChatImageStore

    @Environment(CaptionStream.self) private var stream
    @Environment(SettingsStore.self) private var settings
    @Environment(\.captionTranslator) private var translator

    /// Side of the chat the bubble lives on:
    ///   - `.system`     → left (the other side)
    ///   - `.microphone` → right (me speaking)
    private var alignment: HorizontalAlignment {
        switch caption.source {
        case .system:     return .leading
        case .microphone: return .trailing
        }
    }

    /// Per-source hue, pulled from Settings → Appearance → Bubble colors.
    /// `BubbleColor.accent` resolves to `Color.accentColor`, so leaving both
    /// pickers on "Match accent" makes the chat a single-color stream;
    /// distinct picks keep mic / system visually separable.
    private var tint: Color {
        switch caption.source {
        case .system:     return settings.systemBubbleColor.color
        case .microphone: return settings.micBubbleColor.color
        }
    }

    var body: some View {
        HStack {
            if alignment == .trailing { Spacer(minLength: 32) }
            VStack(alignment: alignment == .leading ? .leading : .trailing, spacing: 5) {
                if let filename = caption.imageFilename,
                   let thumbnail = imageStore.loadThumbnail(filename: filename) {
                    ScreenshotBubbleBody(
                        thumbnail: thumbnail,
                        fullImageURL: imageStore.url(forFilename: filename),
                        label: caption.text,
                        tint: tint,
                        alignment: alignment
                    )
                } else {
                    Text(caption.text)
                        .font(.system(size: settings.bubbleFontSize))
                        .foregroundStyle(caption.isFinal ? .primary : .secondary)
                        .multilineTextAlignment(alignment == .leading ? .leading : .trailing)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            tint.opacity(caption.isFinal ? 0.22 : 0.10),
                                            tint.opacity(caption.isFinal ? 0.14 : 0.06)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(
                                    tint.opacity(caption.isFinal ? 0.18 : 0.32),
                                    lineWidth: caption.isFinal ? 0.6 : 1
                                )
                        )
                        .shadow(
                            color: tint.opacity(caption.isFinal ? 0.16 : 0.0),
                            radius: 6,
                            y: 2
                        )
                }

                if let translated = trimmedTranslation {
                    TranslationRow(text: translated, tint: tint, alignment: alignment)
                }

                HStack(spacing: 6) {
                    if let lang = caption.language {
                        Text(lang.badge)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(.gray.opacity(0.18))
                            )
                    }
                    if !caption.isFinal {
                        Text("…")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .contextMenu { contextMenuContent }
            if alignment == .leading { Spacer(minLength: 32) }
        }
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
    }

    // MARK: - Context menu

    private var trimmedTranslation: String? {
        guard let raw = caption.translation else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var sourceLanguageChoices: [Language] {
        let target = settings.translationTargetLanguage
        return stream.languages.selectedLanguages
            .subtracting([target])
            .sorted { $0.displayName < $1.displayName }
    }

    private var hasAnyTranslateOption: Bool {
        let target = settings.translationTargetLanguage
        if let src = caption.language { return src != target }
        return !sourceLanguageChoices.isEmpty
    }

    @ViewBuilder
    private var contextMenuContent: some View {
        let target = settings.translationTargetLanguage
        let trimmed = caption.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasText = !trimmed.isEmpty
        let alreadyTranslated = caption.translation != nil
            && caption.translationLanguage == target

        if let filename = caption.imageFilename {
            // Screenshot bubble — full PNG to the clipboard, not the
            // generic "Screenshot of X" label.
            Button {
                Self.copyImageToPasteboard(filename: filename, imageStore: imageStore)
            } label: {
                Label("Copy image", systemImage: "photo.on.rectangle")
            }
            if let translated = trimmedTranslation {
                Button {
                    Self.copyToPasteboard(translated)
                } label: {
                    Label("Copy translation", systemImage: "doc.on.doc.fill")
                }
            }
            Divider()
        } else if hasText {
            Button {
                Self.copyToPasteboard(trimmed)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            if let translated = trimmedTranslation {
                Button {
                    Self.copyToPasteboard(translated)
                } label: {
                    Label("Copy translation", systemImage: "doc.on.doc.fill")
                }
            }
            Divider()
        }

        if hasText && hasAnyTranslateOption {
            if alreadyTranslated {
                translateMenuItem(
                    label: "Re-translate to \(target.displayName)",
                    systemImage: "arrow.clockwise"
                )
                Button {
                    stream.clearTranslation(forCaptionID: caption.id)
                } label: {
                    Label("Remove translation", systemImage: "xmark.circle")
                }
            } else {
                translateMenuItem(
                    label: "Translate to \(target.displayName)",
                    systemImage: "globe"
                )
            }
            Divider()
        }

        Button(role: .destructive) {
            stream.deleteCaption(caption.id)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private static func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Reads the full-resolution PNG from disk (not the cached thumbnail
    /// — that's resized) and writes it to the general pasteboard as an
    /// NSImage so downstream apps (Preview, image editors, Slack/iMessage)
    /// paste the original quality.
    private static func copyImageToPasteboard(filename: String, imageStore: ChatImageStore) {
        guard let image = imageStore.loadImage(filename: filename) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
    }

    @ViewBuilder
    private func translateMenuItem(label: String, systemImage: String) -> some View {
        // Resolve which source to translate from. Preference order:
        //   1. The language the engine already attached to the caption.
        //   2. If the user has narrowed Speech Recognition to one language,
        //      use that one — the caption can only be in it anyway.
        // Otherwise we don't know, and the submenu asks the user to pick.
        if let src = caption.language {
            singleSourceTranslateButton(label: label, systemImage: systemImage, source: src)
        } else if sourceLanguageChoices.count == 1, let only = sourceLanguageChoices.first {
            singleSourceTranslateButton(label: label, systemImage: systemImage, source: only)
        } else {
            Menu {
                ForEach(sourceLanguageChoices) { lang in
                    Button(lang.displayName) {
                        translator?.requestManualTranslation(
                            captionID: caption.id,
                            sourceLanguage: lang
                        )
                    }
                }
            } label: {
                Label(label, systemImage: systemImage)
            }
            .disabled(translator == nil || sourceLanguageChoices.isEmpty)
        }
    }

    private func singleSourceTranslateButton(
        label: String,
        systemImage: String,
        source: Language
    ) -> some View {
        Button {
            translator?.requestManualTranslation(
                captionID: caption.id,
                sourceLanguage: source
            )
        } label: {
            Label(label, systemImage: systemImage)
        }
        .disabled(translator == nil)
    }
}

/// Compact translation row shown directly under the main bubble. Globe
/// glyph + translated text, indented to the same side as the bubble.
/// No background of its own — visually leans on the parent bubble.
private struct TranslationRow: View {
    let text: String
    let tint: Color
    let alignment: HorizontalAlignment

    @Environment(SettingsStore.self) private var settings

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "globe")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(tint.opacity(0.85))
                .padding(.top, 2)
            Text(text)
                .font(.system(size: max(8, settings.bubbleFontSize - 1)))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(alignment == .leading ? .leading : .trailing)
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: 420, alignment: alignment == .leading ? .leading : .trailing)
    }
}

/// Screenshot bubble: small caption row with a clickable thumbnail.
/// Click → Quick Look preview using SwiftUI's `.quickLookPreview` (the
/// image is dumped to a temp file the first time it's opened).
private struct ScreenshotBubbleBody: View {
    /// Low-resolution preview shown in the chat. Drives layout cheaply
    /// even when many screenshots are in the same scroll.
    let thumbnail: NSImage
    /// Disk URL of the full-resolution PNG. Used by QuickLook on click;
    /// no temp-file round-trip needed.
    let fullImageURL: URL
    let label: String
    let tint: Color
    let alignment: HorizontalAlignment

    @State private var quickLookURL: URL?

    var body: some View {
        VStack(alignment: alignment == .leading ? .leading : .trailing, spacing: 8) {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 320, maxHeight: 200)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(tint.opacity(0.4), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
                .onTapGesture { quickLookURL = fullImageURL }
                .help("Click to preview full size")

            Label(label, systemImage: "camera.viewfinder")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(tint.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(tint.opacity(0.22), lineWidth: 0.6)
        )
        .quickLookPreview($quickLookURL)
    }
}

private struct LoadingView: View {
    let message: String

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 110, height: 110)
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 52, weight: .light))
                    .foregroundStyle(Color.accentColor.gradient)
                    .symbolEffect(.pulse, options: .repeating)
            }
            Text(message)
                .font(.title3.weight(.semibold))
            Text("First launch loads the chosen Whisper model from the local folder you configured. Subsequent launches reuse the cache.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            ProgressView().controlSize(.regular)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

private struct ErrorView: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.18))
                    .frame(width: 96, height: 96)
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(.orange.gradient)
            }
            Text("Couldn't start")
                .font(.title3.weight(.semibold))
            ScrollView {
                Text(message)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
                    .frame(maxWidth: 560, alignment: .leading)
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(.thinMaterial)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.6)
                    )
            }
            .frame(maxWidth: 600, maxHeight: 260)
            HStack(spacing: 10) {
                Button("Dismiss", action: onDismiss)
                    .buttonStyle(.bordered)
                Menu {
                    Button("Microphone…") { PermissionsCoordinator.openSettings(for: .microphone) }
                    Button("Screen Recording…") { PermissionsCoordinator.openSettings(for: .screenRecording) }
                } label: {
                    Label("Privacy Settings", systemImage: "lock.shield")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// MARK: - Bottom bar

private struct BottomBar: View {
    let stream: CaptionStream
    @Environment(SettingsStore.self) private var settings

    private var engineLabel: String {
        switch settings.transcriptionEngine {
        case .whisper:    return "\(settings.whisperModel.displayName.lowercased()) · on-device"
        case .deepgram:   return "Deepgram Nova-3 · cloud"
        case .elevenlabs: return "ElevenLabs Scribe v2 · cloud"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
                .opacity(0.25)

            HStack(spacing: 10) {
                Button {
                    stream.newSession()
                } label: {
                    Label("New chat", systemImage: "square.and.pencil")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(stream.state.isBusy)
                .help("Save the current chat to history and start a fresh one.")

                AutoScrollToggle()

                Spacer()

                HStack(spacing: 6) {
                    Image(systemName: engineIcon)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(engineLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule(style: .continuous)
                        .fill(.regularMaterial)
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                )
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 10)
        }
        .background(.bar)
    }

    private var engineIcon: String {
        switch settings.transcriptionEngine {
        case .whisper:    return "cpu"
        case .deepgram:   return "cloud"
        case .elevenlabs: return "cloud"
        }
    }
}

/// Persistent toggle for the Main HUD's auto-scroll behaviour. Lives next
/// to "New chat" in the bottom bar. Toggling has no immediate effect when
/// no stream is running — auto-scroll only fires while captions arrive.
private struct AutoScrollToggle: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Toggle(isOn: $settings.autoScrollMainHUD) {
            Label("Auto-scroll", systemImage: "arrow.down.to.line")
        }
        .toggleStyle(.button)
        .controlSize(.regular)
        .help(settings.autoScrollMainHUD
            ? "Auto-scroll ON — feed follows the latest caption. Click to disable so you can read history."
            : "Auto-scroll OFF — feed stays where you scrolled it. Click to follow the latest caption again.")
    }
}

#Preview {
    ContentView()
}
