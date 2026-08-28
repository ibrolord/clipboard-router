import ClipboardRouterCore
import CryptoKit
import Foundation
import Security

/// Synchronous non-synchronizable Keychain identity for encrypted clipboard shares.
///
/// The private key never enters the transport. Public-key exchange is intentionally explicit:
/// callers must authenticate a recipient public key out of band before calling
/// `SecureShareClipCodec.seal`.
public final class KeychainSecureShareKeyProvider: SecureShareKeyProvider, @unchecked Sendable {
    public let service: String
    public let account: String

    public init(
        service: String = "com.clipboardrouter.secure-share-key",
        account: String = "primary"
    ) {
        self.service = service
        self.account = account
    }

    public func recipientPublicKey() throws -> Curve25519.KeyAgreement.PublicKey {
        try makePrivateKey().publicKey
    }

    public func recipientPrivateKey() throws -> Curve25519.KeyAgreement.PrivateKey {
        try makePrivateKey()
    }

    public func exportedPublicKeyString() throws -> String {
        Self.publicKeyString(from: try recipientPublicKey())
    }

    public static func publicKeyString(
        from publicKey: Curve25519.KeyAgreement.PublicKey
    ) -> String {
        "clipboard-router-recipient-key:v1:" + publicKey.rawRepresentation.base64EncodedString()
    }

    public static func publicKey(from string: String) throws -> Curve25519.KeyAgreement.PublicKey {
        let prefix = "clipboard-router-recipient-key:v1:"
        guard string.hasPrefix(prefix),
              let data = Data(base64Encoded: String(string.dropFirst(prefix.count))),
              data.count == 32
        else { throw SecureShareError.keyUnavailable }
        do {
            return try Curve25519.KeyAgreement.PublicKey(rawRepresentation: data)
        } catch {
            throw SecureShareError.keyUnavailable
        }
    }

    private func makePrivateKey() throws -> Curve25519.KeyAgreement.PrivateKey {
        if let data = read() {
            do { return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data) }
            catch { throw SecureShareError.keyUnavailable }
        }
        let key = Curve25519.KeyAgreement.PrivateKey()
        let status = add(key.rawRepresentation)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw SecureShareError.keyUnavailable
        }
        if status == errSecDuplicateItem, let data = read() {
            do { return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data) }
            catch { throw SecureShareError.keyUnavailable }
        }
        // A duplicate item means the key already exists. If it cannot be read, returning the
        // freshly generated key would publish a public half whose private half was never stored.
        // Fail closed so callers never distribute an undecryptable recipient identity.
        guard status == errSecSuccess else { throw SecureShareError.keyUnavailable }
        return key
    }

    private func query() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecUseDataProtectionKeychain as String: kCFBooleanTrue as Any,
        ]
    }

    private func read() -> Data? {
        var request = query()
        request[kSecReturnData as String] = kCFBooleanTrue as Any
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess else {
            return nil
        }
        return result as? Data
    }

    private func add(_ data: Data) -> OSStatus {
        var attributes = query()
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly
        return SecItemAdd(attributes as CFDictionary, nil)
    }
}

/// High-level typed service used by AppModel and tests. Decryption remains explicit and does not
/// write to history or the general pasteboard.
public actor SecureShareClipService {
    private let keyProvider: any SecureShareKeyProvider
    private let receiver: SecureShareReceiver

    public init(
        keyProvider: any SecureShareKeyProvider,
        replayStore: any SecureShareReplayStore = InMemorySecureShareReplayStore()
    ) {
        self.keyProvider = keyProvider
        receiver = SecureShareReceiver(keyProvider: keyProvider, replayStore: replayStore)
    }

    public func localRecipientKeyString() throws -> String {
        KeychainSecureShareKeyProvider.publicKeyString(from: try keyProvider.recipientPublicKey())
    }

    public func sealForLocalRecipient(_ content: ClipContent) throws -> String {
        try SecureShareClipCodec.seal(
            content,
            for: keyProvider.recipientPublicKey()
        )
    }

    public func seal(
        _ content: ClipContent,
        for recipientKeyString: String
    ) throws -> String {
        let publicKey = try KeychainSecureShareKeyProvider.publicKey(from: recipientKeyString)
        return try SecureShareClipCodec.seal(content, for: publicKey)
    }

    public func decrypt(_ transport: String) async throws -> ClipContent {
        try await SecureShareClipCodec.open(transport, using: receiver)
    }
}
