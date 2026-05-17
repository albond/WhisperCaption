import Foundation

/// Recipient + supported ERC-20 stablecoins for the Tip Jar.
///
/// The recipient address is a plain EVM address — it works on every
/// EVM-compatible chain. The Tip Jar offers two chains:
///
///  - **Polygon** (default) — gas typically under $0.01 per transfer, so
///    sending a small tip is actually economical.
///  - **Ethereum mainnet** — supports the widest token set (incl. EURC)
///    but gas can run $5–20 for a single ERC-20 transfer, which makes
///    sub-$20 tips economically silly.
///
/// USDC and USDT live on both chains at different contract addresses;
/// EURC only has a canonical Circle deployment on Ethereum mainnet, so
/// it's offered only when Ethereum is selected.
///
/// Sending on any *other* network (TRC-20, BSC, Arbitrum, Base, Solana
/// SPL, …) goes to a different address space and is unrecoverable. The
/// UI surfaces a quiet but unmissable warning for whichever chain is
/// currently selected.
///
/// **No QR code or wallet deeplink is generated.** The wallet ecosystem
/// turned out to be too fragmented for a single QR payload to work
/// reliably across MetaMask, Trust Wallet, Rainbow, Coinbase Wallet and
/// the rest on non-Ethereum chains. The Tip Jar instead surfaces a
/// big copy-to-clipboard address with the token + network spelled out
/// next to it — donors paste it into their own wallet's send flow.
enum TipJar {

    /// Destination EVM address — canonical EIP-55 mixed-case form. The
    /// same address is the recipient on every EVM chain (Ethereum,
    /// Polygon, etc.) because address derivation is identical across
    /// EVM chains. Verified by `TipJarPaymentURITests`. Wallets silently
    /// reject ERC-20 transfers whose addresses fail the checksum, so
    /// this string must NEVER be re-typed without re-running the
    /// checksum-validation test.
    static let recipient = "0xF734F20bFeB7ddb3f0519ADAfbBa056939c9C261"
}

// MARK: - Network

/// One EVM chain the Tip Jar can route a payment over.
enum TipJarNetwork: String, CaseIterable, Identifiable, Hashable, Sendable {
    case polygon
    case ethereum

    var id: String { rawValue }

    /// Human-readable name shown in the network selector.
    var displayName: String {
        switch self {
        case .polygon:  return "Polygon"
        case .ethereum: return "Ethereum mainnet"
        }
    }

    /// Short one-line hint about typical transfer gas cost, shown next
    /// to the network in the selector.
    var feeHint: String {
        switch self {
        case .polygon:  return "low fee — typically under $0.01"
        case .ethereum: return "high fee — ≈ $5–20 per transfer"
        }
    }

    /// Name of the asset-catalog image holding this chain's brand
    /// badge (circular, ready to render at any pixel size). Pre-
    /// composited so we don't have to layer a `Circle` background
    /// behind a transparent mark — important because SwiftUI's
    /// macOS `Menu` items render `Image` reliably but flatten custom
    /// `View` compositions to native asset size.
    var assetName: String {
        switch self {
        case .ethereum: return "EthereumLogo"
        case .polygon:  return "PolygonLogo"
        }
    }

    /// Tokens this chain has a canonical, verified contract address
    /// for. Source of truth: which (token, network) pairs are populated
    /// in `TipJarToken.contractAddress(on:)`.
    var supportedTokens: [TipJarToken] {
        TipJarToken.allCases.filter { $0.contractAddress(on: self) != nil }
    }
}

// MARK: - Token

/// One ERC-20 stablecoin offered as a tipping option.
enum TipJarToken: String, CaseIterable, Identifiable, Hashable, Sendable {
    case usdc
    case usdt
    case eurc

    var id: String { rawValue }

    /// Short user-facing ticker shown in the picker / hints.
    var ticker: String {
        switch self {
        case .usdc: return "USDC"
        case .usdt: return "USDT"
        case .eurc: return "EURC"
        }
    }

    /// One-line description used as a subtitle / accessibility hint.
    var subtitle: String {
        switch self {
        case .usdc: return "USD-pegged stablecoin by Circle"
        case .usdt: return "USD-pegged stablecoin by Tether"
        case .eurc: return "EUR-pegged stablecoin by Circle"
        }
    }

    /// ISO-style currency code used in the amount label.
    /// USDC/USDT track the dollar; EURC tracks the euro.
    var currencySymbol: String {
        switch self {
        case .usdc, .usdt: return "$"
        case .eurc:        return "€"
        }
    }

    /// "USD" for dollar-backed tokens, "EUR" for euro-backed.
    var pegLabel: String {
        switch self {
        case .usdc, .usdt: return "USD"
        case .eurc:        return "EUR"
        }
    }

    /// ERC-20 contract address for this token on the given EVM chain —
    /// canonical EIP-55 mixed-case capitalization. Returns nil if the
    /// token isn't issued on that chain (e.g. EURC on Polygon, where
    /// Circle hasn't shipped a canonical deployment yet).
    func contractAddress(on network: TipJarNetwork) -> String? {
        switch (self, network) {
        // Ethereum mainnet
        case (.usdc, .ethereum):
            return "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
        case (.usdt, .ethereum):
            return "0xdAC17F958D2ee523a2206206994597C13D831ec7"
        case (.eurc, .ethereum):
            return "0x1aBaEA1f7C830bD89Acc67eC4af516284b1bC33c"

        // Polygon PoS — Circle-native USDC + Tether USDT.
        // EURC has no canonical Circle deployment on Polygon yet, so
        // the picker hides EURC when Polygon is selected.
        case (.usdc, .polygon):
            return "0x3c499c542cef5E3811e1192ce70d8cC03d5c3359"
        case (.usdt, .polygon):
            return "0xc2132D05D31c914a87C6611C10748AEb04B58e8F"
        case (.eurc, .polygon):
            return nil
        }
    }
}
