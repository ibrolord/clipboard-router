import Foundation
import XCTest
@testable import ClipboardRouterCore

final class AutomationFlowTests: XCTestCase {
    func testFlowDecodeRevalidatesBoundsAndSharedPortability() throws {
        let flow = try ClipFlow(
            name: "Qualify account",
            steps: [
                .addTags(id: UUID(), tags: ["qualified"]),
                .openWeb(
                    id: UUID(),
                    template: "https://app.hubspot.com/search?q={email}",
                    label: "HubSpot"
                ),
            ]
        )
        XCTAssertEqual(try JSONDecoder().decode(ClipFlow.self, from: JSONEncoder().encode(flow)), flow)

        XCTAssertThrowsError(try ClipFlow(name: "Empty", steps: []))
        XCTAssertThrowsError(try ClipFlow(
            name: "Shared local app",
            steps: [.openApplication(id: UUID(), bookmarkData: Data([1]), displayName: "CRM")],
            sharedFolderID: UUID()
        )) { error in
            XCTAssertEqual(error as? ClipFlowError, .nonPortableSharedStep)
        }
    }

    func testAutomaticExternalFlowRequiresReview() throws {
        let folderID = UUID()
        let local = try ClipFlow(
            name: "File it",
            trigger: .folderEntry(folderID: folderID, includeDescendants: false),
            steps: [.addTags(id: UUID(), tags: ["new"])]
        )
        let external = try ClipFlow(
            name: "Open CRM",
            trigger: .folderEntry(folderID: folderID, includeDescendants: false),
            steps: [.openWeb(
                id: UUID(),
                template: "https://example.com/search?q={clip}",
                label: "CRM"
            )]
        )
        XCTAssertFalse(local.requiresReviewWhenTriggered)
        XCTAssertTrue(external.requiresReviewWhenTriggered)
    }

    func testCustomTextFlowPersistsMatcherAndMatchesClipText() throws {
        let matcher = try CustomClipTextMatcher(
            mode: .wordsOrPhrases,
            pattern: "enterprise, renewal"
        )
        let flow = try ClipFlow(
            name: "Enterprise follow-up",
            entityFilter: .customText,
            customMatcher: matcher,
            steps: [.addTags(id: UUID(), tags: ["enterprise"])]
        )

        XCTAssertTrue(flow.matches(entities: [], clipText: "Enterprise account"))
        XCTAssertFalse(flow.matches(entities: [], clipText: "Self-serve account"))
        XCTAssertEqual(
            try JSONDecoder().decode(ClipFlow.self, from: JSONEncoder().encode(flow)),
            flow
        )
    }

    func testCustomTextFlowCannotPersistWithoutValidatedMatcher() {
        XCTAssertThrowsError(try ClipFlow(
            name: "Broken custom flow",
            entityFilter: .customText,
            steps: [.addTags(id: UUID(), tags: ["lead"])]
        )) { error in
            XCTAssertEqual(error as? ClipFlowError, .invalidCustomMatcher)
        }
    }

    func testOrganizationStepsMustPrecedeSideEffects() throws {
        XCTAssertThrowsError(try ClipFlow(
            name: "Misordered",
            steps: [
                .openWeb(
                    id: UUID(),
                    template: "https://example.com/search?q={clip}",
                    label: "CRM"
                ),
                .moveToFolder(id: UUID(), folderID: UUID()),
            ]
        )) { error in
            XCTAssertEqual(error as? ClipFlowError, .invalidSteps)
        }
    }

    func testOrganizationStepsCommitTagsAndMoveAtomically() async throws {
        let source = try ClipFolder(name: "Inbox", sortOrder: 0, createdAt: Date(timeIntervalSince1970: 1))
        let destination = try ClipFolder(name: "Qualified", sortOrder: 1, createdAt: Date(timeIntervalSince1970: 1))
        let clip = try SavedClip(
            name: "Acme",
            content: ClipContent.detect(text: "sam@acme.example"),
            folderID: source.id,
            createdAt: Date(timeIntervalSince1970: 2),
            tags: ["lead"]
        )
        let library = try ClipboardLibrary(snapshot: ClipboardLibrarySnapshot(
            savedClips: [clip],
            folders: [source, destination]
        ))
        let updated = try await library.applyAutomationOrganization(
            to: clip.id,
            addingTags: ["qualified", "Lead"],
            movingTo: destination.id,
            shouldMove: true,
            expectingFingerprint: clip.content.deduplicationFingerprint
        )
        XCTAssertEqual(updated.folderID, destination.id)
        XCTAssertEqual(updated.tags, ["lead", "qualified"])

        let beforeFailure = await library.snapshot()
        await XCTAssertThrowsErrorAsync {
            _ = try await library.applyAutomationOrganization(
                to: clip.id,
                addingTags: ["bad\u{0000}tag"],
                movingTo: source.id,
                shouldMove: true,
                expectingFingerprint: clip.content.deduplicationFingerprint
            )
        }
        let afterFailure = await library.snapshot()
        XCTAssertEqual(afterFailure, beforeFailure)
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {}
}
