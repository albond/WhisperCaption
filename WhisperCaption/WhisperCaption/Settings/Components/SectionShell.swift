import SwiftUI

/// Reusable layout shell for every Settings detail page.
///
/// Visual contract:
///  • The page title + tinted icon live in the WINDOW TITLE BAR — same
///    place macOS System Settings shows them. We don't render a second
///    hero block at the top of the scroll view.
///  • The detail pane uses a `.thinMaterial` backdrop so cards float on
///    a softly tinted surface rather than a flat window color.
///  • Cards (`SettingsCard`) carry rounded corners, a hair-thin border +
///    plus-lighter top highlight, and a soft drop shadow.

// MARK: - Section shell

struct SectionShell<Content: View>: View {

    let descriptor: SettingsCategoryDescriptor
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                content()
            }
            .frame(maxWidth: 640, alignment: .center)
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SettingsBackground())
        // Inline title shown in the (compact) window title bar.
        .navigationTitle(descriptor.title)
    }
}

// MARK: - Toolbar title

/// Tinted SF symbol + section name. Lives in the window title bar
/// alongside the `sidebar.left` toggle so the toolbar reads as one
/// coherent strip instead of "lonely toggle floating next to nothing".
struct ToolbarTitleLabel: View {

    let descriptor: SettingsCategoryDescriptor

    var body: some View {
        Label {
            Text(descriptor.title)
                .font(.headline)
        } icon: {
            Image(systemName: descriptor.systemImage)
                .foregroundStyle(descriptor.tint.color)
        }
        .labelStyle(.titleAndIcon)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(descriptor.title)
    }
}

// MARK: - Hero icon (kept for sections that build their own layout)

/// Used by sections that build their own non-`SectionShell` layout (e.g.
/// `ChatHistorySection` with its split list/detail layout).
struct SettingsHeroIcon: View {
    let systemName: String
    let tint: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.95), tint.opacity(0.78)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.30),
                            Color.white.opacity(0.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.7
                )

            Image(systemName: systemName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
                .accessibilityHidden(true)
        }
        .frame(width: 36, height: 36)
        .shadow(color: tint.opacity(0.28), radius: 6, y: 3)
    }
}

// MARK: - Background

/// Detail-pane backdrop. Uses a thin material overlay so the cards sit
/// on a neutral surface (rather than pure window background).
private struct SettingsBackground: View {
    var body: some View {
        Rectangle()
            .fill(.background)
            .overlay(
                Rectangle()
                    .fill(.thinMaterial.opacity(0.4))
            )
            .ignoresSafeArea()
    }
}

// MARK: - Card

/// One rounded card grouping related rows. Optional title sits above
/// the card in soft caption weight (Title Case, NOT uppercase tracking);
/// optional footer drops beneath in secondary text. Inner content is
/// untouched — callers compose rows with `SettingsRow` or raw HStacks.
struct SettingsCard<Content: View>: View {

    var title: String?
    var footer: String?

    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary.opacity(0.9))
                    .padding(.horizontal, 6)
            }

            VStack(spacing: 0) {
                content()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.background.secondary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.6)
            )
            .overlay(alignment: .top) {
                // Hair-thin top highlight — sells the "lifted" look.
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .trim(from: 0.0, to: 0.5)
                    .stroke(
                        LinearGradient(
                            colors: [.white.opacity(0.18), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.6
                    )
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(0.06), radius: 6, y: 2)

            if let footer {
                Text(.init(footer))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 6)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Row primitives

/// Two-line label used inside cards — bold title + secondary subtitle.
struct SettingsRowLabel: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.body.weight(.medium))
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Hairline divider between rows inside a `SettingsCard`. Softer than
/// the default so it doesn't visually chop the card into pieces.
struct SettingsRowDivider: View {
    var body: some View {
        Divider()
            .opacity(0.4)
            .padding(.vertical, 10)
    }
}
