import ClipboardRouterCore
import ClipboardRouterPlatform
import Combine
import XCTest
@testable import ClipboardRouterApp

@MainActor
final class SmartViewBulkAppTests: XCTestCase {
    func testAccessibilityLibrarySectionSelectionIsDeferredAndRejectsStaleDestination() async {
        let model = makeModel()
        await model.start()
        model.selectLibrarySection(.allSaved)

        model.requestAccessibilityLibrarySectionSelection(.history)

        XCTAssertEqual(model.selectedSection, .allSaved)
        let selected = await waitUntil { model.selectedSection == .history }
        XCTAssertTrue(selected)

        model.requestAccessibilityLibrarySectionSelection(.folder(UUID()))
        try? await Task.sleep(for: .milliseconds(40))

        XCTAssertEqual(model.selectedSection, .history)
    }

    func testWritingCurrentLibrarySelectionDoesNotRepublishListState() async throws {
        let clip = HistoryItem(
            content: try ClipContent.detect(text: "stable selection"),
            createdAt: Date()
        )
        let model = makeModel(snapshot: ClipboardLibrarySnapshot(history: [clip]))
        await model.start()
        model.setSelectedClipIDs([clip.id])

        var changeCount = 0
        let observation = model.objectWillChange.sink { changeCount += 1 }

        model.setSelectedClipIDs([clip.id])

        XCTAssertEqual(changeCount, 0)
        withExtendedLifetime(observation) {}
    }

    func testAccessibilityClipSelectionIsDeferredAndSelectsOnlyAVisibleClip() async throws {
        let first = HistoryItem(
            content: try ClipContent.detect(text: "first selectable clip"),
            createdAt: Date()
        )
        let second = HistoryItem(
            content: try ClipContent.detect(text: "second selectable clip"),
            createdAt: Date().addingTimeInterval(-1)
        )
        let model = makeModel(
            snapshot: ClipboardLibrarySnapshot(history: [first, second])
        )
        await model.start()

        model.requestAccessibilityClipSelection(second.id)

        // The request must not mutate SwiftUI's List binding on the AX callback stack.
        XCTAssertTrue(model.selectedClipIDs.isEmpty)
        XCTAssertNil(model.selectedClipID)

        let selected = await waitUntil { model.selectedClipID == second.id }

        XCTAssertTrue(selected)
        XCTAssertEqual(model.selectedClipIDs, [second.id])
        XCTAssertEqual(model.selectedClipID, second.id)

        model.requestAccessibilityClipSelection(UUID())
        try? await Task.sleep(for: .milliseconds(40))

        XCTAssertEqual(model.selectedClipIDs, [second.id])
        XCTAssertEqual(model.selectedClipID, second.id)
    }

    func testPersistedUserSmartViewAppearsAndUsesOrdinarySearchResults() async throws {
        let saved = try SavedClip(
            name: "Lead",
            content: try ClipContent.detect(text: "northwind prospect"),
            createdAt: Date(),
            tags: ["lead"]
        )
        let view = try UserSmartView(name: "Leads", query: "tag:lead")
        let model = makeModel(
            snapshot: ClipboardLibrarySnapshot(savedClips: [saved]),
            views: [view]
        )
        await model.start()

        model.applySmartView(.user(view.id))
        let loaded = await waitUntil { model.clipsForSelectedSection.map(\.id) == [saved.id] }

        XCTAssertTrue(loaded)
    }

    func testMenuSearchReturnsMatchingSmartViewWithoutPersistingResults() async throws {
        let view = try UserSmartView(name: "Renewal Leads", query: "tag:renewal")
        let model = makeModel(views: [view])
        await model.start()

        model.updateMenuSearch("renewal")

        XCTAssertEqual(model.menuMatchingSmartViews.map(\.id), [.user(view.id)])
    }

    func testMixedBulkPinMutatesSavedAndEnumeratesImmutableHistory() async throws {
        let now = Date()
        let history = HistoryItem(
            content: try ClipContent.detect(text: "bulk candidate"),
            createdAt: now
        )
        let saved = try SavedClip(
            name: "Bulk saved",
            content: try ClipContent.detect(text: "bulk candidate"),
            createdAt: now
        )
        let view = try UserSmartView(name: "Bulk", query: "bulk candidate")
        let model = makeModel(
            snapshot: ClipboardLibrarySnapshot(history: [history], savedClips: [saved]),
            views: [view]
        )
        await model.start()
        model.applySmartView(.user(view.id))
        _ = await waitUntil { model.clipsForSelectedSection.count == 2 }
        model.setSelectedClipIDs([history.id, saved.id])

        model.performBulkLibraryMutation(.setPinned(true))
        let finished = await waitUntil { model.pendingBulkLibraryResult != nil }

        XCTAssertEqual(
            finished ? BulkAppObservation(
                savedPinned: model.snapshot.savedClips.first?.isPinned == true,
                historyUnchanged: model.snapshot.history == [history],
                successCount: model.pendingBulkLibraryResult?.successCount,
                failureReasons: model.pendingBulkLibraryResult?.failures.map(\.reason) ?? []
            ) : nil,
            BulkAppObservation(
                savedPinned: true,
                historyUnchanged: true,
                successCount: 1,
                failureReasons: ["History is immutable. Save it before organizing it."]
            )
        )
    }

    func testBulkSecretLikeSavedItemFailsClosedEvenWithoutStoredSensitivityMetadata() async throws {
        let saved = try SavedClip(
            name: "Token",
            content: try ClipContent.detect(text: "sk-proj-abcdefghijklmnopqrstuvwxyz123456"),
            createdAt: Date()
        )
        let model = makeModel(snapshot: ClipboardLibrarySnapshot(savedClips: [saved]))
        await model.start()
        model.selectLibrarySection(.allSaved)
        model.setSelectedClipIDs([saved.id])

        model.performBulkLibraryMutation(.addTags(["safe"]))
        _ = await waitUntil { model.pendingBulkLibraryResult != nil }

        XCTAssertEqual(
            model.pendingBulkLibraryResult?.failures.map(\.reason),
            ["Sensitive items require individual review."]
        )
    }

    func testDeletingActiveUserSmartViewReturnsToOrdinarySection() async throws {
        let view = try UserSmartView(name: "Temporary", query: "type:url")
        let model = makeModel(views: [view])
        await model.start()
        model.applySmartView(.user(view.id))

        model.deleteUserSmartView(id: view.id)
        let deleted = await waitUntil { model.userSmartViews.isEmpty }

        XCTAssertEqual(deleted ? model.activeSmartViewID : .user(view.id), nil)
    }

    private func makeModel(
        snapshot: ClipboardLibrarySnapshot = .empty,
        views: [UserSmartView] = []
    ) -> AppModel {
        AppModel(
            defaults: UserDefaults(suiteName: "SmartViewBulkAppTests.\(UUID())")!,
            hotKey: SmartViewBulkHotKey(),
            supportDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(
                "SmartViewBulkAppTests-\(UUID())", isDirectory: true
            ),
            libraryPersistence: InMemoryClipboardLibraryStore(snapshot: snapshot),
            userSmartViewStore: InMemoryUserSmartViewStore(views: views)
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}

private struct BulkAppObservation: Equatable {
    let savedPinned: Bool
    let historyUnchanged: Bool
    let successCount: Int?
    let failureReasons: [String]
}

@MainActor
private final class SmartViewBulkHotKey: GlobalHotKeyRegistering {
    func register(_: GlobalHotKeyDescriptor, handler _: @escaping @MainActor () -> Void) throws {}
    func unregister() {}
}
