import ClipboardRouterCore
import CryptoKit
import Foundation
import XCTest
@testable import ClipboardRouterPlatform

final class DirectDistributionLicensePlatformTests: XCTestCase {
    func testVerifierAcceptsAuthenticP256TokenAndDecodesClaims() throws {
        let privateKey = P256.Signing.PrivateKey()
        let claims = try makeClaims()
        let token = try signedToken(claims: claims, privateKey: privateKey)
        let verifier = P256DirectLicenseTokenVerifier(
            keyProvider: StaticLicensePublicKeyProvider(
                keyData: privateKey.publicKey.derRepresentation
            )
        )

        XCTAssertTrue(verifier.isConfigured)
        XCTAssertEqual(try verifier.verify(token), claims)
    }

    func testVerifierRejectsPayloadAndSignatureTampering() throws {
        let privateKey = P256.Signing.PrivateKey()
        let claims = try makeClaims()
        let token = try signedToken(claims: claims, privateKey: privateKey)
        let verifier = P256DirectLicenseTokenVerifier(
            keyProvider: StaticLicensePublicKeyProvider(
                keyData: privateKey.publicKey.derRepresentation
            )
        )
        let segments = token.split(separator: ".").map(String.init)
        XCTAssertEqual(segments.count, 3)

        let alteredPayload = segments[1].dropLast() + (segments[1].last == "A" ? "B" : "A")
        XCTAssertThrowsError(try verifier.verify(
            "crl1.\(alteredPayload).\(segments[2])"
        ))

        let otherSignature = try P256.Signing.PrivateKey().signature(
            for: Data("crl1.\(segments[1])".utf8)
        )
        XCTAssertThrowsError(try verifier.verify(
            "crl1.\(segments[1]).\(base64URL(otherSignature.derRepresentation))"
        ))
    }

    func testVerifierRejectsSignedInvalidClaims() throws {
        let privateKey = P256.Signing.PrivateKey()
        let invalidJSON: [String: Any] = [
            "schemaVersion": 1,
            "licenseID": "license-a",
            "accountID": "account-a",
            "deviceID": "device-a",
            "plan": "subscription",
            "issuedAt": 1_700_000_000_000,
            "offlineGraceDuration": 0,
        ]
        let payload = try JSONSerialization.data(withJSONObject: invalidJSON, options: [.sortedKeys])
        let token = try signedToken(payload: payload, privateKey: privateKey)
        let verifier = P256DirectLicenseTokenVerifier(
            keyProvider: StaticLicensePublicKeyProvider(
                keyData: privateKey.publicKey.derRepresentation
            )
        )

        XCTAssertThrowsError(try verifier.verify(token)) { error in
            XCTAssertEqual(error as? DirectLicenseError, .invalidClaims)
        }
    }

    func testVerifierFailsClosedWhenNoBundledPublicKeyIsConfigured() {
        let verifier = P256DirectLicenseTokenVerifier(
            keyProvider: StaticLicensePublicKeyProvider(keyData: nil)
        )

        XCTAssertFalse(verifier.isConfigured)
        XCTAssertThrowsError(try verifier.verify("crl1.payload.signature")) { error in
            XCTAssertEqual(error as? DirectLicenseError, .verifierUnavailable)
        }
    }

    func testRepositoryUsesProviderNeutralIdempotentRoutesWithoutCredentialHeaders() async throws {
        RecordingLicenseURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordingLicenseURLProtocol.self]
        let client = HTTPDirectLicenseRepositoryClient(
            baseURL: URL(string: "https://license.example.test")!,
            session: URLSession(configuration: configuration)
        )

        _ = try await client.activate(licenseKey: "LICENSE-KEY-123", deviceID: "device-a")
        _ = try await client.activate(licenseKey: "LICENSE-KEY-123", deviceID: "device-a")
        _ = try await client.restore(accountID: "account-a", deviceID: "device-a")
        _ = try await client.restore(accountID: "account-a", deviceID: "device-a")

        let requests = RecordingLicenseURLProtocol.recordedRequests()
        XCTAssertEqual(requests.map { $0.url?.path }, [
            "/v1/licenses/activate",
            "/v1/licenses/activate",
            "/v1/licenses/restore",
            "/v1/licenses/restore",
        ])
        let keys = requests.compactMap { $0.value(forHTTPHeaderField: "Idempotency-Key") }
        XCTAssertEqual(keys.count, 4)
        XCTAssertEqual(keys[0], keys[1])
        XCTAssertEqual(keys[2], keys[3])
        XCTAssertNotEqual(keys[0], keys[2])
        XCTAssertFalse(keys.joined().contains("LICENSE-KEY-123"))
        XCTAssertTrue(requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == nil
        })
    }

    private func makeClaims() throws -> DirectLicenseTokenClaims {
        let issuedAt = Date(timeIntervalSince1970: 1_700_000_000)
        return try DirectLicenseTokenClaims(
            licenseID: "license-a",
            accountID: "account-a",
            deviceID: "device-a",
            plan: .subscription,
            issuedAt: issuedAt,
            expiresAt: issuedAt.addingTimeInterval(30 * 24 * 60 * 60),
            offlineGraceDuration: 3 * 24 * 60 * 60
        )
    }

    private func signedToken(
        claims: DirectLicenseTokenClaims,
        privateKey: P256.Signing.PrivateKey
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try signedToken(payload: encoder.encode(claims), privateKey: privateKey)
    }

    private func signedToken(
        payload: Data,
        privateKey: P256.Signing.PrivateKey
    ) throws -> String {
        let payloadSegment = base64URL(payload)
        let signature = try privateKey.signature(for: Data("crl1.\(payloadSegment)".utf8))
        return "crl1.\(payloadSegment).\(base64URL(signature.derRepresentation))"
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private struct StaticLicensePublicKeyProvider: DirectLicensePublicKeyProviding {
    let keyData: Data?
    func publicKeyDER() -> Data? { keyData }
}

private final class RecordingLicenseURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var requests: [URLRequest] = []
    private static let requestLock = NSLock()

    static func reset() {
        requestLock.lock()
        requests = []
        requestLock.unlock()
    }

    static func recordedRequests() -> [URLRequest] {
        requestLock.lock()
        defer { requestLock.unlock() }
        return requests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestLock.lock()
        Self.requests.append(request)
        Self.requestLock.unlock()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"token":"signed-token"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
