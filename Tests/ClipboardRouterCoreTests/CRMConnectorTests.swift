import ClipboardRouterCore
import XCTest

final class CRMConnectorTests: XCTestCase {
    func testFieldMappingAcceptsAllowlistedContactFields() throws {
        let mapping = try CRMFieldMapping(object: .contact, fields: ["email": "person@example.com"])

        XCTAssertEqual(mapping.fields, ["email": "person@example.com"])
    }

    func testFieldMappingRejectsUnknownProviderField() {
        XCTAssertThrowsError(try CRMFieldMapping(object: .contact, fields: ["ownerId": "secret"] as [String: String]))
    }

    func testFieldMappingRejectsWhitespaceOnlyValue() {
        XCTAssertThrowsError(try CRMFieldMapping(object: .contact, fields: ["email": "   "]))
    }

    func testWriteReviewRejectsMappingForDifferentObject() throws {
        let mapping = try CRMFieldMapping(object: .company, fields: ["name": "Acme"])

        XCTAssertThrowsError(try CRMWriteReview(
            connectionID: UUID(), provider: .salesforce, object: .contact,
            mode: .create, mapping: mapping, sourceFingerprint: "source"
        ))
    }

    func testUpdateRequiresProviderRecordID() throws {
        let mapping = try CRMFieldMapping(object: .contact, fields: ["email": "person@example.com"])

        XCTAssertThrowsError(try CRMWriteReview(
            connectionID: UUID(), provider: .hubSpot, object: .contact,
            mode: .update, mapping: mapping, sourceFingerprint: "source"
        ))
    }

    func testUpdateRejectsProviderIDThatCouldEscapeURLPath() throws {
        let mapping = try CRMFieldMapping(object: .contact, fields: ["email": "person@example.com"])

        XCTAssertThrowsError(try CRMWriteReview(
            connectionID: UUID(), provider: .hubSpot, object: .contact,
            mode: .update, existingProviderID: "../contacts?all=true",
            mapping: mapping, sourceFingerprint: "source"
        ))
    }

    func testNewContactRequiresDuplicateLookupKey() throws {
        let mapping = try CRMFieldMapping(object: .contact, fields: ["firstName": "Pat"])

        XCTAssertThrowsError(try CRMWriteReview(
            connectionID: UUID(), provider: .salesforce, object: .contact,
            mode: .create, mapping: mapping, sourceFingerprint: "source"
        ))
    }

    func testSalesforceContactCreateRequiresLastName() throws {
        let mapping = try CRMFieldMapping(
            object: .contact,
            fields: ["email": "person@example.com"]
        )

        XCTAssertThrowsError(try CRMWriteReview(
            connectionID: UUID(), provider: .salesforce, object: .contact,
            mode: .create, mapping: mapping, sourceFingerprint: "source"
        ))
    }

    func testIdempotencyKeyIsStableAcrossDictionaryOrder() throws {
        let connectionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let first = try CRMWriteReview(
            connectionID: connectionID, provider: .salesforce, object: .contact,
            mode: .create,
            mapping: CRMFieldMapping(object: .contact, fields: ["email": "p@example.com", "firstName": "Pat", "lastName": "Example"]),
            sourceFingerprint: "source"
        )
        let second = try CRMWriteReview(
            connectionID: connectionID, provider: .salesforce, object: .contact,
            mode: .create,
            mapping: CRMFieldMapping(object: .contact, fields: ["lastName": "Example", "firstName": "Pat", "email": "p@example.com"]),
            sourceFingerprint: "source"
        )

        XCTAssertEqual(first.idempotencyKey, second.idempotencyKey)
    }

    func testIdempotencyKeyChangesWhenReviewedValueChanges() throws {
        let connectionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let first = try review(connectionID: connectionID, email: "first@example.com")
        let second = try review(connectionID: connectionID, email: "second@example.com")

        XCTAssertNotEqual(first.idempotencyKey, second.idempotencyKey)
    }

    func testHubSpotRequiresHTTPSTokenBroker() {
        let definition = CRMConnectionDefinition(
            provider: .hubSpot, displayName: "HubSpot", clientID: "client",
            redirectURI: URL(string: "clipboardrouter://oauth/hubspot")!,
            tokenBrokerURL: URL(string: "http://broker.example.com")
        )

        XCTAssertNotNil(definition.externalSetupBlocker)
    }

    func testHubSpotRejectsBrokerURLWithEmbeddedCredentials() {
        let definition = CRMConnectionDefinition(
            provider: .hubSpot, displayName: "HubSpot", clientID: "client",
            redirectURI: URL(string: "clipboardrouter://oauth/hubspot")!,
            tokenBrokerURL: URL(string: "https://user:password@broker.example.com")
        )

        XCTAssertNotNil(definition.externalSetupBlocker)
    }

    func testSalesforceDoesNotRequireTokenBroker() {
        let definition = CRMConnectionDefinition(
            provider: .salesforce, displayName: "Salesforce", clientID: "client",
            redirectURI: URL(string: "clipboardrouter://oauth/salesforce")!
        )

        XCTAssertNil(definition.externalSetupBlocker)
    }

    private func review(connectionID: UUID, email: String) throws -> CRMWriteReview {
        try CRMWriteReview(
            connectionID: connectionID, provider: .salesforce, object: .contact,
            mode: .create,
            mapping: CRMFieldMapping(
                object: .contact,
                fields: ["email": email, "lastName": "Reviewed"]
            ),
            sourceFingerprint: "source"
        )
    }
}
