import Foundation
import CryptoKit

/// Shared by Nexus (macOS) and Nexus Remote (iOS). Every remote message is sealed with ChaCha20-Poly1305.
///   Pairing key  = HKDF-SHA256(6-digit code, salt from the Mac)   — used once, for the /pair handshake
///   Device key   = 32 random bytes issued by the Mac on pairing   — used for every later request
public enum RemoteCrypto {
    public static let serviceType = "_nexusremote._tcp"
    public static let defaultPort: UInt16 = 7789

    public static func pairingKey(code: String, salt: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(code.utf8)), salt: salt,
                               info: Data("nexus-remote-pairing-v1".utf8), outputByteCount: 32)
    }

    public static func seal(_ object: [String: Any], key: SymmetricKey) throws -> Data {
        let json = try JSONSerialization.data(withJSONObject: object)
        let box = try ChaChaPoly.seal(json, using: key)
        return box.combined.base64EncodedData()
    }

    public static func open(_ data: Data, key: SymmetricKey) throws -> [String: Any] {
        guard let raw = Data(base64Encoded: data) else { throw CocoaError(.coderReadCorrupt) }
        let box = try ChaChaPoly.SealedBox(combined: raw)
        let json = try ChaChaPoly.open(box, using: key)
        guard let obj = try JSONSerialization.jsonObject(with: json) as? [String: Any] else { throw CocoaError(.coderReadCorrupt) }
        return obj
    }

    public static func randomData(_ n: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &bytes)
        return Data(bytes)
    }
}
