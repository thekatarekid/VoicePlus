import Foundation
import CryptoKit

/// What one device shows in its QR: identity + ephemeral X25519 public key + short code (the HKDF salt,
/// also read aloud/compared by the human so a swapped QR is caught).
public struct PairingPayload: Codable, Equatable, Sendable {
    public static let scheme = "voiceplus-pair"
    public var deviceID: String
    public var deviceName: String
    public var publicKey: Data      // 32-byte X25519 raw representation
    public var shortCode: String    // 6 digits

    public init(deviceID: String, deviceName: String, publicKey: Data, shortCode: String) {
        self.deviceID = deviceID; self.deviceName = deviceName; self.publicKey = publicKey; self.shortCode = shortCode
    }

    /// URL form encoded in the QR: voiceplus-pair://v1?d=<id>&n=<name>&k=<base64url pub>&c=<code>
    public var qrString: String {
        var c = URLComponents(); c.scheme = Self.scheme; c.host = "v1"
        c.queryItems = [.init(name: "d", value: deviceID), .init(name: "n", value: deviceName),
                        .init(name: "k", value: publicKey.base64URLEncoded), .init(name: "c", value: shortCode)]
        return c.string ?? ""
    }

    public enum ParseError: Error, Equatable { case badScheme, missingField(String), badKey }

    public static func parse(_ string: String) throws -> PairingPayload {
        guard let c = URLComponents(string: string), c.scheme == scheme, c.host == "v1" else { throw ParseError.badScheme }
        func q(_ n: String) throws -> String {
            guard let v = c.queryItems?.first(where: { $0.name == n })?.value, !v.isEmpty else { throw ParseError.missingField(n) }
            return v
        }
        guard let key = Data(base64URL: try q("k")), key.count == 32 else { throw ParseError.badKey }
        return PairingPayload(deviceID: try q("d"), deviceName: try q("n"), publicKey: key, shortCode: try q("c"))
    }
}

public enum PairingError: Error, Equatable { case codeMismatch, badPeerKey, selfPairing }

/// One side of a handshake. Each device: `let s = PairingSession(...)`, show `s.payload` as QR, scan the peer's,
/// call `s.complete(with:)`. Both sides derive the same `SyncKey` (X25519 ECDH → HKDF, salt = both short codes sorted).
public final class PairingSession: @unchecked Sendable {
    public let deviceID: String
    public let deviceName: String
    public let shortCode: String
    private let privateKey: Curve25519.KeyAgreement.PrivateKey

    public init(deviceID: String, deviceName: String, shortCode: String? = nil) {
        self.deviceID = deviceID; self.deviceName = deviceName
        self.shortCode = shortCode ?? Self.randomCode()
        self.privateKey = Curve25519.KeyAgreement.PrivateKey()
    }

    public var payload: PairingPayload {
        PairingPayload(deviceID: deviceID, deviceName: deviceName, publicKey: privateKey.publicKey.rawRepresentation, shortCode: shortCode)
    }

    /// `confirmedPeerCode` is what the user read off the other screen; must match the scanned payload's code.
    public func complete(with peer: PairingPayload, confirmedPeerCode: String? = nil) throws -> SyncKey {
        guard peer.deviceID != deviceID else { throw PairingError.selfPairing }
        if let c = confirmedPeerCode, c != peer.shortCode { throw PairingError.codeMismatch }
        guard let pub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peer.publicKey) else { throw PairingError.badPeerKey }
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: pub)
        let salt = Data([shortCode, peer.shortCode].sorted().joined(separator: "|").utf8)
        return SyncKey.derive(fromSharedSecret: shared, salt: salt)
    }

    public static func randomCode() -> String { String(format: "%06d", Int.random(in: 0..<1_000_000)) }
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    init?(base64URL s: String) {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        self.init(base64Encoded: b)
    }
}
