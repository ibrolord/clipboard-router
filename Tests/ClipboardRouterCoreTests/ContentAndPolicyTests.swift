import Foundation
import XCTest
@testable import ClipboardRouterCore

final class ContentAndPolicyTests: XCTestCase {
    func testLegacySnapshotWithoutPendingSyncJournalDecodesAsEmptyJournal() throws {
        let encoded = try JSONEncoder().encode(ClipboardLibrarySnapshot.empty)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "pendingSavedLibraryMutations")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(ClipboardLibrarySnapshot.self, from: legacyData)

        XCTAssertTrue(decoded.pendingSavedLibraryMutations.isEmpty)
        XCTAssertEqual(decoded.schemaVersion, ClipboardLibrarySnapshot.currentSchemaVersion)
    }

    func testLegacyPendingMutationWithoutTokenReceivesAcknowledgementIdentity() throws {
        let id = UUID()
        let data = Data(
            """
            {"id":"\(id.uuidString)","kind":"folder","isDeletion":false,"modifiedAt":0}
            """.utf8
        )

        let mutation = try JSONDecoder().decode(PendingSavedLibraryMutation.self, from: data)

        XCTAssertEqual(mutation.id, id)
        XCTAssertNotEqual(
            mutation.token,
            UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        )
    }

    func testURLDetectionPreservesOriginalUnicodeText() throws {
        let original = "  https://example.com/über?q=hello  \n"
        let content = try ClipContent.detect(text: original)

        XCTAssertEqual(content.type, .url)
        XCTAssertEqual(content.text, original)
        XCTAssertEqual(content.deduplicationFingerprint.count, 64)
        XCTAssertEqual(content.deduplicationFingerprint, content.deduplicationFingerprint)
    }

    func testNonWebURLAndOrdinaryUnicodeArePlainText() throws {
        XCTAssertEqual(try ClipContent.detect(text: "not a URL").type, .plainText)
        XCTAssertEqual(try ClipContent.detect(text: "mailto:test@example.com").type, .plainText)
        XCTAssertEqual(try ClipContent.detect(text: "こんにちは\nمرحبا").type, .plainText)
    }

    func testEmptyContentAndInvalidRetentionAreRejected() {
        XCTAssertThrowsError(try ClipContent.detect(text: "")) { error in
            XCTAssertEqual(error as? ClipboardLibraryError, .emptyContent)
        }
        XCTAssertThrowsError(try HistoryRetentionPolicy(maximumAge: 0)) { error in
            XCTAssertEqual(error as? ClipboardLibraryError, .invalidRetentionDuration)
        }
    }

    func testDecodedModelsEnforceContentAndRetentionInvariants() throws {
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                ClipContent.self,
                from: Data(#"{"type":"plainText","text":""}"#.utf8)
            )
        ) { error in
            XCTAssertEqual(error as? ClipboardLibraryError, .emptyContent)
        }
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                HistoryRetentionPolicy.self,
                from: Data(#"{"maximumAge":-1}"#.utf8)
            )
        ) { error in
            XCTAssertEqual(error as? ClipboardLibraryError, .invalidRetentionDuration)
        }
    }

    func testCapturePolicyRejectsPauseExcludedApplicationAndPrivacyMarkers() throws {
        let content = try ClipContent.detect(text: "private value")
        let base = CaptureCandidate(content: content)

        var paused = CapturePolicy(isCaptureEnabled: false)
        XCTAssertEqual(paused.decision(for: base), .reject(.capturePaused))

        paused.isCaptureEnabled = true
        paused.setApplication("  COM.EXAMPLE.Secrets  ", excluded: true)
        let excluded = CaptureCandidate(
            content: content,
            sourceApplicationBundleIdentifier: "com.example.secrets"
        )
        XCTAssertEqual(paused.decision(for: excluded), .reject(.applicationExcluded))

        for marker in PasteboardSemanticType.privacySensitiveTypes {
            let candidate = CaptureCandidate(
                content: content,
                pasteboardTypeIdentifiers: [marker]
            )
            XCTAssertEqual(
                paused.decision(for: candidate),
                .reject(.concealedOrTransientType),
                "Expected marker \(marker) to be ignored"
            )
        }
    }

    func testPrivacyMarkersCannotBeRemovedByInitializer() throws {
        let content = try ClipContent.detect(text: "secret")
        let policy = CapturePolicy(ignoredPasteboardTypeIdentifiers: [])

        XCTAssertTrue(
            PasteboardSemanticType.privacySensitiveTypes.isSubset(
                of: policy.ignoredPasteboardTypeIdentifiers
            )
        )
        XCTAssertEqual(
            policy.decision(
                for: CaptureCandidate(
                    content: content,
                    pasteboardTypeIdentifiers: [PasteboardSemanticType.concealed]
                )
            ),
            .reject(.concealedOrTransientType)
        )
    }

    func testPrivacyMarkersAreRestoredWhenDecodingPersistedPolicy() throws {
        let json = Data(
            """
            {
              "isCaptureEnabled": true,
              "excludedApplicationBundleIdentifiers": [],
              "ignoredPasteboardTypeIdentifiers": []
            }
            """.utf8
        )
        let decoded = try JSONDecoder().decode(CapturePolicy.self, from: json)

        XCTAssertTrue(
            PasteboardSemanticType.privacySensitiveTypes.isSubset(
                of: decoded.ignoredPasteboardTypeIdentifiers
            )
        )
    }
}
