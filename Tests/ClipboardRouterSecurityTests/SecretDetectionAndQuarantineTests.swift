import ClipboardRouterCore
import Foundation
import XCTest
@testable import ClipboardRouterSecurity

final class SecretDetectionAndQuarantineTests: XCTestCase {
    private let detector = SecretDetector()
    private let syntheticAWSKey = ["AKIA", "IOSFODNN7EXAMPLX"].joined()
    private let syntheticAWSSessionKey = ["ASIA", "IOSFODNN7EXAMPLX"].joined()
    private let syntheticSlackBotToken = [
        "xoxb", "123456789012", "123456789012", "AbCdEfGhIjKlMnOp",
    ].joined(separator: "-")
    private let syntheticSlackAppToken = [
        "xapp", "1", "A1234567890", "B1234567890", "AbCdEfGhIjKlMnOp",
    ].joined(separator: "-")
    private let syntheticAWSFalsePositive = "AWS_ACCESS_KEY_ID="
        + ["AKIA", "IOSFODNN7EXAMPLE"].joined()

    func testDetectsEverySupportedSecretCategory() throws {
        let fixtures: [(SecretCategory, String)] = [
            (.privateKey, "-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0BAQEFAASC"),
            (.awsAccessKey, syntheticAWSKey),
            (.openAIAPIKey, "sk-proj-AbC123def456GHI789jkl012MNOpqr345"),
            (.githubToken, "ghp_abcdefghijklmnopqrstuvwxyzABCDEFGHIJ"),
            (.slackToken, syntheticSlackBotToken),
            (
                .jsonWebToken,
                "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjMifQ.signature123"
            ),
            (.credentialURL, "https://alice:swordfish@example.com/private"),
            (.environmentAssignment, "export DATABASE_PASSWORD=correct-horse-battery-staple"),
            (.connectionString, "postgresql://dbuser:dbpass123@db.example.com/app"),
            (.paymentCard, "Payment card: 4242 4242 4242 4242"),
        ]

        for (category, text) in fixtures {
            let result = try detector.scan(ClipContent.detect(text: text))
            XCTAssertTrue(result.contains(category), "Expected \(category) for fixture")
        }
    }

    func testHighAndMediumConfidenceAreTyped() {
        let token = detector.scan(text: syntheticAWSKey)
        XCTAssertEqual(
            token.detections.first { $0.category == .awsAccessKey }?.confidence,
            .high
        )

        let paymentCard = detector.scan(text: "4242-4242-4242-4242")
        XCTAssertEqual(
            paymentCard.detections.first { $0.category == .paymentCard }?.confidence,
            .medium
        )
    }

    func testDetectsProviderAndConnectionStringVariants() {
        let fixtures: [(SecretCategory, String)] = [
            (.privateKey, "-----BEGIN RSA PRIVATE KEY-----"),
            (.awsAccessKey, syntheticAWSSessionKey),
            (.openAIAPIKey, "sk-svcacct-AbC123def456GHI789jkl012MNOpqr"),
            (.githubToken, "github_pat_11AA22BB33_CC44DD55EE66FF77GG88"),
            (.slackToken, syntheticSlackAppToken),
            (.environmentAssignment, "CLIENT_SECRET='six-or-more-characters'"),
            (
                .connectionString,
                "Server=db.example.com;Database=app;User Id=reader;Password=swordfish"
            ),
        ]

        for (category, text) in fixtures {
            XCTAssertTrue(detector.scan(text: text).contains(category), "Expected \(category)")
        }
    }

    func testFalsePositiveFixturesRemainClear() {
        let fixtures = [
            "-----BEGIN PUBLIC KEY-----",
            syntheticAWSFalsePositive,
            "OPENAI_API_KEY=YOUR_OPENAI_API_KEY",
            "github.com/org/repository",
            "Version 1.2.3-beta.4",
            "https://alice@example.com/private",
            "NODE_ENV=production",
            "NEXT_PUBLIC_API_KEY=publishable-client-value",
            "MONKEY=banana-value",
            "PRIVATE_KEY_PATH=/Users/example/.ssh/id_ed25519",
            "Server=db.example.com;User Id=reader;Integrated Security=true",
            "4242 4242 4242 4241",
            "Order 79927398713",
            "0000 0000 0000 0000",
        ]

        for fixture in fixtures {
            XCTAssertEqual(detector.scan(text: fixture), .clear, "False positive: \(fixture)")
        }
    }

    func testLuhnValidationAcceptsCommonCardLengthsAndRejectsInvalidCheckDigit() {
        XCTAssertTrue(detector.scan(text: "378282246310005").contains(.paymentCard))
        XCTAssertTrue(detector.scan(text: "6011-1111-1111-1117").contains(.paymentCard))
        XCTAssertFalse(detector.scan(text: "6011-1111-1111-1118").contains(.paymentCard))
    }

    func testScanResultSerializationCannotLeakMatchedValue() throws {
        let canary = "sk-proj-CanaryABC123def456GHI789jkl012MNOpqr"
        let data = try JSONEncoder().encode(detector.scan(text: canary))
        let encoded = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertFalse(encoded.contains(canary))
        XCTAssertTrue(encoded.contains(SecretCategory.openAIAPIKey.rawValue))
    }

    func testContentScanIncludesOCRAndCallerExtractedRichAndHTMLText() throws {
        let image = try ClipContent(
            type: .image,
            text: "Screenshot",
            representations: ClipRepresentations(ocrText: syntheticAWSKey)
        )
        XCTAssertTrue(detector.scan(image).contains(.awsAccessKey))

        let rich = try ClipContent(type: .richText, text: "Safe fallback")
        let result = detector.scan(
            rich,
            extractedRichText: "PASSWORD=correct-horse-battery-staple",
            extractedHTMLText: "ghp_abcdefghijklmnopqrstuvwxyzABCDEFGHIJ"
        )
        XCTAssertTrue(result.contains(.environmentAssignment))
        XCTAssertTrue(result.contains(.githubToken))
    }

    func testSubmitAllowsClearContentWithoutRetainingIt() async throws {
        let store = QuarantineStore()
        let content = try ClipContent.detect(text: "ordinary clipboard note")

        let decision = await store.submit(content)

        XCTAssertEqual(decision, .allowed)
        let pending = await store.pending()
        XCTAssertTrue(pending.isEmpty)
    }

    func testReviewKeepAndDeleteAreExplicitStateTransitions() async throws {
        let store = QuarantineStore()
        let first = try ClipContent.detect(text: "DATABASE_PASSWORD=correct-horse-battery-staple")
        let second = try ClipContent.detect(text: syntheticAWSKey)

        let firstReceipt = try quarantinedReceipt(await store.submit(first))
        let secondReceipt = try quarantinedReceipt(await store.submit(second))

        let review = await store.review(id: firstReceipt.id)
        XCTAssertEqual(review?.content, first)
        XCTAssertEqual(review?.receipt, firstReceipt)

        let kept = await store.keep(id: firstReceipt.id)
        let reviewAfterKeep = await store.review(id: firstReceipt.id)
        XCTAssertEqual(kept, first)
        XCTAssertNil(reviewAfterKeep)

        let firstDelete = await store.delete(id: secondReceipt.id)
        let repeatedDelete = await store.delete(id: secondReceipt.id)
        XCTAssertTrue(firstDelete)
        XCTAssertFalse(repeatedDelete)
        let pending = await store.pending()
        XCTAssertTrue(pending.isEmpty)
    }

    func testReviewDoesNotExtendTwentyFourHourTTL() async throws {
        let store = QuarantineStore()
        let start = Date(timeIntervalSince1970: 1_000)
        let content = try ClipContent.detect(text: "PASSWORD=correct-horse-battery-staple")
        let receipt = try quarantinedReceipt(await store.submit(content, at: start))

        XCTAssertEqual(receipt.expiresAt, start.addingTimeInterval(24 * 60 * 60))
        let immediatelyBeforeExpiry = await store.review(
            id: receipt.id,
            at: receipt.expiresAt.addingTimeInterval(-0.001)
        )
        let atExpiry = await store.review(id: receipt.id, at: receipt.expiresAt)
        let keepAfterExpiry = await store.keep(id: receipt.id, at: receipt.expiresAt)
        XCTAssertNotNil(immediatelyBeforeExpiry)
        XCTAssertNil(atExpiry)
        XCTAssertNil(keepAfterExpiry)
    }

    func testHealthSummaryContainsOnlyCountsAndCategories() async throws {
        let store = QuarantineStore()
        let canary = "sk-proj-HealthCanary123def456GHI789jkl012MNOp"
        let content = try ClipContent.detect(text: "\(canary)\nPASSWORD=correct-horse-battery-staple")
        _ = await store.submit(content)

        let health = await store.health()
        XCTAssertEqual(health.quarantinedClipCount, 1)
        XCTAssertEqual(health.count(for: .openAIAPIKey), 1)
        XCTAssertEqual(health.count(for: .environmentAssignment), 1)

        let data = try JSONEncoder().encode(health)
        let encoded = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(encoded.contains(canary))
        XCTAssertFalse(encoded.contains("correct-horse-battery-staple"))
    }

    func testHealthCountsEachCategoryOncePerClipAndDropsExpiredEntries() async throws {
        let store = QuarantineStore()
        let start = Date(timeIntervalSince1970: 2_000)
        let repeatedCards = try ClipContent.detect(
            text: "4242 4242 4242 4242 and 378282246310005"
        )
        let aws = try ClipContent.detect(text: syntheticAWSKey)
        _ = await store.submit(repeatedCards, at: start)
        _ = await store.submit(aws, at: start.addingTimeInterval(1))

        let beforeExpiry = await store.health(at: start.addingTimeInterval(10))
        XCTAssertEqual(beforeExpiry.quarantinedClipCount, 2)
        XCTAssertEqual(beforeExpiry.count(for: .paymentCard), 1)
        XCTAssertEqual(beforeExpiry.count(for: .awsAccessKey), 1)

        let purged = await store.purgeExpired(at: start.addingTimeInterval(24 * 60 * 60))
        XCTAssertEqual(purged, 1)
        let afterExpiry = await store.health(at: start.addingTimeInterval(24 * 60 * 60))
        XCTAssertEqual(afterExpiry.quarantinedClipCount, 1)
        XCTAssertEqual(afterExpiry.count(for: .paymentCard), 0)
        XCTAssertEqual(afterExpiry.count(for: .awsAccessKey), 1)
    }

    func testExpirationSnapshotPurgesOnceAndSuppliesNextTimerDeadline() async throws {
        let store = QuarantineStore()
        let start = Date(timeIntervalSince1970: 3_000)
        let first = try quarantinedReceipt(
            await store.submit(
                try ClipContent.detect(text: "PASSWORD=correct-horse-battery-staple"),
                at: start
            )
        )
        let second = try quarantinedReceipt(
            await store.submit(
                try ClipContent.detect(text: syntheticAWSKey),
                at: start.addingTimeInterval(10)
            )
        )

        let snapshot = await store.expirationSnapshot(at: first.expiresAt)

        XCTAssertEqual(snapshot.purgedCount, 1)
        XCTAssertEqual(snapshot.pending.map(\.id), [second.id])
        XCTAssertEqual(snapshot.health.quarantinedClipCount, 1)
        XCTAssertEqual(snapshot.nextExpirationDate, second.expiresAt)
    }

    private func quarantinedReceipt(_ decision: QuarantineDecision) throws -> QuarantineReceipt {
        guard case let .quarantined(receipt) = decision else {
            XCTFail("Expected sensitive content to be quarantined")
            throw TestError.expectedQuarantine
        }
        return receipt
    }

    private enum TestError: Error {
        case expectedQuarantine
    }
}
