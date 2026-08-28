import ClipboardRouterCore
import CryptoKit
import Foundation
import Security

public struct CRMTokenSet: Codable, Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Date
    public let accountID: String?
    public let instanceURL: URL?
    public let scopes: Set<String>

    public init(
        accessToken: String,
        refreshToken: String,
        expiresAt: Date,
        accountID: String?,
        instanceURL: URL?,
        scopes: Set<String>
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.accountID = accountID
        self.instanceURL = instanceURL
        self.scopes = scopes
    }
}

public protocol CRMCredentialStoring: Sendable {
    func load(connectionID: UUID) throws -> CRMTokenSet?
    func save(_ tokens: CRMTokenSet, connectionID: UUID) throws
    func delete(connectionID: UUID) throws
}

public struct KeychainCRMCredentialStore: CRMCredentialStoring {
    private let service = "com.clipboardrouter.crm.oauth"
    public init() {}
    public func load(connectionID: UUID) throws -> CRMTokenSet? {
        var query = base(connectionID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw CRMConnectorError.connectionNotConfigured }
        return try JSONDecoder().decode(CRMTokenSet.self, from: data)
    }
    public func save(_ tokens: CRMTokenSet, connectionID: UUID) throws {
        let data = try JSONEncoder().encode(tokens)
        let query = base(connectionID)
        let updates = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
        if status == errSecItemNotFound {
            var add = query; add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            add[kSecAttrSynchronizable as String] = false
            guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else {
                throw CRMConnectorError.connectionNotConfigured
            }
        } else if status != errSecSuccess { throw CRMConnectorError.connectionNotConfigured }
    }
    public func delete(connectionID: UUID) throws {
        let status = SecItemDelete(base(connectionID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CRMConnectorError.connectionNotConfigured
        }
    }
    private func base(_ id: UUID) -> [String: Any] {[
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: id.uuidString,
        kSecAttrSynchronizable as String: false,
    ]}
}

public struct CRMPKCE: Equatable, Sendable {
    public let verifier: String
    public let challenge: String
    public static func generate(bytes: [UInt8]) -> CRMPKCE {
        let verifier = Data(bytes).base64URLEncodedString()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
        return CRMPKCE(verifier: verifier, challenge: challenge)
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

public struct CRMHTTPRequest: Equatable, Sendable {
    public let method: String; public let url: URL
    public let headers: [String: String]; public let body: Data?
    public let mayHaveCommittedWrite: Bool
    public init(
        method: String,
        url: URL,
        headers: [String: String] = [:],
        body: Data? = nil,
        mayHaveCommittedWrite: Bool = false
    ) {
        self.method = method; self.url = url; self.headers = headers; self.body = body
        self.mayHaveCommittedWrite = mayHaveCommittedWrite
    }
}
public struct CRMHTTPResponse: Equatable, Sendable {
    public let status: Int; public let headers: [String: String]; public let body: Data
    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status; self.headers = headers; self.body = body
    }
}
public protocol CRMHTTPTransport: Sendable { func send(_ request: CRMHTTPRequest) async throws -> CRMHTTPResponse }

public enum CRMTransportError: Error, Equatable, Sendable {
    case timeoutBeforeSend
    case timeoutAfterRequestSent
    case offline
}

public enum CRMClientError: Error, Equatable, Sendable {
    case unauthorized, rateLimited(Date?), terminal(Int), timedOutUncertain, invalidResponse
}

public struct URLSessionCRMHTTPTransport: CRMHTTPTransport {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }
    public func send(_ request: CRMHTTPRequest) async throws -> CRMHTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        urlRequest.timeoutInterval = 20
        request.headers.forEach { urlRequest.setValue($0.value, forHTTPHeaderField: $0.key) }
        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let response = response as? HTTPURLResponse else { throw CRMClientError.invalidResponse }
            return CRMHTTPResponse(
                status: response.statusCode,
                headers: Dictionary(uniqueKeysWithValues: response.allHeaderFields.compactMap {
                    guard let key = $0.key as? String, let value = $0.value as? String else { return nil }
                    return (key.lowercased(), value)
                }),
                body: data
            )
        } catch let error as URLError {
            if request.mayHaveCommittedWrite {
                throw CRMTransportError.timeoutAfterRequestSent
            }
            if error.code == .timedOut {
                throw CRMTransportError.timeoutBeforeSend
            }
            throw CRMTransportError.offline
        }
    }
}

public struct CRMProviderClient: Sendable {
    public let provider: CRMProvider
    private let transport: any CRMHTTPTransport
    public init(provider: CRMProvider, transport: any CRMHTTPTransport) { self.provider = provider; self.transport = transport }

    public func duplicateLookupRequest(review: CRMWriteReview, tokens: CRMTokenSet) throws -> CRMHTTPRequest {
        let key: String; let value: String
        switch review.object {
        case .contact:
            if let email = review.mapping.fields["email"], !email.isEmpty {
                key = provider == .hubSpot ? "email" : "Email"
                value = email
            } else {
                key = provider == .hubSpot ? "phone" : "Phone"
                value = review.mapping.fields["phone"] ?? ""
            }
        case .company:
            key = provider == .hubSpot ? "domain" : "Name"
            value = provider == .hubSpot
                ? review.mapping.fields["domain"] ?? ""
                : review.mapping.fields["name"] ?? ""
        case .task: throw CRMConnectorError.invalidMapping
        }
        guard !value.isEmpty else { throw CRMConnectorError.invalidMapping }
        if provider == .hubSpot {
            let url = URL(string: "https://api.hubapi.com/crm/v3/objects/\(review.object == .contact ? "contacts" : "companies")/search")!
            let body = try JSONSerialization.data(withJSONObject: [
                "filterGroups": [["filters": [[
                    "propertyName": key, "operator": "EQ", "value": value,
                ]]]],
                "limit": 2,
            ])
            return authorized("POST", url, tokens, body)
        }
        guard let base = validatedSalesforceInstanceURL(tokens.instanceURL) else {
            throw CRMClientError.invalidResponse
        }
        let object = review.object == .contact ? "Contact" : "Account"
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let query = "SELECT Id FROM \(object) WHERE \(key) = '\(escaped)' LIMIT 2"
        var components = URLComponents(url: base.appendingPathComponent("services/data/v61.0/query"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        return authorized("GET", components.url!, tokens, nil)
    }

    public func writeRequest(review: CRMWriteReview, tokens: CRMTokenSet) throws -> CRMHTTPRequest {
        let body = try JSONSerialization.data(withJSONObject: providerFields(review))
        let url: URL
        if provider == .hubSpot {
            let object = review.object == .contact ? "contacts" : review.object == .company ? "companies" : "tasks"
            var path = "https://api.hubapi.com/crm/v3/objects/\(object)"
            if review.mode == .update { path += "/\(review.existingProviderID!)" }
            url = URL(string: path)!
        } else {
            guard let base = validatedSalesforceInstanceURL(tokens.instanceURL) else {
                throw CRMClientError.invalidResponse
            }
            let object = review.object == .contact ? "Contact" : review.object == .company ? "Account" : "Task"
            var path = "services/data/v61.0/sobjects/\(object)"
            if review.mode == .update { path += "/\(review.existingProviderID!)" }
            url = base.appendingPathComponent(path)
        }
        return authorized(
            review.mode == .create ? "POST" : "PATCH",
            url,
            tokens,
            body,
            mayHaveCommittedWrite: true
        )
    }

    private func authorized(
        _ method: String,
        _ url: URL,
        _ tokens: CRMTokenSet,
        _ body: Data?,
        mayHaveCommittedWrite: Bool = false
    ) -> CRMHTTPRequest {
        CRMHTTPRequest(
            method: method,
            url: url,
            headers: [
                "Authorization": "Bearer \(tokens.accessToken)",
                "Content-Type": "application/json",
            ],
            body: body,
            mayHaveCommittedWrite: mayHaveCommittedWrite
        )
    }

    private func validatedSalesforceInstanceURL(_ url: URL?) -> URL? {
        guard let url,
              url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false,
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil
        else { return nil }
        return url
    }
    private func providerFields(_ review: CRMWriteReview) -> [String: Any] {
        if provider == .hubSpot {
            let map: [String: String] = [
                "email":"email", "firstName":"firstname", "lastName":"lastname",
                "phone":"phone", "companyName":"company", "jobTitle":"jobtitle",
                "name":"name", "domain":"domain", "website":"website",
                "subject":"hs_task_subject", "body":"hs_task_body",
                "dueAt":"hs_timestamp", "status":"hs_task_status",
                "priority":"hs_task_priority",
            ]
            return ["properties": Dictionary(uniqueKeysWithValues: review.mapping.fields.compactMap {
                key, value in map[key].map { ($0, value) }
            })]
        }
        let map: [String: String] = ["email":"Email","firstName":"FirstName","lastName":"LastName","phone":"Phone","companyName":"AccountName","jobTitle":"Title","name":"Name","domain":"Website","website":"Website","subject":"Subject","body":"Description","dueAt":"ActivityDate","status":"Status","priority":"Priority","relatedRecordID":"WhoId"]
        return Dictionary(uniqueKeysWithValues: review.mapping.fields.compactMap { key, value in map[key].map { ($0, value) } })
    }
}
