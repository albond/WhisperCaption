import Foundation
import Testing
@testable import WhisperCaption

/// Verifies every Token × Amount combination produces a URI that
/// (a) embeds the right token contract so the wallet never falls back
/// to ETH, (b) embeds the right recipient, (c) uses canonical EIP-55
/// mixed-case capitalization on every Ethereum address. Trust Wallet
/// silently rejects ERC-20 URIs whose contract address has an invalid
/// mixed-case checksum.
struct TipJarPaymentURITests {

    // MARK: - Canonical strings (hand-verified against issuer docs +
    // checksummed by an external Keccak-256 implementation; treat as
    // fixed-point fixtures — if production code drifts, the test fails
    // before the wallet does.)

    private let recipient = "0xF734F20bFeB7ddb3f0519ADAfbBa056939c9C261"

    private let usdc = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
    private let usdt = "0xdAC17F958D2ee523a2206206994597C13D831ec7"
    private let eurc = "0x1aBaEA1f7C830bD89Acc67eC4af516284b1bC33c"

    // MARK: - Model returns the canonical strings

    @Test func recipient_matchesCanonical() {
        #expect(TipJar.recipient == recipient)
    }

    @Test func contracts_matchCanonical() {
        #expect(TipJarToken.usdc.contractAddress == usdc)
        #expect(TipJarToken.usdt.contractAddress == usdt)
        #expect(TipJarToken.eurc.contractAddress == eurc)
    }

    // MARK: - URIs without amount

    @Test func usdc_noAmount() {
        let uri = TipJarPaymentURI.make(token: .usdc, amount: nil)
        #expect(uri == "ethereum:\(usdc)@1/transfer?address=\(recipient)")
    }

    @Test func usdt_noAmount() {
        let uri = TipJarPaymentURI.make(token: .usdt, amount: nil)
        #expect(uri == "ethereum:\(usdt)@1/transfer?address=\(recipient)")
    }

    @Test func eurc_noAmount() {
        let uri = TipJarPaymentURI.make(token: .eurc, amount: nil)
        #expect(uri == "ethereum:\(eurc)@1/transfer?address=\(recipient)")
    }

    // MARK: - URIs with amount (6 decimals → $5 = 5_000_000 base units)

    @Test func usdc_fiveDollars() {
        let uri = TipJarPaymentURI.make(token: .usdc, amount: TipJarAmount(text: "5"))
        #expect(uri == "ethereum:\(usdc)@1/transfer?address=\(recipient)&uint256=5000000")
    }

    @Test func usdt_fiveDollars() {
        let uri = TipJarPaymentURI.make(token: .usdt, amount: TipJarAmount(text: "5"))
        #expect(uri == "ethereum:\(usdt)@1/transfer?address=\(recipient)&uint256=5000000")
    }

    @Test func eurc_fiveEuros() {
        let uri = TipJarPaymentURI.make(token: .eurc, amount: TipJarAmount(text: "5"))
        #expect(uri == "ethereum:\(eurc)@1/transfer?address=\(recipient)&uint256=5000000")
    }

    // MARK: - Cross-cutting invariants

    @Test func everyURI_embedsContract() {
        for token in TipJarToken.allCases {
            for amountText in ["", "5", "0.25"] {
                let amount = TipJarAmount(text: amountText)
                let uri = TipJarPaymentURI.make(token: token, amount: amount)
                #expect(uri.contains(token.contractAddress),
                        "URI \(uri) should contain \(token.contractAddress)")
            }
        }
    }

    @Test func noAmountURIs_areDistinctPerToken() {
        let uris = TipJarToken.allCases.map { TipJarPaymentURI.make(token: $0, amount: nil) }
        #expect(Set(uris).count == uris.count, "Per-token URIs must differ")
    }

    @Test func everyURI_isERC20TransferToRecipient() {
        for token in TipJarToken.allCases {
            for amountText in ["", "5"] {
                let amount = TipJarAmount(text: amountText)
                let uri = TipJarPaymentURI.make(token: token, amount: amount)
                #expect(uri.hasPrefix("ethereum:"))
                #expect(uri.contains("@1/transfer?address=\(recipient)"))
            }
        }
    }

    // MARK: - Address shape

    @Test func recipient_isHexAndCorrectLength() {
        let r = TipJar.recipient
        #expect(r.hasPrefix("0x"))
        #expect(r.count == 42)
        let hex = Set("0123456789abcdefABCDEF")
        #expect(r.dropFirst(2).allSatisfy { hex.contains($0) })
    }

    /// Catch the bug that nearly shipped: every Ethereum address in the
    /// model — recipient + every ERC-20 contract — must match its
    /// canonical EIP-55 mixed-case form byte-for-byte. The canonical
    /// strings up top serve as the golden source, computed out-of-band
    /// with Keccak-256. If anyone re-types an address with the wrong
    /// capitalization (e.g. all-lowercase from a copy-paste), this
    /// test trips before the wallet silently rejects the URI.
    @Test func ethereumAddresses_useCanonicalEIP55Capitalization() {
        #expect(TipJar.recipient == recipient)
        #expect(TipJarToken.usdc.contractAddress == usdc)
        #expect(TipJarToken.usdt.contractAddress == usdt)
        #expect(TipJarToken.eurc.contractAddress == eurc)

        let hex = Set("0123456789abcdefABCDEF")
        for addr in [recipient, usdc, usdt, eurc] {
            #expect(addr.hasPrefix("0x"))
            #expect(addr.count == 42)
            #expect(addr.dropFirst(2).allSatisfy { hex.contains($0) })
        }
    }
}
