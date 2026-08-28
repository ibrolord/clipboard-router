import Foundation
import XCTest
@testable import ClipboardRouterCore

final class SmartViewsAndBulkTests: XCTestCase {
    func testSmartViewValidationUsesTheAuthoritativeMetadataGrammar() throws {
        let query = try ClipSearchQuery.validate("origin:saved tag:lead source:chrome")
        XCTAssertEqual(query.normalized, "origin:saved tag:lead source:chrome")
    }

    func testSmartViewValidationRejectsMalformedBooleanFilter() {
        XCTAssertThrowsError(try ClipSearchQuery.validate("pinned:maybe"))
    }

    func testSmartViewExplanationNamesEveryStructuredFilter() throws {
        let query = try ClipSearchQuery.validate("type:url folder:prospects captures:>=2")
        XCTAssertEqual(query.explanations, ["Type: url", "Folder: prospects", "Capture count filter"])
    }

    func testSmartViewLibraryRejectsCaseInsensitiveDuplicateNames() async throws {
        let library = try await UserSmartViewLibrary.open(persistence: InMemoryUserSmartViewStore())
        _ = try await library.create(name: "Leads", query: "tag:lead")
        await XCTAssertThrowsErrorAsync {
            _ = try await library.create(name: "leads", query: "type:url")
        }
    }

    func testSmartViewLibraryPersistsRenamePinReorderAndDelete() async throws {
        let store = InMemoryUserSmartViewStore()
        let library = try await UserSmartViewLibrary.open(persistence: store)
        let first = try await library.create(name: "One", query: "type:url")
        let second = try await library.create(name: "Two", query: "kind:note")
        try await library.rename(id: first.id, name: "Links")
        try await library.setPinned(id: second.id, pinned: true)
        try await library.reorder(ids: [second.id, first.id])
        try await library.delete(id: first.id)
        let reopened = try await UserSmartViewLibrary.open(persistence: store)
        let names = await reopened.snapshot().map(\.name)
        XCTAssertEqual(names, ["Two"])
    }

    func testBulkPlannerRejectsHistoryForSavedMutationWithoutDroppingEligibleSavedItem() throws {
        let saved = try savedClip(1)
        let history = try historyItem(2)
        let snapshot = ClipboardLibrarySnapshot(history: [history], savedClips: [saved])
        let plan = try BulkLibraryMutationPlanner.plan(
            selections: [
                .init(id: history.id, origin: .history),
                .init(id: saved.id, origin: .saved),
            ],
            snapshot: snapshot,
            operation: .setPinned(true)
        )
        XCTAssertEqual(plan.failures, [.init(id: history.id, reason: .immutableHistory)])
    }

    func testBulkPlannerReportsSensitiveAndViewerFailuresPerItem() throws {
        let sensitive = try SavedClip(
            id: uuid(3),
            name: "Sensitive",
            content: try ClipContent.detect(text: "reviewed secret"),
            createdAt: Date(),
            sensitivity: try ClipSensitivityMetadata(category: "apiKey", confidence: 90, detectorVersion: 1)
        )
        let viewer = try savedClip(4)
        let plan = try BulkLibraryMutationPlanner.plan(
            selections: [
                .init(id: sensitive.id, origin: .saved),
                .init(id: viewer.id, origin: .saved),
            ],
            snapshot: ClipboardLibrarySnapshot(savedClips: [sensitive, viewer]),
            operation: .addTags(["lead"]),
            forbiddenSavedIDs: [viewer.id]
        )
        XCTAssertEqual(Set(plan.failures.map(\.reason)), [.sensitive, .permissionDenied])
    }

    func testBulkSavedMutationCommitsAllEligibleItemsTogether() async throws {
        let first = try savedClip(5)
        let second = try savedClip(6)
        let library = try await ClipboardLibrary.open(
            persistence: InMemoryClipboardLibraryStore(
                snapshot: ClipboardLibrarySnapshot(savedClips: [first, second])
            )
        )
        let plan = try BulkLibraryMutationPlanner.plan(
            selections: [
                .init(id: first.id, origin: .saved),
                .init(id: second.id, origin: .saved),
            ],
            snapshot: await library.snapshot(),
            operation: .addTags(["prospect"])
        )
        _ = try await library.applyBulkMutation(plan)
        let tags = await library.snapshot().savedClips.map { $0.tags ?? [] }
        XCTAssertEqual(tags, [["prospect"], ["prospect"]])
    }

    func testBulkMutationAbortsEveryItemWhenOneSourceChanged() async throws {
        let first = try savedClip(7)
        let second = try savedClip(8)
        let library = try await ClipboardLibrary.open(
            persistence: InMemoryClipboardLibraryStore(
                snapshot: ClipboardLibrarySnapshot(savedClips: [first, second])
            )
        )
        let plan = try BulkLibraryMutationPlanner.plan(
            selections: [
                .init(id: first.id, origin: .saved),
                .init(id: second.id, origin: .saved),
            ],
            snapshot: await library.snapshot(),
            operation: .setPinned(true)
        )
        try await library.renameSavedClip(id: second.id, to: "Changed")
        await XCTAssertThrowsErrorAsync { _ = try await library.applyBulkMutation(plan) }
        let pinnedCount = await library.snapshot().savedClips.filter(\.isPinned).count
        XCTAssertEqual(pinnedCount, 0)
    }

    func testBulkHistorySaveLeavesHistoryRowsUnchanged() async throws {
        let history = try historyItem(9)
        let library = try await ClipboardLibrary.open(
            persistence: InMemoryClipboardLibraryStore(
                snapshot: ClipboardLibrarySnapshot(history: [history])
            )
        )
        let plan = try BulkLibraryMutationPlanner.plan(
            selections: [.init(id: history.id, origin: .history)],
            snapshot: await library.snapshot(),
            operation: .saveHistory(folderID: nil)
        )
        _ = try await library.applyBulkMutation(plan)
        let remainingHistory = await library.snapshot().history
        XCTAssertEqual(remainingHistory, [history])
    }

    func testBulkMutationPersistenceFailureLeavesEveryItemUnchanged() async throws {
        let first = try savedClip(10)
        let second = try savedClip(11)
        let store = BulkFailingStore(
            snapshot: ClipboardLibrarySnapshot(savedClips: [first, second])
        )
        let library = try await ClipboardLibrary.open(persistence: store)
        let plan = try BulkLibraryMutationPlanner.plan(
            selections: [
                .init(id: first.id, origin: .saved),
                .init(id: second.id, origin: .saved),
            ],
            snapshot: await library.snapshot(),
            operation: .setPinned(true)
        )
        await store.setFailing(true)

        await XCTAssertThrowsErrorAsync { _ = try await library.applyBulkMutation(plan) }
        let pinnedCount = await library.snapshot().savedClips.filter(\.isPinned).count

        XCTAssertEqual(pinnedCount, 0)
    }

    private func savedClip(_ value: Int) throws -> SavedClip {
        try SavedClip(
            id: uuid(value),
            name: "Saved \(value)",
            content: try ClipContent.detect(text: "clip \(value)"),
            createdAt: Date(timeIntervalSince1970: TimeInterval(value))
        )
    }

    private func historyItem(_ value: Int) throws -> HistoryItem {
        HistoryItem(
            id: uuid(value),
            content: try ClipContent.detect(text: "history \(value)"),
            createdAt: Date().addingTimeInterval(TimeInterval(-value))
        )
    }

    private func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }
}

private actor BulkFailingStore: ClipboardLibraryPersisting {
    private var snapshot: ClipboardLibrarySnapshot
    private var isFailing = false

    init(snapshot: ClipboardLibrarySnapshot) { self.snapshot = snapshot }
    func load() async throws -> ClipboardLibrarySnapshot { snapshot }
    func save(_ snapshot: ClipboardLibrarySnapshot) async throws {
        if isFailing { throw ClipboardLibraryPersistenceError.unwritableFile(URL(fileURLWithPath: "/tmp/failing"), "expected") }
        self.snapshot = snapshot
    }
    func setFailing(_ value: Bool) { isFailing = value }
}

private extension XCTestCase {
    func XCTAssertThrowsErrorAsync(
        _ expression: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await expression()
            XCTFail("Expected expression to throw", file: file, line: line)
        } catch {
            // Expected.
        }
    }
}
