import Foundation
import XCTest
@testable import ClipboardRouterCore

final class ActionableClipDetectionTests: XCTestCase {
    private let detector = ActionableClipDetector()

    func testDetectsSupportedEntitiesInSourceOrder() throws {
        let entities = detector.detect(
            in: "Email sam@example.com, call +1 (416) 555-0198, visit https://example.com/pricing on August 15, 2026 at 2 PM."
        )

        XCTAssertEqual(
            entities.map(\.kind),
            [.emailAddress, .phoneNumber, .webURL, .date]
        )
        XCTAssertEqual(entities[0].normalizedValue, "sam@example.com")
        XCTAssertEqual(entities[1].normalizedValue, "+14165550198")
        XCTAssertEqual(entities[2].normalizedValue, "https://example.com/pricing")
        XCTAssertNotNil(entities[3].date)
    }

    func testRejectsUnsupportedSchemesAndImplausiblePhoneNumbers() {
        let entities = detector.detect(in: "ftp://example.com and 12345")
        XCTAssertTrue(entities.isEmpty)
    }

    func testDeduplicatesURLsButPreservesEmailLocalPartCase() {
        let entities = detector.detect(
            in: "sam@example.com then SAM@example.com and https://example.com twice https://example.com"
        )
        XCTAssertEqual(
            entities.filter { $0.kind == .emailAddress }.map(\.normalizedValue),
            ["sam@example.com", "SAM@example.com"]
        )
        XCTAssertEqual(entities.filter { $0.kind == .webURL }.count, 1)
    }

    func testRefusesUnboundedInput() {
        let text = String(repeating: "a", count: ActionableClipDetector.maximumInputUTF8Bytes + 1)
        XCTAssertTrue(detector.detect(in: text).isEmpty)
    }

    func testAutomationFilterAndFolderConditionAreManualEligibilityOnly() throws {
        let folderID = UUID()
        let entity = DetectedClipEntity(
            kind: .emailAddress,
            displayValue: "sam@example.com",
            normalizedValue: "sam@example.com",
            utf16Range: NSRange(location: 0, length: 15)
        )
        let automation = try ClipAutomation(
            name: "Research in portal",
            entityFilter: .email,
            requiredFolderID: folderID,
            target: .webURLTemplate("https://example.com/search?q={email}")
        )

        XCTAssertTrue(automation.applies(to: [entity], folderID: folderID))
        XCTAssertFalse(automation.applies(to: [entity], folderID: nil))
        XCTAssertFalse(automation.applies(to: [], folderID: folderID))
    }

    func testCustomWordsMatchAnyLiteralAndRespectCasePreference() throws {
        let insensitive = try CustomClipTextMatcher(
            mode: .wordsOrPhrases,
            pattern: "enterprise, renewal due"
        )
        XCTAssertTrue(insensitive.matches("ACME is an Enterprise account"))
        XCTAssertTrue(insensitive.matches("The renewal due date is Friday"))
        XCTAssertFalse(insensitive.matches("A new self-serve signup"))

        let sensitive = try CustomClipTextMatcher(
            mode: .wordsOrPhrases,
            pattern: "Enterprise",
            isCaseSensitive: true
        )
        XCTAssertTrue(sensitive.matches("Enterprise account"))
        XCTAssertFalse(sensitive.matches("enterprise account"))
    }

    func testCustomRegularExpressionMatchesLocallyAndRejectsRiskyFeatures() throws {
        let matcher = try CustomClipTextMatcher(
            mode: .regularExpression,
            pattern: #"\b(ACME|Globex)-\d{3}\b"#
        )
        XCTAssertTrue(matcher.matches("Lead ACME-142 is ready"))
        XCTAssertFalse(matcher.matches("Lead ACME-14 is incomplete"))

        XCTAssertThrowsError(try CustomClipTextMatcher(
            mode: .regularExpression,
            pattern: #"(?=secret)"#
        ))
        XCTAssertThrowsError(try CustomClipTextMatcher(
            mode: .regularExpression,
            pattern: #"(a+)+$"#
        ))
        XCTAssertThrowsError(try CustomClipTextMatcher(
            mode: .regularExpression,
            pattern: #"(a|aa)+$"#
        ))
        XCTAssertThrowsError(try CustomClipTextMatcher(
            mode: .regularExpression,
            pattern: #"(lead)\1"#
        ))
    }

    func testCustomRegularExpressionRejectsAdjacentAmbiguousRepetitionsBeforeMatching() {
        let measuredAttack = #"(a*)(a*)(a*)(a*)(a*)(a*)(a*)(a*)b"#
        let startedAt = ContinuousClock.now

        XCTAssertThrowsError(try CustomClipTextMatcher(
            mode: .regularExpression,
            pattern: measuredAttack
        )) { error in
            XCTAssertEqual(error as? CustomClipTextMatcherError, .unsafeRegularExpression)
        }
        XCTAssertLessThan(
            startedAt.duration(to: .now),
            .milliseconds(100),
            "Unsafe user regex must be rejected by structural validation, before ICU can match it."
        )

        for pattern in [#"(a*)(a*)b"#, #"a+a+$"#, #"a{0,20}a{0,20}b"#, #"a?a?a"#] {
            XCTAssertThrowsError(try CustomClipTextMatcher(
                mode: .regularExpression,
                pattern: pattern
            ), "Expected ambiguous repetition to be rejected: \(pattern)")
        }

        let persistedAttack = #"{"mode":"regularExpression","pattern":"(a*)(a*)(a*)(a*)(a*)(a*)(a*)(a*)b","isCaseSensitive":false}"#
        XCTAssertThrowsError(try JSONDecoder().decode(
            CustomClipTextMatcher.self,
            from: Data(persistedAttack.utf8)
        ))

        let combinatorialAlternation = Array(repeating: #"(a|aa)"#, count: 9).joined() + "b"
        XCTAssertThrowsError(try CustomClipTextMatcher(
            mode: .regularExpression,
            pattern: combinatorialAlternation
        ))
    }

    func testCustomRegularExpressionPreservesUsefulConservativeSubset() throws {
        let identifier = try CustomClipTextMatcher(
            mode: .regularExpression,
            pattern: #"\b[A-Z]{2,5}-\d{3}\b"#,
            isCaseSensitive: true
        )
        XCTAssertTrue(identifier.matches("Ticket ACME-142 is ready"))
        XCTAssertFalse(identifier.matches("Ticket acme-142 is ready"))

        let repeatedLiteralGroup = try CustomClipTextMatcher(
            mode: .regularExpression,
            pattern: #"^(ab)+$"#
        )
        XCTAssertTrue(repeatedLiteralGroup.matches("ababab"))

        let characterClassLiteral = try CustomClipTextMatcher(
            mode: .regularExpression,
            pattern: #"^[+?]{2}$"#
        )
        XCTAssertTrue(characterClassLiteral.matches("+?"))
    }

    func testCustomMatcherFailsClosedForOversizedClipText() throws {
        let matcher = try CustomClipTextMatcher(
            mode: .wordsOrPhrases,
            pattern: "qualified"
        )
        let oversized = String(repeating: "a", count: CustomClipTextMatcher.maximumInputUTF8Bytes)
            + "qualified"
        XCTAssertFalse(matcher.matches(oversized))
    }

    func testCustomAutomationRequiresMatcherAndUsesClipTextAtEligibilityBoundary() throws {
        XCTAssertThrowsError(try ClipAutomation(
            name: "Open account playbook",
            entityFilter: .customText,
            target: .webURLTemplate("https://example.com/search?q={clip}")
        )) { error in
            XCTAssertEqual(error as? ClipAutomationError, .invalidCustomMatcher)
        }

        let matcher = try CustomClipTextMatcher(
            mode: .regularExpression,
            pattern: #"\b(qualified|enterprise)\b"#
        )
        let automation = try ClipAutomation(
            name: "Open account playbook",
            entityFilter: .customText,
            customMatcher: matcher,
            target: .webURLTemplate("https://example.com/search?q={clip}")
        )
        XCTAssertTrue(automation.applies(to: [], clipText: "Qualified lead", folderID: nil))
        XCTAssertFalse(automation.applies(to: [], clipText: "Self-serve lead", folderID: nil))
        XCTAssertEqual(
            try JSONDecoder().decode(ClipAutomation.self, from: JSONEncoder().encode(automation)),
            automation
        )
    }

    func testURLTemplateEncodesClipAsOneQueryValueAndRejectsUnsafeTargets() throws {
        let template = try AutomationURLTemplate("https://example.com/search?q={clip}")
        let rendered = try template.render(clipText: "Acme & Sons = buyer?", entities: [])
        XCTAssertEqual(
            rendered.absoluteString,
            "https://example.com/search?q=Acme%20%26%20Sons%20%3D%20buyer%3F"
        )
        XCTAssertThrowsError(try AutomationURLTemplate("file:///tmp/{clip}"))
        XCTAssertThrowsError(try AutomationURLTemplate("http://example.com/?q={clip}"))
        XCTAssertThrowsError(try AutomationURLTemplate("https://user:pass@example.com/?q={clip}"))
        XCTAssertThrowsError(try AutomationURLTemplate("https://example.com/static"))
    }

    func testPersistedAutomationIsRevalidatedWhenDecoded() throws {
        let automation = try ClipAutomation(
            name: "Search portal",
            target: .webURLTemplate("https://example.com/search?q={clip}")
        )
        let encoded = try JSONEncoder().encode(automation)
        let unsafe = String(decoding: encoded, as: UTF8.self)
            .replacingOccurrences(of: #"https:\/\/"#, with: #"http:\/\/"#)
        XCTAssertNotEqual(unsafe, String(decoding: encoded, as: UTF8.self))

        XCTAssertThrowsError(try JSONDecoder().decode(
            ClipAutomation.self,
            from: Data(unsafe.utf8)
        ))
    }

    func testApplicationAutomationRequiresBookmarkAndSafeDisplayName() {
        XCTAssertThrowsError(try ClipAutomation(
            name: "Open CRM",
            target: .application(bookmarkData: Data(), displayName: "CRM")
        ))
        XCTAssertThrowsError(try ClipAutomation(
            name: "Open CRM",
            target: .application(bookmarkData: Data([1]), displayName: "CRM\nInjected")
        ))
    }
}
