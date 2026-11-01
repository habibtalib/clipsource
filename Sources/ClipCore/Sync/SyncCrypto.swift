import CommonCrypto
import CryptoKit
import Foundation

public enum SyncCryptoError: Error, CustomStringConvertible {
    case keyDerivation
    case badCiphertext
    case wrongPassphrase
    /// The key record asks for a PBKDF2 iteration count outside the accepted range.
    case unsupportedIterations(Int)

    public var description: String {
        switch self {
        case .keyDerivation: return "Key derivation failed"
        case .badCiphertext: return "Cannot decrypt synced entry (wrong passphrase or corrupt data)"
        case .wrongPassphrase: return "Wrong sync passphrase"
        case let .unsupportedIterations(n): return "Sync key record has an unsupported iteration count (\(n)); reset sync to create a new one"
        }
    }
}

/// End-to-end sync key. PBKDF2-SHA256(passphrase, salt) gives a 32-byte master key; HKDF-SHA256 splits it
/// into an AES-GCM key for payloads and an HMAC key for dedup hashes. The web viewer derives the same keys
/// with WebCrypto (site/app/sync-crypto.js); Tests/Fixtures/sync-vector.json pins both sides.
public struct SyncKey: Sendable {
    public static let defaultIterations = 600_000
    public static let checkPlaintext = "clipsource-sync-check-v1"
    static let hkdfSalt = Data("clipsource".utf8)

    /// The PBKDF2 output. Stored in the Keychain so the passphrase itself is never kept.
    public let master: Data
    let encKey: SymmetricKey
    let macKey: SymmetricKey

    public init(master: Data) {
        self.master = master
        let ikm = SymmetricKey(data: master)
        encKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: Self.hkdfSalt,
                                        info: Data("clipsource-enc-v1".utf8), outputByteCount: 32)
        macKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: Self.hkdfSalt,
                                        info: Data("clipsource-mac-v1".utf8), outputByteCount: 32)
    }

    public static func derive(passphrase: String, salt: Data, iterations: Int = defaultIterations) throws -> SyncKey {
        guard iterations > 0, iterations <= Int(UInt32.max) else { throw SyncCryptoError.unsupportedIterations(iterations) }
        var out = Data(count: 32)
        let password = Data(passphrase.precomposedStringWithCanonicalMapping.utf8)
        let status = out.withUnsafeMutableBytes { outPtr in
            salt.withUnsafeBytes { saltPtr in
                password.withUnsafeBytes { pwPtr in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                         pwPtr.baseAddress?.assumingMemoryBound(to: Int8.self), password.count,
                                         saltPtr.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                                         outPtr.baseAddress?.assumingMemoryBound(to: UInt8.self), 32)
                }
            }
        }
        guard status == kCCSuccess else { throw SyncCryptoError.keyDerivation }
        return SyncKey(master: out)
    }

    public static func randomSalt() -> Data {
        Data((0..<16).map { _ in UInt8.random(in: 0...255) })
    }

    /// AES-GCM, base64 of nonce (12) + ciphertext + tag (16). `nonce` is for test vectors only.
    public func seal(_ plaintext: Data, nonce: Data? = nil) throws -> String {
        let n = try nonce.map { try AES.GCM.Nonce(data: $0) } ?? AES.GCM.Nonce()
        let box = try AES.GCM.seal(plaintext, using: encKey, nonce: n)
        guard let combined = box.combined else { throw SyncCryptoError.badCiphertext }
        return combined.base64EncodedString()
    }

    public func open(_ base64: String) throws -> Data {
        guard let data = Data(base64Encoded: base64), let box = try? AES.GCM.SealedBox(combined: data),
              let plain = try? AES.GCM.open(box, using: encKey) else { throw SyncCryptoError.badCiphertext }
        return plain
    }

    /// Server-side dedup key: hex HMAC-SHA256 of the text. Same text gives the same row on every device.
    public func hash(_ text: String) -> String {
        HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: macKey).map { String(format: "%02x", $0) }.joined()
    }

    /// Encrypted known value stored next to the salt, so other devices can verify the passphrase.
    public func makeCheck() throws -> String {
        try seal(Data(Self.checkPlaintext.utf8))
    }

    public func verify(check: String) -> Bool {
        (try? open(check)).map { String(decoding: $0, as: UTF8.self) == Self.checkPlaintext } ?? false
    }

    public func sealPayload(_ payload: SyncPayload, nonce: Data? = nil) throws -> String {
        try seal(SyncPayload.encoder.encode(payload), nonce: nonce)
    }

    public func openPayload(_ base64: String) throws -> SyncPayload {
        try SyncPayload.decoder.decode(SyncPayload.self, from: open(base64))
    }
}
