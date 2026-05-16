import Foundation

/// Recipient + supported ERC-20 stablecoins for the Tip Jar.
///
/// USDC, USDT, and EURC live on Ethereum mainnet at the same recipient
/// wallet — same address, different token contracts. Sending on any
/// other network (TRC-20, Polygon, BSC, Arbitrum, Base, Solana SPL, …)
/// goes to a different address space and is unrecoverable. The UI
/// surfaces a quiet but unmissable mainnet-only reminder.
enum TipJar {

    /// Destination Ethereum address — canonical EIP-55 mixed-case form.
    /// Verified by `TipJarPaymentURITests`. Trust Wallet and MetaMask
    /// silently reject ERC-20 URIs whose addresses fail the checksum,
    /// so this string must NEVER be re-typed without re-running the
    /// checksum-validation test.
    static let recipient = "0xF734F20bFeB7ddb3f0519ADAfbBa056939c9C261"
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

    /// ERC-20 contract address on Ethereum mainnet — canonical EIP-55
    /// mixed-case capitalization. Encoded into the QR payload so a
    /// wallet that supports EIP-681 can pre-fill the token + amount on
    /// scan.
    var contractAddress: String {
        switch self {
        case .usdc: return "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
        case .usdt: return "0xdAC17F958D2ee523a2206206994597C13D831ec7"
        case .eurc: return "0x1aBaEA1f7C830bD89Acc67eC4af516284b1bC33c"
        }
    }

    /// All three tokens use 6 decimals. Kept as a per-case property so
    /// adding a new token with different precision later is a one-line
    /// change here, not a sweep across callers.
    var decimals: Int { 6 }
}

// MARK: - Amount

/// Human-typed tip amount, parsed from the text field.
///
/// We accept either a comma or a dot as the decimal separator (some locales
/// use comma) and reject anything that isn't a positive finite number.
struct TipJarAmount: Equatable, Sendable {

    let value: Decimal

    init?(text: String) {
        let trimmed = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard !trimmed.isEmpty else { return nil }
        guard let decimal = Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        guard decimal > 0 else { return nil }
        self.value = decimal
    }

    /// Convert the human amount into the token's smallest indivisible
    /// unit (`amount * 10^decimals`) as a base-10 string.
    /// Returns nil if the result would be fractional below the token's
    /// precision (e.g. $0.0000001 USDC).
    func baseUnitsString(decimals: Int) -> String? {
        var scaled = value
        var multiplier = Decimal(1)
        for _ in 0..<decimals {
            multiplier *= 10
        }
        scaled *= multiplier

        var rounded = Decimal()
        var input = scaled
        NSDecimalRound(&rounded, &input, 0, .plain)

        guard rounded >= 1 else { return nil }
        return NSDecimalNumber(decimal: rounded).stringValue
    }
}

// MARK: - Payment URI

/// Builds the QR-code payload using EIP-681 (the Ethereum URI scheme
/// most wallets understand for "scan to pay").
///
/// The token contract is **always** embedded in the URI, even when the
/// amount is empty — without it the wallet has no way of knowing which
/// asset to debit and falls back to ETH. That's a footgun, not a
/// feature: scanning a USDC tip-jar QR and seeing "Send ETH" is
/// exactly the wrong default.
///
///  - With amount: `ethereum:<contract>@1/transfer?address=<recipient>&uint256=<base_units>`
///  - Without amount: `ethereum:<contract>@1/transfer?address=<recipient>`
///    (wallet pre-selects the token + recipient, prompts for amount)
enum TipJarPaymentURI {

    static func make(token: TipJarToken, amount: TipJarAmount?) -> String {
        let base = "ethereum:\(token.contractAddress)@1/transfer?address=\(TipJar.recipient)"
        if let amount, let baseUnits = amount.baseUnitsString(decimals: token.decimals) {
            return base + "&uint256=\(baseUnits)"
        }
        return base
    }
}
