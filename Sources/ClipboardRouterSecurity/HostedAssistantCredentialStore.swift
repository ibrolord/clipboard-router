import Foundation
import Security

public protocol HostedAssistantCredentialStoring: Sendable {
    func loadAPIKey() throws -> String?
    func saveAPIKey(_ apiKey: String) throws
    func deleteAPIKey() throws
}

public enum HostedAssistantCredentialError: Error, Equatable, LocalizedError, Sendable {
    case invalidCredential
    case corruptCredential
    case keychainFailure(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .invalidCredential: "Enter a valid API key."
        case .corruptCredential: "The saved Assistant credential is unreadable. Disconnect it and save the key again."
        case .keychainFailure: "The API key could not be stored in this Mac's Keychain."
        }
    }
}

public struct KeychainHostedAssistantCredentialStore: HostedAssistantCredentialStoring {
    public static let service = "com.clipboardrouter.hosted-assistant"
    public static let account = "openai-api-key"

    public init() {}

    public func loadAPIKey() throws -> String? {
        let protectedResult = read(useDataProtectionKeychain: true)
        switch protectedResult {
        case let .value(value?):
            // Retry cleanup left behind by an earlier ad-hoc build. The protected value remains
            // authoritative even if the best-effort legacy deletion still cannot complete.
            _ = SecItemDelete(baseQuery(useDataProtectionKeychain: false) as CFDictionary)
            return value
        case .corrupt:
            throw HostedAssistantCredentialError.corruptCredential
        case .value(nil), .failure(errSecMissingEntitlement):
            // Ad-hoc development builds do not receive the application identifier required by
            // the Data Protection Keychain. The legacy macOS Keychain is still encrypted and
            // honors the same device-only accessibility class, so use it as a narrow fallback.
            switch read(useDataProtectionKeychain: false) {
            case let .value(value): return value
            case .corrupt: throw HostedAssistantCredentialError.corruptCredential
            case let .failure(status):
                throw HostedAssistantCredentialError.keychainFailure(status)
            }
        case let .failure(status):
            throw HostedAssistantCredentialError.keychainFailure(status)
        }
    }

    public func saveAPIKey(_ apiKey: String) throws {
        let normalized = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidCredential(normalized) else {
            throw HostedAssistantCredentialError.invalidCredential
        }
        let data = Data(normalized.utf8)
        let protectedStatus = upsert(data, useDataProtectionKeychain: true)
        if protectedStatus == errSecMissingEntitlement {
            let fallbackStatus = upsert(data, useDataProtectionKeychain: false)
            guard fallbackStatus == errSecSuccess else {
                throw HostedAssistantCredentialError.keychainFailure(fallbackStatus)
            }
        } else {
            guard protectedStatus == errSecSuccess else {
                throw HostedAssistantCredentialError.keychainFailure(protectedStatus)
            }
            // A newly signed build may replace a credential created by an earlier ad-hoc build.
            let cleanupStatus = SecItemDelete(
                baseQuery(useDataProtectionKeychain: false) as CFDictionary
            )
            // The protected credential is already durable. Never destroy it just because
            // best-effort cleanup of an older ad-hoc-build credential failed; deleteAPIKey()
            // still clears both stores when the user disconnects.
            _ = cleanupStatus
        }
    }

    public func deleteAPIKey() throws {
        let protectedStatus = SecItemDelete(
            baseQuery(useDataProtectionKeychain: true) as CFDictionary
        )
        let fallbackStatus = SecItemDelete(
            baseQuery(useDataProtectionKeychain: false) as CFDictionary
        )
        let allowed: Set<OSStatus> = [errSecSuccess, errSecItemNotFound, errSecMissingEntitlement]
        guard allowed.contains(protectedStatus) else {
            throw HostedAssistantCredentialError.keychainFailure(protectedStatus)
        }
        guard allowed.contains(fallbackStatus) else {
            throw HostedAssistantCredentialError.keychainFailure(fallbackStatus)
        }
    }

    private enum ReadResult {
        case value(String?)
        case corrupt
        case failure(OSStatus)
    }

    private func read(useDataProtectionKeychain: Bool) -> ReadResult {
        var query = baseQuery(useDataProtectionKeychain: useDataProtectionKeychain)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return .value(nil) }
        guard status == errSecSuccess else { return .failure(status) }
        guard let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              Self.isValidCredential(value)
        else { return .corrupt }
        return .value(value)
    }

    private static func isValidCredential(_ value: String) -> Bool {
        value.utf8.count >= 20
            && value.utf8.count <= 512
            && value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
            && value.rangeOfCharacter(from: .controlCharacters) == nil
    }

    private func upsert(_ data: Data, useDataProtectionKeychain: Bool) -> OSStatus {
        let query = baseQuery(useDataProtectionKeychain: useDataProtectionKeychain)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecDuplicateItem else { return status }
        return SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
    }

    private func baseQuery(useDataProtectionKeychain: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        if useDataProtectionKeychain {
            query[kSecUseDataProtectionKeychain as String] = kCFBooleanTrue as Any
        }
        return query
    }
}
