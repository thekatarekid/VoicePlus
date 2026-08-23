import Foundation
import CryptoKit

/// "Export everything" — a single `.voiceplus` file: encrypted `SyncPayload` under a key derived from a
/// user passphrase (HKDF with a random salt stored in the header). Portable; no account, no server.
public enum ExportBundle {
    public static let fileExtension = "voiceplus"
    static let magic = Data("VPEX1".utf8)
    static let saltLength = 16

    public static func export(_ payload: SyncPayload, passphrase: String) throws -> Data {
        var salt = Data(count: saltLength)
        salt.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, saltLength, $0.baseAddress!) }
        let key = SyncKey.derive(fromPairingSecret: Data(passphrase.utf8), salt: salt)
        return magic + salt + (try key.seal(payload.encoded(), aad: magic))
    }

    public static func `import`(_ data: Data, passphrase: String) throws -> SyncPayload {
        guard data.count > magic.count + saltLength, data.prefix(magic.count) == magic else { throw SyncCryptoError.badFormat }
        let salt = data.subdata(in: magic.count ..< magic.count + saltLength)
        let key = SyncKey.derive(fromPairingSecret: Data(passphrase.utf8), salt: salt)
        let plain = try key.open(data.suffix(from: magic.count + saltLength), aad: magic)
        return try SyncPayload.decode(plain)
    }

    public static func export(_ payload: SyncPayload, passphrase: String, to url: URL) throws {
        try export(payload, passphrase: passphrase).write(to: url, options: .atomic)
    }
    public static func `import`(from url: URL, passphrase: String) throws -> SyncPayload {
        try `import`(try Data(contentsOf: url), passphrase: passphrase)
    }
}
