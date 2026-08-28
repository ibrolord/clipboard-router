import ClipboardRouterCore
import ClipboardRouterPlatform
import Foundation
import XCTest

final class CRMConnectorPlatformTests: XCTestCase {
    func testHubSpotDuplicateLookupUsesSearchEndpointAndReviewedEmail() async throws {
        let transport = ScriptedCRMTransport([])
        let request = try CRMProviderClient(provider: .hubSpot, transport: transport)
            .duplicateLookupRequest(review: try review(provider: .hubSpot), tokens: tokens())
        let object = try JSONSerialization.jsonObject(with: request.body!) as! [String: Any]
        let groups = object["filterGroups"] as! [[String: Any]]
        let filters = groups[0]["filters"] as! [[String: Any]]

        XCTAssertEqual(
            [request.method, request.url.absoluteString, filters[0]["propertyName"] as! String, filters[0]["value"] as! String],
            ["POST", "https://api.hubapi.com/crm/v3/objects/contacts/search", "email", "person@example.com"]
        )
    }

    func testSalesforceCompanyLookupRequiresReviewedNameInsteadOfDomain() async throws {
        let mapping = try CRMFieldMapping(object: .company, fields: ["domain": "example.com"])

        XCTAssertThrowsError(try CRMWriteReview(
            connectionID: UUID(), provider: .salesforce, object: .company,
            mode: .create, mapping: mapping, sourceFingerprint: "source"
        ))
    }

    func testSalesforceCompanyLookupQueriesReviewedName() async throws {
        let transport = ScriptedCRMTransport([])
        let company = try CRMWriteReview(
            connectionID: UUID(), provider: .salesforce, object: .company,
            mode: .create,
            mapping: CRMFieldMapping(object: .company, fields: ["name": "Acme"]),
            sourceFingerprint: "source"
        )
        let request = try CRMProviderClient(provider: .salesforce, transport: transport)
            .duplicateLookupRequest(review: company, tokens: tokens())
        let query = URLComponents(url: request.url, resolvingAgainstBaseURL: false)!
            .queryItems!.first(where: { $0.name == "q" })!.value!

        XCTAssertEqual(query, "SELECT Id FROM Account WHERE Name = 'Acme' LIMIT 2")
    }

    func testSalesforcePhoneOnlyContactQueriesReviewedPhone() async throws {
        let transport = ScriptedCRMTransport([])
        let contact = try CRMWriteReview(
            connectionID: UUID(), provider: .salesforce, object: .contact,
            mode: .create,
            mapping: CRMFieldMapping(
                object: .contact,
                fields: ["phone": "+14165551212", "lastName": "Reviewed"]
            ),
            sourceFingerprint: "source"
        )
        let request = try CRMProviderClient(provider: .salesforce, transport: transport)
            .duplicateLookupRequest(review: contact, tokens: tokens())
        let query = URLComponents(url: request.url, resolvingAgainstBaseURL: false)!
            .queryItems!.first(where: { $0.name == "q" })!.value!

        XCTAssertEqual(query, "SELECT Id FROM Contact WHERE Phone = '+14165551212' LIMIT 2")
    }

    func testHubSpotBrokerIsRequiredBeforeAuthorization() async {
        let credentials = MemoryCRMCredentialStore()
        let oauth = CRMOAuthCoordinator(
            transport: ScriptedCRMTransport([]), credentials: credentials,
            randomBytes: { Array(repeating: 7, count: 32) }
        )
        let definition = CRMConnectionDefinition(
            provider: .hubSpot, displayName: "HubSpot", clientID: "client",
            redirectURI: URL(string: "clipboardrouter://oauth/hubspot")!
        )

        do {
            _ = try await oauth.begin(definition)
            XCTFail("Expected brokerRequired")
        } catch {
            XCTAssertEqual(error as? CRMOAuthError, .brokerRequired)
        }
    }

    func testSalesforceAuthorizationUsesPKCEStateAndNativeCallback() async throws {
        let oauth = CRMOAuthCoordinator(
            transport: ScriptedCRMTransport([]), credentials: MemoryCRMCredentialStore(),
            randomBytes: { Array(repeating: 7, count: 32) }
        )
        let request = try await oauth.begin(definition(provider: .salesforce))
        let items = URLComponents(url: request.authorizationURL, resolvingAgainstBaseURL: false)!.queryItems!
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })

        XCTAssertEqual(
            [values["response_type"], values["code_challenge_method"], values["redirect_uri"]],
            ["code", "S256", "clipboardrouter://oauth/salesforce"]
        )
    }

    func testSalesforceExchangeSendsVerifierWithoutClientSecret() async throws {
        let transport = ScriptedCRMTransport([.success(tokenResponse())])
        let credentials = MemoryCRMCredentialStore()
        let oauth = CRMOAuthCoordinator(
            transport: transport, credentials: credentials,
            randomBytes: { Array(repeating: 7, count: 32) }
        )
        let definition = definition(provider: .salesforce)
        let request = try await oauth.begin(definition)
        let callback = URL(string: "clipboardrouter://oauth/salesforce?code=abc&state=\(request.state)")!
        _ = try await oauth.complete(callbackURL: callback, request: request, definition: definition)
        let sent = await transport.requests[0]
        let form = String(data: sent.body!, encoding: .utf8)!

        XCTAssertEqual(
            [sent.url.absoluteString, String(form.contains("code_verifier=")), String(form.contains("client_secret="))],
            ["https://login.salesforce.com/services/oauth2/token", "true", "false"]
        )
    }

    func testHubSpotExchangeUsesConfiguredBrokerAndNeverDirectTokenEndpoint() async throws {
        let transport = ScriptedCRMTransport([.success(tokenResponse())])
        let oauth = CRMOAuthCoordinator(
            transport: transport, credentials: MemoryCRMCredentialStore(),
            randomBytes: { Array(repeating: 7, count: 32) }
        )
        let definition = definition(provider: .hubSpot)
        let request = try await oauth.begin(definition)
        let callback = URL(string: "clipboardrouter://oauth/hubspot?code=abc&state=\(request.state)")!
        _ = try await oauth.complete(callbackURL: callback, request: request, definition: definition)
        let destination = await transport.requests[0].url.absoluteString

        XCTAssertEqual(destination, "https://broker.example.com/oauth/hubspot/exchange")
    }

    func testStateMismatchDoesNotCallTransport() async throws {
        let transport = ScriptedCRMTransport([])
        let oauth = CRMOAuthCoordinator(
            transport: transport, credentials: MemoryCRMCredentialStore(),
            randomBytes: { Array(repeating: 7, count: 32) }
        )
        let definition = definition(provider: .salesforce)
        let request = try await oauth.begin(definition)
        let callback = URL(string: "clipboardrouter://oauth/salesforce?code=abc&state=wrong")!
        _ = try? await oauth.complete(callbackURL: callback, request: request, definition: definition)
        let requestCount = await transport.requests.count

        XCTAssertEqual(requestCount, 0)
    }

    func testEditedDefinitionCannotRedirectInFlightOAuthExchange() async throws {
        let transport = ScriptedCRMTransport([.success(tokenResponse())])
        let oauth = CRMOAuthCoordinator(
            transport: transport, credentials: MemoryCRMCredentialStore(),
            randomBytes: { Array(repeating: 7, count: 32) }
        )
        let original = definition(provider: .hubSpot)
        let request = try await oauth.begin(original)
        let edited = CRMConnectionDefinition(
            id: original.id,
            provider: .hubSpot,
            displayName: original.displayName,
            clientID: "changed-client",
            redirectURI: original.redirectURI,
            tokenBrokerURL: URL(string: "https://other-broker.example.com")!
        )
        let callback = URL(
            string: "clipboardrouter://oauth/hubspot?code=abc&state=\(request.state)"
        )!

        do {
            _ = try await oauth.complete(
                callbackURL: callback,
                request: request,
                definition: edited
            )
            XCTFail("Expected edited OAuth definition to be rejected")
        } catch {
            XCTAssertEqual(error as? CRMOAuthError, .invalidCallback)
        }
        let requestCount = await transport.requests.count
        XCTAssertEqual(requestCount, 0)
    }

    func testExpiredOAuthAttemptDoesNotExchangeCode() async throws {
        let transport = ScriptedCRMTransport([])
        let oauth = CRMOAuthCoordinator(
            transport: transport, credentials: MemoryCRMCredentialStore(),
            randomBytes: { Array(repeating: 7, count: 32) }
        )
        let definition = definition(provider: .salesforce)
        let started = Date(timeIntervalSince1970: 1_000)
        let request = try await oauth.begin(definition, now: started)
        let callback = URL(string: "clipboardrouter://oauth/salesforce?code=abc&state=\(request.state)")!
        _ = try? await oauth.complete(
            callbackURL: callback,
            request: request,
            definition: definition,
            now: started.addingTimeInterval(601)
        )
        let requestCount = await transport.requests.count

        XCTAssertEqual(requestCount, 0)
    }

    func testDuplicateRecordStopsCreateWrite() async throws {
        let transport = ScriptedCRMTransport([.success(jsonResponse(200, ["results": [["id": "123"]]]))])
        let credentials = MemoryCRMCredentialStore(tokens: tokens())
        let oauth = CRMOAuthCoordinator(transport: transport, credentials: credentials)
        let executor = CRMWriteExecutor(transport: transport, credentials: credentials, oauth: oauth)

        let result = await executor.execute(try review(provider: .salesforce), definition: definition(provider: .salesforce))

        XCTAssertEqual(result, .duplicate(
            providerID: "123",
            deepLink: URL(string: "https://tenant.my.salesforce.com/lightning/r/Contact/123/view")
        ))
    }

    func testUnauthorizedLookupRefreshesOnceThenCreates() async throws {
        let transport = ScriptedCRMTransport([
            .success(CRMHTTPResponse(status: 401)),
            .success(tokenResponse(access: "fresh")),
            .success(jsonResponse(200, ["records": []])),
            .success(jsonResponse(201, ["id": "new123"])),
        ])
        let credentials = MemoryCRMCredentialStore(tokens: tokens())
        let oauth = CRMOAuthCoordinator(transport: transport, credentials: credentials)
        let executor = CRMWriteExecutor(transport: transport, credentials: credentials, oauth: oauth)

        let result = await executor.execute(try review(provider: .salesforce), definition: definition(provider: .salesforce))

        XCTAssertEqual(result, .succeeded(
            providerID: "new123",
            deepLink: URL(string: "https://tenant.my.salesforce.com/lightning/r/Contact/new123/view")
        ))
    }

    func testSecondUnauthorizedResponseRequiresReconnect() async throws {
        let transport = ScriptedCRMTransport([
            .success(CRMHTTPResponse(status: 401)),
            .success(tokenResponse(access: "fresh")),
            .success(CRMHTTPResponse(status: 401)),
        ])
        let credentials = MemoryCRMCredentialStore(tokens: tokens())
        let oauth = CRMOAuthCoordinator(transport: transport, credentials: credentials)
        let executor = CRMWriteExecutor(transport: transport, credentials: credentials, oauth: oauth)

        let result = await executor.execute(try review(provider: .salesforce), definition: definition(provider: .salesforce))

        XCTAssertEqual(result, .reconnectRequired)
    }

    func testRateLimitReturnsRetryAfterWithoutCreating() async throws {
        let transport = ScriptedCRMTransport([
            .success(CRMHTTPResponse(status: 429, headers: ["Retry-After": "60"])),
        ])
        let credentials = MemoryCRMCredentialStore(tokens: tokens())
        let oauth = CRMOAuthCoordinator(transport: transport, credentials: credentials)
        let executor = CRMWriteExecutor(transport: transport, credentials: credentials, oauth: oauth)
        let now = Date(timeIntervalSince1970: 1_000)

        let result = await executor.execute(
            try review(provider: .salesforce), definition: definition(provider: .salesforce), now: now
        )

        XCTAssertEqual(result, .rateLimited(retryAfter: Date(timeIntervalSince1970: 1_060)))
    }

    func testTimeoutAfterWriteRequiresReconciliationAndDoesNotRetry() async throws {
        let transport = ScriptedCRMTransport([
            .success(jsonResponse(200, ["records": []])),
            .failure(.timeoutAfterRequestSent),
        ])
        let credentials = MemoryCRMCredentialStore(tokens: tokens())
        let oauth = CRMOAuthCoordinator(transport: transport, credentials: credentials)
        let executor = CRMWriteExecutor(transport: transport, credentials: credentials, oauth: oauth)
        let review = try review(provider: .salesforce)

        let result = await executor.execute(review, definition: definition(provider: .salesforce))

        XCTAssertEqual(result, .reconciliationRequired(idempotencyKey: review.idempotencyKey))
    }

    func testMalformedDuplicateResponseFailsClosedBeforeCreate() async throws {
        let transport = ScriptedCRMTransport([
            .success(jsonResponse(200, [:])),
            .success(jsonResponse(201, ["id": "must-not-create"])),
        ])
        let credentials = MemoryCRMCredentialStore(tokens: tokens())
        let oauth = CRMOAuthCoordinator(transport: transport, credentials: credentials)
        let executor = CRMWriteExecutor(transport: transport, credentials: credentials, oauth: oauth)

        _ = await executor.execute(try review(provider: .salesforce), definition: definition(provider: .salesforce))
        let requestCount = await transport.requests.count

        XCTAssertEqual(requestCount, 1)
    }

    func testDuplicateLookup404FailsClosedBeforeCreate() async throws {
        let transport = ScriptedCRMTransport([
            .success(CRMHTTPResponse(status: 404)),
            .success(jsonResponse(201, ["id": "must-not-create"])),
        ])
        let credentials = MemoryCRMCredentialStore(tokens: tokens())
        let oauth = CRMOAuthCoordinator(transport: transport, credentials: credentials)
        let executor = CRMWriteExecutor(transport: transport, credentials: credentials, oauth: oauth)

        _ = await executor.execute(try review(provider: .salesforce), definition: definition(provider: .salesforce))
        let requestCount = await transport.requests.count

        XCTAssertEqual(requestCount, 1)
    }

    func testProviderResponseRejectsUnsafeRecordID() async throws {
        let transport = ScriptedCRMTransport([
            .success(jsonResponse(200, ["records": []])),
            .success(jsonResponse(201, ["id": "../other"])),
        ])
        let credentials = MemoryCRMCredentialStore(tokens: tokens())
        let oauth = CRMOAuthCoordinator(transport: transport, credentials: credentials)
        let executor = CRMWriteExecutor(transport: transport, credentials: credentials, oauth: oauth)

        let result = await executor.execute(try review(provider: .salesforce), definition: definition(provider: .salesforce))
        let failed: Bool
        if case .failed = result { failed = true } else { failed = false }

        XCTAssertTrue(failed)
    }

    func testWriteRequestMarksOnlyMutationAsPossiblyCommitted() async throws {
        let client = CRMProviderClient(provider: .salesforce, transport: ScriptedCRMTransport([]))
        let review = try review(provider: .salesforce)
        let lookup = try client.duplicateLookupRequest(review: review, tokens: tokens())
        let write = try client.writeRequest(review: review, tokens: tokens())

        XCTAssertEqual([lookup.mayHaveCommittedWrite, write.mayHaveCommittedWrite], [false, true])
    }

    func testHubSpotContactWriteUsesProviderPropertyNames() async throws {
        let review = try CRMWriteReview(
            connectionID: definition(provider: .hubSpot).id,
            provider: .hubSpot,
            object: .contact,
            mode: .create,
            mapping: CRMFieldMapping(
                object: .contact,
                fields: ["email": "person@example.com", "firstName": "Pat", "jobTitle": "AE"]
            ),
            sourceFingerprint: "source"
        )
        let request = try CRMProviderClient(provider: .hubSpot, transport: ScriptedCRMTransport([]))
            .writeRequest(review: review, tokens: tokens())
        let body = try JSONSerialization.jsonObject(with: request.body!) as! [String: Any]
        let properties = body["properties"] as! [String: String]

        XCTAssertEqual(properties, ["email": "person@example.com", "firstname": "Pat", "jobtitle": "AE"])
    }

    func testSalesforceFollowUpTaskWriteUsesAllowlistedTaskFields() async throws {
        let review = try CRMWriteReview(
            connectionID: definition(provider: .salesforce).id,
            provider: .salesforce,
            object: .task,
            mode: .create,
            mapping: CRMFieldMapping(
                object: .task,
                fields: ["subject": "Follow up", "body": "Call Pat", "status": "Not Started"]
            ),
            sourceFingerprint: "source"
        )
        let request = try CRMProviderClient(provider: .salesforce, transport: ScriptedCRMTransport([]))
            .writeRequest(review: review, tokens: tokens())
        let properties = try JSONSerialization.jsonObject(with: request.body!) as! [String: String]

        XCTAssertEqual(properties, ["Subject": "Follow up", "Description": "Call Pat", "Status": "Not Started"])
    }

    func testSalesforceCreateUsesVersionedSObjectEndpoint() async throws {
        let request = try CRMProviderClient(provider: .salesforce, transport: ScriptedCRMTransport([]))
            .writeRequest(review: try review(provider: .salesforce), tokens: tokens())

        XCTAssertEqual(request.url.absoluteString, "https://tenant.my.salesforce.com/services/data/v61.0/sobjects/Contact")
    }

    func testSalesforceRequestRejectsNonHTTPSInstanceURL() async throws {
        let unsafe = CRMTokenSet(
            accessToken: "token", refreshToken: "refresh", expiresAt: .distantFuture,
            accountID: nil, instanceURL: URL(string: "http://tenant.example.com"), scopes: []
        )

        XCTAssertThrowsError(try CRMProviderClient(
            provider: .salesforce,
            transport: ScriptedCRMTransport([])
        ).writeRequest(review: try review(provider: .salesforce), tokens: unsafe))
    }

    private func review(provider: CRMProvider) throws -> CRMWriteReview {
        let definition = definition(provider: provider)
        return try CRMWriteReview(
            connectionID: definition.id, provider: provider, object: .contact,
            mode: .create,
            mapping: CRMFieldMapping(
                object: .contact,
                fields: provider == .salesforce
                    ? ["email": "person@example.com", "lastName": "Reviewed"]
                    : ["email": "person@example.com"]
            ),
            sourceFingerprint: "source"
        )
    }

    private func definition(provider: CRMProvider) -> CRMConnectionDefinition {
        CRMConnectionDefinition(
            id: UUID(uuidString: provider == .hubSpot
                ? "11111111-1111-1111-1111-111111111111"
                : "22222222-2222-2222-2222-222222222222")!,
            provider: provider,
            displayName: provider == .hubSpot ? "HubSpot" : "Salesforce",
            clientID: "client",
            redirectURI: URL(string: "clipboardrouter://oauth/\(provider == .hubSpot ? "hubspot" : "salesforce")")!,
            tokenBrokerURL: provider == .hubSpot ? URL(string: "https://broker.example.com")! : nil
        )
    }

    private func tokens() -> CRMTokenSet {
        CRMTokenSet(
            accessToken: "old", refreshToken: "refresh",
            expiresAt: Date(timeIntervalSince1970: 9_999), accountID: "account",
            instanceURL: URL(string: "https://tenant.my.salesforce.com")!, scopes: ["api"]
        )
    }

    private func tokenResponse(access: String = "token") -> CRMHTTPResponse {
        jsonResponse(200, [
            "access_token": access, "refresh_token": "refresh", "expires_in": 3600,
            "instance_url": "https://tenant.my.salesforce.com", "scope": "api refresh_token",
        ])
    }

    private func jsonResponse(_ status: Int, _ value: Any) -> CRMHTTPResponse {
        CRMHTTPResponse(status: status, body: try! JSONSerialization.data(withJSONObject: value))
    }
}

private final class MemoryCRMCredentialStore: CRMCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: CRMTokenSet?
    init(tokens: CRMTokenSet? = nil) { value = tokens }
    func load(connectionID: UUID) throws -> CRMTokenSet? { lock.withLock { value } }
    func save(_ tokens: CRMTokenSet, connectionID: UUID) throws { lock.withLock { value = tokens } }
    func delete(connectionID: UUID) throws { lock.withLock { value = nil } }
}

private actor ScriptedCRMTransport: CRMHTTPTransport {
    private var results: [Result<CRMHTTPResponse, CRMTransportError>]
    private(set) var requests: [CRMHTTPRequest] = []
    init(_ results: [Result<CRMHTTPResponse, CRMTransportError>]) { self.results = results }
    func send(_ request: CRMHTTPRequest) async throws -> CRMHTTPResponse {
        requests.append(request)
        guard !results.isEmpty else { throw CRMTransportError.offline }
        return try results.removeFirst().get()
    }
}
