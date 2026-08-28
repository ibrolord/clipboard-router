import Foundation
import XCTest
@testable import ClipboardRouterCore

final class ClipboardLibraryTests: XCTestCase {
    func testPinHistoryItemAtomicallyCreatesPinnedSavedClipWithProvenance() async throws {
        let capturedAt = Date(timeIntervalSince1970: 500)
        let pinDate = Date(timeIntervalSince1970: 600)
        let history = HistoryItem(
            content: try ClipContent.detect(text: "pin from menu bar"),
            createdAt: capturedAt,
            sourceApplicationBundleIdentifier: "com.example.editor",
            originatingDeviceIdentifier: "device-1",
            pasteboardTypeIdentifiers: ["public.utf8-plain-text"]
        )
        let library = try ClipboardLibrary(
            snapshot: ClipboardLibrarySnapshot(history: [history])
        )

        let pinned = try await library.pinHistoryItem(id: history.id, at: pinDate)

        let snapshot = await library.snapshot()
        XCTAssertEqual(snapshot.savedClips, [pinned])
        XCTAssertEqual(pinned.pinnedAt, pinDate)
        XCTAssertEqual(pinned.modifiedAt, pinDate)
        XCTAssertEqual(pinned.sourceHistoryItemID, history.id)
        XCTAssertEqual(pinned.sourceApplicationBundleIdentifier, "com.example.editor")
        XCTAssertEqual(pinned.originatingDeviceIdentifier, "device-1")
        XCTAssertEqual(pinned.originallyCapturedAt, capturedAt)
        XCTAssertEqual(pinned.pasteboardTypeIdentifiers, ["public.utf8-plain-text"])
        XCTAssertEqual(snapshot.pendingSavedLibraryMutations.count, 1)
        XCTAssertFalse(try XCTUnwrap(snapshot.pendingSavedLibraryMutations.first).isDeletion)

        let repeated = try await library.pinHistoryItem(
            id: history.id,
            at: pinDate.addingTimeInterval(10)
        )
        let afterRepeatedPin = await library.snapshot()
        XCTAssertEqual(repeated.id, pinned.id)
        XCTAssertEqual(afterRepeatedPin.savedClips.count, 1)
    }

    func testPinHistoryPersistenceFailureLeavesNoSavedOrJournalState() async throws {
        let history = HistoryItem(
            content: try ClipContent.detect(text: "atomic failure"),
            createdAt: Date(timeIntervalSince1970: 700)
        )
        let before = ClipboardLibrarySnapshot(history: [history])
        let library = try ClipboardLibrary(
            snapshot: before,
            persistence: RejectingCompoundSaveStore(snapshot: before)
        )

        do {
            _ = try await library.pinHistoryItem(id: history.id)
            XCTFail("Expected persistence failure")
        } catch {
            XCTAssertEqual(error as? CompoundSaveStoreError, .intentionalFailure)
        }

        let after = await library.snapshot()
        XCTAssertEqual(after, before)
    }

    func testPinHistoryReusesAnExistingLinkedSavedClip() async throws {
        let date = Date(timeIntervalSince1970: 750)
        let history = HistoryItem(
            content: try ClipContent.detect(text: "already organized"),
            createdAt: date
        )
        let existing = try SavedClip(
            name: "Custom organized name",
            content: history.content,
            sourceHistoryItemID: history.id,
            createdAt: date
        )
        let library = try ClipboardLibrary(snapshot: ClipboardLibrarySnapshot(
            history: [history],
            savedClips: [existing]
        ))

        let pinned = try await library.pinHistoryItem(
            id: history.id,
            at: date.addingTimeInterval(1)
        )

        let snapshot = await library.snapshot()
        XCTAssertEqual(pinned.id, existing.id)
        XCTAssertEqual(pinned.name, existing.name)
        XCTAssertTrue(pinned.isPinned)
        XCTAssertEqual(snapshot.savedClips.count, 1)
    }

    func testPinHistoryCreatesLocalCopyInsteadOfMutatingForbiddenLinkedClip() async throws {
        let date = Date(timeIntervalSince1970: 775)
        let history = HistoryItem(
            content: try ClipContent.detect(text: "shared read only"),
            createdAt: date
        )
        let sharedFolder = try ClipFolder(
            name: "Read Only Shared",
            sortOrder: 0,
            createdAt: date
        )
        let readOnly = try SavedClip(
            name: "Collaborator copy",
            content: history.content,
            folderID: sharedFolder.id,
            sourceHistoryItemID: history.id,
            createdAt: date
        )
        let library = try ClipboardLibrary(snapshot: ClipboardLibrarySnapshot(
            history: [history],
            savedClips: [readOnly],
            folders: [sharedFolder]
        ))

        let pinned = try await library.pinHistoryItem(
            id: history.id,
            reusableSavedClips: [],
            forbiddenFolderIDs: [sharedFolder.id],
            at: date.addingTimeInterval(1)
        )

        let snapshot = await library.snapshot()
        XCTAssertNotEqual(pinned.id, readOnly.id)
        XCTAssertNil(pinned.folderID)
        XCTAssertTrue(pinned.isPinned)
        XCTAssertFalse(try XCTUnwrap(snapshot.savedClips.first(where: {
            $0.id == readOnly.id
        })).isPinned)
        XCTAssertEqual(snapshot.savedClips.count, 2)
    }

    func testVaultMoveCleanupAtomicallyRemovesHistoryAndAllLinkedSavedCopies() async throws {
        let date = Date(timeIntervalSince1970: 800)
        let history = HistoryItem(
            content: try ClipContent.detect(text: "linked source"),
            createdAt: date
        )
        let first = try SavedClip(
            name: "First",
            content: history.content,
            sourceHistoryItemID: history.id,
            createdAt: date
        )
        let second = try SavedClip(
            name: "Second",
            content: history.content,
            sourceHistoryItemID: history.id,
            createdAt: date
        )
        let unrelated = try SavedClip(
            name: "Unrelated",
            content: try ClipContent.detect(text: "keep"),
            createdAt: date
        )
        let library = try ClipboardLibrary(snapshot: ClipboardLibrarySnapshot(
            history: [history],
            savedClips: [first, second, unrelated]
        ))

        let removed = try await library.deleteOrdinaryCopiesForVaultMove(
            expectedHistoryItem: history,
            expectedSavedClips: [first, second],
            forbiddenFolderIDs: [],
            at: date.addingTimeInterval(1)
        )

        let snapshot = await library.snapshot()
        XCTAssertEqual(Set(removed), [first.id, second.id])
        XCTAssertTrue(snapshot.history.isEmpty)
        XCTAssertEqual(snapshot.savedClips.map(\.id), [unrelated.id])
        XCTAssertEqual(
            Set(snapshot.pendingSavedLibraryMutations.filter(\.isDeletion).map(\.id)),
            [first.id, second.id]
        )
    }

    func testVaultCleanupFailsAtomicallyWhenLinkedClipMovesAfterEncryption() async throws {
        let date = Date(timeIntervalSince1970: 900)
        let history = HistoryItem(
            content: try ClipContent.detect(text: "race source"),
            createdAt: date
        )
        let sharedFolder = try ClipFolder(
            name: "Collaborative",
            sortOrder: 0,
            createdAt: date
        )
        let saved = try SavedClip(
            name: "Race target",
            content: history.content,
            sourceHistoryItemID: history.id,
            createdAt: date
        )
        let library = try ClipboardLibrary(snapshot: ClipboardLibrarySnapshot(
            history: [history],
            savedClips: [saved],
            folders: [sharedFolder]
        ))
        let encryptedExpectation = saved

        try await library.moveSavedClip(
            id: saved.id,
            to: sharedFolder.id,
            at: date.addingTimeInterval(1)
        )
        do {
            _ = try await library.deleteOrdinaryCopiesForVaultMove(
                expectedHistoryItem: history,
                expectedSavedClips: [encryptedExpectation],
                forbiddenFolderIDs: [sharedFolder.id]
            )
            XCTFail("Expected changed-source failure")
        } catch {
            XCTAssertEqual(
                error as? ClipboardLibraryError,
                .ordinaryVaultMoveSourceChanged(saved.id)
            )
        }

        let snapshot = await library.snapshot()
        XCTAssertEqual(snapshot.history.map(\.id), [history.id])
        XCTAssertEqual(snapshot.savedClips.map(\.id), [saved.id])
        XCTAssertEqual(snapshot.savedClips.first?.folderID, sharedFolder.id)
        XCTAssertFalse(snapshot.pendingSavedLibraryMutations.contains(where: \.isDeletion))
    }

    func testVaultCleanupFailsWhenNewLinkedSavedCopyAppearsAfterManifest() async throws {
        let date = Date(timeIntervalSince1970: 950)
        let history = HistoryItem(
            content: try ClipContent.detect(text: "manifest expansion"),
            createdAt: date
        )
        let expected = try SavedClip(
            name: "Confirmed copy",
            content: history.content,
            sourceHistoryItemID: history.id,
            createdAt: date
        )
        let library = try ClipboardLibrary(snapshot: ClipboardLibrarySnapshot(
            history: [history],
            savedClips: [expected]
        ))
        let added = try await library.saveHistoryItem(
            id: history.id,
            name: "Added after confirmation",
            at: date.addingTimeInterval(1)
        )

        do {
            _ = try await library.deleteOrdinaryCopiesForVaultMove(
                expectedHistoryItem: history,
                expectedSavedClips: [expected],
                forbiddenFolderIDs: [],
                completeLinkedHistoryItemID: history.id,
                expectedCompleteLinkedSavedClipIDs: [expected.id]
            )
            XCTFail("Expected complete-scope failure")
        } catch {
            XCTAssertEqual(
                error as? ClipboardLibraryError,
                .ordinaryVaultMoveScopeChanged(history.id)
            )
        }

        let snapshot = await library.snapshot()
        XCTAssertEqual(snapshot.history.map(\.id), [history.id])
        XCTAssertEqual(Set(snapshot.savedClips.map(\.id)), [expected.id, added.id])
        XCTAssertFalse(snapshot.pendingSavedLibraryMutations.contains(where: \.isDeletion))
    }

    func testSavingHistoryPreservesOriginalProvenanceMetadata() async throws {
        let library = try ClipboardLibrary()
        // Keep this provenance fixture away from a UTC/local-calendar day boundary. Date search
        // intentionally follows the user's local calendar; this test is about metadata retention.
        let capturedAt = Date(timeIntervalSince1970: 43_200)
        let context = ClipCaptureContext(
            sourceApplicationName: "Safari",
            sourceURL: "https://example.com/research",
            sourceDomain: "example.com",
            deviceLabel: "Work Mac",
            operatingSystem: "macOS"
        )
        let sensitivity = try ClipSensitivityMetadata(
            category: "openAIAPIKey",
            confidence: 100,
            detectorVersion: 1
        )
        let outcome = try await library.capture(
            CaptureCandidate(
                content: try ClipContent.detect(text: "research note"),
                sourceApplicationBundleIdentifier: "com.apple.Safari",
                originatingDeviceIdentifier: "device-a",
                captureContext: context,
                sensitivity: sensitivity,
                pasteboardTypeIdentifiers: ["public.html", "public.utf8-plain-text"],
                capturedAt: capturedAt
            )
        )
        guard case let .inserted(history) = outcome else {
            return XCTFail("Expected inserted history")
        }

        let saved = try await library.saveHistoryItem(
            id: history.id,
            at: capturedAt.addingTimeInterval(10)
        )

        XCTAssertEqual(saved.sourceApplicationBundleIdentifier, "com.apple.Safari")
        XCTAssertEqual(saved.originatingDeviceIdentifier, "device-a")
        XCTAssertEqual(saved.captureContext, context)
        XCTAssertEqual(saved.originallyCapturedAt, capturedAt)
        XCTAssertEqual(saved.sensitivity, sensitivity)
        XCTAssertEqual(
            saved.pasteboardTypeIdentifiers,
            ["public.html", "public.utf8-plain-text"]
        )

        let bySource = await library.search(query: "source:safari", limit: 10)
        XCTAssertTrue(bySource.contains { $0.id == saved.id })
        let dateToken = ClipSearchIndex.dateToken(capturedAt)
        let byDate = await library.search(query: "date:\(dateToken)", limit: 10)
        XCTAssertTrue(byDate.contains { $0.id == saved.id })
        let bySensitivity = await library.search(query: "secret:openAIAPIKey", limit: 10)
        XCTAssertTrue(bySensitivity.contains { $0.id == saved.id })
        let byUTI = await library.search(query: "public.html", limit: 10)
        XCTAssertTrue(byUTI.contains { $0.id == saved.id })
    }

    func testRecordPasteUpdatesDeviceLocalUsageThroughHistoryAndSavedClipIDs() async throws {
        let library = try ClipboardLibrary()
        let outcome = try await library.capture(
            CaptureCandidate(
                content: try ClipContent.detect(text: "frequently pasted value"),
                capturedAt: Date(timeIntervalSince1970: 1_000)
            )
        )
        guard case let .inserted(history) = outcome else {
            return XCTFail("Expected inserted history")
        }
        let saved = try await library.saveHistoryItem(
            id: history.id,
            at: Date(timeIntervalSince1970: 1_001)
        )

        try await library.recordPaste(id: history.id, at: Date(timeIntervalSince1970: 1_002))
        try await library.recordPaste(id: saved.id, at: Date(timeIntervalSince1970: 1_003))

        let snapshot = await library.snapshot()
        let updated = try XCTUnwrap(snapshot.history.first(where: { $0.id == history.id }))
        XCTAssertEqual(updated.pasteCount, 2)
        XCTAssertEqual(updated.lastPastedAt, Date(timeIntervalSince1970: 1_003))
    }

    func testDuplicateCollapsingRefreshesAndMovesExistingItemToFront() async throws {
        let library = try ClipboardLibrary()
        let firstDate = Date(timeIntervalSince1970: 1_000)
        let secondDate = Date(timeIntervalSince1970: 1_001)
        let repeated = try ClipContent.detect(text: "same")

        _ = try await library.capture(
            CaptureCandidate(
                content: repeated,
                sourceApplicationBundleIdentifier: "com.example.one",
                capturedAt: firstDate
            )
        )
        let outcome = try await library.capture(
            CaptureCandidate(
                content: repeated,
                sourceApplicationBundleIdentifier: "com.example.two",
                capturedAt: secondDate
            )
        )

        guard case let .refreshedDuplicate(refreshed) = outcome else {
            return XCTFail("Expected a refreshed duplicate")
        }
        XCTAssertEqual(refreshed.captureCount, 2)
        XCTAssertEqual(refreshed.createdAt, firstDate)
        XCTAssertEqual(refreshed.lastCapturedAt, secondDate)
        XCTAssertEqual(refreshed.sourceApplicationBundleIdentifier, "com.example.two")

        _ = try await library.capture(
            CaptureCandidate(
                content: repeated,
                sourceApplicationBundleIdentifier: "com.example.stale",
                capturedAt: firstDate.addingTimeInterval(-1)
            )
        )
        var snapshot = await library.snapshot()
        XCTAssertEqual(snapshot.history.count, 1)
        XCTAssertEqual(snapshot.history[0].captureCount, 3)
        XCTAssertEqual(snapshot.history[0].lastCapturedAt, secondDate)
        XCTAssertEqual(snapshot.history[0].sourceApplicationBundleIdentifier, "com.example.two")

        _ = try await library.capture(
            CaptureCandidate(
                content: try ClipContent.detect(text: "different"),
                capturedAt: secondDate.addingTimeInterval(1)
            )
        )
        _ = try await library.capture(
            CaptureCandidate(
                content: repeated,
                capturedAt: secondDate.addingTimeInterval(2)
            )
        )
        snapshot = await library.snapshot()
        XCTAssertEqual(snapshot.history.count, 2)
        XCTAssertEqual(snapshot.history[0].content, repeated)
        XCTAssertEqual(snapshot.history[0].captureCount, 4)
    }

    func testCapturePolicyChangesPersistAndIgnoredCopiesNeverAppearLater() async throws {
        let store = InMemoryClipboardLibraryStore()
        let library = try await ClipboardLibrary.open(persistence: store)
        let content = try ClipContent.detect(text: "do not retain")

        try await library.setCaptureEnabled(false)
        let pausedOutcome = try await library.capture(CaptureCandidate(content: content))
        XCTAssertEqual(pausedOutcome, .ignored(.capturePaused))
        try await library.setCaptureEnabled(true)
        try await library.setApplication("com.example.blocked", excluded: true)
        let excludedOutcome = try await library.capture(
            CaptureCandidate(
                content: content,
                sourceApplicationBundleIdentifier: "COM.EXAMPLE.BLOCKED"
            )
        )
        XCTAssertEqual(excludedOutcome, .ignored(.applicationExcluded))

        let reopened = try await ClipboardLibrary.open(persistence: store)
        let snapshot = await reopened.snapshot()
        XCTAssertTrue(snapshot.history.isEmpty)
        XCTAssertTrue(snapshot.settings.capturePolicy.isCaptureEnabled)
        XCTAssertFalse(snapshot.settings.effectiveLocationContextEnabled)
        XCTAssertTrue(
            snapshot.settings.capturePolicy.excludedApplicationBundleIdentifiers
                .contains("com.example.blocked")
        )
    }

    func testOptionalDeviceContextPreferencePersists() async throws {
        let store = InMemoryClipboardLibraryStore()
        let library = try await ClipboardLibrary.open(persistence: store)

        try await library.setLocationContextEnabled(true)

        let reopened = try await ClipboardLibrary.open(persistence: store)
        let reopenedSnapshot = await reopened.snapshot()
        XCTAssertTrue(reopenedSnapshot.settings.effectiveLocationContextEnabled)
    }

    func testRetentionPrunesHistoryButNeverIndependentSavedClip() async throws {
        let library = try ClipboardLibrary()
        let now = Date(timeIntervalSince1970: 200_000)
        let oldDate = now.addingTimeInterval(-2 * 24 * 60 * 60)

        let outcome = try await library.capture(
            CaptureCandidate(
                content: try ClipContent.detect(text: "keep me intentionally"),
                capturedAt: oldDate
            )
        )
        guard case let .inserted(historyItem) = outcome else {
            return XCTFail("Expected inserted history item")
        }
        let saved = try await library.saveHistoryItem(
            id: historyItem.id,
            name: "Persistent reference",
            at: oldDate
        )

        let oneDay = try HistoryRetentionPolicy(maximumAge: 24 * 60 * 60)
        try await library.setRetentionPolicy(oneDay, referenceDate: now)
        var snapshot = await library.snapshot()
        XCTAssertTrue(snapshot.history.isEmpty)
        XCTAssertEqual(snapshot.savedClips.map(\.id), [saved.id])

        try await library.clearHistory()
        snapshot = await library.snapshot()
        XCTAssertEqual(snapshot.savedClips.map(\.id), [saved.id])
    }

    func testRetentionBoundaryKeepsItemAtExactCutoff() async throws {
        let library = try ClipboardLibrary()
        let now = Date(timeIntervalSince1970: 500_000)
        let oneHour = try HistoryRetentionPolicy(maximumAge: 3_600)
        try await library.setRetentionPolicy(oneHour, referenceDate: now)

        _ = try await library.capture(
            CaptureCandidate(
                content: try ClipContent.detect(text: "boundary"),
                capturedAt: now.addingTimeInterval(-3_600)
            )
        )
        let snapshot = await library.snapshot()
        XCTAssertEqual(snapshot.history.count, 1)
        let removedCount = try await library.pruneHistory(referenceDate: now)
        XCTAssertEqual(removedCount, 0)
    }

    func testFolderDeleteMovesClipsToUnfiledAndReorderIsContiguous() async throws {
        let library = try ClipboardLibrary()
        let baseDate = Date(timeIntervalSince1970: 10_000)
        let firstFolder = try await library.createFolder(name: "First", at: baseDate)
        let secondFolder = try await library.createFolder(
            name: "Second",
            at: baseDate.addingTimeInterval(1)
        )

        let capture = try await library.capture(
            CaptureCandidate(
                content: try ClipContent.detect(text: "folder content"),
                capturedAt: baseDate.addingTimeInterval(2)
            )
        )
        guard case let .inserted(item) = capture else {
            return XCTFail("Expected inserted item")
        }
        let saved = try await library.saveHistoryItem(
            id: item.id,
            folderID: firstFolder.id,
            at: baseDate.addingTimeInterval(3)
        )

        try await library.reorderFolder(
            id: secondFolder.id,
            to: 0,
            at: baseDate.addingTimeInterval(4)
        )
        var snapshot = await library.snapshot()
        XCTAssertEqual(snapshot.folders.map(\.id), [secondFolder.id, firstFolder.id])
        XCTAssertEqual(snapshot.folders.map(\.sortOrder), [0, 1])

        try await library.deleteFolder(id: firstFolder.id, at: baseDate.addingTimeInterval(5))
        snapshot = await library.snapshot()
        XCTAssertEqual(snapshot.folders.map(\.id), [secondFolder.id])
        XCTAssertEqual(snapshot.folders.map(\.sortOrder), [0])
        XCTAssertEqual(snapshot.savedClips.first(where: { $0.id == saved.id })?.folderID, nil)
        XCTAssertEqual(snapshot.savedClips.count, 1)
    }

    func testSavedClipRenameMoveDeleteAndSearchIndexStayConsistent() async throws {
        let library = try ClipboardLibrary()
        let folder = try await library.createFolder(name: "Research")
        let capture = try await library.capture(
            CaptureCandidate(content: try ClipContent.detect(text: "quarterly cobalt report"))
        )
        guard case let .inserted(item) = capture else {
            return XCTFail("Expected inserted item")
        }
        let saved = try await library.saveHistoryItem(id: item.id)

        try await library.renameSavedClip(id: saved.id, to: "  Mining brief  ")
        try await library.moveSavedClip(id: saved.id, to: folder.id)
        var results = await library.search(query: "mining", limit: 10)
        XCTAssertEqual(results.first?.id, saved.id)
        XCTAssertEqual(results.first?.name, "Mining brief")

        try await library.deleteSavedClip(id: saved.id)
        results = await library.search(query: "mining", limit: 10)
        XCTAssertFalse(results.contains(where: { $0.id == saved.id }))
    }

    func testInvalidReferencesAndNamesFailWithoutMutatingState() async throws {
        let library = try ClipboardLibrary()
        let initial = await library.snapshot()

        do {
            _ = try await library.createFolder(name: "   ")
            XCTFail("Expected empty-name failure")
        } catch {
            XCTAssertEqual(error as? ClipboardLibraryError, .emptyName)
        }
        do {
            try await library.deleteFolder(id: UUID())
            XCTFail("Expected missing-folder failure")
        } catch {
            guard case .folderNotFound = error as? ClipboardLibraryError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let final = await library.snapshot()
        XCTAssertEqual(final, initial)
    }

    func testSavingHistoryItemInNewFolderPersistsBothAndRejectsDuplicateWithoutOrphan() async throws {
        let library = try ClipboardLibrary()
        let capture = try await library.capture(
            CaptureCandidate(content: try ClipContent.detect(text: "save me in a new folder"))
        )
        guard case let .inserted(history) = capture else {
            return XCTFail("Expected history insertion")
        }

        let result = try await library.saveHistoryItemInNewFolder(id: history.id, folderName: "  Project notes  ")
        var snapshot = await library.snapshot()
        XCTAssertEqual(result.folder.name, "Project notes")
        XCTAssertEqual(snapshot.folders, [result.folder])
        XCTAssertEqual(snapshot.savedClips.map(\.folderID), [result.folder.id])
        let mutations = snapshot.pendingSavedLibraryMutations
        XCTAssertEqual(mutations.count, 2)
        XCTAssertEqual(mutations[0].id, result.folder.id)
        XCTAssertEqual(mutations[0].kind, .folder)
        XCTAssertFalse(mutations[0].isDeletion)
        XCTAssertEqual(mutations[1].id, result.savedClip.id)
        XCTAssertEqual(mutations[1].kind, .savedClip)
        XCTAssertFalse(mutations[1].isDeletion)

        do {
            _ = try await library.saveHistoryItemInNewFolder(id: history.id, folderName: "project NOTES")
            XCTFail("Expected duplicate folder name failure")
        } catch {
            XCTAssertEqual(error as? ClipboardLibraryError, .duplicateFolderName("project NOTES"))
        }
        snapshot = await library.snapshot()
        XCTAssertEqual(snapshot.folders.count, 1)
        XCTAssertEqual(snapshot.savedClips.count, 1)
    }

    func testCompoundSavePersistenceFailureRollsBackFolderClipAndJournal() async throws {
        let history = HistoryItem(
            content: try ClipContent.detect(text: "cannot persist this folder save"),
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let before = ClipboardLibrarySnapshot(history: [history])
        let library = try ClipboardLibrary(
            snapshot: before,
            persistence: RejectingCompoundSaveStore(snapshot: before)
        )

        do {
            _ = try await library.saveHistoryItemInNewFolder(id: history.id, folderName: "Never persisted")
            XCTFail("Expected persistence failure")
        } catch {
            XCTAssertEqual(error as? CompoundSaveStoreError, .intentionalFailure)
        }

        let afterFailure = await library.snapshot()
        XCTAssertEqual(afterFailure, before)
    }

    func testFolderCreateAndRenameRejectCaseAndDiacriticDuplicatesWithoutJournalChanges() async throws {
        let library = try ClipboardLibrary()
        let résumé = try await library.createFolder(name: "Résumé")
        let archive = try await library.createFolder(name: "Archive")
        let before = await library.snapshot()

        do {
            _ = try await library.createFolder(name: "resume\u{301}")
            XCTFail("Expected duplicate create failure")
        } catch {
            XCTAssertEqual(error as? ClipboardLibraryError, .duplicateFolderName("resume\u{301}"))
        }
        let afterDuplicateCreate = await library.snapshot()
        XCTAssertEqual(afterDuplicateCreate, before)

        do {
            try await library.renameFolder(id: archive.id, to: " RÉSUMÉ ")
            XCTFail("Expected duplicate rename failure")
        } catch {
            XCTAssertEqual(error as? ClipboardLibraryError, .duplicateFolderName("RÉSUMÉ"))
        }
        let afterDuplicateRename = await library.snapshot()
        XCTAssertEqual(afterDuplicateRename, before)
        XCTAssertEqual(afterDuplicateRename.folders.first(where: { $0.id == résumé.id })?.name, "Résumé")
    }

    func testConcurrentDuplicateFolderSavesProduceOneFolderAndOneSavedClip() async throws {
        let library = try ClipboardLibrary()
        let capture = try await library.capture(
            CaptureCandidate(content: try ClipContent.detect(text: "only save once"))
        )
        guard case let .inserted(history) = capture else {
            return XCTFail("Expected history insertion")
        }

        let outcomes = await withTaskGroup(of: Result<Void, Error>.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    do {
                        _ = try await library.saveHistoryItemInNewFolder(id: history.id, folderName: "One destination")
                        return .success(())
                    } catch {
                        return .failure(error)
                    }
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }

        XCTAssertEqual(outcomes.filter { if case .success = $0 { true } else { false } }.count, 1)
        XCTAssertEqual(outcomes.filter { result in
            guard case let .failure(error) = result else { return false }
            return error as? ClipboardLibraryError == .duplicateFolderName("One destination")
        }.count, 1)
        let snapshot = await library.snapshot()
        XCTAssertEqual(snapshot.folders.count, 1)
        XCTAssertEqual(snapshot.savedClips.count, 1)
    }

    func testSavingMissingHistoryItemInNewFolderLeavesSnapshotUnchanged() async throws {
        let library = try ClipboardLibrary()
        let before = await library.snapshot()

        do {
            _ = try await library.saveHistoryItemInNewFolder(id: UUID(), folderName: "Should not exist")
            XCTFail("Expected missing history failure")
        } catch {
            guard case .historyItemNotFound = error as? ClipboardLibraryError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let after = await library.snapshot()
        XCTAssertEqual(after, before)
    }

    func testApplyingSyncedLibraryPreservesHistoryAndLocalOnlyItems() async throws {
        let now = Date(timeIntervalSince1970: 900_000)
        let managedFolderID = UUID()
        let deletedFolderID = UUID()
        let managedClipID = UUID()
        let tombstonedClipID = UUID()
        let localOnlyClipID = UUID()
        let history = HistoryItem(
            content: try ClipContent.detect(text: "ordinary history"),
            createdAt: now
        )
        let oldManagedFolder = try ClipFolder(
            id: managedFolderID,
            name: "Old remote name",
            sortOrder: 0,
            createdAt: now
        )
        let deletedFolder = try ClipFolder(
            id: deletedFolderID,
            name: "Deleted remotely",
            sortOrder: 1,
            createdAt: now
        )
        let oldManagedClip = try SavedClip(
            id: managedClipID,
            name: "Old remote clip",
            content: try ClipContent.detect(text: "old synced text"),
            folderID: managedFolderID,
            createdAt: now
        )
        let tombstonedClip = try SavedClip(
            id: tombstonedClipID,
            name: "Delete me",
            content: try ClipContent.detect(text: "remote tombstone"),
            createdAt: now
        )
        let localOnlyClip = try SavedClip(
            id: localOnlyClipID,
            name: "Too large for sync",
            content: try ClipContent.detect(text: "keep locally"),
            folderID: deletedFolderID,
            createdAt: now
        )
        let library = try ClipboardLibrary(
            snapshot: ClipboardLibrarySnapshot(
                history: [history],
                savedClips: [oldManagedClip, tombstonedClip, localOnlyClip],
                folders: [oldManagedFolder, deletedFolder]
            )
        )
        let remoteFolder = try ClipFolder(
            id: managedFolderID,
            name: "Renamed remotely",
            sortOrder: 0,
            createdAt: now
        )
        let remoteClip = try SavedClip(
            id: managedClipID,
            name: "Updated remotely",
            content: try ClipContent.detect(text: "new synced text"),
            folderID: managedFolderID,
            createdAt: now
        )

        try await library.applySyncedSavedLibrary(
            savedClips: [remoteClip],
            folders: [remoteFolder],
            managedSavedClipIDs: [managedClipID, tombstonedClipID],
            managedFolderIDs: [managedFolderID, deletedFolderID],
            at: now.addingTimeInterval(1)
        )

        let result = await library.snapshot()
        XCTAssertEqual(result.history.map(\.id), [history.id])
        XCTAssertEqual(result.folders.map(\.name), ["Renamed remotely"])
        XCTAssertEqual(result.savedClips.first(where: { $0.id == managedClipID })?.name, "Updated remotely")
        XCTAssertFalse(result.savedClips.contains(where: { $0.id == tombstonedClipID }))
        XCTAssertEqual(result.savedClips.first(where: { $0.id == localOnlyClipID })?.folderID, nil)
        XCTAssertTrue(result.pendingSavedLibraryMutations.isEmpty)
    }

    func testSavedLibraryMutationJournalPersistsAndAcknowledgesOnlyExactVersion() async throws {
        let store = InMemoryClipboardLibraryStore()
        let library = try await ClipboardLibrary.open(persistence: store)
        let firstDate = Date(timeIntervalSince1970: 1_000_000)
        // Filesystems and imported records can collapse edits to the same timestamp. The journal
        // must still distinguish the exact outbox acknowledgement from a newer local edit.
        let secondDate = firstDate
        let folder = try await library.createFolder(name: "First", at: firstDate)
        let firstSnapshot = await library.snapshot()
        let firstMutation = try XCTUnwrap(firstSnapshot.pendingSavedLibraryMutations.first)
        XCTAssertEqual(firstMutation.id, folder.id)
        XCTAssertFalse(firstMutation.isDeletion)

        try await library.renameFolder(id: folder.id, to: "Second", at: secondDate)
        try await library.acknowledgePendingSavedLibraryMutation(firstMutation)
        var snapshot = await library.snapshot()
        let newerMutation = try XCTUnwrap(snapshot.pendingSavedLibraryMutations.first)
        XCTAssertEqual(newerMutation.modifiedAt, secondDate)
        XCTAssertNotEqual(newerMutation.token, firstMutation.token)

        let reopened = try await ClipboardLibrary.open(persistence: store)
        let reopenedSnapshot = await reopened.snapshot()
        XCTAssertEqual(reopenedSnapshot.pendingSavedLibraryMutations, [newerMutation])
        try await reopened.acknowledgePendingSavedLibraryMutation(newerMutation)
        snapshot = await reopened.snapshot()
        XCTAssertTrue(snapshot.pendingSavedLibraryMutations.isEmpty)
    }

    func testRemoteProjectionCannotOverwriteAtomicallyPendingLocalEdit() async throws {
        let date = Date(timeIntervalSince1970: 1_100_000)
        let library = try ClipboardLibrary()
        let capture = try await library.capture(
            CaptureCandidate(
                content: try ClipContent.detect(text: "local value"),
                capturedAt: date
            )
        )
        guard case let .inserted(history) = capture else {
            return XCTFail("Expected history insertion")
        }
        let local = try await library.saveHistoryItem(id: history.id, at: date)
        let remote = try SavedClip(
            id: local.id,
            name: "Remote stale value",
            content: try ClipContent.detect(text: "remote value"),
            createdAt: date.addingTimeInterval(-10)
        )

        try await library.applySyncedSavedLibrary(
            savedClips: [remote],
            folders: [],
            managedSavedClipIDs: [local.id],
            managedFolderIDs: []
        )

        var snapshot = await library.snapshot()
        XCTAssertEqual(snapshot.savedClips.first(where: { $0.id == local.id })?.content.text, "local value")
        let pending = try XCTUnwrap(snapshot.pendingSavedLibraryMutations.first)
        try await library.acknowledgePendingSavedLibraryMutation(pending)
        try await library.applySyncedSavedLibrary(
            savedClips: [remote],
            folders: [],
            managedSavedClipIDs: [local.id],
            managedFolderIDs: []
        )
        snapshot = await library.snapshot()
        XCTAssertEqual(snapshot.savedClips.first(where: { $0.id == local.id })?.content.text, "remote value")
    }

    func testRemoveAccountScopedSavedLibraryDropsPendingItemsAndMutationHints() async throws {
        let library = try ClipboardLibrary()
        let sharedFolder = try await library.createFolder(name: "Shared account")
        let sharedClip = try await library.createNote(
            title: "Pending shared note",
            body: "Must disappear after an account change",
            folderID: sharedFolder.id
        )
        let localFolder = try await library.createFolder(name: "Local")
        let localClip = try await library.createNote(
            title: "Local note",
            body: "Must remain",
            folderID: localFolder.id
        )

        try await library.removeAccountScopedSavedLibrary(
            savedClipIDs: [sharedClip.id],
            folderIDs: [sharedFolder.id]
        )

        let snapshot = await library.snapshot()
        XCTAssertFalse(snapshot.savedClips.contains { $0.id == sharedClip.id })
        XCTAssertFalse(snapshot.folders.contains { $0.id == sharedFolder.id })
        XCTAssertFalse(snapshot.pendingSavedLibraryMutations.contains {
            $0.id == sharedClip.id || $0.id == sharedFolder.id
        })
        XCTAssertTrue(snapshot.savedClips.contains { $0.id == localClip.id })
        XCTAssertTrue(snapshot.folders.contains { $0.id == localFolder.id })
    }
}

private enum CompoundSaveStoreError: Error, Equatable {
    case intentionalFailure
}

private actor RejectingCompoundSaveStore: ClipboardLibraryPersisting {
    init(snapshot _: ClipboardLibrarySnapshot) {}

    func load() async throws -> ClipboardLibrarySnapshot { .empty }

    func save(_: ClipboardLibrarySnapshot) async throws {
        throw CompoundSaveStoreError.intentionalFailure
    }
}
