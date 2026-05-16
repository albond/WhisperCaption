import Foundation

/// Tiny helper that filters the sidebar against the search field.
/// Returns category IDs that match a query against title, subtitle, and
/// keyword list.
@MainActor
enum SettingsSearch {

    /// Empty / whitespace query returns nil (caller shows the full
    /// grouped sidebar). Non-empty query returns a flat ordered list of
    /// categories whose descriptor matches. Match is case-insensitive
    /// substring against title + subtitle + keywords.
    static func filter(query: String) -> [SettingsCategoryDescriptor]? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let needle = trimmed.lowercased()

        return SettingsRegistry.allDescriptors.filter { d in
            if d.title.lowercased().contains(needle) { return true }
            if d.subtitle.lowercased().contains(needle) { return true }
            return d.keywords.contains(where: { $0.lowercased().contains(needle) })
        }
    }
}
