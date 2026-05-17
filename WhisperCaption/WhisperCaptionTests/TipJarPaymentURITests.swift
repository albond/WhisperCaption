import Foundation
import Testing
@testable import WhisperCaption

/// EVM-address fidelity tests for the Tip Jar.
///
/// We no longer ship QR codes or wallet deeplinks (mobile wallet
/// ecosystem proved too fragmented to land on one format that works
/// across MetaMask, Trust Wallet, Rainbow, Coinbase Wallet on
/// non-Ethereum chains). What remains is a plain copy-to-clipboard
/// address path — so the only thing the tests need to guarantee is
/// that every address rendered in the UI is byte-for-byte the
/// canonical EIP-55 mixed-case form. Wallets silently reject ERC-20
/// transfers whose addresses fail the Keccak-256 checksum; this test
/// catches that drift before a wallet does.
struct TipJarPaymentURITests {

    // MARK: - Canonical strings (hand-verified against issuer docs +
    // checksummed by an external Keccak-256 implementation; treat as
    // fixed-point fixtures — if production code drifts, the test fails
    // before the wallet does.)

    private let recipient = "0xF734F20bFeB7ddb3f0519ADAfbBa056939c9C261"

    // Ethereum mainnet
    private let usdcEth = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
    private let usdtEth = "0xdAC17F958D2ee523a2206206994597C13D831ec7"
    private let eurcEth = "0x1aBaEA1f7C830bD89Acc67eC4af516284b1bC33c"

    // Polygon PoS
    private let usdcPolygon = "0x3c499c542cef5E3811e1192ce70d8cC03d5c3359"
    private let usdtPolygon = "0xc2132D05D31c914a87C6611C10748AEb04B58e8F"

    // MARK: - Recipient

    @Test func recipient_matchesCanonical() {
        #expect(TipJar.recipient == recipient)
    }

    @Test func recipient_isHexAndCorrectLength() {
        let r = TipJar.recipient
        #expect(r.hasPrefix("0x"))
        #expect(r.count == 42)
        let hex = Set("0123456789abcdefABCDEF")
        #expect(r.dropFirst(2).allSatisfy { hex.contains($0) })
    }

    // MARK: - Token contracts per chain

    @Test func ethereumContracts_matchCanonical() {
        #expect(TipJarToken.usdc.contractAddress(on: .ethereum) == usdcEth)
        #expect(TipJarToken.usdt.contractAddress(on: .ethereum) == usdtEth)
        #expect(TipJarToken.eurc.contractAddress(on: .ethereum) == eurcEth)
    }

    @Test func polygonContracts_matchCanonical() {
        #expect(TipJarToken.usdc.contractAddress(on: .polygon) == usdcPolygon)
        #expect(TipJarToken.usdt.contractAddress(on: .polygon) == usdtPolygon)
        // EURC has no canonical Circle deployment on Polygon — the
        // picker filters it out when Polygon is selected.
        #expect(TipJarToken.eurc.contractAddress(on: .polygon) == nil)
    }

    // MARK: - Network's supportedTokens reflects contractAddress map

    @Test func polygonSupportedTokens_excludesEurc() {
        let polygonTokens = TipJarNetwork.polygon.supportedTokens
        #expect(polygonTokens.contains(.usdc))
        #expect(polygonTokens.contains(.usdt))
        #expect(!polygonTokens.contains(.eurc))
    }

    @Test func ethereumSupportedTokens_includesAll() {
        let ethTokens = TipJarNetwork.ethereum.supportedTokens
        #expect(ethTokens.contains(.usdc))
        #expect(ethTokens.contains(.usdt))
        #expect(ethTokens.contains(.eurc))
    }

    // MARK: - EIP-55 mixed-case capitalization

    /// Every EVM address in the model — recipient + every token contract
    /// on every chain — must match its canonical EIP-55 mixed-case form
    /// byte-for-byte. The canonical strings up top serve as the golden
    /// source, computed out-of-band with Keccak-256. If anyone re-types
    /// an address with the wrong capitalization (e.g. all-lowercase
    /// from a copy-paste), this test trips before any wallet does.
    @Test func evmAddresses_useCanonicalEIP55Capitalization() {
        #expect(TipJar.recipient == recipient)
        #expect(TipJarToken.usdc.contractAddress(on: .ethereum) == usdcEth)
        #expect(TipJarToken.usdt.contractAddress(on: .ethereum) == usdtEth)
        #expect(TipJarToken.eurc.contractAddress(on: .ethereum) == eurcEth)
        #expect(TipJarToken.usdc.contractAddress(on: .polygon) == usdcPolygon)
        #expect(TipJarToken.usdt.contractAddress(on: .polygon) == usdtPolygon)

        let hex = Set("0123456789abcdefABCDEF")
        let allAddresses = [recipient, usdcEth, usdtEth, eurcEth, usdcPolygon, usdtPolygon]
        for addr in allAddresses {
            #expect(addr.hasPrefix("0x"))
            #expect(addr.count == 42)
            #expect(addr.dropFirst(2).allSatisfy { hex.contains($0) })
        }
    }
}
