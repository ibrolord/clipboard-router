import ClipboardRouterCore
import Foundation

public struct CRMOAuthRequest: Equatable, Sendable {
    public let authorizationURL: URL
    public let state: String
    public let verifier: String
    public let connectionID: UUID
    /// Immutable configuration reviewed when the browser authorization began.
    /// The callback must never use a definition edited while OAuth is in flight.
    public let definition: CRMConnectionDefinition
    public let createdAt: Date
}

public enum CRMOAuthError: Error, Equatable, LocalizedError, Sendable {
    case brokerRequired
    case invalidConfiguration
    case invalidCallback
    case stateMismatch
    case expired
    case exchangeRejected(Int)
    case invalidTokenResponse

    public var errorDescription: String? {
        switch self {
        case .brokerRequired: "Configure the provider's HTTPS token broker before connecting."
        case .invalidConfiguration: "The OAuth client ID, callback URL, or broker URL is invalid."
        case .invalidCallback: "The OAuth callback did not contain a valid authorization code."
        case .stateMismatch: "The OAuth response state did not match this connection attempt."
        case .expired: "The OAuth connection attempt expired. Start it again from Settings."
        case let .exchangeRejected(status): "The OAuth token service rejected the exchange (HTTP \(status))."
        case .invalidTokenResponse: "The OAuth token service returned an invalid response."
        }
    }
}

public actor CRMOAuthCoordinator {
    private let transport: any CRMHTTPTransport
    private let credentials: any CRMCredentialStoring
    private let randomBytes: @Sendable () -> [UInt8]

    public init(
        transport: any CRMHTTPTransport,
        credentials: any CRMCredentialStoring,
        randomBytes: @escaping @Sendable () -> [UInt8] = {
            var generator = SystemRandomNumberGenerator()
            return (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        }
    ) {
        self.transport = transport
        self.credentials = credentials
        self.randomBytes = randomBytes
    }

    public func begin(
        _ definition: CRMConnectionDefinition,
        now: Date = Date()
    ) throws -> CRMOAuthRequest {
        let redirectScheme = definition.redirectURI.scheme?.lowercased()
        let isAllowedRedirect = redirectScheme == "https"
            || definition.redirectURI.host?.lowercased() == "localhost"
            || redirectScheme == "clipboardrouter"
        guard !definition.clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              isAllowedRedirect
        else { throw CRMOAuthError.invalidConfiguration }
        if definition.provider == .hubSpot {
            guard definition.externalSetupBlocker == nil else { throw CRMOAuthError.brokerRequired }
        }
        let verifierEntropy = randomBytes()
        let stateEntropy = randomBytes()
        guard verifierEntropy.count >= 32, stateEntropy.count >= 32 else {
            throw CRMOAuthError.invalidConfiguration
        }
        let pkce = CRMPKCE.generate(bytes: verifierEntropy)
        let state = Data(stateEntropy).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        var components = URLComponents(string: definition.provider == .hubSpot
            ? "https://app.hubspot.com/oauth/authorize"
            : "https://login.salesforce.com/services/oauth2/authorize")!
        let scopes = definition.provider == .hubSpot
            ? "oauth crm.objects.contacts.read crm.objects.contacts.write crm.objects.companies.read crm.objects.companies.write crm.objects.tasks.read crm.objects.tasks.write"
            : "api refresh_token"
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: definition.clientID),
            URLQueryItem(name: "redirect_uri", value: definition.redirectURI.absoluteString),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        return CRMOAuthRequest(
            authorizationURL: components.url!,
            state: state,
            verifier: pkce.verifier,
            connectionID: definition.id,
            definition: definition,
            createdAt: now
        )
    }

    public func complete(
        callbackURL: URL,
        request: CRMOAuthRequest,
        definition: CRMConnectionDefinition,
        now: Date = Date()
    ) async throws -> CRMTokenSet {
        guard request.connectionID == definition.id,
              request.definition == definition,
              callbackURL.scheme?.lowercased() == definition.redirectURI.scheme?.lowercased(),
              callbackURL.host?.lowercased() == definition.redirectURI.host?.lowercased(),
              callbackURL.path == definition.redirectURI.path
        else { throw CRMOAuthError.invalidCallback }
        let age = now.timeIntervalSince(request.createdAt)
        guard age >= 0, age <= 10 * 60 else { throw CRMOAuthError.expired }
        let query = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard query.first(where: { $0.name == "state" })?.value == request.state else {
            throw CRMOAuthError.stateMismatch
        }
        guard let code = query.first(where: { $0.name == "code" })?.value,
              !code.isEmpty,
              code.utf8.count <= 8_192
        else {
            throw CRMOAuthError.invalidCallback
        }
        let url: URL
        if definition.provider == .hubSpot {
            guard let broker = definition.tokenBrokerURL else { throw CRMOAuthError.brokerRequired }
            url = broker.appendingPathComponent("oauth/hubspot/exchange")
        } else {
            url = URL(string: "https://login.salesforce.com/services/oauth2/token")!
        }
        let form = formBody([
            "grant_type": "authorization_code", "code": code,
            "client_id": definition.clientID,
            "redirect_uri": definition.redirectURI.absoluteString,
            "code_verifier": request.verifier,
        ])
        let response = try await transport.send(CRMHTTPRequest(
            method: "POST", url: url,
            headers: ["Content-Type": "application/x-www-form-urlencoded"], body: form
        ))
        guard (200..<300).contains(response.status) else { throw CRMOAuthError.exchangeRejected(response.status) }
        let tokens = try parseTokens(response.body, now: now, priorRefreshToken: nil)
        try credentials.save(tokens, connectionID: definition.id)
        return tokens
    }

    public func refresh(
        _ current: CRMTokenSet,
        definition: CRMConnectionDefinition,
        now: Date = Date()
    ) async throws -> CRMTokenSet {
        let url: URL
        if definition.provider == .hubSpot {
            guard let broker = definition.tokenBrokerURL else { throw CRMOAuthError.brokerRequired }
            url = broker.appendingPathComponent("oauth/hubspot/refresh")
        } else {
            url = URL(string: "https://login.salesforce.com/services/oauth2/token")!
        }
        let response = try await transport.send(CRMHTTPRequest(
            method: "POST", url: url,
            headers: ["Content-Type": "application/x-www-form-urlencoded"],
            body: formBody([
                "grant_type": "refresh_token", "refresh_token": current.refreshToken,
                "client_id": definition.clientID,
            ])
        ))
        guard (200..<300).contains(response.status) else { throw CRMOAuthError.exchangeRejected(response.status) }
        let tokens = try parseTokens(response.body, now: now, priorRefreshToken: current.refreshToken)
        try credentials.save(tokens, connectionID: definition.id)
        return tokens
    }

    public func disconnect(_ definition: CRMConnectionDefinition) throws {
        try credentials.delete(connectionID: definition.id)
    }

    private func parseTokens(_ data: Data, now: Date, priorRefreshToken: String?) throws -> CRMTokenSet {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = object["access_token"] as? String,
              let refresh = object["refresh_token"] as? String ?? priorRefreshToken,
              !access.isEmpty, access.utf8.count <= 16_384,
              !refresh.isEmpty, refresh.utf8.count <= 16_384
        else { throw CRMOAuthError.invalidTokenResponse }
        let expires = (object["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        let scopes = Set((object["scope"] as? String ?? "").split(separator: " ").map(String.init))
        let instanceURL = (object["instance_url"] as? String).flatMap(URL.init(string:))
        if let instanceURL,
           instanceURL.scheme?.lowercased() != "https"
                || instanceURL.host?.isEmpty != false
                || instanceURL.user != nil
                || instanceURL.password != nil
        {
            throw CRMOAuthError.invalidTokenResponse
        }
        return CRMTokenSet(
            accessToken: access, refreshToken: refresh,
            expiresAt: now.addingTimeInterval(expires),
            accountID: (object["hub_id"] as? NSNumber)?.stringValue ?? object["id"] as? String,
            instanceURL: instanceURL,
            scopes: scopes
        )
    }

    private func formBody(_ values: [String: String]) -> Data {
        var components = URLComponents()
        components.queryItems = values.sorted { $0.key < $1.key }.map {
            URLQueryItem(name: $0.key, value: $0.value)
        }
        return Data((components.percentEncodedQuery ?? "").utf8)
    }
}

public actor CRMWriteExecutor {
    private let transport: any CRMHTTPTransport
    private let credentials: any CRMCredentialStoring
    private let oauth: CRMOAuthCoordinator

    public init(
        transport: any CRMHTTPTransport,
        credentials: any CRMCredentialStoring,
        oauth: CRMOAuthCoordinator
    ) {
        self.transport = transport; self.credentials = credentials; self.oauth = oauth
    }

    public func execute(
        _ review: CRMWriteReview,
        definition: CRMConnectionDefinition,
        now: Date = Date()
    ) async -> CRMWriteOutcome {
        do {
            guard definition.externalSetupBlocker == nil,
                  var tokens = try credentials.load(connectionID: definition.id)
            else { return .reconnectRequired }
            let client = CRMProviderClient(provider: definition.provider, transport: transport)
            var didRefresh = false

            if review.mode == .create, review.object != .task {
                let lookup = try await sendAuthorized(
                    tokens: tokens,
                    didRefresh: didRefresh,
                    definition: definition,
                    now: now
                ) { try client.duplicateLookupRequest(review: review, tokens: $0) }
                tokens = lookup.tokens
                didRefresh = lookup.didRefresh
                if lookup.response.status == 429 {
                    return .rateLimited(retryAfter: retryAfter(lookup.response.headers, now: now))
                }
                guard (200..<300).contains(lookup.response.status) else {
                    return .failed("The provider rejected duplicate checking (HTTP \(lookup.response.status)).")
                }
                if let duplicate = try duplicateID(from: lookup.response) {
                    return .duplicate(
                        providerID: duplicate,
                        deepLink: deepLink(
                            provider: definition.provider,
                            object: review.object,
                            providerID: duplicate,
                            instanceURL: tokens.instanceURL,
                            responseHeaders: lookup.response.headers
                        )
                    )
                }
            }

            let write: AuthorizedResponse
            do {
                write = try await sendAuthorized(
                    tokens: tokens,
                    didRefresh: didRefresh,
                    definition: definition,
                    now: now
                ) { try client.writeRequest(review: review, tokens: $0) }
            } catch CRMTransportError.timeoutAfterRequestSent {
                return .reconciliationRequired(idempotencyKey: review.idempotencyKey)
            }
            if write.response.status == 429 {
                return .rateLimited(retryAfter: retryAfter(write.response.headers, now: now))
            }
            guard (200..<300).contains(write.response.status) else {
                return .failed("The provider rejected the reviewed write (HTTP \(write.response.status)).")
            }
            let id = try providerID(response: write.response, fallback: review.existingProviderID)
            return .succeeded(
                providerID: id,
                deepLink: deepLink(
                    provider: definition.provider,
                    object: review.object,
                    providerID: id,
                    instanceURL: write.tokens.instanceURL,
                    responseHeaders: write.response.headers
                )
            )
        } catch CRMTransportError.timeoutBeforeSend { return .failed("The request timed out before a write was sent.") }
        catch CRMTransportError.offline { return .failed("The CRM is unreachable. Nothing was retried automatically.") }
        catch CRMClientError.unauthorized { return .reconnectRequired }
        catch CRMOAuthError.exchangeRejected(400), CRMOAuthError.exchangeRejected(401) {
            return .reconnectRequired
        }
        catch { return .failed(error.localizedDescription) }
    }

    public func reconcile(
        _ review: CRMWriteReview,
        definition: CRMConnectionDefinition
    ) async -> CRMWriteOutcome {
        do {
            guard review.object != .task,
                  let tokens = try credentials.load(connectionID: definition.id),
                  definition.externalSetupBlocker == nil
            else { return .reconciliationRequired(idempotencyKey: review.idempotencyKey) }
            let client = CRMProviderClient(provider: definition.provider, transport: transport)
            let lookup = try await sendAuthorized(
                tokens: tokens,
                didRefresh: false,
                definition: definition,
                now: Date()
            ) { try client.duplicateLookupRequest(review: review, tokens: $0) }
            if lookup.response.status == 429 {
                return .rateLimited(retryAfter: retryAfter(lookup.response.headers, now: Date()))
            }
            guard (200..<300).contains(lookup.response.status) else {
                return .failed("The provider rejected reconciliation (HTTP \(lookup.response.status)).")
            }
            if let id = try duplicateID(from: lookup.response) {
                return .succeeded(
                    providerID: id,
                    deepLink: deepLink(
                        provider: definition.provider,
                        object: review.object,
                        providerID: id,
                        instanceURL: lookup.tokens.instanceURL,
                        responseHeaders: lookup.response.headers
                    )
                )
            }
            return .reconciliationRequired(idempotencyKey: review.idempotencyKey)
        } catch CRMClientError.unauthorized { return .reconnectRequired }
        catch { return .failed(error.localizedDescription) }
    }

    private struct AuthorizedResponse: Sendable {
        let response: CRMHTTPResponse
        let tokens: CRMTokenSet
        let didRefresh: Bool
    }

    private func sendAuthorized(
        tokens initialTokens: CRMTokenSet,
        didRefresh initialDidRefresh: Bool,
        definition: CRMConnectionDefinition,
        now: Date,
        request: (CRMTokenSet) throws -> CRMHTTPRequest
    ) async throws -> AuthorizedResponse {
        var tokens = initialTokens
        var didRefresh = initialDidRefresh
        while true {
            let response = try await transport.send(request(tokens))
            guard response.status == 401 else {
                return AuthorizedResponse(
                    response: response,
                    tokens: tokens,
                    didRefresh: didRefresh
                )
            }
            guard !didRefresh else { throw CRMClientError.unauthorized }
            tokens = try await oauth.refresh(tokens, definition: definition, now: now)
            didRefresh = true
        }
    }

    private func duplicateID(from response: CRMHTTPResponse) throws -> String? {
        let object = try JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        if let results = object?["results"] as? [[String: Any]] {
            guard results.count <= 1 else { throw CRMClientError.invalidResponse }
            return try validatedProviderID(
                results.first?["id"] as? String ?? results.first?["Id"] as? String
            )
        }
        if let records = object?["records"] as? [[String: Any]] {
            guard records.count <= 1 else { throw CRMClientError.invalidResponse }
            return try validatedProviderID(records.first?["Id"] as? String)
        }
        throw CRMClientError.invalidResponse
    }

    private func providerID(response: CRMHTTPResponse, fallback: String?) throws -> String {
        if response.status == 204, let fallback { return fallback }
        let object = try JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        guard let id = object?["id"] as? String else { throw CRMClientError.invalidResponse }
        guard let validated = try validatedProviderID(id) else {
            throw CRMClientError.invalidResponse
        }
        return validated
    }

    private func validatedProviderID(_ id: String?) throws -> String? {
        guard let id else { return nil }
        guard id.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil else {
            throw CRMClientError.invalidResponse
        }
        return id
    }

    private func retryAfter(_ headers: [String: String], now: Date) -> Date? {
        guard let raw = headers.first(where: { $0.key.lowercased() == "retry-after" })?.value else { return nil }
        if let seconds = TimeInterval(raw) { return now.addingTimeInterval(max(0, seconds)) }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return formatter.date(from: raw)
    }

    private func deepLink(
        provider: CRMProvider,
        object: CRMObjectType,
        providerID: String,
        instanceURL: URL?,
        responseHeaders: [String: String]
    ) -> URL? {
        guard providerID.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
            return nil
        }
        if provider == .salesforce, let instanceURL {
            let objectName = object == .contact ? "Contact" : object == .company ? "Account" : "Task"
            return instanceURL
                .appendingPathComponent("lightning")
                .appendingPathComponent("r")
                .appendingPathComponent(objectName)
                .appendingPathComponent(providerID)
                .appendingPathComponent("view")
        }
        guard provider == .hubSpot,
              let raw = responseHeaders.first(where: { $0.key.lowercased() == "location" })?.value,
              let url = URL(string: raw),
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "app.hubspot.com"
        else { return nil }
        return url
    }
}
