import SwiftUI

/// One row in the Settings sidebar — colored rounded icon tile + title.
/// Tuned to read like macOS System Settings: rounded squircle, gradient
/// fill + subtle inner top highlight, comfortable spacing between the
/// icon and the label.
struct SidebarRow: View {

    let descriptor: SettingsCategoryDescriptor
    var isSelected: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            iconTile

            Text(descriptor.title)
                .font(.system(.body))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(descriptor.title). \(descriptor.subtitle)")
    }

    /// Mirrors the hero icon design in `SectionShell` at a smaller scale
    /// so the sidebar visually previews the bigger header tile the user
    /// will land on after selecting the row.
    private var iconTile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            descriptor.tint.color.opacity(0.95),
                            descriptor.tint.color.opacity(0.78)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.30),
                            Color.white.opacity(0.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.6
                )

            Image(systemName: descriptor.systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.15), radius: 0.8, y: 0.4)
                .accessibilityHidden(true)
        }
        .frame(width: 22, height: 22)
    }
}

#Preview {
    List {
        SidebarRow(descriptor: SettingsCategoryID.appearance.descriptor)
        SidebarRow(descriptor: SettingsCategoryID.privacy.descriptor)
        SidebarRow(descriptor: SettingsCategoryID.hotkeys.descriptor)
        SidebarRow(descriptor: SettingsCategoryID.speech.descriptor)
        SidebarRow(descriptor: SettingsCategoryID.tipJar.descriptor)
        SidebarRow(descriptor: SettingsCategoryID.about.descriptor)
    }
    .listStyle(.sidebar)
    .frame(width: 260, height: 480)
}
