import Foundation
import XCTest
@testable import ClipboardRouterPlatform

final class LiveLinkPreviewTests: XCTestCase {
    func testURLPolicyAllowsOnlyPublicHTTPSWithoutCredentials() throws {
        let policy = LiveLinkPreviewURLPolicy()
        XCTAssertEqual(
            try policy.validated(try XCTUnwrap(URL(string: "https://example.com/path#fragment"))).absoluteString,
            "https://example.com/path"
        )

        let blocked = [
            "http://example.com",
            "file:///tmp/private",
            "custom://example.com",
            "https://user:password@example.com",
            "https://localhost",
            "https://service.local",
            "https://127.0.0.1",
            "https://10.0.0.1",
            "https://169.254.1.1",
            "https://172.16.0.1",
            "https://192.168.1.1",
            "https://192.0.2.1",
            "https://198.18.0.1",
            "https://198.51.100.1",
            "https://203.0.113.1",
            "https://[::1]",
            "https://[fe80::1]",
            "https://[fc00::1]",
            "https://[2001:db8::1]",
        ]
        for value in blocked {
            XCTAssertThrowsError(try policy.validated(try XCTUnwrap(URL(string: value))), value)
        }
    }

    func testURLPolicyBlocksKnownActionAndSignedQueryKeys() throws {
        let policy = LiveLinkPreviewURLPolicy()
        for key in [
            "login_challenge", "x-amz-signature", "x-goog-signature",
            "authenticity_token", "reset_password_token", "vendor_credential_id",
            "prefix-api-key", "please_verify_now",
        ] {
            let url = try XCTUnwrap(URL(string: "https://example.com/action?\(key)=value"))
            XCTAssertThrowsError(try policy.validated(url), key) { error in
                XCTAssertEqual(error as? LiveLinkPreviewError, .sensitiveQuery)
            }
        }
    }

    func testURLPolicyBlocksActionLikePathSegmentsIncludingEncodedAndCompoundForms() throws {
        let policy = LiveLinkPreviewURLPolicy()
        for path in [
            "/unsubscribe/opaque-token", "/reset/opaque-token", "/login",
            "/action/opaque-token", "/confirm/opaque-token", "/verify/opaque-token",
            "/reset-password/opaque-token", "/%75nsubscribe/opaque-token",
            "/password-reset/opaque-token", "/confirm-email/opaque-token",
            "/magic-link/opaque-token", "/unsubscribe.html/opaque-token",
        ] {
            let url = try XCTUnwrap(URL(string: "https://example.com\(path)"))
            XCTAssertThrowsError(try policy.validated(url), path) { error in
                XCTAssertEqual(error as? LiveLinkPreviewError, .sensitiveQuery)
            }
        }
        XCTAssertNoThrow(try policy.validated(
            try XCTUnwrap(URL(string: "https://example.com/articles/security"))
        ))
    }

    func testPinnedTransportUsesResolvedAddressAndSanitizesRequest() async throws {
        let url = try XCTUnwrap(URL(string: "https://example.com:8443/a%20b?q=1"))
        var request = URLRequest(url: url)
        request.setValue("Bearer should-not-leak", forHTTPHeaderField: "Authorization")
        request.setValue("session=should-not-leak", forHTTPHeaderField: "Cookie")
        request.setValue("https://private.example", forHTTPHeaderField: "Referer")
        let html = "<html><title>Safe</title></html>"
        let connector = StubPinnedConnector(rawResponse: rawHTTPResponse(body: Data(html.utf8)))
        let transport = BoundedLiveLinkPreviewHTTPTransport(connector: connector)

        let result = try await transport.fetch(
            request,
            maximumBytes: 1_024,
            resolvedAddresses: ["93.184.216.34"]
        )

        XCTAssertEqual(result.data, Data(html.utf8))
        let calls = await connector.calls
        let call = try XCTUnwrap(calls.first)
        XCTAssertEqual(call.address, "93.184.216.34")
        XCTAssertEqual(call.port, 8443)
        XCTAssertEqual(call.tlsServerName, "example.com")
        let serialized = try XCTUnwrap(String(data: call.request, encoding: .utf8))
        XCTAssertTrue(serialized.hasPrefix("GET /a%20b?q=1 HTTP/1.1\r\n"))
        XCTAssertTrue(serialized.contains("Host: example.com:8443\r\n"))
        XCTAssertFalse(serialized.localizedCaseInsensitiveContains("authorization"))
        XCTAssertFalse(serialized.localizedCaseInsensitiveContains("cookie"))
        XCTAssertFalse(serialized.localizedCaseInsensitiveContains("referer"))
    }

    func testPinnedTransportDecodesBoundedChunkedBody() async throws {
        let connector = StubPinnedConnector(rawResponse: Data(
            "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nWiki\r\n5\r\npedia\r\n0\r\n\r\n".utf8
        ))
        let transport = BoundedLiveLinkPreviewHTTPTransport(connector: connector)
        let result = try await transport.fetch(
            URLRequest(url: try XCTUnwrap(URL(string: "https://example.com"))),
            maximumBytes: 9,
            resolvedAddresses: ["93.184.216.34"]
        )
        XCTAssertEqual(String(data: result.data, encoding: .utf8), "Wikipedia")
    }

    func testClientParsesMetadataAndHonorsCacheRefreshAndClear() async throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/article"))
        let html = """
        <html><head>
          <meta property="og:title" content="Clipboard &amp; Context">
          <meta property="og:site_name" content="Example Docs">
          <meta name="description" content="A bounded preview.">
        </head></html>
        """
        let transport = StubPreviewTransport(responses: [
            response(url: url, data: Data(html.utf8)),
            response(url: url, data: Data(html.utf8)),
            response(url: url, data: Data(html.utf8)),
        ])
        let client = LiveLinkPreviewClient(
            resolver: StubPreviewResolver(addresses: ["93.184.216.34"]),
            transport: transport
        )

        let first = try await client.preview(for: url, refresh: false)
        let cached = try await client.preview(for: url, refresh: false)
        _ = try await client.preview(for: url, refresh: true)
        await client.clearCache()
        _ = try await client.preview(for: url, refresh: false)

        XCTAssertEqual(first.title, "Clipboard & Context")
        XCTAssertEqual(first.siteName, "Example Docs")
        XCTAssertEqual(first.summary, "A bounded preview.")
        XCTAssertEqual(cached, first)
        let callCount = await transport.callCount
        let maximumByteValues = await transport.maximumByteValues
        XCTAssertEqual(callCount, 3)
        XCTAssertEqual(maximumByteValues, [LiveLinkPreviewClient.maximumHTMLBytes,
                                           LiveLinkPreviewClient.maximumHTMLBytes,
                                           LiveLinkPreviewClient.maximumHTMLBytes])
    }

    func testUnsafeRedirectIsRejectedBeforeSecondRequest() async throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/start"))
        let transport = StubPreviewTransport(responses: [response(
            url: url,
            status: 302,
            headers: ["Location": "http://127.0.0.1/admin"]
        )])
        let client = LiveLinkPreviewClient(
            resolver: StubPreviewResolver(addresses: ["93.184.216.34"]),
            transport: transport
        )

        do {
            _ = try await client.preview(for: url, refresh: false)
            XCTFail("Expected the unsafe redirect to be blocked")
        } catch let error as LiveLinkPreviewError {
            XCTAssertTrue(error.isBlocked)
        }
        let callCount = await transport.callCount
        XCTAssertEqual(callCount, 1)
    }

    func testPrivateDNSResolutionIsRejectedBeforeTransport() async throws {
        let url = try XCTUnwrap(URL(string: "https://looks-public.example/article"))
        let transport = StubPreviewTransport(responses: [])
        let client = LiveLinkPreviewClient(
            resolver: StubPreviewResolver(error: .localNetworkAddress),
            transport: transport
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await client.preview(for: url, refresh: false)
        }
        let callCount = await transport.callCount
        XCTAssertEqual(callCount, 0)
    }

    func testTransportBoundErrorIsPreserved() async throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/huge"))
        let transport = StubPreviewTransport(
            responses: [],
            error: LiveLinkPreviewError.responseTooLarge(
                maximum: LiveLinkPreviewClient.maximumHTMLBytes
            )
        )
        let client = LiveLinkPreviewClient(
            resolver: StubPreviewResolver(addresses: ["93.184.216.34"]),
            transport: transport
        )

        do {
            _ = try await client.preview(for: url, refresh: false)
            XCTFail("Expected a bounded response error")
        } catch let error as LiveLinkPreviewError {
            XCTAssertEqual(error, .responseTooLarge(maximum: LiveLinkPreviewClient.maximumHTMLBytes))
        }
    }

    func testCacheDoesNotCollapseCaseSensitivePaths() async throws {
        let upper = try XCTUnwrap(URL(string: "https://EXAMPLE.com/Article"))
        let lower = try XCTUnwrap(URL(string: "https://example.com/article"))
        let cache = MemoryLiveLinkPreviewCache()
        await cache.insert(
            LiveLinkPreviewMetadata(sourceURL: upper, title: "Upper"),
            for: upper
        )

        let upperValue = await cache.value(for: upper)
        let lowerValue = await cache.value(for: lower)
        XCTAssertEqual(upperValue?.title, "Upper")
        XCTAssertNil(lowerValue)
    }

    func testClientReResolvesEverySafeRedirectAndPinsEachAnswer() async throws {
        let start = try XCTUnwrap(URL(string: "https://one.example/start"))
        let end = try XCTUnwrap(URL(string: "https://two.example/end"))
        let html = "<html><title>Redirected</title></html>"
        let resolver = StubPreviewResolver(addressesByHost: [
            "one.example": ["203.0.113.10"],
            "two.example": ["198.51.100.20"],
        ])
        let transport = StubPreviewTransport(responses: [
            response(url: start, status: 302, headers: ["Location": end.absoluteString]),
            response(url: end, data: Data(html.utf8)),
        ])
        let client = LiveLinkPreviewClient(resolver: resolver, transport: transport)

        _ = try await client.preview(for: start, refresh: true)

        let requestedHosts = await resolver.requestedHosts
        let resolvedAddressValues = await transport.resolvedAddressValues
        XCTAssertEqual(requestedHosts, ["one.example", "two.example"])
        XCTAssertEqual(resolvedAddressValues, [["203.0.113.10"], ["198.51.100.20"]])
    }

    func testImageRedirectIsNeverFollowedEvenWhenSameOrigin() async throws {
        let page = try XCTUnwrap(URL(string: "https://example.com/article"))
        let image = try XCTUnwrap(URL(string: "https://example.com/image.png"))
        let html = "<html><head><title>Page</title><meta property=\"og:image\" content=\"\(image.absoluteString)\"></head></html>"
        let transport = StubPreviewTransport(responses: [
            response(url: page, data: Data(html.utf8)),
            response(url: image, status: 302, headers: ["Location": "/other.png"]),
        ])
        let client = LiveLinkPreviewClient(
            resolver: StubPreviewResolver(addresses: ["93.184.216.34"]),
            transport: transport
        )

        let preview = try await client.preview(for: page, refresh: true)

        XCTAssertNil(preview.imageData)
        let callCount = await transport.callCount
        XCTAssertEqual(callCount, 2)
    }

    private func response(
        url: URL,
        status: Int = 200,
        headers: [String: String] = ["Content-Type": "text/html; charset=utf-8"],
        data: Data = Data()
    ) -> LiveLinkPreviewHTTPResponse {
        LiveLinkPreviewHTTPResponse(
            data: data,
            response: HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
        )
    }
}

private actor StubPreviewResolver: LiveLinkPreviewHostResolving {
    private let addresses: [String]
    private let addressesByHost: [String: [String]]
    private let error: LiveLinkPreviewError?
    private(set) var requestedHosts: [String] = []

    init(
        addresses: [String] = [],
        addressesByHost: [String: [String]] = [:],
        error: LiveLinkPreviewError? = nil
    ) {
        self.addresses = addresses
        self.addressesByHost = addressesByHost
        self.error = error
    }

    func resolvePublicAddresses(_ host: String) async throws -> [String] {
        requestedHosts.append(host)
        if let error { throw error }
        return addressesByHost[host] ?? addresses
    }
}

private actor StubPreviewTransport: LiveLinkPreviewHTTPTransporting {
    private var responses: [LiveLinkPreviewHTTPResponse]
    private let error: LiveLinkPreviewError?
    private(set) var callCount = 0
    private(set) var maximumByteValues: [Int] = []
    private(set) var resolvedAddressValues: [[String]] = []

    init(responses: [LiveLinkPreviewHTTPResponse], error: LiveLinkPreviewError? = nil) {
        self.responses = responses
        self.error = error
    }

    func fetch(_ request: URLRequest, maximumBytes: Int, resolvedAddresses: [String]) async throws
        -> LiveLinkPreviewHTTPResponse
    {
        callCount += 1
        maximumByteValues.append(maximumBytes)
        resolvedAddressValues.append(resolvedAddresses)
        if let error { throw error }
        guard !responses.isEmpty else { throw LiveLinkPreviewError.invalidResponse }
        return responses.removeFirst()
    }
}

private actor StubPinnedConnector: LiveLinkPreviewPinnedConnecting {
    struct Call: Sendable {
        let address: String
        let port: UInt16
        let tlsServerName: String
        let request: Data
        let maximumResponseBytes: Int
        let timeout: TimeInterval
    }

    private let rawResponse: Data
    private(set) var calls: [Call] = []

    init(rawResponse: Data) { self.rawResponse = rawResponse }

    func exchange(
        address: String,
        port: UInt16,
        tlsServerName: String,
        request: Data,
        maximumResponseBytes: Int,
        timeout: TimeInterval
    ) async throws -> Data {
        calls.append(Call(
            address: address,
            port: port,
            tlsServerName: tlsServerName,
            request: request,
            maximumResponseBytes: maximumResponseBytes,
            timeout: timeout
        ))
        return rawResponse
    }
}

private func rawHTTPResponse(body: Data) -> Data {
    var value = Data("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
    value.append(body)
    return value
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {}
}
