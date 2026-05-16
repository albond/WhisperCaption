import SwiftUI

/// Settings page for browsing and deleting persisted chat sessions.
/// Two-pane layout: list of sessions on the left, read-only preview of
/// the selected session on the right.
struct ChatHistorySection: View {

    @Environment(ChatHistoryStore.self) private var history
    @Environment(CaptionStream.self)   private var stream

    /// Multi-selection set driving the right pane. macOS `List(selection:)`
    /// gives us ⌘-click for toggle and ⇧-click for range natively.
    @State private var selectedIDs: Set<String> = []

    /// Disk snapshot of the selected *historical* session — populated
    /// only when exactly one historical chat is selected.
    @State private var loadedSession: ChatSession?

    /// Delete-confirmation alert state.
    @State private var pendingDeleteIDs: Set<String>?

    private let descriptor = SettingsCategoryID.chatHistory.descriptor

    private var singleSelectedID: String? {
        selectedIDs.count == 1 ? selectedIDs.first : nil
    }

    private var displayedCaptions: [Caption] {
        guard let id = singleSelectedID else { return [] }
        if id == stream.activeSession.id {
            return stream.captions
        }
        return loadedSession?.captions ?? []
    }

    private var hasDisplayedSession: Bool {
        guard let id = singleSelectedID else { return false }
        if id == stream.activeSession.id { return true }
        return loadedSession?.id == id
    }

    var body: some View {
        VStack(spacing: 0) {
            actionsBar
                .padding(.horizontal, 18)
                .padding(.vertical, 10)

            Divider().opacity(0.4)

            HSplitView {
                sessionList
                    .frame(minWidth: 220, idealWidth: 280, maxWidth: 360)

                detailPane
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(descriptor.title)
        .onAppear {
            history.refreshIndex()
            if selectedIDs.isEmpty {
                selectedIDs = [stream.activeSession.id]
            }
            loadSelected()
        }
        .onChange(of: singleSelectedID) { _, _ in loadSelected() }
        .alert(
            alertTitle(for: pendingDeleteIDs),
            isPresented: Binding(
                get: { pendingDeleteIDs != nil },
                set: { if !$0 { pendingDeleteIDs = nil } }
            ),
            presenting: pendingDeleteIDs
        ) { ids in
            Button("Delete", role: .destructive) { confirmDelete(ids: ids) }
            Button("Cancel", role: .cancel) {}
        } message: { ids in
            if ids.count == 1, let id = ids.first {
                Text("Chat “\(id)” and all its screenshots will be deleted. This cannot be undone.")
            } else {
                Text("\(ids.count) chats will be deleted with all their screenshots. This cannot be undone.")
            }
        }
    }

    private func alertTitle(for ids: Set<String>?) -> String {
        guard let ids else { return "Delete chat?" }
        return ids.count == 1 ? "Delete chat?" : "Delete \(ids.count) chats?"
    }

    // MARK: - Actions bar

    private var actionsBar: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(descriptor.subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)

            if !selectedIDs.isEmpty {
                Button {
                    exportSelected()
                } label: {
                    Label("Export (\(selectedIDs.count))", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Save the selected chat to a ZIP containing chat.md and a media/ folder with the screenshots.")

                Button(role: .destructive) {
                    pendingDeleteIDs = selectedIDs
                } label: {
                    Label("Delete (\(selectedIDs.count))", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Text("\(history.index.count) sessions")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule(style: .continuous).fill(.thinMaterial)
                )
        }
    }

    // MARK: - Left pane

    private var sessionList: some View {
        Group {
            if history.index.isEmpty {
                emptyList
            } else {
                List(selection: $selectedIDs) {
                    ForEach(history.index) { meta in
                        let active = (meta.id == stream.activeSession.id)
                        SessionRow(
                            meta: meta,
                            isActive: active,
                            liveCaptions: active ? stream.captions : nil
                        )
                        .tag(meta.id)
                        .contextMenu {
                            Button("Make active") {
                                stream.activate(sessionID: meta.id)
                                selectedIDs = [meta.id]
                            }
                            Button(
                                selectedIDs.contains(meta.id) && selectedIDs.count > 1
                                    ? "Delete selected (\(selectedIDs.count))"
                                    : "Delete",
                                role: .destructive
                            ) {
                                pendingDeleteIDs = selectedIDs.contains(meta.id)
                                    ? selectedIDs
                                    : [meta.id]
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private var emptyList: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No saved chats yet")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("They appear here after the first capture session.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Right pane

    @ViewBuilder
    private var detailPane: some View {
        switch selectedIDs.count {
        case 0:
            ContentUnavailableView(
                "Pick a chat",
                systemImage: "sidebar.left",
                description: Text("Click a chat on the left. ⌘-click to add to the selection, ⇧-click for a range.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case 1:
            if let id = singleSelectedID, hasDisplayedSession {
                VStack(spacing: 0) {
                    detailHeader(id: id, captions: displayedCaptions)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                    Divider().opacity(0.4)
                    if displayedCaptions.isEmpty {
                        emptyPreview
                    } else {
                        previewFeed(sessionID: id, captions: displayedCaptions)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

        default:
            bulkSelectionPane
        }
    }

    private var bulkSelectionPane: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Color.accentColor.opacity(0.6))
            Text("\(selectedIDs.count) chats selected")
                .font(.title3.weight(.semibold))
            Text("Delete them all at once. This cannot be undone — screenshots go with them.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button(role: .destructive) {
                pendingDeleteIDs = selectedIDs
            } label: {
                Label("Delete \(selectedIDs.count) chats", systemImage: "trash")
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func detailHeader(id: String, captions: [Caption]) -> some View {
        let isActive = (id == stream.activeSession.id)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(id)
                    .font(.system(.headline, design: .monospaced))
                HStack(spacing: 6) {
                    if isActive {
                        Text("active")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor))
                    }
                    Text("\(captions.count) messages")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !isActive {
                Button {
                    stream.activate(sessionID: id)
                } label: {
                    Label("Make active", systemImage: "arrow.right.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            Button(role: .destructive) {
                pendingDeleteIDs = [id]
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var emptyPreview: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Empty chat")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func previewFeed(sessionID: String, captions: [Caption]) -> some View {
        let imageStore = history.imageStore(forSessionID: sessionID)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(captions) { caption in
                    PreviewBubble(caption: caption, imageStore: imageStore)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Actions

    private func loadSelected() {
        guard let id = singleSelectedID else {
            loadedSession = nil
            return
        }
        if id == stream.activeSession.id {
            loadedSession = nil
            return
        }
        if loadedSession?.id == id { return }
        loadedSession = history.load(id: id)
    }

    /// Bundle each currently-selected chat into a ZIP.
    private func exportSelected() {
        guard !selectedIDs.isEmpty else { return }

        var payloads: [ChatExporter.Payload] = []
        for id in selectedIDs {
            let imageStore = history.imageStore(forSessionID: id)
            if id == stream.activeSession.id {
                var snapshot = stream.activeSession
                snapshot.captions = stream.captions
                snapshot.updatedAt = Date()
                payloads.append(.init(session: snapshot, imageStore: imageStore))
            } else if let session = history.load(id: id) {
                payloads.append(.init(session: session, imageStore: imageStore))
            }
        }
        ChatExporter.run(payloads: payloads)
    }

    private func confirmDelete(ids: Set<String>) {
        let containsActive = ids.contains(stream.activeSession.id)
        for id in ids {
            history.delete(id: id)
        }
        if containsActive {
            stream.newSession()
        }
        selectedIDs.subtract(ids)
        if selectedIDs.isEmpty, history.index.contains(where: { $0.id == stream.activeSession.id }) {
            selectedIDs = [stream.activeSession.id]
        }
        loadSelected()
    }
}

// MARK: - Row

private struct SessionRow: View {
    let meta: ChatHistoryStore.SessionMeta
    let isActive: Bool
    /// For the active row we pass the live `stream.captions` so the
    /// counts don't lag the autosave debounce (1.5 s). Nil for inactive
    /// rows — those use the disk-derived counts in `meta`.
    var liveCaptions: [Caption]? = nil

    private var captionCount: Int {
        liveCaptions?.count ?? meta.captionCount
    }

    private var screenshotCount: Int {
        if let live = liveCaptions {
            return live.reduce(into: 0) { sum, c in if c.imageFilename != nil { sum += 1 } }
        }
        return meta.screenshotCount
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(meta.displayName)
                        .font(.system(.callout, design: .monospaced))
                        .lineLimit(1)
                    if isActive {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 6, height: 6)
                    }
                }
                HStack(spacing: 8) {
                    Label("\(captionCount)", systemImage: "text.bubble")
                    if screenshotCount > 0 {
                        Label("\(screenshotCount)", systemImage: "camera.viewfinder")
                    }
                    Text(byteString(meta.onDiskBytes))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private func byteString(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB]
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }
}

// MARK: - Bubble preview

/// Compact read-only bubble for the preview pane. Same alignment cues
/// as the main window (mic = right/blue, system = left/purple).
private struct PreviewBubble: View {
    let caption: Caption
    let imageStore: ChatImageStore

    private var alignment: HorizontalAlignment {
        caption.source == .microphone ? .trailing : .leading
    }
    private var tint: Color {
        caption.source == .microphone ? .blue : .purple
    }

    var body: some View {
        HStack {
            if alignment == .trailing { Spacer(minLength: 24) }
            VStack(alignment: alignment == .leading ? .leading : .trailing, spacing: 3) {
                if let filename = caption.imageFilename,
                   let nsImage = imageStore.loadImage(filename: filename) {
                    VStack(alignment: alignment == .leading ? .leading : .trailing, spacing: 4) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: 260, maxHeight: 160)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(tint.opacity(0.35), lineWidth: 1)
                            )
                        Label(caption.text, systemImage: "camera.viewfinder")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(tint.opacity(0.10))
                    )
                } else {
                    Text(caption.text)
                        .font(.callout)
                        .multilineTextAlignment(alignment == .leading ? .leading : .trailing)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(tint.opacity(0.14))
                        )
                        .textSelection(.enabled)
                }
                Text(caption.startedAt.formatted(date: .omitted, time: .standard))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if alignment == .leading { Spacer(minLength: 24) }
        }
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
    }
}
