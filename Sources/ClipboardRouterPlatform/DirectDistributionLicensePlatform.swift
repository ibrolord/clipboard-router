import ClipboardRouterCore
import CryptoKit
import Foundation
import Security

public protocol DirectLicensePublicKeyProviding: Sendable {
    func publicKeyDER() -> Data?
}

public struct BundleDirectLicensePublicKeyProvider: DirectLicensePublicKeyProviding {
    public static let infoKey = "ClipboardRouterLicensePublicKeyDERBase64"
    private let bundle: Bundle

    public init(bundle: Bundle = .main) { self.bundle = bundle }

    public func publicKeyDER() -> Data? {
        guard let encoded = bundle.object(forInfoDictionaryKey: Self.infoKey) as? String,
              !encoded.isEmpty,
              encoded.utf8.count <= 4_096
        else { return nil }
        return Data(base64Encoded: encoded)
    }
}

public protocol DirectLicenseTokenVerifying: Sendable {
    var isConfigured: Bool { get }
    func verify(_ token: String) throws -> DirectLicenseTokenClaims
}

public struct P256DirectLicenseTokenVerifier: DirectLicenseTokenVerifying {
    private let keyProvider: any DirectLicensePublicKeyProviding

    public init(
        keyProvider: any DirectLicensePublicKeyProviding = BundleDirectLicensePublicKeyProvider()
    ) {
        self.keyProvider = keyProvider
    }

    public var isConfigured: Bool {
        guard let keyData = keyProvider.publicKeyDER() else { return false }
        return (try? P256.Signing.PublicKey(derRepresentation: keyData)) != nil
    }

    public func verify(_ token: String) throws -> DirectLicenseTokenClaims {
        guard let keyData = keyProvider.publicKeyDER() else {
            throw DirectLicenseError.verifierUnavailable
        }
        guard token.utf8.count <= 24_000,
              token.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
        else { throw DirectLicenseError.invalidToken }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "crl1",
              let payload = Self.base64URLDecode(String(parts[1])),
              let signatureData = Self.base64URLDecode(String(parts[2]))
        else { throw DirectLicenseError.invalidToken }

        let publicKey: P256.Signing.PublicKey
        let signature: P256.Signing.ECDSASignature
        do {
            publicKey = try P256.Signing.PublicKey(derRepresentation: keyData)
            signature = try P256.Signing.ECDSASignature(derRepresentation: signatureData)
        } catch {
            throw DirectLicenseError.invalidSignature
        }
        let signedBytes = Data("crl1.\(parts[1])".utf8)
        guard publicKey.isValidSignature(signature, for: signedBytes) else {
            throw DirectLicenseError.invalidSignature
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        do {
            return try decoder.decode(DirectLicenseTokenClaims.self, from: payload)
        } catch {
            throw DirectLicenseError.invalidClaims
        }
    }

    private static func base64URLDecode(_ value: String) -> Data? {
        guard value.utf8.count <= 20_000,
              value.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        else { return nil }
        var base64 = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: base64)
    }
}

public protocol DirectLicenseCredentialStoring: Sendable {
    func loadToken() async throws -> String?
    func saveToken(_ token: String) async throws
    func deleteToken() async throws
    func loadClockCheckpoint() async throws -> DirectLicenseClockCheckpoint?
    func saveClockCheckpoint(_ checkpoint: DirectLicenseClockCheckpoint) async throws
    func deleteClockCheckpoint() async throws
}

public actor KeychainDirectLicenseCredentialStore: DirectLicenseCredentialStoring {
    private let service: String
    private let tokenAccount = "direct-license-token.v1"
    private let clockAccount = "direct-license-clock.v1"

    public init(service: String = "com.clipboardrouter.ClipboardRouter.license") {
        self.service = service
    }

    public func loadToken() throws -> String? {
        guard let data = try read(account: tokenAccount) else { return nil }
        guard data.count <= 24_000, let token = String(data: data, encoding: .utf8) else {
            throw DirectLicenseError.secureStorageFailure
        }
        return token
    }

    public func saveToken(_ token: String) throws {
        guard token.utf8.count <= 24_000,
              token.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
        else { throw DirectLicenseError.invalidToken }
        try upsert(Data(token.utf8), account: tokenAccount)
    }

    public func deleteToken() throws { try delete(account: tokenAccount) }

    public func loadClockCheckpoint() throws -> DirectLicenseClockCheckpoint? {
        guard let data = try read(account: clockAccount) else { return nil }
        guard data.count <= 2_048 else { throw DirectLicenseError.secureStorageFailure }
        do { return try JSONDecoder().decode(DirectLicenseClockCheckpoint.self, from: data) }
        catch { throw DirectLicenseError.secureStorageFailure }
    }

    public func saveClockCheckpoint(_ checkpoint: DirectLicenseClockCheckpoint) throws {
        do { try upsert(JSONEncoder().encode(checkpoint), account: clockAccount) }
        catch let error as DirectLicenseError { throw error }
        catch { throw DirectLicenseError.secureStorageFailure }
    }

    public func deleteClockCheckpoint() throws { try delete(account: clockAccount) }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecUseDataProtectionKeychain as String: kCFBooleanTrue as Any,
        ]
    }

    private func read(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw DirectLicenseError.secureStorageFailure
        }
        return data
    }

    private func upsert(_ data: Data, account: String) throws {
        let query = baseQuery(account: account)
        let status = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else {
                throw DirectLicenseError.secureStorageFailure
            }
        } else if status != errSecSuccess {
            throw DirectLicenseError.secureStorageFailure
        }
    }

    private func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DirectLicenseError.secureStorageFailure
        }
    }
}

public protocol DirectLicenseRepositoryClient: Sendable {
    var isConfigured: Bool { get }
    func startTrial(deviceID: String) async throws -> String
    func activate(licenseKey: String, deviceID: String) async throws -> String
    func restore(accountID: String, deviceID: String) async throws -> String
    func refresh(token: String, deviceID: String) async throws -> String
    func deactivate(token: String, deviceID: String) async throws
}

public struct BundleConfiguredDirectLicenseRepositoryClient: DirectLicenseRepositoryClient {
    public static let serviceURLInfoKey = "ClipboardRouterLicenseServiceURL"
    public static let commerceProviderInfoKey = "ClipboardRouterCommerceProviderIdentifier"
    private let client: HTTPDirectLicenseRepositoryClient?

    public init(bundle: Bundle = .main, session: URLSession? = nil) {
        guard let raw = bundle.object(forInfoDictionaryKey: Self.serviceURLInfoKey) as? String,
              let url = URL(string: raw),
              url.scheme == "https", url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              let rawCommerceProvider = bundle.object(
                  forInfoDictionaryKey: Self.commerceProviderInfoKey
              ) as? String,
              case let commerceProvider = rawCommerceProvider.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ),
              (1...128).contains(commerceProvider.utf8.count),
              commerceProvider.rangeOfCharacter(from: .controlCharacters) == nil
        else {
            client = nil
            return
        }
        client = HTTPDirectLicenseRepositoryClient(baseURL: url, session: session)
    }

    public var isConfigured: Bool { client != nil }

    public func startTrial(deviceID: String) async throws -> String {
        guard let client else { throw DirectLicenseError.repositoryUnavailable }
        return try await client.startTrial(deviceID: deviceID)
    }

    public func activate(licenseKey: String, deviceID: String) async throws -> String {
        guard let client else { throw DirectLicenseError.repositoryUnavailable }
        return try await client.activate(licenseKey: licenseKey, deviceID: deviceID)
    }

    public func restore(accountID: String, deviceID: String) async throws -> String {
        guard let client else { throw DirectLicenseError.repositoryUnavailable }
        return try await client.restore(accountID: accountID, deviceID: deviceID)
    }

    public func refresh(token: String, deviceID: String) async throws -> String {
        guard let client else { throw DirectLicenseError.repositoryUnavailable }
        return try await client.refresh(token: token, deviceID: deviceID)
    }

    public func deactivate(token: String, deviceID: String) async throws {
        guard let client else { throw DirectLicenseError.repositoryUnavailable }
        try await client.deactivate(token: token, deviceID: deviceID)
    }
}

public struct HTTPDirectLicenseRepositoryClient: DirectLicenseRepositoryClient, @unchecked Sendable {
    private struct TokenResponse: Decodable { let token: String }
    private let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession? = nil) {
        self.baseURL = baseURL
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            configuration.timeoutIntervalForRequest = 12
            configuration.timeoutIntervalForResource = 20
            self.session = URLSession(
                configuration: configuration,
                delegate: DirectLicenseNoRedirectDelegate(),
                delegateQueue: nil
            )
        }
    }

    public var isConfigured: Bool { true }

    public func startTrial(deviceID: String) async throws -> String {
        try await tokenRequest(
            path: "v1/licenses/trial",
            body: ["deviceID": deviceID],
            idempotencyMaterial: "trial:\(deviceID)",
            rejectedError: .activationRejected
        )
    }

    public func activate(licenseKey: String, deviceID: String) async throws -> String {
        let normalized = licenseKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (8...512).contains(normalized.utf8.count) else {
            throw DirectLicenseError.activationRejected
        }
        return try await tokenRequest(
            path: "v1/licenses/activate",
            body: ["licenseKey": normalized, "deviceID": deviceID],
            idempotencyMaterial: "activate:\(normalized):\(deviceID)",
            rejectedError: .activationRejected
        )
    }

    public func restore(accountID: String, deviceID: String) async throws -> String {
        let normalized = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...256).contains(normalized.utf8.count) else {
            throw DirectLicenseError.restoreRejected
        }
        return try await tokenRequest(
            path: "v1/licenses/restore",
            body: ["accountID": normalized, "deviceID": deviceID],
            idempotencyMaterial: "restore:\(normalized):\(deviceID)",
            rejectedError: .restoreRejected
        )
    }

    public func refresh(token: String, deviceID: String) async throws -> String {
        try await tokenRequest(
            path: "v1/licenses/refresh",
            body: ["token": token, "deviceID": deviceID],
            idempotencyMaterial: "refresh:\(Self.digest(token)):\(deviceID)",
            rejectedError: .repositoryUnavailable
        )
    }

    public func deactivate(token: String, deviceID: String) async throws {
        _ = try await request(
            path: "v1/licenses/deactivate",
            body: ["token": token, "deviceID": deviceID],
            idempotencyMaterial: "deactivate:\(Self.digest(token)):\(deviceID)",
            rejectedError: .deactivationRejected
        )
    }

    private func tokenRequest(
        path: String,
        body: [String: String],
        idempotencyMaterial: String,
        rejectedError: DirectLicenseError
    ) async throws -> String {
        let data = try await request(
            path: path,
            body: body,
            idempotencyMaterial: idempotencyMaterial,
            rejectedError: rejectedError
        )
        guard data.count <= 32_000,
              let response = try? JSONDecoder().decode(TokenResponse.self, from: data),
              !response.token.isEmpty,
              response.token.utf8.count <= 24_000
        else { throw DirectLicenseError.repositoryUnavailable }
        return response.token
    }

    private func request(
        path: String,
        body: [String: String],
        idempotencyMaterial: String,
        rejectedError: DirectLicenseError
    ) async throws -> Data {
        let url = baseURL.appendingPathComponent(path)
        guard url.scheme == "https", url.host == baseURL.host else {
            throw DirectLicenseError.repositoryUnavailable
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.digest(idempotencyMaterial), forHTTPHeaderField: "Idempotency-Key")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        do {
            let (data, response) = try await session.data(for: request)
            guard data.count <= 32_000, let http = response as? HTTPURLResponse else {
                throw DirectLicenseError.repositoryUnavailable
            }
            switch http.statusCode {
            case 200...299: return data
            case 400...499: throw rejectedError
            default: throw DirectLicenseError.repositoryUnavailable
            }
        } catch let error as DirectLicenseError {
            throw error
        } catch {
            throw DirectLicenseError.repositoryUnavailable
        }
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

private final class DirectLicenseNoRedirectDelegate: NSObject, URLSessionTaskDelegate,
    @unchecked Sendable
{
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest: URLRequest
    ) async -> URLRequest? {
        // License keys and tokens must never be replayed to a redirect target. The configured
        // service may rotate behind its own HTTPS origin without an application-layer redirect.
        nil
    }
}

public protocol DirectLicenseClockProviding: Sendable {
    func observation() -> DirectLicenseClockObservation
}

public struct SystemDirectLicenseClock: DirectLicenseClockProviding {
    public init() {}
    public func observation() -> DirectLicenseClockObservation {
        DirectLicenseClockObservation(
            wallClock: Date(),
            monotonicUptime: ProcessInfo.processInfo.systemUptime
        )
    }
}
