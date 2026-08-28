import Foundation
import XCTest
@testable import ClipboardRouterCore

final class NotesAndHierarchyTests: XCTestCase {
    func testLegacyV2SavedClipAndFolderDecodeAsClipAtRootInSchemaV3() throws {
        let date = Date(timeIntervalSince1970: 100)
        let folder = try ClipFolder(name: "Legacy", sortOrder: 0, createdAt: date)
        let clip = try SavedClip(
            name: "Legacy clip",
            content: try ClipContent.detect(text: "legacy body"),
            folderID: folder.id,
            createdAt: date
        )
        let encoded = try JSONEncoder().encode(
            ClipboardLibrarySnapshot(schemaVersion: 2, savedClips: [clip], folders: [folder])
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["schemaVersion"] = 2
        var saved = try XCTUnwrap(object["savedClips"] as? [[String: Any]])
        saved[0].removeValue(forKey: "kind")
        saved[0].removeValue(forKey: "derivedFromHistoryItemID")
        object["savedClips"] = saved
        var folders = try XCTUnwrap(object["folders"] as? [[String: Any]])
        folders[0].removeValue(forKey: "parentFolderID")
        object["folders"] = folders

        let decoded = try JSONDecoder().decode(
            ClipboardLibrarySnapshot.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(decoded.schemaVersion, 3)
        XCTAssertEqual(decoded.savedClips.first?.kind, .clip)
        XCTAssertNil(decoded.savedClips.first?.derivedFromHistoryItemID)
        XCTAssertNil(decoded.folders.first?.parentFolderID)
    }

    func testCreateUpdateAndPinNotePersistAtomically() async throws {
        let library = try ClipboardLibrary()
        let folder = try await library.createFolder(name: "Notes")
        let note = try await library.createNote(
            title: "Launch plan",
            body: "First draft",
            folderID: folder.id,
            pinned: true,
            at: Date(timeIntervalSince1970: 10)
        )
        XCTAssertEqual(note.kind, .note)
        XCTAssertEqual(note.folderID, folder.id)
        XCTAssertTrue(note.isPinned)

        let updated = try await library.updateNote(
            id: note.id,
            title: "Launch checklist",
            body: "Ship on Friday",
            at: Date(timeIntervalSince1970: 20)
        )
        XCTAssertEqual(updated.content.text, "Ship on Friday")
        XCTAssertEqual(updated.name, "Launch checklist")
        XCTAssertEqual(updated.folderID, folder.id)
        XCTAssertTrue(updated.isPinned)

        let results = await library.search(query: "friday kind:note", limit: 10)
        XCTAssertEqual(results.map(\.id), [note.id])
    }

    func testAtomicNoteEditUpdatesTitleBodyAndFolderWithOneJournalEntry() async throws {
        let library = try ClipboardLibrary()
        let first = try await library.createFolder(name: "First")
        let second = try await library.createFolder(name: "Second")
        let note = try await library.createNote(
            title: "Draft",
            body: "old body",
            folderID: first.id
        )

        let updated = try await library.updateNote(
            id: note.id,
            title: "Final",
            body: "new body",
            folderID: second.id,
            at: Date(timeIntervalSince1970: 50)
        )
        let snapshot = await library.snapshot()

        XCTAssertEqual(updated.name, "Final")
        XCTAssertEqual(updated.content.text, "new body")
        XCTAssertEqual(updated.folderID, second.id)
        XCTAssertEqual(
            snapshot.pendingSavedLibraryMutations.filter {
                $0.kind == .savedClip && $0.id == note.id
            }.count,
            1
        )

        let beforeInvalidDestination = snapshot
        await XCTAssertThrowsErrorAsync {
            _ = try await library.updateNote(
                id: note.id,
                title: "Should not publish",
                body: "changed",
                folderID: UUID()
            )
        } validate: { error in
            guard case .folderNotFound = error as? ClipboardLibraryError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let afterInvalidDestination = await library.snapshot()
        XCTAssertEqual(afterInvalidDestination, beforeInvalidDestination)
    }

    func testHistoryConversionIsNonDestructiveAndUsesDerivedProvenance() async throws {
        let history = HistoryItem(
            content: try ClipContent.detect(text: "turn this into a note"),
            createdAt: Date(timeIntervalSince1970: 1),
            sourceApplicationBundleIdentifier: "com.example.Source"
        )
        let library = try ClipboardLibrary(snapshot: ClipboardLibrarySnapshot(history: [history]))

        let note = try await library.convertHistoryItemToNote(
            id: history.id,
            title: "Derived note",
            pinned: true,
            at: Date(timeIntervalSince1970: 2)
        )
        let snapshot = await library.snapshot()

        XCTAssertEqual(snapshot.history, [history])
        XCTAssertEqual(note.kind, .note)
        XCTAssertNil(note.sourceHistoryItemID)
        XCTAssertEqual(note.derivedFromHistoryItemID, history.id)
        XCTAssertEqual(note.sourceApplicationBundleIdentifier, "com.example.Source")
    }

    func testSavedClipConversionPreservesIdentityFolderPinAndProvenance() async throws {
        let historyID = UUID()
        let folder = try ClipFolder(name: "Research", sortOrder: 0, createdAt: .distantPast)
        let saved = try SavedClip(
            name: "Original",
            content: try ClipContent.detect(text: "editable source"),
            folderID: folder.id,
            sourceHistoryItemID: historyID,
            createdAt: .distantPast,
            pinnedAt: .distantPast
        )
        let library = try ClipboardLibrary(snapshot: ClipboardLibrarySnapshot(
            savedClips: [saved],
            folders: [folder]
        ))

        let note = try await library.convertSavedClipToNote(id: saved.id, title: "Working note")

        XCTAssertEqual(note.id, saved.id)
        XCTAssertEqual(note.kind, .note)
        XCTAssertEqual(note.folderID, folder.id)
        XCTAssertEqual(note.pinnedAt, saved.pinnedAt)
        XCTAssertEqual(note.sourceHistoryItemID, historyID)
        XCTAssertEqual(note.derivedFromHistoryItemID, historyID)
        XCTAssertEqual(note.content, saved.content)
    }

    func testClipEditingPreservesHistoryAndSavedMetadataWithoutFlatteningRichContent() async throws {
        let history = HistoryItem(
            content: try ClipContent.detect(text: "https://example.com/original"),
            createdAt: Date(timeIntervalSince1970: 1),
            sourceApplicationBundleIdentifier: "com.example.browser"
        )
        let savedHistoryID = UUID()
        let saved = try SavedClip(
            name: "Pinned draft",
            content: try ClipContent.detect(text: "old body"),
            sourceHistoryItemID: savedHistoryID,
            createdAt: Date(timeIntervalSince1970: 2),
            pinnedAt: Date(timeIntervalSince1970: 3),
            sourceApplicationBundleIdentifier: "com.example.editor"
        )
        let rich = try SavedClip(
            name: "Rich source",
            content: ClipContent(type: .richText, text: "styled body"),
            createdAt: Date(timeIntervalSince1970: 4)
        )
        let library = try ClipboardLibrary(snapshot: ClipboardLibrarySnapshot(
            history: [history], savedClips: [saved, rich]
        ))

        let derived = try await library.createEditedCopyFromHistory(
            id: history.id,
            title: "Edited link",
            body: "https://example.org/changed",
            at: Date(timeIntervalSince1970: 5)
        )
        let snapshotAfterHistoryEdit = await library.snapshot()
        XCTAssertEqual(snapshotAfterHistoryEdit.history, [history])
        XCTAssertEqual(derived.kind, .clip)
        XCTAssertNil(derived.sourceHistoryItemID)
        XCTAssertEqual(derived.derivedFromHistoryItemID, history.id)
        XCTAssertEqual(derived.content.type, .url)
        XCTAssertEqual(derived.content.representations.url?.host, "example.org")
        XCTAssertEqual(derived.sourceApplicationBundleIdentifier, "com.example.browser")

        let updated = try await library.updateSavedClipContent(
            id: saved.id,
            title: "Updated draft",
            body: "new body",
            folderID: nil,
            at: Date(timeIntervalSince1970: 6)
        )
        XCTAssertEqual(updated.id, saved.id)
        XCTAssertEqual(updated.kind, .clip)
        XCTAssertEqual(updated.pinnedAt, saved.pinnedAt)
        XCTAssertEqual(updated.sourceApplicationBundleIdentifier, "com.example.editor")
        XCTAssertEqual(updated.content.text, "new body")
        XCTAssertEqual(updated.derivedFromHistoryItemID, savedHistoryID)

        let beforeRejectedEdit = await library.snapshot()
        await XCTAssertThrowsErrorAsync {
            _ = try await library.updateSavedClipContent(
                id: rich.id,
                title: "Flattened",
                body: "plain fallback",
                folderID: nil
            )
        } validate: { error in
            guard case .unsupportedClipEditing = error as? ClipboardLibraryError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let afterRejectedEdit = await library.snapshot()
        XCTAssertEqual(afterRejectedEdit, beforeRejectedEdit)

        let richCopy = try await library.createEditedCopyFromSavedClip(
            id: rich.id,
            title: "Editable rich copy",
            body: "plain reviewed body",
            folderID: nil,
            at: Date(timeIntervalSince1970: 7)
        )
        let afterRichCopy = await library.snapshot()
        XCTAssertEqual(afterRichCopy.savedClips.first(where: { $0.id == rich.id }), rich)
        XCTAssertNotEqual(richCopy.id, rich.id)
        XCTAssertEqual(richCopy.content.type, .plainText)
        XCTAssertEqual(richCopy.content.text, "plain reviewed body")
    }

    func testClipAndNoteEditorsRejectStaleOptimisticConcurrencyTokens() async throws {
        let originalDate = Date(timeIntervalSince1970: 10)
        let clip = try SavedClip(
            name: "Clip",
            content: ClipContent(type: .plainText, text: "clip v1"),
            createdAt: originalDate
        )
        let note = try SavedClip(
            kind: .note,
            name: "Note",
            content: ClipContent(type: .plainText, text: "note v1"),
            createdAt: originalDate
        )
        let library = try ClipboardLibrary(snapshot: ClipboardLibrarySnapshot(
            savedClips: [clip, note]
        ))
        let clipExpectation = SavedClipEditExpectation(
            name: clip.name,
            modifiedAt: clip.modifiedAt,
            folderID: clip.folderID,
            contentFingerprint: clip.content.deduplicationFingerprint
        )
        let noteExpectation = SavedClipEditExpectation(
            name: note.name,
            modifiedAt: note.modifiedAt,
            folderID: note.folderID,
            contentFingerprint: note.content.deduplicationFingerprint
        )

        _ = try await library.renameSavedClip(
            id: clip.id,
            to: "Renamed elsewhere",
            at: originalDate
        )
        _ = try await library.updateNote(
            id: note.id,
            title: "Note v2",
            body: "note v2",
            folderID: nil,
            at: Date(timeIntervalSince1970: 20)
        )
        let current = await library.snapshot()

        await XCTAssertThrowsErrorAsync {
            _ = try await library.updateSavedClipContent(
                id: clip.id,
                title: "Stale clip",
                body: "stale clip",
                folderID: nil,
                expecting: clipExpectation
            )
        } validate: { error in
            guard case .savedItemChangedDuringEdit = error as? ClipboardLibraryError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        await XCTAssertThrowsErrorAsync {
            _ = try await library.updateNote(
                id: note.id,
                title: "Stale note",
                body: "stale note",
                folderID: nil,
                expecting: noteExpectation
            )
        } validate: { error in
            guard case .savedItemChangedDuringEdit = error as? ClipboardLibraryError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let afterRejectedStaleEdits = await library.snapshot()
        XCTAssertEqual(afterRejectedStaleEdits, current)
    }

    func testTypedOrAssetBackedContentCannotConvertToNoteAndDoesNotMutate() async throws {
        let asset = try ClipAssetReference(
            digest: String(repeating: "a", count: 64),
            kind: .image,
            uniformTypeIdentifier: "public.png",
            byteCount: 10,
            relativePath: String(repeating: "a", count: 64)
        )
        let assetBackedText = try ClipContent(
            type: .plainText,
            text: "fallback must not lose image",
            representations: ClipRepresentations(image: asset)
        )
        let imageHistory = HistoryItem(content: assetBackedText, createdAt: .distantPast)
        let richSaved = try SavedClip(
            name: "Rich",
            content: try ClipContent(type: .richText, text: "rich fallback"),
            createdAt: .distantPast
        )
        let library = try ClipboardLibrary(snapshot: ClipboardLibrarySnapshot(
            history: [imageHistory],
            savedClips: [richSaved]
        ))
        let before = await library.snapshot()

        await XCTAssertThrowsErrorAsync {
            _ = try await library.convertHistoryItemToNote(id: imageHistory.id)
        } validate: { error in
            XCTAssertEqual(
                error as? ClipboardLibraryError,
                .unsupportedNoteConversion(imageHistory.id)
            )
        }
        await XCTAssertThrowsErrorAsync {
            _ = try await library.convertSavedClipToNote(id: richSaved.id)
        } validate: { error in
            XCTAssertEqual(
                error as? ClipboardLibraryError,
                .unsupportedNoteConversion(richSaved.id)
            )
        }
        let after = await library.snapshot()
        XCTAssertEqual(after, before)
        XCTAssertFalse(assetBackedText.isSafelyConvertibleToNote)
        XCTAssertFalse(richSaved.content.isSafelyConvertibleToNote)
        XCTAssertTrue(try ClipContent.detect(text: "Markdown **note**").isSafelyConvertibleToNote)
        XCTAssertTrue(try ClipContent.detect(text: "https://example.com").isSafelyConvertibleToNote)
    }

    func testNestedFoldersAllowSameNameAcrossBranchesAndRejectSiblingDuplicate() async throws {
        let library = try ClipboardLibrary()
        let work = try await library.createFolder(name: "Work")
        let personal = try await library.createFolder(name: "Personal")
        let workArchive = try await library.createFolder(name: "Archive", parentFolderID: work.id)
        let personalArchive = try await library.createFolder(
            name: "Archive",
            parentFolderID: personal.id
        )
        XCTAssertEqual(workArchive.parentFolderID, work.id)
        XCTAssertEqual(personalArchive.parentFolderID, personal.id)

        await XCTAssertThrowsErrorAsync {
            _ = try await library.createFolder(name: "archive", parentFolderID: work.id)
        } validate: { error in
            XCTAssertEqual(error as? ClipboardLibraryError, .duplicateFolderName("archive"))
        }
    }

    func testMoveFolderRejectsSelfAndDescendantWithoutPublishing() async throws {
        let library = try ClipboardLibrary()
        let root = try await library.createFolder(name: "Root")
        let child = try await library.createFolder(name: "Child", parentFolderID: root.id)
        let grandchild = try await library.createFolder(name: "Grandchild", parentFolderID: child.id)
        let before = await library.snapshot()

        await XCTAssertThrowsErrorAsync {
            try await library.moveFolder(id: root.id, to: root.id)
        } validate: { error in
            XCTAssertEqual(error as? ClipboardLibraryError, .folderCycle(root.id))
        }
        await XCTAssertThrowsErrorAsync {
            try await library.moveFolder(id: root.id, to: grandchild.id)
        } validate: { error in
            XCTAssertEqual(error as? ClipboardLibraryError, .folderCycle(root.id))
        }
        let afterRejectedMoves = await library.snapshot()
        XCTAssertEqual(afterRejectedMoves, before)
    }

    func testDeleteFolderPromotesDirectChildrenAndUnfilesOnlyDirectItems() async throws {
        let library = try ClipboardLibrary()
        let root = try await library.createFolder(name: "Root")
        let deleted = try await library.createFolder(name: "Delete me", parentFolderID: root.id)
        let child = try await library.createFolder(name: "Child", parentFolderID: deleted.id)
        let grandchild = try await library.createFolder(name: "Grandchild", parentFolderID: child.id)
        let direct = try await library.createNote(
            title: "Direct",
            body: "direct",
            folderID: deleted.id
        )
        let nested = try await library.createNote(
            title: "Nested",
            body: "nested",
            folderID: child.id
        )

        try await library.deleteFolder(id: deleted.id)
        let snapshot = await library.snapshot()

        XCTAssertEqual(snapshot.folders.first(where: { $0.id == child.id })?.parentFolderID, root.id)
        XCTAssertEqual(snapshot.folders.first(where: { $0.id == grandchild.id })?.parentFolderID, child.id)
        XCTAssertNil(snapshot.savedClips.first(where: { $0.id == direct.id })?.folderID)
        XCTAssertEqual(snapshot.savedClips.first(where: { $0.id == nested.id })?.folderID, child.id)
    }

    func testFolderOrderingIsScopedToSiblingsAndAncestorPathIsSearchable() async throws {
        let library = try ClipboardLibrary()
        let rootA = try await library.createFolder(name: "Clients")
        let rootB = try await library.createFolder(name: "Personal")
        let childA = try await library.createFolder(name: "Acme", parentFolderID: rootA.id)
        let childB = try await library.createFolder(name: "Beacon", parentFolderID: rootA.id)
        let note = try await library.createNote(
            title: "Decision log",
            body: "approved rollout",
            folderID: childB.id
        )

        try await library.reorderFolder(id: childB.id, to: 0)
        let snapshot = await library.snapshot()
        let roots = snapshot.folders
            .filter { $0.parentFolderID == nil }
            .sorted { $0.sortOrder < $1.sortOrder }
        let children = snapshot.folders
            .filter { $0.parentFolderID == rootA.id }
            .sorted { $0.sortOrder < $1.sortOrder }
        XCTAssertEqual(roots.map(\.id), [rootA.id, rootB.id])
        XCTAssertEqual(children.map(\.id), [childB.id, childA.id])
        XCTAssertEqual(roots.map(\.sortOrder), [0, 1])
        XCTAssertEqual(children.map(\.sortOrder), [0, 1])

        let byAncestorPath = await library.search(query: "folderpath:clients", limit: 10)
        XCTAssertEqual(byAncestorPath.map(\.id), [note.id])
    }

    func testNoteMutationFailureRollsBackItemAndJournal() async throws {
        let before = ClipboardLibrarySnapshot.empty
        let store = RejectingNoteStore(snapshot: before)
        let library = try ClipboardLibrary(snapshot: before, persistence: store)

        await XCTAssertThrowsErrorAsync {
            _ = try await library.createNote(title: "Nope", body: "not persisted")
        } validate: { error in
            XCTAssertEqual(error as? RejectingNoteStore.Failure, .intentional)
        }
        let afterFailure = await library.snapshot()
        XCTAssertEqual(afterFailure, before)
    }
}

private actor RejectingNoteStore: ClipboardLibraryPersisting {
    enum Failure: Error, Equatable { case intentional }
    private let snapshot: ClipboardLibrarySnapshot

    init(snapshot: ClipboardLibrarySnapshot) { self.snapshot = snapshot }
    func load() async throws -> ClipboardLibrarySnapshot { snapshot }
    func save(_: ClipboardLibrarySnapshot) async throws { throw Failure.intentional }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    validate: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {
        validate(error)
    }
}
