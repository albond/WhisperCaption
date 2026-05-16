import SwiftUI
import AppKit

/// Root of the Settings window:
///  • `NavigationSplitView` — sidebar with grouped categories + global
///    search field, detail pane shows the selected section.
///  • Live theme — `.preferredColorScheme(...)` driven by
///    `SettingsStore.appearance`; switches Light/Dark/System without
///    reopening the window.
///  • Accent override — `.tint(...)` driven by `SettingsStore.accentColor`.
///
/// Opened with ⌘, (standard macOS Settings shortcut).
struct SettingsView: View {

    @Environment(SettingsStore.self) private var store

    @State private var selection: SettingsCategoryID? = .defaultSelection
    @State private var searchQuery: String = ""

    var body: some View {
        NavigationSplitView {
            SettingsSidebar(
                selection: $selection,
                searchQuery: $searchQuery
            )
        } detail: {
            detail
                .navigationSplitViewColumnWidth(min: 480, ideal: 620)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(
            minWidth: 780, idealWidth: 880, maxWidth: .infinity,
            minHeight: 520, idealHeight: 620, maxHeight: .infinity
        )
        .preferredColorScheme(store.appearance.colorScheme)
        .tint(store.accentColor.color)
        .toolbarBackground(.thinMaterial, for: .windowToolbar)
        .background(SettingsWindowConfigurator())
        .environment(store)
        .onChange(of: searchQuery) { _, _ in
            // Snap the detail view to the first match so the user lands
            // somewhere meaningful instead of staring at a stale page.
            guard !searchQuery.isEmpty,
                  let first = SettingsSearch.filter(query: searchQuery)?.first
            else { return }
            if selection != first.id {
                selection = first.id
            }
        }
        // Deep-link: any caller can post `.selectSettingsCategory` with a
        // `SettingsCategoryID` payload to jump the sidebar to that page.
        // Used by the About link to the Tip Jar and by the menu-bar
        // "Tip Jar…" item.
        .onReceive(NotificationCenter.default.publisher(for: .selectSettingsCategory)) { note in
            guard let target = note.object as? SettingsCategoryID else { return }
            if !searchQuery.isEmpty { searchQuery = "" }
            if selection != target { selection = target }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let id = selection {
            id.content
        } else {
            ContentUnavailableView(
                "Pick a category",
                systemImage: "sidebar.left",
                description: Text("Choose a section in the sidebar, or search above to jump to a setting.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }
}

// MARK: - Window configurator

/// Reaches into the hosting `NSWindow` and flips it into a one-row
/// `.unifiedCompact` title bar: traffic lights, the sidebar-toggle,
/// and the section title all share the same thin top strip — instead
/// of the default two-row layout where the toolbar items sit BELOW
/// a separate title row.
///
/// `Settings { ... }.windowToolbarStyle(.unifiedCompact)` on the Scene
/// alone doesn't apply this reliably (SwiftUI seems to reset toolbar
/// style after the window is created with a sidebar split). Walking up
/// to the NSWindow and setting it directly is the only path that survives.
private struct SettingsWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .visible
            window.styleMask.insert(.fullSizeContentView)
            window.toolbar?.displayMode = .iconOnly
            window.toolbarStyle = .unifiedCompact
            // Strip the minimize button per the Settings HUD descriptor.
            if !HUDDescriptor.settingsHUD.allowsMinimize {
                window.styleMask.remove(.miniaturizable)
            }
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

#Preview {
    SettingsView()
        .environment(SettingsStore())
}
