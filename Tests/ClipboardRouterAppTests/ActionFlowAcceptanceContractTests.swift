import ClipboardRouterCore
import ClipboardRouterPlatform
import Foundation
import XCTest
@testable import ClipboardRouterApp

final class ActionFlowAccessibilityContractTests: XCTestCase {
    func testUUIDKeyedIdentifiersAreStableAndDistinct() {
        let id = UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!

        XCTAssertEqual(
            ActionFlowAccessibility.flowRow(id),
            "uiAcceptance.actions.flowRow.01234567-89ab-cdef-0123-456789abcdef"
        )
        XCTAssertEqual(
            ActionFlowAccessibility.flowEdit(id),
            "uiAcceptance.actions.flowEdit.01234567-89ab-cdef-0123-456789abcdef"
        )
        XCTAssertEqual(
            ActionFlowAccessibility.flowDelete(id),
            "uiAcceptance.actions.flowDelete.01234567-89ab-cdef-0123-456789abcdef"
        )
        XCTAssertEqual(
            ActionFlowAccessibility.confirmFlowDelete(id),
            "uiAcceptance.actions.confirmFlowDelete.01234567-89ab-cdef-0123-456789abcdef"
        )
        XCTAssertEqual(
            ActionFlowAccessibility.review(id),
            "uiAcceptance.flow.review.01234567-89ab-cdef-0123-456789abcdef"
        )
        XCTAssertEqual(
            ActionFlowAccessibility.reviewRun(id),
            "uiAcceptance.flow.reviewRun.01234567-89ab-cdef-0123-456789abcdef"
        )
        XCTAssertEqual(
            ActionFlowAccessibility.reviewCancel(id),
            "uiAcceptance.flow.reviewCancel.01234567-89ab-cdef-0123-456789abcdef"
        )
        XCTAssertEqual(
            ActionFlowAccessibility.reviewStep(id),
            "uiAcceptance.flow.reviewStep.01234567-89ab-cdef-0123-456789abcdef"
        )

        let identifiers = [
            ActionFlowAccessibility.flowRow(id),
            ActionFlowAccessibility.flowEdit(id),
            ActionFlowAccessibility.flowDelete(id),
            ActionFlowAccessibility.confirmFlowDelete(id),
            ActionFlowAccessibility.review(id),
            ActionFlowAccessibility.reviewRun(id),
            ActionFlowAccessibility.reviewCancel(id),
            ActionFlowAccessibility.reviewStep(id),
        ]
        XCTAssertEqual(Set(identifiers).count, identifiers.count)
    }

    func testAccessibilityValuesDescribeCurrentStateRatherThanClaimingSuccess() {
        XCTAssertEqual(
            ActionFlowAccessibility.flowRowValue(
                matcherSummary: "Matches /renewal/",
                stepCount: 2,
                isAutomatic: false,
                isEnabled: true
            ),
            "Enabled, Matches /renewal/, 2 steps, manual"
        )
        XCTAssertEqual(
            ActionFlowAccessibility.editorValue(
                editingID: nil,
                matcherState: "Custom match invalid",
                stepCount: 2,
                canCommit: false
            ),
            "Creating, Custom match invalid, 2 steps, cannot save"
        )
        XCTAssertEqual(
            ActionFlowAccessibility.reviewValue(
                flowName: "Local follow-up",
                stepCount: 2,
                triggeredAutomatically: false,
                isRunning: false
            ),
            "Local follow-up, 2 steps, manual run, ready for review"
        )
    }

    func testSafeRegexMatchesAndUnsafeRegexStillFailsClosed() throws {
        let safe = try CustomClipTextMatcher(
            mode: .regularExpression,
            pattern: #"\b(enterprise|renewal)\b"#
        )
        XCTAssertTrue(safe.matches("Enterprise renewal discussion"))
        XCTAssertFalse(safe.matches("Personal reminder"))

        XCTAssertThrowsError(try CustomClipTextMatcher(
            mode: .regularExpression,
            pattern: #"(a+)+"#
        ))
        XCTAssertThrowsError(try CustomClipTextMatcher(
            mode: .regularExpression,
            pattern: #"(?=secret)secret"#
        ))

        let persistedUnsafe = Data(
            #"{"mode":"regularExpression","pattern":"(a+)+","isCaseSensitive":false}"#.utf8
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(CustomClipTextMatcher.self, from: persistedUnsafe)
        )
    }
}

@MainActor
final class ActionFlowPersistenceResumeTests: XCTestCase {
    func testRelaunchResumesOnlyPendingLocalStepAndPersistsCompletedReceipts() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActionFlowResume-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = try SavedClip(
            name: "Acceptance account",
            content: ClipContent.detect(text: "Enterprise renewal discussion"),
            createdAt: Date(timeIntervalSince1970: 2_000_000_000),
            tags: ["acceptance-reviewed"]
        )
        let tagStepID = UUID()
        let noteStepID = UUID()
        let flow = try ClipFlow(
            name: "Acceptance local resume",
            steps: [
                .addTags(id: tagStepID, tags: ["acceptance-reviewed"]),
                .createTaskDraft(
                    id: noteStepID,
                    titleTemplate: "Follow up: {title}",
                    dueInDays: 2
                ),
            ]
        )
        let plan = try ClipFlowRunPlan(
            flow: flow,
            clipID: source.id,
            clipFingerprint: source.content.deduplicationFingerprint
        )
        let runStore = JSONFileAutomationRunLedgerStore(
            fileURL: root.appendingPathComponent("automation-runs.json")
        )
        let preRelaunchLedger = AutomationRunLedger(persistence: runStore)
        _ = try await preRelaunchLedger.createRun(
            plan: plan,
            triggerKind: .manual,
            idempotencyKey: "acceptance-local-resume",
            requiresReview: false
        )
        let firstClaim = try await preRelaunchLedger.claimNextStep(
            runID: plan.id,
            workerID: UUID()
        )
        XCTAssertEqual(firstClaim.receipt.sourceStepIDs, [tagStepID])
        try await preRelaunchLedger.markStepSucceeded(firstClaim)

        let defaultsName = "ActionFlowResumeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set(try JSONEncoder().encode([flow]), forKey: "clipFlows.v1")
        let libraryStore = InMemoryClipboardLibraryStore(
            snapshot: ClipboardLibrarySnapshot(savedClips: [source])
        )

        var firstModel: AppModel? = AppModel(
            defaults: defaults,
            hotKey: ActionFlowTestHotKeyRegistrar(),
            supportDirectory: root,
            libraryPersistence: libraryStore,
            automationRunStore: runStore
        )
        await firstModel?.start()

        let resumedRequest = try XCTUnwrap(firstModel?.pendingFlowReview)
        XCTAssertEqual(resumedRequest.id, plan.id)
        XCTAssertEqual(
            firstModel?.automationRunSnapshot.runs.first?.steps.map(\.status),
            [.succeeded, .pending]
        )
        let resumed = await firstModel?.executeFlow(resumedRequest)
        XCTAssertEqual(resumed, true)

        let completed = try XCTUnwrap(firstModel?.automationRunSnapshot.runs.first)
        XCTAssertEqual(completed.status, .succeeded)
        XCTAssertEqual(completed.steps.map(\.status), [.succeeded, .succeeded])
        XCTAssertEqual(completed.steps.map(\.attemptCount), [1, 1])
        XCTAssertEqual(
            firstModel?.snapshot.savedClips.first(where: { $0.id == source.id })?.tags,
            ["acceptance-reviewed"]
        )
        XCTAssertEqual(
            firstModel?.snapshot.savedClips.filter { $0.kind == .note }.count,
            1
        )

        firstModel = nil
        let relaunched = AppModel(
            defaults: defaults,
            hotKey: ActionFlowTestHotKeyRegistrar(),
            supportDirectory: root,
            libraryPersistence: libraryStore,
            automationRunStore: runStore
        )
        await relaunched.start()

        XCTAssertNil(relaunched.pendingFlowReview)
        let persisted = try XCTUnwrap(relaunched.automationRunSnapshot.runs.first)
        XCTAssertEqual(persisted.status, .succeeded)
        XCTAssertEqual(persisted.steps.map(\.status), [.succeeded, .succeeded])
        XCTAssertEqual(persisted.steps.map(\.attemptCount), [1, 1])
        XCTAssertEqual(
            relaunched.snapshot.savedClips.first(where: { $0.id == source.id })?.tags,
            ["acceptance-reviewed"]
        )
        XCTAssertEqual(relaunched.snapshot.savedClips.filter { $0.kind == .note }.count, 1)
    }
}

@MainActor
private final class ActionFlowTestHotKeyRegistrar: GlobalHotKeyRegistering {
    func register(
        _ descriptor: GlobalHotKeyDescriptor,
        handler: @escaping @MainActor () -> Void
    ) throws {}

    func unregister() {}
}
