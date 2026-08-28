import ClipboardRouterCore
import ClipboardRouterPlatform
import XCTest
@testable import ClipboardRouterApp

@MainActor
final class AutomationRunAppTests: XCTestCase {
    func testPendingReviewSurvivesRelaunchWithoutTouchingPasteboard() async throws {
        let saved = try makeSavedClip()
        let flow = try ClipFlow(
            name: "Open CRM",
            steps: [.openWeb(
                id: UUID(),
                template: "https://example.com/search?q={clip}",
                label: "CRM"
            )]
        )
        let store = InMemoryAutomationRunLedgerStore()
        let runID = UUID()
        let plan = try ClipFlowRunPlan(
            id: runID,
            flow: flow,
            clipID: saved.id,
            clipFingerprint: saved.content.deduplicationFingerprint
        )
        let ledger = AutomationRunLedger(persistence: store)
        _ = try await ledger.createRun(
            plan: plan,
            triggerKind: .manual,
            idempotencyKey: "persisted-review",
            requiresReview: true
        )
        let textWriter = RunLedgerTextPasteboardWriter()
        let typedWriter = RunLedgerTypedPasteboardWriter()
        let model = try makeModel(
            flow: flow,
            saved: saved,
            store: store,
            textWriter: textWriter,
            typedWriter: typedWriter
        )

        await model.start()

        XCTAssertEqual(model.pendingFlowReview?.id, runID)
        XCTAssertEqual(model.automationRunSnapshot.runs.first?.status, .needsReview)
        XCTAssertEqual(textWriter.writeCount, 0)
        XCTAssertEqual(typedWriter.writeCount, 0)
    }

    func testChangedFlowFailsRecoveredRunClosed() async throws {
        let saved = try makeSavedClip()
        let flowID = UUID()
        let original = try ClipFlow(
            id: flowID,
            name: "Original",
            steps: [.addTags(id: UUID(), tags: ["original"])]
        )
        let changed = try ClipFlow(
            id: flowID,
            name: "Changed",
            steps: [.addTags(id: UUID(), tags: ["changed"])]
        )
        let store = InMemoryAutomationRunLedgerStore()
        let plan = try ClipFlowRunPlan(
            flow: original,
            clipID: saved.id,
            clipFingerprint: saved.content.deduplicationFingerprint
        )
        let ledger = AutomationRunLedger(persistence: store)
        _ = try await ledger.createRun(
            plan: plan,
            triggerKind: .manual,
            idempotencyKey: "stale-flow",
            requiresReview: true
        )
        let model = try makeModel(flow: changed, saved: saved, store: store)

        await model.start()

        XCTAssertNil(model.pendingFlowReview)
        XCTAssertEqual(model.automationRunSnapshot.runs.first?.status, .failed)
        XCTAssertEqual(model.automationRunSnapshot.runs.first?.failureCode, .staleFlow)
    }

    func testRestoredOrSyncLikeFolderContentsNeverCreateTriggerRuns() async throws {
        let folder = try ClipFolder(name: "Qualified", sortOrder: 0, createdAt: Date())
        let saved = try SavedClip(
            name: "Existing synced item",
            content: ClipContent.detect(text: "person@example.com"),
            folderID: folder.id,
            createdAt: Date()
        )
        let flow = try ClipFlow(
            name: "React only to local entry",
            trigger: .folderEntry(folderID: folder.id, includeDescendants: false),
            entityFilter: .email,
            steps: [.addTags(id: UUID(), tags: ["qualified"])]
        )
        let store = InMemoryAutomationRunLedgerStore()
        let model = try makeModel(
            flow: flow,
            saved: saved,
            folders: [folder],
            store: store
        )

        await model.start()

        XCTAssertTrue(model.automationRunSnapshot.runs.isEmpty)
        XCTAssertNil(model.pendingFlowReview)
    }

    func testCompletedOrganizationReceiptDoesNotReplayAndLeavesPasteboardUntouched() async throws {
        let saved = try makeSavedClip()
        let flow = try ClipFlow(
            name: "Tag once",
            steps: [.addTags(id: UUID(), tags: ["qualified"])]
        )
        let store = InMemoryAutomationRunLedgerStore()
        let textWriter = RunLedgerTextPasteboardWriter()
        let typedWriter = RunLedgerTypedPasteboardWriter()
        let model = try makeModel(
            flow: flow,
            saved: saved,
            store: store,
            textWriter: textWriter,
            typedWriter: typedWriter
        )
        await model.start()
        model.selectLibrarySection(.allSaved)
        let clip = try XCTUnwrap(model.clipsForSelectedSection.first)

        model.requestFlowRun(flow, for: clip)
        let reviewAppeared = await waitUntil { model.pendingFlowReview != nil }
        XCTAssertTrue(reviewAppeared)
        let request = try XCTUnwrap(model.pendingFlowReview)
        let firstExecution = await model.executeFlow(request)
        XCTAssertTrue(firstExecution)
        XCTAssertEqual(model.snapshot.savedClips.first?.tags, ["qualified"])
        XCTAssertEqual(model.automationRunSnapshot.runs.first?.status, .succeeded)
        let afterFirstRun = model.snapshot

        let duplicateExecution = await model.executeFlow(request)
        XCTAssertTrue(duplicateExecution)
        XCTAssertEqual(model.snapshot, afterFirstRun)
        XCTAssertEqual(textWriter.writeCount, 0)
        XCTAssertEqual(typedWriter.writeCount, 0)
    }

    private func makeSavedClip() throws -> SavedClip {
        try SavedClip(
            name: "Account",
            content: ClipContent.detect(text: "person@example.com"),
            createdAt: Date()
        )
    }

    private func makeModel(
        flow: ClipFlow,
        saved: SavedClip,
        folders: [ClipFolder] = [],
        store: any AutomationRunLedgerPersisting,
        textWriter: RunLedgerTextPasteboardWriter = RunLedgerTextPasteboardWriter(),
        typedWriter: RunLedgerTypedPasteboardWriter = RunLedgerTypedPasteboardWriter()
    ) throws -> AppModel {
        let suite = "AutomationRunAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defaults.set(try JSONEncoder().encode([flow]), forKey: "clipFlows.v1")
        return AppModel(
            defaults: defaults,
            pasteboardWriter: textWriter,
            typedPasteboardWriter: typedWriter,
            hotKey: RunLedgerHotKeyRegistrar(),
            supportDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("AutomationRunAppTests-\(UUID().uuidString)"),
            libraryPersistence: InMemoryClipboardLibraryStore(
                snapshot: ClipboardLibrarySnapshot(savedClips: [saved], folders: folders)
            ),
            automationRunStore: store
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

@MainActor
private final class RunLedgerHotKeyRegistrar: GlobalHotKeyRegistering {
    func register(
        _ descriptor: GlobalHotKeyDescriptor,
        handler: @escaping @MainActor () -> Void
    ) throws {}
    func unregister() {}
}

@MainActor
private final class RunLedgerTextPasteboardWriter: PasteboardWriting {
    private(set) var writeCount = 0
    func writeForRouting(_ text: String) -> Bool {
        writeCount += 1
        return true
    }
}

@MainActor
private final class RunLedgerTypedPasteboardWriter: TypedPasteboardWriting {
    private(set) var writeCount = 0
    func write(
        _ content: ClipContent,
        mode: ClipPasteboardWriteMode
    ) async throws {
        writeCount += 1
    }

    func write(
        _ content: ClipContent,
        mode: ClipPasteboardWriteMode,
        sourceTypeIdentifiers: [String]
    ) async throws {
        writeCount += 1
    }
}
