import SwiftUI
import AppKit

/// "Buy the author a coffee" — crypto-only, stablecoin-only, address +
/// network spelled out plainly so the donor can paste it into their own
/// wallet's send flow.
///
/// No QR codes, no wallet deeplinks. We tried both: `ethereum:` EIP-681
/// URIs are spec-compliant but their mobile-wallet support is wildly
/// inconsistent across chains; wallet-specific HTTPS universal links
/// (MetaMask, Trust Wallet) work in exactly one wallet each and break
/// everywhere else. The plain-address path is the only thing that
/// reliably works in every wallet, so that's all we offer — clearly
/// labelled with token and network.
///
/// Compact layout: two settings cards, no scroll.
///   1. "Buy the author a coffee" — token pills, filtered by the
///      currently-selected chain.
///   2. "Send to" — big bold instruction stating the token + chain,
///      the address as a tappable copy-to-clipboard surface, an
///      inline network selector, and the unmissable
///      "<chain> only — other networks unrecoverable" warning.
struct TipJarSection: View {

    private let descriptor = SettingsCategoryID.tipJar.descriptor

    /// Default to Polygon — gas under a cent makes a small tip actually
    /// economical. Donors who want Ethereum mainnet can flip the
    /// network selector in the second card.
    @State private var network: TipJarNetwork = .polygon
    @State private var token: TipJarToken = .usdc

    private var warningFooter: String {
        switch network {
        case .polygon:
            return "**Polygon only** — sending on any other network (Ethereum mainnet, TRC-20, BSC, Arbitrum, Base, Solana, …) goes to a different address space and is unrecoverable."
        case .ethereum:
            return "**Ethereum mainnet only** — sending on any other network (Polygon, TRC-20, BSC, Arbitrum, Base, Solana, …) goes to a different address space and is unrecoverable."
        }
    }

    var body: some View {
        SectionShell(descriptor: descriptor) {
            TipJarComposeCard(
                token: $token,
                network: network
            )

            TipJarSendCard(
                token: token,
                network: $network,
                warningFooter: warningFooter
            )
        }
        .onChange(of: network) { _, newValue in
            // If the new network doesn't support the currently-selected
            // token, snap to the first one it does. (EURC isn't on
            // Polygon, for example.)
            if !newValue.supportedTokens.contains(token) {
                token = newValue.supportedTokens.first ?? .usdc
            }
        }
    }
}

// MARK: - Compose card

private struct TipJarComposeCard: View {

    @Binding var token: TipJarToken
    let network: TipJarNetwork

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        SettingsCard(
            title: "Buy the author a coffee",
            footer: "WhisperCaption is free and open source — if it saved you time today, a coffee back is appreciated. No account, no middleman, no fees skimmed."
        ) {
            TokenPillRow(selected: $token,
                         availableTokens: network.supportedTokens)
                .animation(
                    reduceMotion
                        ? .linear(duration: 0.001)
                        : .spring(response: 0.34, dampingFraction: 0.82),
                    value: token
                )
                .animation(
                    reduceMotion
                        ? .linear(duration: 0.001)
                        : .spring(response: 0.34, dampingFraction: 0.82),
                    value: network
                )
        }
    }
}

// MARK: - Token pill row

private struct TokenPillRow: View {

    @Binding var selected: TipJarToken
    let availableTokens: [TipJarToken]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(availableTokens) { tk in
                TokenPill(
                    token: tk,
                    isSelected: tk == selected
                ) {
                    selected = tk
                }
            }
        }
    }
}

private struct TokenPill: View {

    let token: TipJarToken
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                glyph
                VStack(alignment: .leading, spacing: 0) {
                    Text(token.ticker)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(token.pegLabel)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(background)
            .overlay(border)
            .scaleEffect(isSelected ? 1.0 : (isHovering ? 1.015 : 1.0))
            .shadow(
                color: token.primaryColor.opacity(isSelected ? 0.20 : 0),
                radius: isSelected ? 8 : 0,
                y: isSelected ? 3 : 0
            )
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .onHover { isHovering = $0 }
        .animation(motionCurve, value: isSelected)
        .animation(motionCurve, value: isHovering)
        .accessibilityLabel("\(token.ticker), \(token.subtitle)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var glyph: some View {
        ZStack {
            Circle()
                .fill(token.gradient)
                .frame(width: 26, height: 26)
                .shadow(color: token.primaryColor.opacity(0.35), radius: 3, y: 1)
            Circle()
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.55), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.6
                )
                .frame(width: 26, height: 26)
            Text(token.currencySymbol)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.15), radius: 0.7, y: 0.7)
        }
    }

    @ViewBuilder
    private var background: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            token.secondaryColor.opacity(0.18),
                            token.primaryColor.opacity(0.10)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        } else {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(.background.tertiary)
        }
    }

    private var border: some View {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder(
                isSelected
                    ? token.primaryColor.opacity(0.65)
                    : Color.primary.opacity(0.08),
                lineWidth: isSelected ? 1.3 : 0.6
            )
    }

    private var motionCurve: Animation {
        reduceMotion
            ? .linear(duration: 0.001)
            : .spring(response: 0.30, dampingFraction: 0.80)
    }
}

// MARK: - Send card

private struct TipJarSendCard: View {

    let token: TipJarToken
    @Binding var network: TipJarNetwork
    let warningFooter: String

    @State private var didCopy: Bool = false
    @State private var copyResetTask: Task<Void, Never>?
    @State private var addressHover: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        SettingsCard(
            title: "Send to",
            footer: warningFooter
        ) {
            VStack(alignment: .center, spacing: 14) {
                instructionRow
                addressPlate
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// Big bold "Send <TOKEN> on <NETWORK> ⇅ to:" line — the actionable
    /// instruction. Network is an inline borderless `Menu` so changing
    /// chain doesn't add a layout row.
    private var instructionRow: some View {
        HStack(spacing: 6) {
            Text("Send")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(token.ticker)
                .font(.title3.weight(.bold))
                .foregroundStyle(token.primaryColor)
            Text("on")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
            networkMenu
            Text("to:")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.top, 2)
    }

    /// Borderless menu styled as a thin inline label — the selected
    /// network's brand badge (blue Ethereum diamond / purple Polygon
    /// hexagon) sits left of the name so the donor sees what they're
    /// switching to in their wallet's network list. Menu items use
    /// `Label(title:image:)` which AppKit bridges to NSMenuItem with
    /// a properly-sized 14-pt icon — wrapping the asset in custom
    /// views inflated to native asset size in the popup.
    private var networkMenu: some View {
        Menu {
            ForEach(TipJarNetwork.allCases) { net in
                Button {
                    network = net
                } label: {
                    Label("\(net.displayName) — \(net.feeHint)",
                          image: net.assetName)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(network.assetName)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 20, height: 20)
                Text(network.displayName)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)
                Image(systemName: "chevron.up.chevron.down")
                    .imageScale(.small)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Switch network")
        .accessibilityLabel("Network: \(network.displayName). Click to change.")
    }

    /// Address as a tappable plate: monospace text, soft glass card,
    /// click anywhere on it = copy to clipboard. The whole surface is
    /// the affordance so there's nothing to aim at.
    private var addressPlate: some View {
        Button(action: copyAddress) {
            HStack(spacing: 10) {
                Text(TipJar.recipient)
                    .font(.system(.body, design: .monospaced).weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                    .imageScale(.medium)
                    .foregroundStyle(didCopy ? Color.green : token.primaryColor)
                    .contentTransition(.symbolEffect(.replace))

                Text(didCopy ? "Copied" : "Copy")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(didCopy ? Color.green : token.primaryColor)
                    .contentTransition(.opacity)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(plateBackground)
            .overlay(plateBorder)
            .shadow(color: token.primaryColor.opacity(addressHover ? 0.18 : 0.10),
                    radius: addressHover ? 10 : 6, y: 2)
            .scaleEffect(addressHover ? 1.005 : 1.0)
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { addressHover = $0 }
        .animation(reduceMotion ? .linear(duration: 0.001)
                                : .spring(response: 0.28, dampingFraction: 0.85),
                   value: addressHover)
        .animation(.easeInOut(duration: 0.18), value: didCopy)
        .accessibilityLabel(didCopy ? "Address copied to clipboard"
                                    : "Copy recipient address \(TipJar.recipient)")
        .help("Click anywhere on the address to copy it")
    }

    private var plateBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        token.secondaryColor.opacity(addressHover ? 0.14 : 0.10),
                        token.primaryColor.opacity(addressHover ? 0.08 : 0.05)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
    }

    private var plateBorder: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(token.primaryColor.opacity(0.30), lineWidth: 1)
    }

    private func copyAddress() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(TipJar.recipient, forType: .string)

        withAnimation(.easeInOut(duration: 0.18)) {
            didCopy = true
        }
        copyResetTask?.cancel()
        copyResetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.18)) {
                didCopy = false
            }
        }
    }
}

// MARK: - Preview

#Preview {
    TipJarSection()
        .frame(width: 720, height: 480)
}
