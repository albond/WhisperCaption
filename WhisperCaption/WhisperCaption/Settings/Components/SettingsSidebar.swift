import SwiftUI

/// Left pane of the Settings split view: search field at top + grouped
/// list of every category. When the search field is non-empty the grouped
/// list collapses into a flat "Results" section.
struct SettingsSidebar: View {

    @Binding var selection: SettingsCategoryID?
    @Binding var searchQuery: String

    var body: some View {
        VStack(spacing: 0) {
            list
        }
        .navigationTitle("Settings")
        .navigationSplitViewColumnWidth(min: 250, ideal: 270, max: 320)
        .searchable(
            text: $searchQuery,
            placement: .sidebar,
            prompt: "Search settings"
        )
    }

    @ViewBuilder
    private var list: some View {
        if let results = SettingsSearch.filter(query: searchQuery) {
            // Flat results list under one synthetic header. Empty array
            // means "no matches" — render an inline hint, not an empty
            // list with weird spacing.
            List(selection: $selection) {
                if results.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("No matches")
                                .font(.callout.weight(.medium))
                            Text("Try a different word or clear the search to see all settings.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 4)
                    }
                } else {
                    Section("Results") {
                        ForEach(results) { d in
                            NavigationLink(value: d.id) {
                                SidebarRow(descriptor: d)
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        } else {
            List(selection: $selection) {
                ForEach(SettingsRegistry.groupedCategories, id: \.group.id) { entry in
                    Section(entry.group.title) {
                        ForEach(entry.items) { d in
                            NavigationLink(value: d.id) {
                                SidebarRow(descriptor: d)
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }
}

#Preview {
    NavigationSplitView {
        SettingsSidebar(
            selection: .constant(.appearance),
            searchQuery: .constant("")
        )
    } detail: {
        Text("Detail")
    }
    .frame(width: 920, height: 600)
}
