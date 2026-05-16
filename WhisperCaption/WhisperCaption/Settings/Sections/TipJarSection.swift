import SwiftUI
import AppKit

/// "Buy the author a coffee" — crypto-only, stablecoin-only, Ethereum
/// mainnet only.
///
/// Compact layout: two settings cards, no hero, no scroll.
///   1. "Compose" — token pills + amount with presets.
///   2. "Scan to send" — QR, summary, recipient address with copy.
/// Mainnet warning lives in the second card's markdown footer so it's
/// always next to the copy-this-and-pay surface, where the donor's
/// attention already is.
struct TipJarSection: View {

    private let descriptor = SettingsCategoryID.tipJar.descriptor

    @State private var token: TipJarToken = .usdc
    @State private var amountText: String = ""

    private var parsedAmount: TipJarAmount? {
        TipJarAmount(text: amountText)
    }

    private var paymentURI: String {
        TipJarPaymentURI.make(token: token, amount: parsedAmount)
    }

    private var hasValidAmount: Bool {
        guard let parsedAmount else { return false }
        return parsedAmount.baseUnitsString(decimals: token.decimals) != nil
    }

    var body: some View {
        SectionShell(descriptor: descriptor) {
            TipJarComposeCard(
                token: $token,
                amountText: $amountText
            )

            TipJarScanCard(
                paymentURI: paymentURI,
                token: token,
                amountText: amountText,
                hasValidAmount: hasValidAmount
            )
        }
    }
}

// MARK: - Compose card

private struct TipJarComposeCard: View {

    @Binding var token: TipJarToken
    @Binding var amountText: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        SettingsCard(
            title: "Buy the author a coffee",
            footer: "WhisperCaption is free and open source — if it saved you time today, a coffee back is appreciated. No account, no middleman, no fees skimmed."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                TokenPillRow(selected: $token)
                AmountRow(text: $amountText, token: token)
            }
            .animation(
                reduceMotion
                    ? .linear(duration: 0.001)
                    : .spring(response: 0.34, dampingFraction: 0.82),
                value: token
            )
        }
    }
}

// MARK: - Token pill row

private struct TokenPillRow: View {

    @Binding var selected: TipJarToken

    var body: some View {
        HStack(spacing: 8) {
            ForEach(TipJarToken.allCases) { tk in
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

// MARK: - Amount row

private struct AmountRow: View {

    @Binding var text: String
    let token: TipJarToken

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            inputField
                .frame(minWidth: 130, idealWidth: 140, maxWidth: 160)
            presetChip("5")
            presetChip("10")
            presetChip("20")
            Spacer(minLength: 0)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Text("Clear")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: text.isEmpty)
    }

    private var inputField: some View {
        HStack(spacing: 6) {
            Text(token.currencySymbol)
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 14, alignment: .leading)
            TextField("0", text: $text)
                .textFieldStyle(.plain)
                .font(.title3.weight(.medium).monospacedDigit())
                .focused($isFocused)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.background.tertiary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    isFocused
                        ? token.primaryColor.opacity(0.55)
                        : Color.primary.opacity(0.10),
                    lineWidth: isFocused ? 1.2 : 0.6
                )
        )
        .animation(.easeInOut(duration: 0.15), value: isFocused)
        .contentShape(Rectangle())
        .onTapGesture { isFocused = true }
    }

    private func presetChip(_ value: String) -> some View {
        let isActive = text == value
        return Button {
            text = value
        } label: {
            Text("\(token.currencySymbol)\(value)")
                .font(.caption.weight(isActive ? .semibold : .medium))
                .foregroundStyle(isActive ? .white : .primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(
                            isActive
                                ? AnyShapeStyle(token.gradient)
                                : AnyShapeStyle(Color.primary.opacity(0.06))
                        )
                )
                .overlay(
                    Capsule()
                        .strokeBorder(
                            isActive
                                ? Color.clear
                                : Color.primary.opacity(0.08),
                            lineWidth: 0.6
                        )
                )
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.16), value: isActive)
    }
}

// MARK: - Scan card

private struct TipJarScanCard: View {

    let paymentURI: String
    let token: TipJarToken
    let amountText: String
    let hasValidAmount: Bool

    @State private var didCopy: Bool = false
    @State private var copyResetTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        SettingsCard(
            title: "Scan to send",
            footer: "**Ethereum mainnet only** — other networks (TRC-20, Polygon, BSC, Arbitrum, Base, Solana) are unrecoverable."
        ) {
            VStack(spacing: 10) {
                qrView
                    .id(paymentURI)
                    .transition(.opacity)
                    .animation(
                        reduceMotion
                            ? .linear(duration: 0.001)
                            : .easeInOut(duration: 0.20),
                        value: paymentURI
                    )

                captionRow
                addressRow
            }
        }
    }

    // MARK: QR

    @ViewBuilder
    private var qrView: some View {
        if let image = QRCodeImage.make(payload: paymentURI, targetPoints: 160) {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: 160, height: 160)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.white)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.6)
                )
                .shadow(color: .black.opacity(0.06), radius: 10, y: 3)
                .accessibilityLabel(qrAccessibilityLabel)
        } else {
            ContentUnavailableView(
                "Couldn't render QR",
                systemImage: "exclamationmark.triangle",
                description: Text("Copy the address below instead.")
            )
            .frame(height: 160)
        }
    }

    private var qrAccessibilityLabel: String {
        if hasValidAmount {
            return "QR code for sending \(amountText) \(token.ticker) on Ethereum mainnet."
        }
        return "QR code for the Ethereum recipient address \(TipJar.recipient)."
    }

    // MARK: Caption (amount · network)

    private var captionRow: some View {
        HStack(spacing: 8) {
            if hasValidAmount {
                Text("\(token.currencySymbol)\(amountText)")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())
                Text(token.ticker)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(token.primaryColor)
            } else {
                Text(token.ticker)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(token.primaryColor)
            }

            Text("·")
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 1)

            Text("Ethereum mainnet")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Address row

    private var addressRow: some View {
        HStack(spacing: 8) {
            Text(TipJar.recipient)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: copyAddress) {
                HStack(spacing: 4) {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        .imageScale(.small)
                    Text(didCopy ? "Copied" : "Copy")
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(didCopy ? Color.green : Color.primary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(didCopy
                              ? Color.green.opacity(0.12)
                              : Color.primary.opacity(0.06))
                )
                .overlay(
                    Capsule()
                        .strokeBorder(
                            didCopy
                                ? Color.green.opacity(0.35)
                                : Color.primary.opacity(0.10),
                            lineWidth: 0.5
                        )
                )
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(didCopy ? "Address copied" : "Copy recipient address")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(.background.tertiary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
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
        .frame(width: 720, height: 600)
}
