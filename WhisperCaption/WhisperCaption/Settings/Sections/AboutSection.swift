import SwiftUI
import AppKit

/// "About" page. Reads top to bottom as: what this app is, the
/// guarantees it makes, where to verify those guarantees in source, how
/// to reach the project, and — last — the exact build that's running.
/// Everything here is read-only.
struct AboutSection: View {

    private let descriptor = SettingsCategoryID.about.descriptor

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    private var bundleID: String {
        Bundle.main.bundleIdentifier ?? "—"
    }

    var body: some View {
        SectionShell(descriptor: descriptor) {
            AboutHeroCard(version: version, build: build)
            AboutHowItWorksCard()
            AboutSeeForYourselfCard()
            AboutTipJarCard()
            AboutContactCard()
            AboutDiagnosticsCard()
            AboutBuildMetadataCard(version: version, build: build, bundleID: bundleID)
        }
    }
}

// MARK: - Hero

private struct AboutHeroCard: View {

    let version: String
    let build: String

    private var icon: NSImage {
        NSApp.applicationIconImage ?? NSImage(named: NSImage.applicationIconName) ?? NSImage()
    }

    var body: some View {
        SettingsCard(title: nil, footer: nil) {
            HStack(alignment: .center, spacing: 16) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 64, height: 64)
                    .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 6) {
                    Text("WhisperCaption")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("Live captions for macOS — local-first, no signups, no telemetry.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    AboutVersionPill(version: version, build: build)
                        .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

private struct AboutVersionPill: View {

    let version: String
    let build: String

    var body: some View {
        HStack(spacing: 5) {
            Text("v\(version)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
            Text("·")
                .foregroundStyle(.tertiary)
            Text("build \(build)")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .monospacedDigit()
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
        )
    }
}

// MARK: - How it works

private struct AboutHowItWorksCard: View {

    var body: some View {
        SettingsCard(title: "How it works", footer: nil) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Two audio streams — your mic and whatever the Mac is playing — go through the speech engine you pick, and land side-by-side in a two-column chat. Choose what fits the moment.")
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(alignment: .top, spacing: 8) {
                    AboutPillarChip(
                        icon: "wifi.slash",
                        tint: .green,
                        title: "Offline",
                        subtitle: "WhisperKit, on-device"
                    )
                    AboutPillarChip(
                        icon: "key.fill",
                        tint: .orange,
                        title: "Your key",
                        subtitle: "Deepgram or ElevenLabs"
                    )
                    AboutPillarChip(
                        icon: "eye.slash.fill",
                        tint: .blue,
                        title: "Yours alone",
                        subtitle: "No telemetry, no account"
                    )
                }
            }
        }
    }
}

private struct AboutPillarChip: View {

    let icon: String
    let tint: Color
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(tint.gradient)
                    .frame(width: 28, height: 28)
                    .shadow(color: tint.opacity(0.28), radius: 3, y: 1)
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(.background.tertiary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.6)
        )
    }
}

// MARK: - See for yourself

private struct AboutSeeForYourselfCard: View {

    private let repoURL = URL(string: "https://github.com/albond/WhisperCaption")!

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        SettingsCard(
            title: "Don't take my word for it",
            footer: "MIT license. The repo is exactly what you run — no hidden binary, no extra server."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Everything WhisperCaption does sits in the open. Read the source, audit what leaves your machine, build your own copy — every privacy claim on this screen is something you can confirm yourself in the code.")
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 16) {
                    AboutStepBadge(number: "1", text: "Clone")
                    AboutStepBadge(number: "2", text: "Open in Xcode")
                    AboutStepBadge(number: "3", text: "⌘R")
                    Spacer(minLength: 0)
                }

                Button(action: { NSWorkspace.shared.open(repoURL) }) {
                    HStack(spacing: 9) {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Open repository on GitHub")
                            .font(.callout.weight(.semibold))
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 11, weight: .semibold))
                            .opacity(0.75)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Color.blue, Color.indigo],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.28), .clear],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 0.6
                            )
                    )
                    .shadow(
                        color: .blue.opacity(isHovering ? 0.32 : 0.20),
                        radius: isHovering ? 10 : 6,
                        y: 2
                    )
                    .scaleEffect(isHovering ? 1.01 : 1.0)
                }
                .buttonStyle(.plain)
                .onHover { isHovering = $0 }
                .animation(
                    reduceMotion ? .linear(duration: 0.001) : .easeInOut(duration: 0.16),
                    value: isHovering
                )
                .accessibilityLabel("Open WhisperCaption repository on GitHub")
            }
        }
    }
}

private struct AboutStepBadge: View {

    let number: String
    let text: String

    var body: some View {
        HStack(spacing: 7) {
            Text(number)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.blue.opacity(0.85)))
            Text(text)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Tip jar shortcut

private struct AboutTipJarCard: View {

    var body: some View {
        SettingsCard(title: nil, footer: nil) {
            AboutLinkRow(
                icon: "cup.and.saucer.fill",
                tint: .orange,
                title: "Tip the author a coffee",
                subtitle: "If WhisperCaption saved you time, send a stablecoin tip on Ethereum mainnet. No fees skimmed."
            ) {
                NotificationCenter.default.post(
                    name: .selectSettingsCategory,
                    object: SettingsCategoryID.tipJar
                )
            }
        }
    }
}

// MARK: - Contact / project links

private struct AboutContactCard: View {

    var body: some View {
        SettingsCard(title: "Project", footer: nil) {
            VStack(spacing: 0) {
                AboutLinkRow(
                    icon: "envelope.fill",
                    tint: .purple,
                    title: "Email",
                    subtitle: "albond.dev@proton.me"
                ) {
                    open("mailto:albond.dev@proton.me")
                }
                SettingsRowDivider()
                AboutLinkRow(
                    icon: "doc.text.fill",
                    tint: .teal,
                    title: "License (MIT)",
                    subtitle: "Free for any use, modification, and redistribution."
                ) {
                    open("https://github.com/albond/WhisperCaption/blob/main/LICENSE")
                }
            }
        }
    }

    private func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Diagnostics

private struct AboutDiagnosticsCard: View {

    var body: some View {
        SettingsCard(
            title: "Diagnostics",
            footer: "Logs use the OSLog subsystem `com.albond.WhisperCaption`. Inspect them in Console.app or via `log show --predicate 'subsystem == \"com.albond.WhisperCaption\"' --info --debug --last 5m`."
        ) {
            HStack {
                SettingsRowLabel(
                    title: "Reveal logs in Console",
                    subtitle: "Opens Console.app for inspection of WhisperCaption's log entries."
                )
                Spacer()
                Button("Open Console") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Console.app"))
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

// MARK: - Build metadata

private struct AboutBuildMetadataCard: View {

    let version: String
    let build: String
    let bundleID: String

    var body: some View {
        SettingsCard(title: "Build", footer: nil) {
            VStack(spacing: 0) {
                metadataRow(label: "Version", value: version)
                SettingsRowDivider()
                metadataRow(label: "Build", value: build)
                SettingsRowDivider()
                metadataRow(label: "Bundle identifier", value: bundleID, monospaced: true)
            }
        }
    }

    private func metadataRow(label: String, value: String, monospaced: Bool = false) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(monospaced ? .system(.body, design: .monospaced) : .body)
                .textSelection(.enabled)
        }
    }
}

// MARK: - Reusable link row

private struct AboutLinkRow: View {

    let icon: String
    let tint: Color
    let title: String
    let subtitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(tint.gradient)
                    .frame(width: 28, height: 28)
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }
            SettingsRowLabel(title: title, subtitle: subtitle)
            Spacer(minLength: 0)
            Button("Open", action: action)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }
}

#Preview {
    AboutSection()
        .frame(width: 720, height: 600)
}
