import Foundation
import XCTest
@testable import ClipboardRouterCore

final class AutomaticOrganizationTests: XCTestCase {
    func testRulesEvaluateDeterministicallyByPriorityWithReasonsAndConfidence() throws {
        let clip = try makeSavedClip(
            text: "Contact owner@example.com at https://docs.example.com/runbook",
            type: .url,
            bundleID: "com.apple.Safari",
            domain: "docs.example.com"
        )
        let lowPriority = try makeRule(
            name: "Safari",
            priority: 20,
            matcher: .sourceApplication("com.apple.Safari")
        )
        let highPriority = try makeRule(
            name: "Example docs",
            priority: 1,
            matcher: .domain("example.com")
        )
        let entity = try makeRule(
            name: "Email",
            priority: 10,
            matcher: .entity(.emailAddress)
        )
        let snapshot = try AutomaticOrganizationSnapshot(rules: [lowPriority, entity, highPriority])

        let suggestions = AutomaticOrganizationEngine().suggestions(
            for: clip,
            snapshot: snapshot,
            context: .committedLocalOrdinary
        )

        XCTAssertEqual(suggestions.map(\.rule.name), ["Example docs", "Email", "Safari"])
        XCTAssertEqual(suggestions.map(\.confidence), [95, 85, 90])
        XCTAssertEqual(suggestions.first?.reason, "Link domain matches example.com")
    }

    func testCustomSafeRegexMatchesAndUnsafeRegexCannotBecomeARule() throws {
        let matcher = try CustomClipTextMatcher(
            mode: .regularExpression,
            pattern: #"\bACME-\d{3}\b"#
        )
        let rule = try makeRule(
            name: "Account IDs",
            priority: 0,
            matcher: .customText(matcher)
        )
        let clip = try makeSavedClip(text: "Follow up on ACME-142")
        let snapshot = try AutomaticOrganizationSnapshot(rules: [rule])

        XCTAssertEqual(
            AutomaticOrganizationEngine().suggestions(
                for: clip,
                snapshot: snapshot,
                context: .committedLocalOrdinary
            ).map(\.rule.id),
            [rule.id]
        )
        XCTAssertThrowsError(try CustomClipTextMatcher(
            mode: .regularExpression,
            pattern: #"(a+)+$"#
        ))
    }

    func testProtectedAndUncommittedOriginsFailClosed() throws {
        let clip = try makeSavedClip(text: "https://example.com", type: .url)
        let rule = try makeRule(
            name: "Links",
            priority: 0,
            matcher: .contentType(.url)
        )
        let snapshot = try AutomaticOrganizationSnapshot(rules: [rule])
        let engine = AutomaticOrganizationEngine()

        for origin in AutomaticOrganizationInputOrigin.allCases where origin != .localUser {
            XCTAssertTrue(engine.suggestions(
                for: clip,
                snapshot: snapshot,
                context: AutomaticOrganizationEvaluationContext(
                    origin: origin,
                    isCommittedOrdinarySavedItem: true,
                    isSensitive: false
                )
            ).isEmpty, "Expected \(origin) to fail closed")
        }
        XCTAssertTrue(engine.suggestions(
            for: clip,
            snapshot: snapshot,
            context: AutomaticOrganizationEvaluationContext(
                origin: .localUser,
                isCommittedOrdinarySavedItem: false,
                isSensitive: false
            )
        ).isEmpty)
        XCTAssertTrue(engine.suggestions(
            for: clip,
            snapshot: snapshot,
            context: AutomaticOrganizationEvaluationContext(
                origin: .localUser,
                isCommittedOrdinarySavedItem: true,
                isSensitive: true
            )
        ).isEmpty)
    }

    func testEvaluationAndAutomaticApplicationCountsAreBounded() throws {
        let clip = try makeSavedClip(text: "bounded")
        let rules = try (0..<AutomaticOrganizationSnapshot.maximumRules).map { index in
            try AutomaticOrganizationRule(
                name: "Rule \(index)",
                priority: index,
                behavior: .alwaysApply,
                matcher: .contentType(.plainText),
                action: AutomaticOrganizationAction(addedTags: ["tag-\(index)"])
            )
        }
        let snapshot = try AutomaticOrganizationSnapshot(rules: rules)

        let matches = AutomaticOrganizationEngine().automaticRules(
            for: clip,
            snapshot: snapshot,
            context: .committedLocalOrdinary
        )
        XCTAssertEqual(matches.count, AutomaticOrganizationEngine.maximumAutomaticApplications)
        XCTAssertEqual(matches.map(\.rule.priority), Array(0..<AutomaticOrganizationEngine.maximumAutomaticApplications))
    }

    func testRuleReplacementIsAtomicAndPreservesEditorImmutableState() throws {
        let original = try AutomaticOrganizationRule(
            name: "Original",
            isEnabled: false,
            priority: 7,
            behavior: .alwaysApply,
            matcher: .contentType(.plainText),
            action: AutomaticOrganizationAction(addedTags: ["original"])
        )
        let sibling = try makeRule(
            name: "Sibling",
            priority: 2,
            matcher: .contentType(.image)
        )
        let snapshot = try AutomaticOrganizationSnapshot(
            rules: [sibling, original],
            suppressedRuleIDs: [original.id]
        )
        let replacement = try AutomaticOrganizationRule(
            id: original.id,
            name: "Edited",
            isEnabled: original.isEnabled,
            priority: original.priority,
            behavior: original.behavior,
            matcher: .domain("example.com"),
            action: AutomaticOrganizationAction(addedTags: ["edited"])
        )

        let updated = try snapshot.replacingRule(replacement, expecting: original)

        XCTAssertEqual(updated.rules.map(\.id), [sibling.id, original.id])
        XCTAssertEqual(updated.rules.last, replacement)
        XCTAssertEqual(updated.suppressedRuleIDs, [original.id])

        var stale = original
        stale.name = "Changed elsewhere"
        XCTAssertThrowsError(try snapshot.replacingRule(replacement, expecting: stale)) {
            XCTAssertEqual($0 as? AutomaticOrganizationError, .staleRule)
        }

        var illegallyReordered = replacement
        illegallyReordered.priority = 0
        XCTAssertThrowsError(try snapshot.replacingRule(illegallyReordered, expecting: original)) {
            XCTAssertEqual($0 as? AutomaticOrganizationError, .invalidRule)
        }

        var invalidFields = replacement
        invalidFields.name = "   "
        XCTAssertThrowsError(try snapshot.replacingRule(invalidFields, expecting: original)) {
            XCTAssertEqual($0 as? AutomaticOrganizationError, .invalidRule)
        }
    }

    func testAtomicFolderAndTagMutationProducesReversibleStatesAndRejectsStaleUndo() async throws {
        let originalDate = Date(timeIntervalSince1970: 100)
        let destination = try ClipFolder(
            name: "Leads",
            sortOrder: 0,
            createdAt: originalDate
        )
        let original = try SavedClip(
            name: "Prospect",
            content: ClipContent.detect(text: "owner@example.com"),
            createdAt: originalDate,
            tags: ["new"]
        )
        let library = try ClipboardLibrary(snapshot: ClipboardLibrarySnapshot(
            savedClips: [original],
            folders: [destination]
        ))
        let appliedDate = Date(timeIntervalSince1970: 200)

        let updated = try await library.applyAutomaticOrganization(
            to: original.id,
            folderID: destination.id,
            tags: ["new", "qualified"],
            expecting: SavedClipOrganizationExpectation(savedClip: original),
            at: appliedDate
        )
        XCTAssertEqual(updated.folderID, destination.id)
        XCTAssertEqual(updated.tags, ["new", "qualified"])

        let receipt = AutomaticOrganizationReceipt(
            savedClipID: original.id,
            ruleID: UUID(),
            appliedAt: appliedDate,
            before: AutomaticOrganizationItemState(savedClip: original),
            after: AutomaticOrganizationItemState(savedClip: updated)
        )
        let restored = try await library.applyAutomaticOrganization(
            to: original.id,
            folderID: receipt.before.folderID,
            tags: receipt.before.tags,
            expecting: receipt.after.expectation,
            at: Date(timeIntervalSince1970: 300)
        )
        XCTAssertNil(restored.folderID)
        XCTAssertEqual(restored.tags, ["new"])

        await XCTAssertThrowsErrorAsync(
            try await library.applyAutomaticOrganization(
                to: original.id,
                folderID: destination.id,
                tags: ["qualified"],
                expecting: receipt.after.expectation
            )
        ) { error in
            XCTAssertEqual(
                error as? ClipboardLibraryError,
                .savedItemChangedDuringEdit(original.id)
            )
        }
    }

    func testPersistenceRoundTripAndChecksumFailure() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("automatic-organization.json")
        let store = JSONFileAutomaticOrganizationStore(fileURL: fileURL)
        let rule = try makeRule(
            name: "Images",
            priority: 0,
            matcher: .contentType(.image)
        )
        let snapshot = try AutomaticOrganizationSnapshot(
            rules: [rule],
            suppressedRuleIDs: [rule.id]
        )

        try await store.save(snapshot)
        let loaded = try await store.load()
        XCTAssertEqual(loaded, snapshot)
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        var data = try Data(contentsOf: fileURL)
        data[data.index(before: data.endIndex)] ^= 1
        try data.write(to: fileURL, options: .atomic)
        await XCTAssertThrowsErrorAsync(try await store.load()) { error in
            XCTAssertNotNil(error as? AutomaticOrganizationPersistenceError)
        }
    }

    private func makeRule(
        name: String,
        priority: Int,
        matcher: AutomaticOrganizationMatcher
    ) throws -> AutomaticOrganizationRule {
        try AutomaticOrganizationRule(
            name: name,
            priority: priority,
            matcher: matcher,
            action: AutomaticOrganizationAction(addedTags: ["matched"])
        )
    }

    private func makeSavedClip(
        text: String,
        type: SupportedContentType = .plainText,
        bundleID: String? = nil,
        domain: String? = nil
    ) throws -> SavedClip {
        try SavedClip(
            name: "Test",
            content: ClipContent(type: type, text: text),
            createdAt: Date(timeIntervalSince1970: 1),
            sourceApplicationBundleIdentifier: bundleID,
            captureContext: ClipCaptureContext(sourceDomain: domain)
        )
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw")
    } catch {
        errorHandler(error)
    }
}
