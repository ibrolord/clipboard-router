import AppKit
import ClipboardRouterCore
import ClipboardRouterPlatform
import XCTest
@testable import ClipboardRouterApp

@MainActor
final class DebugBundleReorderTests: XCTestCase {
    func testReorderIdentifiersAreStablePerItem() {
        let id = UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!

        XCTAssertEqual(
            DebugBundleAccessibility.item(id),
            "uiAcceptance.debugBundle.item.01234567-89ab-cdef-0123-456789abcdef"
        )
        XCTAssertEqual(
            DebugBundleAccessibility.moveEarlier(id),
            "uiAcceptance.debugBundle.moveEarlier.01234567-89ab-cdef-0123-456789abcdef"
        )
        XCTAssertEqual(
            DebugBundleAccessibility.moveLater(id),
            "uiAcceptance.debugBundle.moveLater.01234567-89ab-cdef-0123-456789abcdef"
        )
        XCTAssertEqual(Set([
            DebugBundleAccessibility.item(id),
            DebugBundleAccessibility.moveEarlier(id),
            DebugBundleAccessibility.moveLater(id),
        ]).count, 3)
    }

    func testInvalidAndStaleMovesFailClosedWithoutChangingDraftOrReview() async throws {
        let items = try makeHistoryItems()
        let supportDirectory = temporarySupportDirectory()
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        let model = makeModel(
            supportDirectory: supportDirectory,
            libraryPersistence: InMemoryClipboardLibraryStore(
                snapshot: ClipboardLibrarySnapshot(history: items)
            )
        )
        await model.start()
        for item in items {
            model.addToDebugBundle(presentedClip(item))
        }
        model.prepareDebugBundleReview()

        let originalPack = try XCTUnwrap(model.debugBundlePack)
        let originalReview = try XCTUnwrap(model.pendingDebugBundleReview)
        let originalStatus = model.statusMessage
        let originalError = model.errorMessage

        XCTAssertFalse(model.moveDebugBundleItem(itemID: UUID(), offset: 1))
        XCTAssertFalse(model.moveDebugBundleItem(itemID: items[0].id, offset: -1))
        XCTAssertFalse(model.moveDebugBundleItem(itemID: items[2].id, offset: 1))
        XCTAssertFalse(model.moveDebugBundleItem(itemID: items[1].id, offset: 0))
        XCTAssertFalse(model.moveDebugBundleItem(itemID: items[1].id, offset: 2))

        XCTAssertEqual(model.debugBundlePack, originalPack)
        XCTAssertEqual(model.pendingDebugBundleReview, originalReview)
        XCTAssertEqual(model.statusMessage, originalStatus)
        XCTAssertEqual(model.errorMessage, originalError)

        XCTAssertTrue(model.moveDebugBundleItem(itemID: items[1].id, offset: -1))
        XCTAssertEqual(model.debugBundlePack?.items.map(\.id), [
            items[1].id, items[0].id, items[2].id,
        ])
        XCTAssertNil(model.pendingDebugBundleReview)
    }

    func testReorderedDraftFlowsThroughReviewSaveAndReopenedProject() async throws {
        let supportDirectory = temporarySupportDirectory()
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        let project = try DeveloperProject(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
            name: "Compiler",
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let workspaceStore = JSONFileDeveloperWorkspaceStore(
            fileURL: supportDirectory.appendingPathComponent("developer-workspace.json")
        )
        try await workspaceStore.save(try DeveloperWorkspaceSnapshot(
            projects: [project],
            activeProjectID: project.id
        ))

        let items = try makeHistoryItems()
        let libraryStore = InMemoryClipboardLibraryStore(
            snapshot: ClipboardLibrarySnapshot(history: items)
        )
        let model = makeModel(
            supportDirectory: supportDirectory,
            libraryPersistence: libraryStore
        )
        await model.start()
        for item in items {
            model.addToDebugBundle(presentedClip(item))
        }

        XCTAssertTrue(model.moveDebugBundleItem(itemID: items[2].id, offset: -1))
        XCTAssertTrue(model.moveDebugBundleItem(itemID: items[2].id, offset: -1))
        let expectedIDs = [items[2].id, items[0].id, items[1].id]
        XCTAssertEqual(model.debugBundlePack?.items.map(\.id), expectedIDs)

        model.prepareDebugBundleReview()
        let request = try XCTUnwrap(model.pendingDebugBundleReview)
        let review = try XCTUnwrap(model.debugBundleReview(
            for: request,
            projectDisplayName: project.name,
            problemStatement: "Why does the compiler fail?"
        ))
        XCTAssertEqual(review.bundle.items.map(\.id), expectedIDs)
        assertMarkdownOrder(
            review.markdown,
            titles: [items[2].content.text, items[0].content.text, items[1].content.text]
        )

        let didPersist = await model.persistDebugBundle(
            request,
            projectID: project.id,
            projectDisplayName: project.name,
            problemStatement: "Why does the compiler fail?"
        )
        XCTAssertTrue(didPersist)
        let saved = try XCTUnwrap(model.developerWorkspaceSnapshot.debugBundles.first)
        XCTAssertEqual(saved.bundle.items.map(\.id), expectedIDs)

        let reopenedModel = makeModel(
            supportDirectory: supportDirectory,
            libraryPersistence: libraryStore
        )
        await reopenedModel.start()
        let reopened = try XCTUnwrap(
            reopenedModel.developerWorkspaceSnapshot.debugBundles.first(where: {
                $0.id == saved.id
            })
        )
        XCTAssertEqual(reopened.bundle.items.map(\.id), expectedIDs)
        XCTAssertEqual(
            try DebugBundleRenderer().renderMarkdown(reopened.bundle),
            review.markdown
        )
    }

    private func makeHistoryItems() throws -> [HistoryItem] {
        let now = Date()
        return try [
            ("10000000-0000-0000-0000-000000000001", "alpha source"),
            ("10000000-0000-0000-0000-000000000002", "beta error: failed"),
            ("10000000-0000-0000-0000-000000000003", "gamma log entry"),
        ].enumerated().map { offset, fixture in
            HistoryItem(
                id: UUID(uuidString: fixture.0)!,
                content: try ClipContent.detect(text: fixture.1),
                createdAt: now.addingTimeInterval(TimeInterval(offset - 3))
            )
        }
    }

    private func presentedClip(_ item: HistoryItem) -> PresentedClip {
        PresentedClip(
            id: item.id,
            title: item.content.text,
            content: item.content,
            date: item.createdAt,
            sourceBundleIdentifier: item.sourceApplicationBundleIdentifier,
            origin: .history,
            captureContext: item.captureContext,
            sensitivity: item.sensitivity,
            pasteboardTypeIdentifiers: item.pasteboardTypeIdentifiers ?? []
        )
    }

    private func makeModel(
        supportDirectory: URL,
        libraryPersistence: any ClipboardLibraryPersisting
    ) -> AppModel {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("DebugBundleReorderTests.\(UUID().uuidString)")
        )
        return AppModel(
            defaults: UserDefaults(suiteName: "DebugBundleReorderTests.\(UUID())")!,
            pasteboardReader: SystemPasteboardReader(pasteboard: pasteboard),
            hotKey: DebugBundleReorderNoopHotKeyRegistrar(),
            supportDirectory: supportDirectory,
            libraryPersistence: libraryPersistence
        )
    }

    private func temporarySupportDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("DebugBundleReorderTests-\(UUID())", isDirectory: true)
    }

    private func assertMarkdownOrder(
        _ markdown: String,
        titles: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let offsets = titles.compactMap { title -> Int? in
            markdown.range(of: title).map {
                markdown.distance(from: markdown.startIndex, to: $0.lowerBound)
            }
        }
        XCTAssertEqual(offsets.count, titles.count, file: file, line: line)
        XCTAssertEqual(offsets, offsets.sorted(), file: file, line: line)
    }
}

@MainActor
private final class DebugBundleReorderNoopHotKeyRegistrar: GlobalHotKeyRegistering {
    func register(
        _: GlobalHotKeyDescriptor,
        handler _: @escaping @MainActor () -> Void
    ) throws {}

    func unregister() {}
}
