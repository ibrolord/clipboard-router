import Foundation
import LocalAuthentication
import Security

public actor LocalAuthenticationAdapter: VaultAuthenticating {
    public init() {}

    public func authenticate(reason: String) async throws {
        let context = LAContext()
        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            throw VaultError.authenticationFailed
        }
        // The Keychain operation performs the one user-presence challenge. Evaluating here
        // as well would present two prompts using two unrelated LAContext instances.
    }
}

/// Stores a non-synchronizable, device-bound key protected by macOS user presence.
/// Access requires a device passcode and Touch ID/password approval as configured by macOS.
public actor KeychainVaultKeyProvider: VaultKeyProviding {
    public let service: String
    public let account: String

    public init(
        service: String = "com.clipboardrouter.vault-key",
        account: String = "primary-vault"
    ) {
        self.service = service
        self.account = account
    }

    public func loadKey(authenticationReason: String) async throws -> Data? {
        switch copyKey(authenticationReason: authenticationReason) {
        case let .found(data):
            return data
        case .missing: return nil
        case let .failed(status):
            throw VaultError.keychainFailure(status)
        }
    }

    public func createKey(authenticationReason: String) async throws -> Data {
        let context = LAContext()
        do {
            guard try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: authenticationReason
            ) else { throw VaultError.authenticationFailed }
        } catch {
            throw VaultError.authenticationFailed
        }
        let key = VaultCrypto.generateKeyData()
        let addStatus = addKey(key)
        if addStatus == errSecDuplicateItem {
            guard let existing = try await loadKey(authenticationReason: authenticationReason) else {
                throw VaultError.keychainFailure(errSecItemNotFound)
            }
            return existing
        }
        guard addStatus == errSecSuccess else { throw VaultError.keychainFailure(addStatus) }
        return key
    }

    public func deleteKey() async throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: kCFBooleanFalse as Any,
            kSecUseDataProtectionKeychain: kCFBooleanTrue as Any,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw VaultError.keychainFailure(status)
        }
    }

    private enum KeyLookup {
        case found(Data)
        case missing
        case failed(OSStatus)
    }

    private func copyKey(authenticationReason: String) -> KeyLookup {
        let context = LAContext()
        context.localizedReason = authenticationReason
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: kCFBooleanFalse as Any,
            kSecUseDataProtectionKeychain: kCFBooleanTrue as Any,
            kSecReturnData: kCFBooleanTrue as Any,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecUseAuthenticationContext: context,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return .missing }
        guard status == errSecSuccess else { return .failed(status) }
        guard let data = result as? Data else { return .failed(errSecDecode) }
        return .found(data)
    }

    private func addKey(_ key: Data) -> OSStatus {
        var accessControlError: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
            .userPresence,
            &accessControlError
        ) else {
            return errSecParam
        }
        let attributes: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: kCFBooleanFalse as Any,
            kSecUseDataProtectionKeychain: kCFBooleanTrue as Any,
            kSecAttrAccessControl: accessControl,
            kSecValueData: key,
        ]
        return SecItemAdd(attributes as CFDictionary, nil)
    }
}

public actor InMemoryVaultKeyProvider: VaultKeyProviding {
    private var key: Data?
    public var loadCount = 0

    public init(key: Data? = nil) { self.key = key }

    public func loadKey(authenticationReason: String) async throws -> Data? {
        loadCount += 1
        return key
    }

    public func createKey(authenticationReason: String) async throws -> Data {
        if let key { return key }
        let generated = VaultCrypto.generateKeyData()
        key = generated
        return generated
    }

    public func deleteKey() async throws { key = nil }
}

public actor StubVaultAuthenticator: VaultAuthenticating {
    public var shouldSucceed: Bool
    public private(set) var callCount = 0

    public init(shouldSucceed: Bool = true) { self.shouldSucceed = shouldSucceed }

    public func authenticate(reason: String) async throws {
        callCount += 1
        guard shouldSucceed else { throw VaultError.authenticationFailed }
    }

    public func setShouldSucceed(_ value: Bool) { shouldSucceed = value }
}
