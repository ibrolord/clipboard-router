import ClipboardRouterCore
import ClipboardRouterPlatform
import ClipboardRouterSecurity
import ClipboardRouterSync
import XCTest
@testable import ClipboardRouterApp

@MainActor
final class AppWorkflowIntegrationTests: XCTestCase {
    func testManualNoteSecretsFailClosedBeforeOrdinaryPersistence() async throws {
        let model = makeModel()
        await model.start()

        let accepted = model.createNote(
            title: "Production token",
            body: "sk-proj-abcdefghijklmnopqrstuvwxyz123456"
        )

        XCTAssertFalse(accepted)
        XCTAssertTrue(model.snapshot.savedClips.isEmpty)
        XCTAssertEqual(
            model.errorMessage,
            AppModelOperationError.sensitiveNoteRequiresVault(category: "openAIAPIKey")
                .localizedDescription
        )
    }

    func testEditorSaveReportsDurableFailureAndSuccessInsteadOfOnlyValidation() async throws {
        let store = FailingToggleClipboardStore(snapshot: ClipboardLibrarySnapshot())
        let model = makeModel(libraryPersistence: store)
        await model.start()
        await store.setShouldFailSave(true)

        let failed = await model.createNoteFromEditor(
            title: "Draft survives",
            body: "The sheet should remain open when persistence fails.",
            folderID: nil
        )
        XCTAssertFalse(failed)
        XCTAssertTrue(model.snapshot.savedClips.isEmpty)
        XCTAssertNotNil(model.errorMessage)

        await store.setShouldFailSave(false)
        model.errorMessage = nil
        let succeeded = await model.createNoteFromEditor(
            title: "Draft survives",
            body: "The sheet should dismiss only after this commit.",
            folderID: nil
        )
        XCTAssertTrue(succeeded)
        XCTAssertEqual(model.snapshot.savedClips.first?.name, "Draft survives")
        let createdID = try XCTUnwrap(model.snapshot.savedClips.first?.id)
        let presentedAfterEditorTurn = await waitUntil {
            model.selectedSection == .smartView(.notes)
                && model.selectedClipID == createdID
                && model.statusMessage == "Note created."
        }
        XCTAssertTrue(presentedAfterEditorTurn)
    }

    func testPostEditorNotePresentationRevalidatesTheDurableNote() async throws {
        let model = makeModel()
        await model.start()

        model.requestPostEditorNotePresentation(UUID(), status: "Should not appear")
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(model.selectedSection, .history)
        XCTAssertNil(model.selectedClipID)
        XCTAssertNil(model.statusMessage)
    }

    func testClipEditorCreatesNonDestructiveHistoryCopyUpdatesSavedClipAndRejectsSecrets() async throws {
        let now = Date()
        let history = HistoryItem(
            content: try ClipContent.detect(text: "history body"),
            createdAt: now,
            sourceApplicationBundleIdentifier: "com.example.Source"
        )
        let saved = try SavedClip(
            name: "Saved body",
            content: try ClipContent.detect(text: "before"),
            createdAt: now,
            pinnedAt: now
        )
        let model = makeModel(libraryPersistence: InMemoryClipboardLibraryStore(
            snapshot: ClipboardLibrarySnapshot(history: [history], savedClips: [saved])
        ))
        await model.start()

        let historyClip = PresentedClip(
            id: history.id,
            title: "history body",
            content: history.content,
            date: history.createdAt,
            sourceBundleIdentifier: history.sourceApplicationBundleIdentifier,
            origin: .history
        )
        XCTAssertTrue(model.saveEditedClip(
            historyClip, title: "Edited copy", body: "changed copy", folderID: nil
        ))
        let historyCopyAppeared = await waitUntil {
            model.snapshot.savedClips.contains { $0.derivedFromHistoryItemID == history.id }
        }
        XCTAssertTrue(historyCopyAppeared)
        XCTAssertEqual(model.snapshot.history, [history])

        let savedClip = PresentedClip(
            id: saved.id,
            title: saved.name,
            content: saved.content,
            date: saved.createdAt,
            sourceBundleIdentifier: nil,
            origin: .saved(folderID: nil)
        )
        XCTAssertTrue(model.saveEditedClip(
            savedClip, title: "Updated", body: "after", folderID: nil
        ))
        let savedClipUpdated = await waitUntil {
            model.snapshot.savedClips.first(where: { $0.id == saved.id })?.content.text == "after"
        }
        XCTAssertTrue(savedClipUpdated)
        XCTAssertEqual(
            model.snapshot.savedClips.first(where: { $0.id == saved.id })?.pinnedAt,
            saved.pinnedAt
        )

        XCTAssertFalse(model.saveEditedClip(
            savedClip,
            title: "Leaked token",
            body: "sk-proj-abcdefghijklmnopqrstuvwxyz123456",
            folderID: nil
        ))
        XCTAssertEqual(
            model.errorMessage,
            AppModelOperationError.sensitiveClipEditRequiresVault(category: "openAIAPIKey")
                .localizedDescription
        )
        XCTAssertEqual(
            model.snapshot.savedClips.first(where: { $0.id == saved.id })?.content.text,
            "after"
        )
    }

    func testNoteEditorUpdateAtomicallyChangesBodyTitleAndFolderAndRejectsSecrets() async throws {
        let folderA = try ClipFolder(name: "Drafts", sortOrder: 0, createdAt: Date())
        let folderB = try ClipFolder(name: "Research", sortOrder: 1, createdAt: Date())
        let note = try SavedClip(
            kind: .note,
            name: "Original",
            content: try ClipContent.detect(text: "original body"),
            folderID: folderA.id,
            createdAt: Date()
        )
        let model = makeModel(libraryPersistence: InMemoryClipboardLibraryStore(
            snapshot: ClipboardLibrarySnapshot(savedClips: [note], folders: [folderA, folderB])
        ))
        await model.start()

        XCTAssertTrue(model.updateNote(
            id: note.id,
            title: "Updated",
            body: "updated body",
            folderID: folderB.id
        ))
        let updated = await waitUntil {
            model.snapshot.savedClips.first?.name == "Updated"
                && model.snapshot.savedClips.first?.content.text == "updated body"
                && model.snapshot.savedClips.first?.folderID == folderB.id
        }
        XCTAssertTrue(updated)

        XCTAssertFalse(model.updateNote(
            id: note.id,
            title: "Leaked key",
            body: "sk-proj-abcdefghijklmnopqrstuvwxyz123456",
            folderID: nil
        ))
        let unchanged = try XCTUnwrap(model.snapshot.savedClips.first)
        XCTAssertEqual(unchanged.name, "Updated")
        XCTAssertEqual(unchanged.content.text, "updated body")
        XCTAssertEqual(unchanged.folderID, folderB.id)
    }

    func testNoteEditorRejectsPrivateSharedAndCrossShareFolderChangesBeforeMutation() async throws {
        let privateFolder = try ClipFolder(
            name: "Private", sortOrder: 0, createdAt: Date(timeIntervalSince1970: 1)
        )
        let rootA = try ClipFolder(
            name: "Share A", sortOrder: 1, createdAt: Date(timeIntervalSince1970: 2)
        )
        let childA = try ClipFolder(
            name: "A child", parentFolderID: rootA.id, sortOrder: 0,
            createdAt: Date(timeIntervalSince1970: 3)
        )
        let rootB = try ClipFolder(
            name: "Share B", sortOrder: 2, createdAt: Date(timeIntervalSince1970: 4)
        )
        let childB = try ClipFolder(
            name: "B child", parentFolderID: rootB.id, sortOrder: 0,
            createdAt: Date(timeIntervalSince1970: 5)
        )
        let privateNote = try SavedClip(
            kind: .note, name: "Private note",
            content: ClipContent(type: .plainText, text: "private body"),
            folderID: privateFolder.id, createdAt: Date(timeIntervalSince1970: 6)
        )
        let sharedNote = try SavedClip(
            kind: .note, name: "Shared note",
            content: ClipContent(type: .plainText, text: "shared body"),
            folderID: childA.id, createdAt: Date(timeIntervalSince1970: 7)
        )
        let model = makeModel(libraryPersistence: InMemoryClipboardLibraryStore(
            snapshot: ClipboardLibrarySnapshot(
                savedClips: [privateNote, sharedNote],
                folders: [privateFolder, rootA, childA, rootB, childB]
            )
        ))
        await model.start()

        let owner = try SharedFolderCloudParticipant(
            id: "owner", displayName: "Owner", role: .owner, acceptance: .accepted
        )
        func projection(root: ClipFolder, child: ClipFolder, items: [SavedClip]) throws
            -> SharedFolderSessionSnapshot
        {
            let scope = try SharedFolderScope(folderID: root.id, ownerParticipantID: "owner")
            return SharedFolderSessionSnapshot(
                location: SharedFolderRemoteLocation(
                    folderID: root.id, zoneName: scope.zoneName, ownerName: "cloud-owner",
                    ownerParticipantID: "owner", shareRecordName: "share-\(root.id)",
                    databaseScope: .ownerPrivate, title: root.name
                ),
                currentParticipantID: "owner",
                participants: [owner],
                folder: root,
                folders: [child],
                savedClips: items,
                managedFolderIDs: [root.id, child.id],
                managedSavedClipIDs: Set(items.map(\.id)),
                status: .synced(Date())
            )
        }
        try await model.applySharedFolderSnapshot(
            projection(root: rootA, child: childA, items: [sharedNote])
        )
        try await model.applySharedFolderSnapshot(
            projection(root: rootB, child: childB, items: [])
        )

        XCTAssertFalse(model.updateNote(
            id: privateNote.id, title: "Blocked", body: "private body", folderID: childA.id
        ))
        XCTAssertFalse(model.updateNote(
            id: sharedNote.id, title: "Blocked", body: "shared body", folderID: privateFolder.id
        ))
        XCTAssertFalse(model.updateNote(
            id: sharedNote.id, title: "Blocked", body: "shared body", folderID: childB.id
        ))
        XCTAssertTrue(model.errorMessage?.contains("separate sync spaces") == true)
        let byID = Dictionary(uniqueKeysWithValues: model.snapshot.savedClips.map { ($0.id, $0) })
        XCTAssertEqual(byID[privateNote.id]?.folderID, privateFolder.id)
        XCTAssertEqual(byID[sharedNote.id]?.folderID, childA.id)
        XCTAssertEqual(byID[privateNote.id]?.name, privateNote.name)
        XCTAssertEqual(byID[sharedNote.id]?.name, sharedNote.name)
    }

    func testNoteConversionPolicyRejectsRichAndExternalRepresentations() throws {
        XCTAssertTrue(AppModel.isSafelyConvertibleToNote(try ClipContent.detect(text: "plain")))
        XCTAssertTrue(AppModel.isSafelyConvertibleToNote(try ClipContent.detect(text: "https://example.com")))

        let reference = try ClipAssetReference(
            digest: String(repeating: "a", count: 64),
            kind: .richText,
            uniformTypeIdentifier: "public.rtf",
            byteCount: 12,
            relativePath: "aa/rich.rtf"
        )
        let rich = try ClipContent(
            type: .plainText,
            text: "rendered text",
            representations: ClipRepresentations(richText: reference)
        )
        XCTAssertFalse(AppModel.isSafelyConvertibleToNote(rich))
        XCTAssertFalse(AppModel.isSafelyConvertibleToNote(
            try ClipContent(type: .image, text: "image OCR")
        ))
    }

    func testRichTextClipCanBeEditedOnlyAsANewPlainTextCopy() async throws {
        let rich = try SavedClip(
            name: "Formatted original",
            content: try ClipContent(type: .richText, text: "formatted source"),
            createdAt: Date(timeIntervalSince1970: 10),
            tags: ["source"]
        )
        let model = makeModel(libraryPersistence: InMemoryClipboardLibraryStore(
            snapshot: ClipboardLibrarySnapshot(savedClips: [rich])
        ))
        await model.start()
        model.selectLibrarySection(.allSaved)
        let presented = try XCTUnwrap(model.clipsForSelectedSection.first)

        XCTAssertTrue(model.canEditClip(presented))
        let saved = await model.saveEditedClipFromEditor(
            presented,
            title: "Editable copy",
            body: "reviewed plain text",
            folderID: nil
        )
        XCTAssertTrue(saved)

        let original = try XCTUnwrap(model.snapshot.savedClips.first { $0.id == rich.id })
        let copy = try XCTUnwrap(model.snapshot.savedClips.first { $0.id != rich.id })
        XCTAssertEqual(original.content.type, .richText)
        XCTAssertEqual(original.content.text, "formatted source")
        XCTAssertEqual(copy.content.type, .plainText)
        XCTAssertEqual(copy.content.text, "reviewed plain text")
        XCTAssertEqual(copy.tags, ["source"])
    }

    func testSavedNoteVaultMovePreservesAuthenticatedItemKind() async throws {
        let note = try SavedClip(
            kind: .note,
            name: "Private note",
            content: try ClipContent.detect(text: "safe private material"),
            createdAt: Date()
        )
        let vaultSession = testVaultSession()
        let vaultStore = InMemoryVaultStore()
        let model = makeModel(
            vaultSession: vaultSession,
            vaultStore: vaultStore,
            libraryPersistence: InMemoryClipboardLibraryStore(snapshot: ClipboardLibrarySnapshot(
                savedClips: [note]
            ))
        )
        await model.start()
        model.selectLibrarySection(.allSaved)
        let presented = try XCTUnwrap(model.clipsForSelectedSection.first)

        model.moveClipToVault(presented)

        let moved = await waitUntil(timeout: .seconds(2)) {
            model.snapshot.savedClips.isEmpty && model.vaultEncryptedItemCount == 1
        }
        XCTAssertTrue(moved)
        let vaultLibrary = try await VaultLibrary.open(store: vaultStore, session: vaultSession)
        try await vaultSession.unlock()
        let vaulted = try await vaultLibrary.items()
        XCTAssertEqual(vaulted.first?.kind, .note)
    }

    func testMenuBarPinOnHistoryCreatesPinnedSavedCopyAndSavedToggleUnpinsIt() async throws {
        let model = makeModel()
        await model.start()
        model.capture(PasteboardCaptureDraft(
            changeCount: 1,
            typeIdentifiers: ["public.utf8-plain-text"],
            plainText: "pin action"
        ))
        let captured = await waitUntil { model.menuBarRecentClips.count == 1 }
        XCTAssertTrue(captured)
        let history = try XCTUnwrap(model.menuBarRecentClips.first)

        model.togglePinOrSave(history)

        let pinnedCreated = await waitUntil { model.menuBarPinnedClips.count == 1 }
        XCTAssertTrue(pinnedCreated)
        let pinned = try XCTUnwrap(model.menuBarPinnedClips.first)
        let persisted = try XCTUnwrap(model.snapshot.savedClips.first)
        XCTAssertTrue(persisted.isPinned)
        XCTAssertEqual(persisted.sourceHistoryItemID, history.id)
        XCTAssertEqual(persisted.pasteboardTypeIdentifiers, ["public.utf8-plain-text"])

        model.togglePinOrSave(pinned)

        let unpinned = await waitUntil {
            model.snapshot.savedClips.first?.isPinned == false
        }
        XCTAssertTrue(unpinned)
        XCTAssertTrue(model.menuBarPinnedClips.isEmpty)
    }

    func testMoveHistoryToVaultAuthenticatesThenRemovesHistoryAndLinkedSavedCopies() async throws {
        let vaultSession = testVaultSession()
        let vaultStore = InMemoryVaultStore()
        let model = makeModel(vaultSession: vaultSession, vaultStore: vaultStore)
        await model.start()
        model.capture(PasteboardCaptureDraft(
            changeCount: 1,
            typeIdentifiers: ["public.utf8-plain-text"],
            plainText: "move history securely"
        ))
        let captured = await waitUntil { model.menuBarRecentClips.count == 1 }
        XCTAssertTrue(captured)
        let history = try XCTUnwrap(model.menuBarRecentClips.first)
        model.saveHistoryClip(history, folderID: nil)
        let saved = await waitUntil { model.snapshot.savedClips.count == 1 }
        XCTAssertTrue(saved)

        XCTAssertTrue(model.canMoveClipToVault(history))
        model.moveClipToVault(history)

        let moved = await waitUntil(timeout: .seconds(2)) {
            model.snapshot.history.isEmpty
                && model.snapshot.savedClips.isEmpty
                && model.vaultEncryptedItemCount == 1
        }
        XCTAssertTrue(moved)
        let vaultLibrary = try await VaultLibrary.open(store: vaultStore, session: vaultSession)
        if !(await vaultSession.isUnlocked) { try await vaultSession.unlock() }
        let vaultItems = try await vaultLibrary.items()
        let vaultItem = try XCTUnwrap(vaultItems.first)
        XCTAssertEqual(vaultItem.provenance?.ordinaryOrigin, .history)
        XCTAssertEqual(vaultItem.provenance?.sourceHistoryItemID, history.id)
        XCTAssertEqual(vaultItem.provenance?.linkedSavedClipIDs.count, 1)
    }

    func testGeneratedSecretDraftNeverEntersOrdinaryLibrary() async throws {
        let model = makeModel()
        await model.start()
        model.capture(PasteboardCaptureDraft(
            changeCount: 1,
            typeIdentifiers: ["public.utf8-plain-text"],
            plainText: "Research Acme before Friday"
        ))
        let captured = await waitUntil { model.menuBarRecentClips.count == 1 }
        XCTAssertTrue(captured)
        let history = try XCTUnwrap(model.menuBarRecentClips.first)
        model.saveHistoryClip(history, folderID: nil)
        let saved = await waitUntil { model.snapshot.savedClips.count == 1 }
        XCTAssertTrue(saved)
        model.selectedSection = .allSaved
        let source = try XCTUnwrap(model.clipsForSelectedSection.first)

        let syntheticAWSKey = ["AKIA", "IOSFODNN7EXAMPLX"].joined()
        let didSave = await model.saveAIDraft(
            "Generated credential \(syntheticAWSKey)",
            sourceClip: source
        )

        XCTAssertFalse(didSave)
        XCTAssertEqual(model.snapshot.savedClips.count, 1)
        XCTAssertEqual(
            model.errorMessage,
            AppModelOperationError.generatedSensitiveContent.localizedDescription
        )
    }

    func testAIDraftUsesSuppliedModelProvenanceWithoutInheritingSharedTeamFolder() async throws {
        // Arrange
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let sharedRoot = try ClipFolder(
            name: "Team research",
            sortOrder: 0,
            createdAt: createdAt
        )
        let sourceNote = try SavedClip(
            kind: .note,
            name: "Acme research",
            content: ClipContent(type: .plainText, text: "Research Acme"),
            folderID: sharedRoot.id,
            createdAt: createdAt
        )
        let owner = try SharedFolderCloudParticipant(
            id: "owner",
            displayName: "Owner",
            role: .owner,
            acceptance: .accepted
        )
        let editor = try SharedFolderCloudParticipant(
            id: "editor",
            displayName: "Editor",
            role: .editor,
            acceptance: .accepted
        )
        let scope = try SharedFolderScope(
            folderID: sharedRoot.id,
            ownerParticipantID: owner.id
        )
        let shared = SharedFolderSessionSnapshot(
            location: SharedFolderRemoteLocation(
                folderID: sharedRoot.id,
                zoneName: scope.zoneName,
                ownerName: "cloud-owner",
                ownerParticipantID: owner.id,
                shareRecordName: "share-team-research",
                databaseScope: .participantShared,
                title: sharedRoot.name
            ),
            currentParticipantID: editor.id,
            participants: [owner, editor],
            folder: sharedRoot,
            folders: [],
            savedClips: [sourceNote],
            managedFolderIDs: [sharedRoot.id],
            managedSavedClipIDs: [sourceNote.id],
            status: .synced(createdAt)
        )
        let model = makeModel()
        await model.start()
        try await model.applySharedFolderSnapshot(shared)
        let source = PresentedClip(
            id: sourceNote.id,
            title: sourceNote.name,
            content: sourceNote.content,
            date: sourceNote.createdAt,
            sourceBundleIdentifier: nil,
            origin: .saved(folderID: sharedRoot.id),
            savedItemKind: .note
        )

        // Act
        let didSave = await model.saveAIDraft(
            "Follow up tomorrow.",
            sourceClip: source,
            modelProvenance: "  gpt-5-mini\n"
        )
        let drafts = model.snapshot.savedClips.filter { $0.id != sourceNote.id }
        let draft = drafts.first

        // Assert
        XCTAssertEqual(
            AIDraftPersistenceObservation(
                didSave: didSave,
                generatedCount: drafts.count,
                folderID: draft?.folderID,
                body: draft?.content.text
            ),
            AIDraftPersistenceObservation(
                didSave: true,
                generatedCount: 1,
                folderID: nil,
                body: "Unverified AI draft · gpt-5-mini\n\nFollow up tomorrow."
            )
        )
    }

    func testPerformInsertUsesSavedPasteDeliveryWhenNoOverrideIsSupplied() async throws {
        // Arrange
        let writer = FakeTypedPasteboardWriter()
        let saved = try SavedClip(
            kind: .note,
            name: "Pricing reply",
            content: ClipContent(type: .plainText, text: "Approved pricing language"),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let model = makeModel(
            typedWriter: writer,
            libraryPersistence: InMemoryClipboardLibraryStore(
                snapshot: ClipboardLibrarySnapshot(savedClips: [saved])
            )
        )
        await model.start()
        let clip = PresentedClip(
            id: saved.id,
            title: saved.name,
            content: saved.content,
            date: saved.createdAt,
            sourceBundleIdentifier: nil,
            origin: .saved(folderID: nil),
            savedItemKind: .note
        )
        guard model.saveInsertAlias(
            for: clip,
            abbreviation: ";pricing",
            delivery: .pasteIntoFrontmostApplication
        ), let result = model.insertAliasResults(matching: ";pricing").first
        else { throw RegressionTestSetupError.aliasWasNotSaved }

        // Act
        model.performInsert(result)

        // Assert
        XCTAssertEqual(
            InsertDefaultDeliveryObservation(
                savedDelivery: result.alias?.delivery,
                clipboardWriteCount: writer.writtenContents.count,
                errorMessage: model.errorMessage
            ),
            InsertDefaultDeliveryObservation(
                savedDelivery: .pasteIntoFrontmostApplication,
                clipboardWriteCount: 0,
                errorMessage: "No fresh previous-app target is available. Open Quick Paste from the app you want to paste into."
            )
        )
    }

    func testVaultAuthenticationFailureDoesNotDeleteOrdinaryHistory() async throws {
        let authenticator = StubVaultAuthenticator(shouldSucceed: false)
        let vaultSession = VaultSession(
            authenticator: authenticator,
            keyProvider: InMemoryVaultKeyProvider()
        )
        let model = makeModel(
            vaultSession: vaultSession,
            vaultStore: InMemoryVaultStore()
        )
        await model.start()
        model.capture(PasteboardCaptureDraft(
            changeCount: 1,
            typeIdentifiers: [],
            plainText: "authentication must happen first"
        ))
        let captured = await waitUntil { model.menuBarRecentClips.count == 1 }
        XCTAssertTrue(captured)
        let history = try XCTUnwrap(model.menuBarRecentClips.first)

        model.moveClipToVault(history)

        let failed = await waitUntil { model.errorMessage != nil }
        XCTAssertTrue(failed)
        XCTAssertEqual(model.snapshot.history.map(\.id), [history.id])
        XCTAssertTrue(model.snapshot.savedClips.isEmpty)
        XCTAssertEqual(model.vaultEncryptedItemCount, 0)
    }

    func testVaultWriteFailureDoesNotDeleteOrdinaryHistoryOrSavedCopy() async throws {
        let model = makeModel(
            vaultSession: testVaultSession(),
            vaultStore: RejectingVaultSaveStore()
        )
        await model.start()
        model.capture(PasteboardCaptureDraft(
            changeCount: 1,
            typeIdentifiers: [],
            plainText: "failed encrypted write"
        ))
        let captured = await waitUntil { model.menuBarRecentClips.count == 1 }
        XCTAssertTrue(captured)
        let history = try XCTUnwrap(model.menuBarRecentClips.first)
        model.saveHistoryClip(history, folderID: nil)
        let saved = await waitUntil { model.snapshot.savedClips.count == 1 }
        XCTAssertTrue(saved)
        let savedID = try XCTUnwrap(model.snapshot.savedClips.first?.id)

        model.moveClipToVault(history)

        let failed = await waitUntil { model.errorMessage != nil }
        XCTAssertTrue(failed)
        XCTAssertEqual(model.snapshot.history.map(\.id), [history.id])
        XCTAssertEqual(model.snapshot.savedClips.map(\.id), [savedID])
        XCTAssertEqual(model.vaultEncryptedItemCount, 0)
    }

    func testUnlockReconcilesAuthenticatedDirectHistoryMove() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppWorkflowIntegrationTests-Recovery-\(UUID())")
        let ordinaryStore = SQLiteFileClipboardLibraryStore(
            fileURL: directory.appendingPathComponent("library.sqlite3")
        )
        let library = try await ClipboardLibrary.open(persistence: ordinaryStore)
        let capturedAt = Date()
        let outcome = try await library.capture(CaptureCandidate(
            content: try ClipContent.detect(text: "recover direct history move"),
            sourceApplicationBundleIdentifier: "com.example.source",
            originatingDeviceIdentifier: "device-recovery",
            pasteboardTypeIdentifiers: ["public.utf8-plain-text"],
            capturedAt: capturedAt
        ))
        guard case let .inserted(history) = outcome else {
            return XCTFail("Expected history insertion")
        }
        let linked = try await library.saveHistoryItem(id: history.id, at: capturedAt)

        let vaultSession = testVaultSession()
        let vaultStore = InMemoryVaultStore()
        let vaultLibrary = try await VaultLibrary.open(store: vaultStore, session: vaultSession)
        try await vaultSession.unlock()
        let provenance = VaultItemProvenance(
            ordinaryOrigin: .history,
            sourceHistoryItemID: history.id,
            linkedSavedClipIDs: [linked.id],
            sourceHistoryFingerprint: VaultHistoryItemFingerprint(history),
            linkedSavedClipFingerprints: [VaultSavedClipFingerprint(linked)],
            sourceApplicationBundleIdentifier: history.sourceApplicationBundleIdentifier,
            originatingDeviceIdentifier: history.originatingDeviceIdentifier,
            captureContext: history.captureContext,
            originallyCapturedAt: history.createdAt,
            sensitivity: history.sensitivity,
            pasteboardTypeIdentifiers: history.pasteboardTypeIdentifiers ?? []
        )
        _ = try await vaultLibrary.add(VaultItem(
            id: history.id,
            name: history.content.text,
            content: history.content,
            createdAt: history.createdAt,
            modifiedAt: history.modifiedAt,
            provenance: provenance
        ))
        await vaultSession.lock()

        let model = makeModel(
            supportDirectory: directory,
            vaultSession: vaultSession,
            vaultStore: vaultStore
        )
        await model.start()
        XCTAssertEqual(model.snapshot.history.map(\.id), [history.id])
        XCTAssertEqual(model.snapshot.savedClips.map(\.id), [linked.id])

        model.unlockVault()

        let reconciled = await waitUntil(timeout: .seconds(2)) {
            model.isVaultUnlocked
                && model.snapshot.history.isEmpty
                && model.snapshot.savedClips.isEmpty
        }
        XCTAssertTrue(reconciled)
    }

    func testVaultMoveRetryResumesAfterEncryptedAddWhenOrdinaryCommitFailed() async throws {
        let date = Date()
        let history = HistoryItem(
            content: try ClipContent.detect(text: "retry exact manifest"),
            createdAt: date
        )
        let saved = try SavedClip(
            name: "Retry target",
            content: history.content,
            sourceHistoryItemID: history.id,
            createdAt: date,
            originallyCapturedAt: date
        )
        let ordinaryStore = FailingToggleClipboardStore(snapshot: ClipboardLibrarySnapshot(
            history: [history],
            savedClips: [saved]
        ))
        await ordinaryStore.setShouldFailSave(true)
        let vaultStore = InMemoryVaultStore()
        let vaultSession = testVaultSession()
        let model = makeModel(
            vaultSession: vaultSession,
            vaultStore: vaultStore,
            libraryPersistence: ordinaryStore
        )
        await model.start()
        let clip = try XCTUnwrap(model.menuBarRecentClips.first)

        model.moveClipToVault(clip)
        let firstFailed = await waitUntil { model.errorMessage != nil && !model.isBusy }
        XCTAssertTrue(firstFailed)
        XCTAssertEqual(model.snapshot.history.map(\.id), [history.id])
        XCTAssertEqual(model.snapshot.savedClips.map(\.id), [saved.id])
        let encryptedAfterFailure = try await vaultStore.load()
        XCTAssertEqual(encryptedAfterFailure.envelopes.count, 1)

        await ordinaryStore.setShouldFailSave(false)
        model.errorMessage = nil
        model.moveClipToVault(clip)

        let resumed = await waitUntil(timeout: .seconds(2)) {
            model.snapshot.history.isEmpty && model.snapshot.savedClips.isEmpty
        }
        XCTAssertTrue(resumed)
        let encryptedAfterRetry = try await vaultStore.load()
        XCTAssertEqual(encryptedAfterRetry.envelopes.count, 1)
    }

    func testRecoveryUsesExactLinkedFingerprintWhenPrimarySavedSourceIsGone() async throws {
        let date = Date()
        let historyID = UUID()
        let primary = try SavedClip(
            name: "Primary removed before recovery",
            content: try ClipContent.detect(text: "fingerprinted payload"),
            sourceHistoryItemID: historyID,
            createdAt: date,
            originallyCapturedAt: date
        )
        let linked = try SavedClip(
            name: "Still present linked copy",
            content: primary.content,
            sourceHistoryItemID: historyID,
            createdAt: date,
            originallyCapturedAt: date
        )
        let changedBeforeEncryption = try SavedClip(
            name: "Changed later",
            content: primary.content,
            sourceHistoryItemID: historyID,
            createdAt: date,
            originallyCapturedAt: date
        )
        let changedAfterEncryption = try SavedClip(
            id: changedBeforeEncryption.id,
            name: "Changed after encryption",
            content: changedBeforeEncryption.content,
            sourceHistoryItemID: historyID,
            createdAt: changedBeforeEncryption.createdAt,
            modifiedAt: date.addingTimeInterval(1),
            originallyCapturedAt: date
        )
        let ordinaryStore = InMemoryClipboardLibraryStore(snapshot: ClipboardLibrarySnapshot(
            savedClips: [linked, changedAfterEncryption]
        ))
        let vaultStore = InMemoryVaultStore()
        let vaultSession = testVaultSession()
        let vaultLibrary = try await VaultLibrary.open(store: vaultStore, session: vaultSession)
        try await vaultSession.unlock()
        let provenance = VaultItemProvenance(
            ordinaryOrigin: .saved,
            sourceHistoryItemID: historyID,
            sourceSavedClipID: primary.id,
            linkedSavedClipIDs: [primary.id, linked.id, changedBeforeEncryption.id],
            linkedSavedClipFingerprints: [
                VaultSavedClipFingerprint(primary),
                VaultSavedClipFingerprint(linked),
                VaultSavedClipFingerprint(changedBeforeEncryption),
            ],
            originallyCapturedAt: primary.originallyCapturedAt
        )
        _ = try await vaultLibrary.add(VaultItem(
            id: primary.id,
            name: primary.name,
            content: primary.content,
            createdAt: primary.createdAt,
            modifiedAt: primary.modifiedAt,
            provenance: provenance
        ))
        await vaultSession.lock()
        let model = makeModel(
            vaultSession: vaultSession,
            vaultStore: vaultStore,
            libraryPersistence: ordinaryStore
        )
        await model.start()
        XCTAssertEqual(Set(model.snapshot.savedClips.map(\.id)), [linked.id, changedAfterEncryption.id])

        model.unlockVault()

        let reconciled = await waitUntil(timeout: .seconds(2)) {
            model.isVaultUnlocked
                && model.snapshot.savedClips.map(\.id) == [changedAfterEncryption.id]
        }
        XCTAssertTrue(
            reconciled,
            "remaining=\(model.snapshot.savedClips.map(\.id)) unlocked=\(model.isVaultUnlocked) error=\(model.errorMessage ?? "nil") status=\(model.statusMessage ?? "nil")"
        )
    }

    func testVaultMoveSummaryCountsExactHistoryAndLinkedSavedCopies() async throws {
        let date = Date()
        let history = HistoryItem(
            content: try ClipContent.detect(text: "count targets"),
            createdAt: date
        )
        let savedA = try SavedClip(
            name: "A",
            content: history.content,
            sourceHistoryItemID: history.id,
            createdAt: date
        )
        let savedB = try SavedClip(
            name: "B",
            content: history.content,
            sourceHistoryItemID: history.id,
            createdAt: date
        )
        let model = makeModel(
            vaultSession: testVaultSession(),
            vaultStore: InMemoryVaultStore(),
            libraryPersistence: InMemoryClipboardLibraryStore(snapshot: ClipboardLibrarySnapshot(
                history: [history],
                savedClips: [savedA, savedB]
            ))
        )
        await model.start()
        let clip = try XCTUnwrap(model.menuBarRecentClips.first)

        let summary = try XCTUnwrap(model.vaultMoveSummary(for: clip))

        XCTAssertEqual(summary.historyItemCount, 1)
        XCTAssertEqual(summary.savedClipCount, 2)
        XCTAssertEqual(summary.ordinaryCopyCount, 3)
        XCTAssertTrue(summary.confirmationMessage.contains("1 History item"))
        XCTAssertTrue(summary.confirmationMessage.contains("2 Saved copies"))
    }

    func testVaultMoveRequiresReconfirmationWhenConfirmedScopeChanges() async throws {
        let date = Date()
        let history = HistoryItem(
            content: try ClipContent.detect(text: "scope changed after confirmation"),
            createdAt: date
        )
        let vaultStore = InMemoryVaultStore()
        let model = makeModel(
            vaultSession: testVaultSession(),
            vaultStore: vaultStore,
            libraryPersistence: InMemoryClipboardLibraryStore(snapshot: ClipboardLibrarySnapshot(
                history: [history]
            ))
        )
        await model.start()
        let clip = try XCTUnwrap(model.menuBarRecentClips.first)
        let confirmed = try XCTUnwrap(model.vaultMoveSummary(for: clip))
        XCTAssertEqual(confirmed.savedClipCount, 0)

        model.saveHistoryClip(clip, folderID: nil)
        let linkedAdded = await waitUntil { model.snapshot.savedClips.count == 1 }
        XCTAssertTrue(linkedAdded)

        model.moveClipToVault(clip, confirmedSummary: confirmed)

        let rejected = await waitUntil {
            model.errorMessage == AppModelOperationError.vaultMoveReconfirmationRequired
                .localizedDescription
        }
        XCTAssertTrue(rejected)
        XCTAssertTrue(model.statusMessage?.contains("Review and confirm again") == true)
        XCTAssertEqual(model.snapshot.history.map(\.id), [history.id])
        XCTAssertEqual(model.snapshot.savedClips.count, 1)
        let encrypted = try await vaultStore.load()
        XCTAssertTrue(encrypted.envelopes.isEmpty)
    }

    func testUnsupportedImageHistoryCannotMoveToVault() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppWorkflowIntegrationTests-Image-\(UUID())")
        let ordinaryStore = SQLiteFileClipboardLibraryStore(
            fileURL: directory.appendingPathComponent("library.sqlite3")
        )
        let library = try await ClipboardLibrary.open(persistence: ordinaryStore)
        _ = try await library.capture(CaptureCandidate(
            content: try ClipContent(type: .image, text: "Image"),
            capturedAt: Date()
        ))
        let model = makeModel(
            supportDirectory: directory,
            vaultSession: testVaultSession(),
            vaultStore: InMemoryVaultStore()
        )
        await model.start()
        let image = try XCTUnwrap(model.menuBarRecentClips.first)

        XCTAssertFalse(model.canMoveClipToVault(image))
    }

    func testCombinedDraftSafetyTextExposesSecretOutsidePlainPreview() {
        let secret = "sk-proj-abcdefghijklmnopqrstuvwxyz123456"
        let draft = PasteboardCaptureDraft(
            changeCount: 1,
            typeIdentifiers: [],
            plainText: "ordinary preview",
            htmlData: Data("<meta content=\"\(secret)\">".utf8)
        )

        let scan = SecretDetector().scan(
            text: draft.textForSensitivityAnalysis(ocrText: nil)
        )

        XCTAssertTrue(scan.contains(.openAIAPIKey))
    }

    func testCombineClipsAndTransformPreviewLeaveOriginalClipUnchanged() async throws {
        let original = try ClipContent.detect(text: "  Hello WORLD  ")
        let now = Date()
        let history = HistoryItem(
            content: original,
            createdAt: now,
            sourceApplicationBundleIdentifier: "com.example.source"
        )
        let clip = PresentedClip(
            id: history.id,
            title: "Greeting",
            content: original,
            date: history.createdAt,
            sourceBundleIdentifier: "com.example.source",
            origin: .history
        )
        let model = makeModel(libraryPersistence: InMemoryClipboardLibraryStore(
            snapshot: ClipboardLibrarySnapshot(history: [history])
        ))
        await model.start()

        model.addToCombinedClips(clip)
        model.previewTransform(.trim, title: "Trim", for: clip)

        XCTAssertEqual(model.combinedClips?.items.map(\.id), [clip.id])
        XCTAssertEqual(model.transformPreview?.transformedText, "Hello WORLD")
        XCTAssertEqual(clip.content, original)
        XCTAssertEqual(model.selectedSection, .workflows)
    }

    func testCombineClipsReviewRendersInOrderAndSavesOneNote() async throws {
        let typedWriter = FakeTypedPasteboardWriter()
        let now = Date()
        let first = HistoryItem(
            content: try ClipContent.detect(text: "First discovery"),
            createdAt: now.addingTimeInterval(-10),
            sourceApplicationBundleIdentifier: "com.example.crm"
        )
        let second = HistoryItem(
            content: try ClipContent.detect(text: "Second discovery"),
            createdAt: now,
            sourceApplicationBundleIdentifier: "com.example.browser"
        )
        let model = makeModel(
            typedWriter: typedWriter,
            libraryPersistence: InMemoryClipboardLibraryStore(
                snapshot: ClipboardLibrarySnapshot(history: [first, second])
            )
        )
        await model.start()

        model.addToCombinedClips(presentedClip(first))
        model.addToCombinedClips(presentedClip(second))
        model.prepareCombinedClipsReview()

        guard let request = model.pendingCombinedClipsReview else {
            XCTFail(model.errorMessage ?? "Combine Clips review was not created")
            return
        }
        let markdown = try XCTUnwrap(model.combinedClipsMarkdown(for: request))
        XCTAssertLessThan(
            try XCTUnwrap(markdown.range(of: "First discovery")?.lowerBound),
            try XCTUnwrap(markdown.range(of: "Second discovery")?.lowerBound)
        )
        model.copyCombinedClips(request)
        let copied = await waitUntil { typedWriter.writtenContents.count == 1 }
        XCTAssertTrue(copied)
        XCTAssertEqual(typedWriter.writtenContents.map(\.text), [markdown])

        let didSave = await model.saveCombinedClipsAsNote(request)
        XCTAssertTrue(didSave)
        let note = try XCTUnwrap(model.snapshot.savedClips.first)
        XCTAssertEqual(note.kind, .note)
        XCTAssertEqual(note.name, "Combined Clips")
        XCTAssertEqual(note.content.text, markdown)
        XCTAssertNil(model.pendingCombinedClipsReview)
        XCTAssertEqual(model.combinedClips?.items.count, 2)
    }

    func testCombineClipsActionsRejectACollectionChangedAfterReview() async throws {
        let history = HistoryItem(
            content: try ClipContent.detect(text: "Reviewed source"),
            createdAt: Date()
        )
        let model = makeModel(libraryPersistence: InMemoryClipboardLibraryStore(
            snapshot: ClipboardLibrarySnapshot(history: [history])
        ))
        await model.start()
        model.addToCombinedClips(presentedClip(history))
        model.prepareCombinedClipsReview()
        guard let request = model.pendingCombinedClipsReview else {
            XCTFail(model.errorMessage ?? "Combine Clips review was not created")
            return
        }

        model.clearCombinedClips()

        XCTAssertNil(model.combinedClipsMarkdown(for: request))
        XCTAssertEqual(
            model.errorMessage,
            AppModelOperationError.combinedClipsChanged.localizedDescription
        )
        let didSave = await model.saveCombinedClipsAsNote(request)
        XCTAssertFalse(didSave)
        XCTAssertTrue(model.snapshot.savedClips.isEmpty)
    }

    func testDebugBundleReviewUsesCoreClassificationAndReviewedMarkdownForActions() async throws {
        let writer = FakeTypedPasteboardWriter()
        let now = Date()
        let first = HistoryItem(
            content: try ClipContent.detect(
                text: "import Foundation\nfunc greet() { print(\"hello\") }"
            ),
            createdAt: now.addingTimeInterval(-10)
        )
        let second = HistoryItem(
            content: try ClipContent.detect(text: "error: build failed with exit code 1"),
            createdAt: now
        )
        let model = makeModel(
            typedWriter: writer,
            libraryPersistence: InMemoryClipboardLibraryStore(
                snapshot: ClipboardLibrarySnapshot(history: [first, second])
            )
        )
        await model.start()
        model.addToDebugBundle(presentedClip(first))
        model.addToDebugBundle(presentedClip(second))
        model.prepareDebugBundleReview()
        guard let request = model.pendingDebugBundleReview,
              let review = model.debugBundleReview(
                for: request,
                projectDisplayName: "Compiler",
                problemStatement: "Why does the build fail?"
              )
        else {
            XCTFail(model.errorMessage ?? "Debug Bundle review was not created")
            return
        }

        model.copyDebugBundle(
            request,
            projectDisplayName: "Compiler",
            problemStatement: "Why does the build fail?"
        )
        let copied = await waitUntil { writer.writtenContents.count == 1 }
        let saved = await model.saveDebugBundleAsNote(
            request,
            projectDisplayName: "Compiler",
            problemStatement: "Why does the build fail?"
        )

        XCTAssertEqual(
            DebugBundleWorkflowObservation(
                badges: review.bundle.items.map {
                    DeveloperFeatureModel.badgeLabel(for: $0.analysis)
                },
                containsProject: review.markdown.contains("# Debug Bundle: Compiler"),
                containsProblem: review.markdown.contains("Why does the build fail?"),
                copied: copied,
                copiedMarkdown: writer.writtenContents.first?.text,
                saved: saved,
                savedMarkdown: model.snapshot.savedClips.first?.content.text
            ),
            DebugBundleWorkflowObservation(
                badges: ["Code", "Error"],
                containsProject: true,
                containsProblem: true,
                copied: true,
                copiedMarkdown: review.markdown,
                saved: true,
                savedMarkdown: review.markdown
            )
        )
    }

    func testDebugBundleActionsRejectSourcesRemovedAfterReview() async throws {
        let writer = FakeTypedPasteboardWriter()
        let history = HistoryItem(
            content: try ClipContent.detect(text: "let value = 42"),
            createdAt: Date()
        )
        let model = makeModel(
            typedWriter: writer,
            libraryPersistence: InMemoryClipboardLibraryStore(
                snapshot: ClipboardLibrarySnapshot(history: [history])
            )
        )
        await model.start()
        model.addToDebugBundle(presentedClip(history))
        model.prepareDebugBundleReview()
        guard let request = model.pendingDebugBundleReview else {
            XCTFail(model.errorMessage ?? "Debug Bundle review was not created")
            return
        }

        model.clearDebugBundle()
        model.copyDebugBundle(
            request,
            projectDisplayName: "Stale",
            problemStatement: ""
        )
        let saved = await model.saveDebugBundleAsNote(
            request,
            projectDisplayName: "Stale",
            problemStatement: ""
        )

        XCTAssertEqual(
            DebugBundleStaleObservation(
                copiedCount: writer.writtenContents.count,
                saved: saved,
                savedCount: model.snapshot.savedClips.count,
                errorMessage: model.errorMessage
            ),
            DebugBundleStaleObservation(
                copiedCount: 0,
                saved: false,
                savedCount: 0,
                errorMessage: AppModelOperationError.debugBundleChanged.localizedDescription
            )
        )
    }

    func testDebugBundleAssistantCopyRevalidatesSourcesAndGeneratedContent() async throws {
        let writer = FakeTypedPasteboardWriter()
        let history = HistoryItem(
            content: try ClipContent.detect(text: "let value = 42"),
            createdAt: Date()
        )
        let model = makeModel(
            typedWriter: writer,
            libraryPersistence: InMemoryClipboardLibraryStore(
                snapshot: ClipboardLibrarySnapshot(history: [history])
            )
        )
        await model.start()
        model.addToDebugBundle(presentedClip(history))
        model.prepareDebugBundleReview()
        guard let request = model.pendingDebugBundleReview else {
            return XCTFail(model.errorMessage ?? "Debug Bundle review was not created")
        }

        let savedUnsafeProvenance = await model.saveDebugBundleAIDraft(
            "ordinary response",
            request: request,
            modelProvenance: "sk-proj-abcdefghijklmnopqrstuvwxyz012345"
        )
        XCTAssertFalse(savedUnsafeProvenance)
        XCTAssertTrue(model.snapshot.savedClips.isEmpty)
        XCTAssertEqual(
            model.errorMessage,
            AppModelOperationError.generatedSensitiveContent.localizedDescription
        )
        model.errorMessage = nil

        model.copyDebugBundleAssistantResponse(
            "sk-proj-abcdefghijklmnopqrstuvwxyz012345",
            request: request
        )
        XCTAssertTrue(writer.writtenContents.isEmpty)
        XCTAssertEqual(
            model.errorMessage,
            AppModelOperationError.generatedSensitiveContent.localizedDescription
        )

        model.errorMessage = nil
        model.clearDebugBundle()
        model.copyDebugBundleAssistantResponse("ordinary response", request: request)
        let rejectedStaleSource = await waitUntil {
            model.errorMessage == AppModelOperationError.debugBundleChanged.localizedDescription
        }
        XCTAssertTrue(rejectedStaleSource)
        XCTAssertTrue(writer.writtenContents.isEmpty)
    }

    func testCombineClipsRejectsSecretLikeRenderedMetadata() async throws {
        let context = ClipCaptureContext(
            sourceApplicationName: "sk-proj-abcdefghijklmnopqrstuvwxyz123456",
            sourceURL: "https://example.com/private"
        )
        let history = HistoryItem(
            content: try ClipContent.detect(text: "Ordinary body"),
            createdAt: Date(),
            captureContext: context
        )
        let model = makeModel(libraryPersistence: InMemoryClipboardLibraryStore(
            snapshot: ClipboardLibrarySnapshot(history: [history])
        ))
        await model.start()

        model.addToCombinedClips(presentedClip(history))
        model.prepareCombinedClipsReview()

        XCTAssertNil(model.pendingCombinedClipsReview)
        XCTAssertEqual(
            model.errorMessage,
            AppModelOperationError.combinedClipsChanged.localizedDescription
        )
    }

    func testTransformPreviewRejectsSecretRevealedByURLDecoding() async throws {
        let encodedSecret = "sk%2Dproj%2Dabcdefghijklmnopqrstuvwxyz012345"
        let history = HistoryItem(
            content: try ClipContent.detect(text: encodedSecret),
            createdAt: Date()
        )
        let model = makeModel(libraryPersistence: InMemoryClipboardLibraryStore(
            snapshot: ClipboardLibrarySnapshot(history: [history])
        ))
        await model.start()

        model.previewTransform(.urlDecode, title: "URL Decode", for: presentedClip(history))

        XCTAssertNil(model.transformPreview)
        XCTAssertEqual(
            model.errorMessage,
            "The transformed result contains a secret-like value and cannot be previewed or copied."
        )
    }

    func testSaveHistoryClipInNewFolderSelectsCreatedFolderAndSavedClip() async throws {
        let model = makeModel()
        await model.start()
        model.capture(PasteboardCaptureDraft(
            changeCount: 1,
            typeIdentifiers: [],
            plainText: "new destination clip"
        ))
        let captured = await waitUntil { !model.menuBarRecentClips.isEmpty }
        XCTAssertTrue(captured)
        let historyClip = try XCTUnwrap(model.menuBarRecentClips.first)

        try await model.saveHistoryClipInNewFolder(historyClip, named: "  Discovery  ")

        let folder = try XCTUnwrap(model.snapshot.folders.first)
        let savedClip = try XCTUnwrap(model.snapshot.savedClips.first)
        XCTAssertEqual(folder.name, "Discovery")
        XCTAssertEqual(savedClip.folderID, folder.id)
        XCTAssertEqual(model.selectedSection, .folder(folder.id))
        XCTAssertEqual(model.selectedClipID, savedClip.id)
    }

    func testSaveHistoryClipInNewFolderRejectsUnavailableLibraryAndNonHistoryClip() async throws {
        let unavailableModel = makeModel()
        let historyClip = try presentedClip("history-only")

        do {
            try await unavailableModel.saveHistoryClipInNewFolder(historyClip, named: "Folder")
            XCTFail("Expected unavailable library error")
        } catch {
            XCTAssertEqual(error as? AppModelOperationError, .libraryUnavailable)
        }

        let model = makeModel()
        await model.start()
        let savedClip = PresentedClip(
            id: UUID(),
            title: "Saved",
            content: try ClipContent.detect(text: "already saved"),
            date: Date(),
            sourceBundleIdentifier: nil,
            origin: .saved(folderID: nil)
        )
        do {
            try await model.saveHistoryClipInNewFolder(savedClip, named: "Folder")
            XCTFail("Expected history-only error")
        } catch {
            XCTAssertEqual(error as? AppModelOperationError, .historyClipRequired)
        }
    }

    func testClipContextMenuPolicyKeepsManagementPrimaryAndPrivateSessionIsolated() throws {
        let model = makeModel()
        let history = try presentedClip("History")
        let savedFolderID = UUID()
        let saved = PresentedClip(
            id: UUID(),
            title: "Saved",
            content: try ClipContent.detect(text: "saved"),
            date: Date(),
            sourceBundleIdentifier: nil,
            origin: .saved(folderID: savedFolderID)
        )
        let privateClip = PresentedClip(
            id: UUID(),
            title: "Private",
            content: try ClipContent.detect(text: "private"),
            date: Date(),
            sourceBundleIdentifier: nil,
            origin: .privateSession
        )

        let historyPolicy = model.clipContextMenuPolicy(for: history)
        XCTAssertEqual(historyPolicy.organization, .saveToFolder)
        XCTAssertTrue(historyPolicy.canShareClip)
        XCTAssertTrue(historyPolicy.canExportClip)
        XCTAssertTrue(historyPolicy.canUseWorkflows)
        XCTAssertTrue(historyPolicy.canRouteToAI)
        XCTAssertFalse(historyPolicy.showsSavedClipControls)

        let savedPolicy = model.clipContextMenuPolicy(for: saved)
        XCTAssertEqual(savedPolicy.organization, .moveToFolder)
        XCTAssertTrue(savedPolicy.showsSavedClipControls)
        XCTAssertTrue(savedPolicy.canMutateSavedClip)
        XCTAssertEqual(savedPolicy.folderID, savedFolderID)

        let privatePolicy = model.clipContextMenuPolicy(for: privateClip)
        XCTAssertEqual(privatePolicy.organization, .none)
        XCTAssertFalse(privatePolicy.canShareClip)
        XCTAssertFalse(privatePolicy.canExportClip)
        XCTAssertFalse(privatePolicy.canUseWorkflows)
        XCTAssertFalse(privatePolicy.canRouteToAI)
        XCTAssertFalse(privatePolicy.showsDelete)

        let sensitive = PresentedClip(
            id: UUID(),
            title: "Sensitive",
            content: try ClipContent.detect(text: "api_key=sk-proj-abcdefghijklmnopqrstuvwxyz123456"),
            date: Date(),
            sourceBundleIdentifier: nil,
            origin: .history,
            sensitivity: try ClipSensitivityMetadata(
                category: "api-key",
                confidence: 100,
                detectorVersion: 1
            )
        )
        let sensitivePolicy = model.clipContextMenuPolicy(for: sensitive)
        XCTAssertFalse(sensitivePolicy.canShareClip)
        XCTAssertFalse(model.canEditClip(sensitive))

        model.route(privateClip, to: DestinationRegistry.destination(id: .chatGPT))
        XCTAssertEqual(
            model.errorMessage,
            "Private Session clips cannot be opened in external AI apps. Copy explicitly if you intend to move this content outside the session."
        )
    }

    func testSingleClipArchiveSelectionPreservesHistoryMetadataAndRejectsPrivateSession() async throws {
        let model = makeModel()
        await model.start()
        model.capture(PasteboardCaptureDraft(
            changeCount: 2,
            typeIdentifiers: ["public.utf8-plain-text"],
            plainText: "archive this clip",
            source: PasteboardCaptureSource(
                applicationBundleIdentifier: "com.example.source"
            )
        ))
        let captured = await waitUntil { !model.menuBarRecentClips.isEmpty }
        XCTAssertTrue(captured)
        let history = try XCTUnwrap(model.menuBarRecentClips.first)

        let selection = try model.archiveSelection(for: history)
        XCTAssertEqual(selection.clip.id, history.id)
        XCTAssertEqual(selection.clip.content, history.content)
        XCTAssertEqual(selection.clip.sourceHistoryItemID, history.id)
        XCTAssertEqual(selection.clip.sourceApplicationBundleIdentifier, "com.example.source")
        XCTAssertTrue(selection.folders.isEmpty)

        let privateClip = PresentedClip(
            id: UUID(),
            title: "Private",
            content: try ClipContent.detect(text: "private"),
            date: Date(),
            sourceBundleIdentifier: nil,
            origin: .privateSession
        )
        XCTAssertThrowsError(try model.archiveSelection(for: privateClip)) { caught in
            XCTAssertEqual(caught as? AppModelOperationError, .ordinaryClipRequired)
        }

        XCTAssertEqual(
            AppModel.safeExportFilename("  Research/notes:\nQ3  "),
            "Research notes Q3"
        )
        XCTAssertEqual(AppModel.safeExportFilename("/\n:"), "Clip")

        let fileReference = try ClipFileReference(
            url: URL(fileURLWithPath: "/tmp/local-reference.txt")
        )
        let localFileClip = PresentedClip(
            id: UUID(),
            title: "Local file",
            content: try ClipContent(
                type: .fileURLs,
                text: fileReference.displayName,
                representations: ClipRepresentations(files: [fileReference])
            ),
            date: Date(),
            sourceBundleIdentifier: nil,
            origin: .history
        )
        XCTAssertEqual(
            model.clipExportDecision(localFileClip),
            .unavailable(
                reason: AppModelOperationError.localFileArchiveUnsupported.localizedDescription
            )
        )
        let legacyStructuredFileURL = try ClipContent(
            type: .url,
            text: "file:///tmp/legacy-reference.txt",
            representations: ClipRepresentations(
                url: URLClipMetadata(originalURL: "file:///tmp/legacy-reference.txt")
            )
        )
        XCTAssertTrue(AppModel.containsNonPortableLocalReference(legacyStructuredFileURL))
    }

    func testOrdinarySearchIsGlobalRankedAndRestoresPreviousSectionWhenCleared() async throws {
        let model = makeModel()
        await model.start()
        model.capture(PasteboardCaptureDraft(
            changeCount: 20,
            typeIdentifiers: ["public.utf8-plain-text"],
            plainText: "global metadata needle",
            source: PasteboardCaptureSource(
                applicationBundleIdentifier: "com.apple.Safari",
                applicationName: "Safari",
                sourceDomain: "example.com"
            )
        ))
        let captured = await waitUntil { model.snapshot.history.count == 1 }
        XCTAssertTrue(captured)
        let history = try XCTUnwrap(model.menuBarRecentClips.first)
        try await model.saveHistoryClipInNewFolder(history, named: "Research")
        let folder = try XCTUnwrap(model.snapshot.folders.first)
        XCTAssertEqual(model.selectedSection, .folder(folder.id))

        model.searchText = "global metadata needle"
        model.updateSearch()
        let searched = await waitUntil { model.searchResults.count == 2 }
        XCTAssertTrue(searched)

        XCTAssertEqual(model.selectedSection, .searchResults)
        XCTAssertEqual(
            model.clipsForSelectedSection.map(\.id),
            model.searchResults.map(\.id),
            "The App layer must preserve Core's relevance order instead of re-sorting by section."
        )
        XCTAssertTrue(model.clipsForSelectedSection.contains { clip in
            if case .history = clip.origin { return true }
            return false
        })
        XCTAssertTrue(model.clipsForSelectedSection.contains { clip in
            if case .saved = clip.origin { return true }
            return false
        })
        XCTAssertEqual(
            model.clipsForSelectedSection.first(where: {
                if case .saved = $0.origin { return true }
                return false
            }).map(model.clipOriginContext),
            "Saved · Research"
        )

        model.clearOrdinarySearch()
        XCTAssertEqual(model.selectedSection, .folder(folder.id))
        XCTAssertTrue(model.searchText.isEmpty)
        XCTAssertTrue(model.searchResults.isEmpty)
    }

    func testSmartViewsApplyAuthoritativeQueryRecipesAndExposeDynamicFacets() async throws {
        let model = makeModel()
        await model.start()
        model.capture(PasteboardCaptureDraft(
            changeCount: 21,
            typeIdentifiers: ["public.url"],
            url: URL(string: "https://docs.example.com/guide"),
            source: PasteboardCaptureSource(
                applicationBundleIdentifier: "com.apple.Safari",
                applicationName: "Safari",
                sourceDomain: "docs.example.com"
            )
        ))
        let captured = await waitUntil { model.snapshot.history.count == 1 }
        XCTAssertTrue(captured)

        let recipes = Dictionary(uniqueKeysWithValues: model.staticSmartViews.map { ($0.id, $0.query) })
        XCTAssertEqual(recipes[.frequentlyUsed], "captures:>=2")
        XCTAssertEqual(recipes[.links], "type:url")
        XCTAssertEqual(recipes[.images], "type:image")
        XCTAssertEqual(recipes[.files], "type:file")
        XCTAssertEqual(recipes[.pdfs], "type:pdf")
        XCTAssertEqual(recipes[.sensitiveReview], "secret:*")
        XCTAssertEqual(recipes[.unfiledSaved], "origin:saved folder:unfiled")
        XCTAssertEqual(recipes[.pinnedSaved], "origin:saved pinned:true")
        XCTAssertTrue(recipes[.today]?.hasPrefix("date:") == true)

        let appView = try XCTUnwrap(model.applicationSmartViews.first)
        XCTAssertEqual(appView.title, "Safari")
        XCTAssertEqual(appView.query, "sourceexact:com.apple.Safari")
        let domainView = try XCTUnwrap(model.domainSmartViews.first)
        XCTAssertEqual(domainView.title, "docs.example.com")
        XCTAssertEqual(domainView.query, "domainexact:docs.example.com")

        model.applySmartView(.links)
        XCTAssertEqual(model.selectedSection, .smartView(.links))
        XCTAssertEqual(model.activeSmartViewID, .links)
        XCTAssertEqual(model.searchText, "type:url")
        let filtered = await waitUntil {
            model.searchResults.map(\.id) == model.snapshot.history.map(\.id)
        }
        XCTAssertTrue(filtered)
        XCTAssertEqual(model.activeSearchChips.map(\.label), ["Type: url"])

        model.searchText = "type:url source:Safari"
        model.updateSearch()
        XCTAssertNil(model.activeSmartViewID)
        XCTAssertEqual(model.selectedSection, .searchResults)
        XCTAssertEqual(model.searchText, "type:url source:Safari")

        model.applySmartView(.links)
        XCTAssertEqual(model.activeSmartViewID, .links)
        XCTAssertEqual(model.selectedSection, .smartView(.links))

        let chip = try XCTUnwrap(model.activeSearchChips.first)
        model.removeSearchChip(chip)
        XCTAssertTrue(model.searchText.isEmpty)
        XCTAssertEqual(model.selectedSection, .history)
    }

    func testDynamicSmartViewBadgesUseTheSameExactFacetAsTheirQueries() async throws {
        let model = makeModel()
        await model.start()
        model.capture(PasteboardCaptureDraft(
            changeCount: 31,
            typeIdentifiers: ["public.utf8-plain-text"],
            plainText: "studio clip",
            source: PasteboardCaptureSource(applicationName: "Visual Studio")
        ))
        model.capture(PasteboardCaptureDraft(
            changeCount: 32,
            typeIdentifiers: ["public.utf8-plain-text"],
            plainText: "designer clip",
            source: PasteboardCaptureSource(applicationName: "Visual Designer")
        ))
        model.capture(PasteboardCaptureDraft(
            changeCount: 33,
            typeIdentifiers: ["public.url"],
            url: URL(string: "https://example.com/root"),
            source: PasteboardCaptureSource(
                applicationBundleIdentifier: "com.apple.Safari",
                applicationName: "Safari",
                sourceDomain: "example.com"
            )
        ))
        model.capture(PasteboardCaptureDraft(
            changeCount: 34,
            typeIdentifiers: ["public.url"],
            url: URL(string: "https://docs.example.com/guide"),
            source: PasteboardCaptureSource(
                applicationBundleIdentifier: "com.apple.Safari",
                applicationName: "Safari",
                sourceDomain: "docs.example.com"
            )
        ))
        let capturedAll = await waitUntil { model.snapshot.history.count == 4 }
        XCTAssertTrue(capturedAll)

        let appView = try XCTUnwrap(model.applicationSmartViews.first { $0.title == "Visual Studio" })
        XCTAssertEqual(appView.query, "sourceexact:Visual+Studio")
        XCTAssertEqual(appView.count, 1)
        model.applySmartView(appView.id)
        let appResultsMatchBadge = await waitUntil {
            model.searchResults.count == appView.count
                && model.searchResults.first?.captureContext?.sourceApplicationName == "Visual Studio"
        }
        XCTAssertTrue(appResultsMatchBadge)
        XCTAssertEqual(model.searchResults.first?.captureContext?.sourceApplicationName, "Visual Studio")

        let domainView = try XCTUnwrap(model.domainSmartViews.first { $0.title == "example.com" })
        XCTAssertEqual(domainView.query, "domainexact:example.com")
        XCTAssertEqual(domainView.count, 1)
        model.applySmartView(domainView.id)
        let domainResultsMatchBadge = await waitUntil {
            model.searchResults.count == domainView.count
                && model.searchResults.first?.captureContext?.sourceDomain == "example.com"
        }
        XCTAssertTrue(domainResultsMatchBadge)
        XCTAssertEqual(model.searchResults.first?.captureContext?.sourceDomain, "example.com")
    }

    func testOrdinarySearchAndSmartViewsExcludePrivateSessionAndSecureSections() async throws {
        let model = makeModel()
        await model.start()
        model.startPrivateSession()
        let started = await waitUntil { model.isPrivateSessionActive }
        XCTAssertTrue(started)
        model.capture(PasteboardCaptureDraft(
            changeCount: 22,
            typeIdentifiers: ["public.utf8-plain-text"],
            plainText: "memory-only-private-needle"
        ))
        let captured = await waitUntil { model.privateSessionClips.count == 1 }
        XCTAssertTrue(captured)

        model.selectLibrarySection(.privateSession)
        XCTAssertFalse(model.isOrdinarySearchAvailable)
        model.searchText = "memory-only-private-needle"
        model.updateSearch()
        try await Task.sleep(for: .milliseconds(160))
        XCTAssertEqual(model.selectedSection, .privateSession)
        XCTAssertTrue(model.searchResults.isEmpty)

        model.selectLibrarySection(.history)
        model.searchText = "memory-only-private-needle"
        model.updateSearch()
        try await Task.sleep(for: .milliseconds(160))
        XCTAssertEqual(model.selectedSection, .searchResults)
        XCTAssertTrue(model.searchResults.isEmpty)
        XCTAssertTrue(model.clipsForSelectedSection.isEmpty)

        model.selectLibrarySection(.vault)
        XCTAssertFalse(model.isOrdinarySearchAvailable)
        XCTAssertTrue(model.searchText.isEmpty)
        XCTAssertTrue(model.searchResults.isEmpty)
    }

    func testSelectingCurrentLibrarySectionIsIdempotent() async {
        let model = makeModel()
        await model.start()
        let selectedClipID = UUID()
        model.selectedClipID = selectedClipID

        model.selectLibrarySection(.history)

        XCTAssertEqual(model.selectedSection, .history)
        XCTAssertEqual(model.selectedClipID, selectedClipID)
    }

    func testSwitchingLibrarySectionRebuildsClipTableAndClearsStaleSelection() async {
        let model = makeModel()
        await model.start()
        let staleClipID = UUID()
        model.selectedClipID = staleClipID

        let historyIdentity = ClipTablePresentation.sectionIdentity(model.selectedSection)
        model.selectLibrarySection(.allSaved)
        let savedIdentity = ClipTablePresentation.sectionIdentity(model.selectedSection)

        XCTAssertNotEqual(historyIdentity, savedIdentity)
        XCTAssertNil(model.selectedClipID)
        XCTAssertTrue(model.selectedClipIDs.isEmpty)
        XCTAssertEqual(
            savedIdentity,
            ClipTablePresentation.sectionIdentity(.allSaved),
            "Repeated updates within one section must retain the same native Table identity"
        )
    }

    func testFileAndPDFSmartViewBadgesMatchTheirExactQueryResults() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SmartViewFileParity-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let textURL = directory.appendingPathComponent("notes.txt")
        let pdfURL = directory.appendingPathComponent("brief.pdf")
        try Data("notes".utf8).write(to: textURL)
        try Data("%PDF-1.4\n".utf8).write(to: pdfURL)

        let model = makeModel()
        await model.start()
        model.capture(PasteboardCaptureDraft(
            changeCount: 30,
            typeIdentifiers: ["public.file-url"],
            fileURLs: [textURL]
        ))
        let firstCaptured = await waitUntil { model.snapshot.history.count == 1 }
        XCTAssertTrue(firstCaptured)
        model.capture(PasteboardCaptureDraft(
            changeCount: 31,
            typeIdentifiers: ["public.file-url", "com.adobe.pdf"],
            fileURLs: [pdfURL]
        ))
        let secondCaptured = await waitUntil { model.snapshot.history.count == 2 }
        XCTAssertTrue(secondCaptured)

        let fileView = try XCTUnwrap(model.staticSmartViews.first { $0.id == .files })
        XCTAssertEqual(fileView.count, 2)
        model.applySmartView(.files)
        let filesFiltered = await waitUntil { model.searchResults.count == fileView.count }
        XCTAssertTrue(filesFiltered)
        XCTAssertTrue(model.searchResults.allSatisfy { $0.content.type == .fileURLs })

        let pdfView = try XCTUnwrap(model.staticSmartViews.first { $0.id == .pdfs })
        XCTAssertEqual(pdfView.count, 1)
        model.applySmartView(.pdfs)
        let pdfsFiltered = await waitUntil { model.searchResults.count == pdfView.count }
        XCTAssertTrue(pdfsFiltered)
        XCTAssertEqual(model.searchResults.first?.content.representations.files.first?.url, pdfURL)
    }

    func testFrequentlyUsedBadgeMatchesLinkedSavedUsageQueryResults() async throws {
        let model = makeModel()
        await model.start()
        let draft = { (changeCount: Int) in
            PasteboardCaptureDraft(
                changeCount: changeCount,
                typeIdentifiers: ["public.utf8-plain-text"],
                plainText: "frequently reused clip"
            )
        }
        model.capture(draft(40))
        let firstCaptured = await waitUntil { model.snapshot.history.count == 1 }
        XCTAssertTrue(firstCaptured)
        model.capture(draft(41))
        let recaptured = await waitUntil { model.snapshot.history.first?.captureCount == 2 }
        XCTAssertTrue(recaptured)
        let history = try XCTUnwrap(model.menuBarRecentClips.first)
        try await model.saveHistoryClipInNewFolder(history, named: "Reusable")

        let view = try XCTUnwrap(model.staticSmartViews.first { $0.id == .frequentlyUsed })
        XCTAssertEqual(view.query, "captures:>=2")
        XCTAssertEqual(view.count, 2, "History and its linked Saved result share the usage counters.")
        model.applySmartView(.frequentlyUsed)
        let filtered = await waitUntil { model.searchResults.count == view.count }
        XCTAssertTrue(filtered)
        XCTAssertTrue(model.searchResults.allSatisfy { $0.captureCount >= 2 })
    }

    func testPasteStackAdvancesOnlyAfterTypedClipboardWriteSucceeds() async throws {
        let writer = FakeTypedPasteboardWriter()
        let now = Date()
        let firstItem = HistoryItem(
            content: try ClipContent.detect(text: "first"),
            createdAt: now
        )
        let secondItem = HistoryItem(
            content: try ClipContent.detect(text: "second"),
            createdAt: now.addingTimeInterval(1)
        )
        let model = makeModel(
            typedWriter: writer,
            libraryPersistence: InMemoryClipboardLibraryStore(
                snapshot: ClipboardLibrarySnapshot(history: [firstItem, secondItem])
            )
        )
        await model.start()
        let first = presentedClip(firstItem)
        let second = presentedClip(secondItem)
        model.addToPasteStack(first)
        model.addToPasteStack(second)

        writer.shouldFail = true
        model.copyNextPasteStackItem()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(model.pasteStackCurrentIndex, 0)

        writer.shouldFail = false
        model.copyNextPasteStackItem()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(model.pasteStackCurrentIndex, 1)
        XCTAssertEqual(writer.writtenContents, [first.content])
    }

    func testPasteStackRejectsConcurrentControlsUntilWriteFinishes() async throws {
        let writer = FakeTypedPasteboardWriter()
        writer.delayMilliseconds = 100
        let now = Date()
        let firstItem = HistoryItem(
            content: try ClipContent.detect(text: "first"),
            createdAt: now
        )
        let secondItem = HistoryItem(
            content: try ClipContent.detect(text: "second"),
            createdAt: now.addingTimeInterval(1)
        )
        let model = makeModel(
            typedWriter: writer,
            libraryPersistence: InMemoryClipboardLibraryStore(
                snapshot: ClipboardLibrarySnapshot(history: [firstItem, secondItem])
            )
        )
        await model.start()
        let first = presentedClip(firstItem)
        let second = presentedClip(secondItem)
        model.addToPasteStack(first)
        model.addToPasteStack(second)

        model.copyNextPasteStackItem()
        model.copyNextPasteStackItem()
        model.skipPasteStackItem()
        XCTAssertTrue(model.isPasteStackWriteInFlight)
        XCTAssertEqual(model.pasteStackCurrentIndex, 0)

        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(model.isPasteStackWriteInFlight)
        XCTAssertEqual(model.pasteStackCurrentIndex, 1)
        XCTAssertEqual(writer.writtenContents, [first.content])
    }

    func testOrdinaryClipboardActionsRunInClickOrderWithoutOverlappingWrites() async throws {
        let writer = FakeTypedPasteboardWriter()
        writer.delayMilliseconds = 50
        let model = makeModel(typedWriter: writer)
        let first = try presentedClip("first queued copy")
        let second = try presentedClip("second queued copy")

        model.copy(first)
        model.copy(second)
        try await Task.sleep(for: .milliseconds(140))

        XCTAssertEqual(writer.writtenContents, [first.content, second.content])
        XCTAssertEqual(writer.maximumConcurrentWriteCount, 1)
    }

    func testTypedCopyPasteAndPasteStackForwardCapturedSourceTypeIdentifiers() async throws {
        let writer = FakeTypedPasteboardWriter()
        let identifiers = ["public.html", "public.utf8-plain-text"]
        let history = HistoryItem(
            content: try ClipContent.detect(text: "typed source"),
            createdAt: Date(),
            pasteboardTypeIdentifiers: identifiers
        )
        let model = makeModel(
            typedWriter: writer,
            libraryPersistence: InMemoryClipboardLibraryStore(
                snapshot: ClipboardLibrarySnapshot(history: [history])
            )
        )
        await model.start()
        let clip = PresentedClip(
            id: history.id,
            title: "typed source",
            content: history.content,
            date: history.createdAt,
            sourceBundleIdentifier: nil,
            origin: .history,
            pasteboardTypeIdentifiers: identifiers
        )

        model.copy(clip)
        model.pasteIntoRememberedApplication(clip)
        model.addToPasteStack(clip)
        model.copyNextPasteStackItem()
        let wroteAll = await waitUntil { writer.writtenContents.count == 3 }

        XCTAssertTrue(wroteAll)
        XCTAssertEqual(writer.writtenSourceTypeIdentifiers, [identifiers, identifiers, identifiers])
    }

    func testPrivateSessionStartAndEndPublishMemoryOnlyState() async throws {
        let model = makeModel()
        await model.start()

        model.startPrivateSession()
        let started = await waitUntil { model.isPrivateSessionActive }
        XCTAssertTrue(started)
        XCTAssertEqual(model.selectedSection, .privateSession)

        model.capture(
            PasteboardCaptureDraft(
                changeCount: 1,
                typeIdentifiers: ["public.utf8-plain-text"],
                plainText: "active-private-session-clip"
            )
        )
        let captured = await waitUntil { model.privateSessionClips.count == 1 }
        XCTAssertTrue(captured)

        model.endPrivateSession()
        XCTAssertFalse(model.isPrivateSessionActive)
        XCTAssertTrue(model.privateSessionClips.isEmpty)
        XCTAssertEqual(model.selectedSection, .history)
    }

    func testCaptureDuringPrivateSessionStartupCannotEnterHistory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrivateSessionStartupCapture-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = makeModel(
            ocrService: DelayedOCRService(delayMilliseconds: 100),
            supportDirectory: directory
        )
        await model.start()

        model.capture(
            PasteboardCaptureDraft(
                changeCount: 1,
                typeIdentifiers: ["public.png"],
                image: PasteboardImageDraft(
                    data: Data("not-a-real-image-needed-by-fake-ocr".utf8),
                    uniformTypeIdentifier: "public.png"
                )
            )
        )
        try await Task.sleep(for: .milliseconds(20))
        model.startPrivateSession()
        XCTAssertTrue(model.isStartingPrivateSession || model.isPrivateSessionActive)

        try await Task.sleep(for: .milliseconds(180))

        XCTAssertTrue(model.isPrivateSessionActive)
        XCTAssertTrue(model.snapshot.history.isEmpty)
        XCTAssertTrue(model.privateSessionClips.isEmpty)
    }

    func testPrivateSessionClipsCannotEscapeIntoDerivedWorkflows() throws {
        let model = makeModel()
        let privateClip = PresentedClip(
            id: UUID(),
            title: "private",
            content: try ClipContent.detect(text: "private"),
            date: Date(),
            sourceBundleIdentifier: nil,
            origin: .privateSession
        )

        model.addToCombinedClips(privateClip)
        model.addToPasteStack(privateClip)
        model.previewTransform(.trim, title: "Trim", for: privateClip)

        XCTAssertNil(model.combinedClips)
        XCTAssertTrue(model.pasteStackItems.isEmpty)
        XCTAssertNil(model.transformPreview)
    }

    func testClipObservedDuringPrivateSessionCannotPersistAfterEndDuringOCR() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrivateSessionCapture-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = makeModel(
            ocrService: DelayedOCRService(delayMilliseconds: 100),
            supportDirectory: directory
        )
        await model.start()
        model.startPrivateSession()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(model.isPrivateSessionActive)

        model.capture(
            PasteboardCaptureDraft(
                changeCount: 1,
                typeIdentifiers: ["public.png"],
                image: PasteboardImageDraft(
                    data: Data("not-a-real-image-needed-by-fake-ocr".utf8),
                    uniformTypeIdentifier: "public.png"
                )
            )
        )
        try await Task.sleep(for: .milliseconds(20))
        model.endPrivateSession()
        try await Task.sleep(for: .milliseconds(180))

        XCTAssertTrue(model.snapshot.history.isEmpty)
        XCTAssertTrue(model.privateSessionClips.isEmpty)
    }

    func testPrivateSessionEndDuringSecretOCRLeavesNoQuarantineOrHistory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrivateSecretCapture-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = makeModel(
            ocrService: DelayedOCRService(
                delayMilliseconds: 100,
                result: "sk-proj-abcdefghijklmnopqrstuvwxyz123456"
            ),
            supportDirectory: directory
        )
        await model.start()
        model.startPrivateSession()
        try await Task.sleep(for: .milliseconds(20))
        model.capture(
            PasteboardCaptureDraft(
                changeCount: 2,
                typeIdentifiers: ["public.png"],
                image: PasteboardImageDraft(
                    data: Data("private-image".utf8),
                    uniformTypeIdentifier: "public.png"
                )
            )
        )
        try await Task.sleep(for: .milliseconds(20))
        model.endPrivateSession()
        try await Task.sleep(for: .milliseconds(180))

        XCTAssertTrue(model.snapshot.history.isEmpty)
        XCTAssertTrue(model.privateSessionClips.isEmpty)
        XCTAssertTrue(model.quarantineReceipts.isEmpty)
        XCTAssertEqual(model.clipboardHealth.quarantinedClipCount, 0)
    }

    func testEndingPrivateSessionCannotBeRepaintedByAwaitedSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrivateSnapshotRace-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = makeModel(supportDirectory: directory)
        await model.start()
        model.startPrivateSession()
        try await Task.sleep(for: .milliseconds(20))
        model.capture(
            PasteboardCaptureDraft(
                changeCount: 3,
                typeIdentifiers: ["public.utf8-plain-text"],
                plainText: "ephemeral"
            )
        )
        model.endPrivateSession()
        try await Task.sleep(for: .milliseconds(80))

        XCTAssertFalse(model.isPrivateSessionActive)
        XCTAssertTrue(model.privateSessionClips.isEmpty)
        XCTAssertTrue(model.snapshot.history.isEmpty)
    }

    func testQuarantineExpirationTimerClearsReceiptsAtDeadline() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuarantineTimer-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = makeModel(
            supportDirectory: directory,
            quarantineStore: QuarantineStore(timeToLive: 0.05)
        )
        await model.start()
        model.capture(
            PasteboardCaptureDraft(
                changeCount: 4,
                typeIdentifiers: ["public.utf8-plain-text"],
                plainText: "sk-proj-abcdefghijklmnopqrstuvwxyz123456"
            )
        )
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(model.quarantineReceipts.count, 1)

        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(model.quarantineReceipts.isEmpty)
        XCTAssertEqual(model.clipboardHealth.quarantinedClipCount, 0)
    }

    func testExplicitlyKeptSecretRetainsSensitivityClassification() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeptSecretClassification-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = makeModel(supportDirectory: directory)
        await model.start()
        model.capture(
            PasteboardCaptureDraft(
                changeCount: 5,
                typeIdentifiers: ["public.utf8-plain-text"],
                plainText: "sk-proj-abcdefghijklmnopqrstuvwxyz123456"
            )
        )
        try await Task.sleep(for: .milliseconds(30))
        let receipt = try XCTUnwrap(model.quarantineReceipts.first)

        model.keepQuarantinedClip(id: receipt.id)
        try await Task.sleep(for: .milliseconds(60))

        let kept = try XCTUnwrap(model.snapshot.history.first)
        XCTAssertEqual(kept.sensitivity?.category, "openAIAPIKey")
        XCTAssertEqual(kept.sensitivity?.confidence, 100)
        XCTAssertTrue(model.quarantineReceipts.isEmpty)

        XCTAssertTrue(model.menuBarRecentClips.isEmpty)
        model.selectLibrarySection(.history)
        let presented = try XCTUnwrap(model.clipsForSelectedSection.first)
        XCTAssertNotNil(presented.sensitivity)
        XCTAssertEqual(
            model.clipExportDecision(presented),
            .requiresSensitiveConfirmation(category: "openAIAPIKey")
        )
        model.exportOrdinaryClip(presented)
        XCTAssertEqual(
            model.errorMessage,
            AppModelOperationError.sensitiveExportConfirmationRequired.localizedDescription
        )
    }

    func testQuarantinedSecretCanBeSharedThenMovedToVaultWithoutEnteringHistory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuarantineShareVault-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vaultSession = testVaultSession()
        let vaultStore = InMemoryVaultStore()
        let model = makeModel(
            supportDirectory: directory,
            vaultSession: vaultSession,
            vaultStore: vaultStore,
            secureShareKeyProvider: InMemorySecureShareKeyProvider()
        )
        await model.start()
        model.capture(PasteboardCaptureDraft(
            changeCount: 6,
            typeIdentifiers: ["public.utf8-plain-text"],
            plainText: "sk-proj-abcdefghijklmnopqrstuvwxyz123456"
        ))
        let captured = await waitUntil { model.quarantineReceipts.count == 1 }
        XCTAssertTrue(captured)
        let receipt = try XCTUnwrap(model.quarantineReceipts.first)

        model.presentEncryptedShareForQuarantine(id: receipt.id)
        let composerOpened = await waitUntil {
            model.pendingEncryptedShareRequest?.quarantineID == receipt.id
        }
        XCTAssertTrue(composerOpened)
        let recipientKeyValue = await model.localSecureSharePublicKeyString()
        let recipientKey = try XCTUnwrap(recipientKeyValue)
        model.generateEncryptedShare(
            for: try XCTUnwrap(model.pendingEncryptedShareRequest!),
            recipientKeyString: recipientKey
        )
        let shareGenerated = await waitUntil { model.encryptedShareEnvelope != nil }
        XCTAssertTrue(shareGenerated)

        model.moveEncryptedShareSourceToVault()
        let moved = await waitUntil(timeout: .seconds(2)) {
            model.quarantineReceipts.isEmpty
                && model.snapshot.history.isEmpty
                && model.vaultEncryptedItemCount == 1
        }
        XCTAssertTrue(moved)
        let vaultLibrary = try await VaultLibrary.open(store: vaultStore, session: vaultSession)
        if !(await vaultSession.isUnlocked) { try await vaultSession.unlock() }
        let items = try await vaultLibrary.items()
        XCTAssertEqual(items.first?.content.text, "sk-proj-abcdefghijklmnopqrstuvwxyz123456")
    }

    func testLegacySecretWithoutStoredClassificationIsMaskedAndExportGated() async throws {
        let secret = try ClipContent.detect(text: "sk-proj-abcdefghijklmnopqrstuvwxyz123456")
        let history = HistoryItem(content: secret, createdAt: Date(), sensitivity: nil)
        let model = makeModel(libraryPersistence: InMemoryClipboardLibraryStore(
            snapshot: ClipboardLibrarySnapshot(history: [history])
        ))
        await model.start()

        XCTAssertTrue(model.menuBarRecentClips.isEmpty)
        model.selectLibrarySection(.history)
        let presented = try XCTUnwrap(model.clipsForSelectedSection.first)
        XCTAssertNil(presented.sensitivity)
        XCTAssertTrue(model.isSensitiveForPresentation(presented))
        XCTAssertEqual(model.persistedSensitiveItemCount, 1)
        XCTAssertEqual(
            model.staticSmartViews.first(where: { $0.id == .sensitiveReview })?.count,
            1
        )
        XCTAssertEqual(
            model.clipExportDecision(presented),
            .requiresSensitiveConfirmation(category: "openAIAPIKey")
        )
        XCTAssertFalse(model.clipContextMenuPolicy(for: presented).canShareClip)
        XCTAssertFalse(model.clipContextMenuPolicy(for: presented).canUseWorkflows)
        model.updateMenuSearch("sk-proj")
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(model.menuSearchResults.isEmpty)
        model.applySmartView(.sensitiveReview)
        XCTAssertEqual(model.clipsForSelectedSection.map(\.id), [history.id])
    }

    func testUnrestoredSharedFolderPermissionsFailClosed() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SharedRoleRestoration-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sharedFolderID = UUID()
        let location = SharedFolderRemoteLocation(
            folderID: sharedFolderID,
            zoneName: "zone",
            ownerName: "owner",
            ownerParticipantID: "owner-id",
            shareRecordName: "share",
            databaseScope: .participantShared,
            title: "Shared research"
        )
        let data = try JSONEncoder().encode([location])
        try data.write(
            to: directory.appendingPathComponent("shared-folder-locations.json"),
            options: .atomic
        )
        let model = makeModel(supportDirectory: directory)
        await model.start()

        XCTAssertFalse(model.canEditSharedFolder(sharedFolderID))
        XCTAssertFalse(model.canManageSharedFolder(sharedFolderID))
        XCTAssertTrue(model.canEditSharedFolder(UUID()))
        XCTAssertTrue(model.canManageSharedFolder(UUID()))

        model.shareFolder(id: sharedFolderID)
        XCTAssertEqual(
            model.errorMessage,
            SharedFolderError.permissionDenied.localizedDescription
        )
        model.errorMessage = nil
        model.presentSharedFolderInvitationSurface(folderID: sharedFolderID)
        XCTAssertEqual(
            model.errorMessage,
            SharedFolderError.permissionDenied.localizedDescription
        )
    }

    func testLocalOnlyTombstonesAreExcludedFromManagedProjection() throws {
        let localOnlyID = UUID()
        let remoteID = UUID()
        let localOnly = try SavedLibrarySyncRecord.tombstone(
            id: localOnlyID,
            kind: .savedClip,
            stamp: LamportStamp(counter: 2, deviceID: "mac")
        )
        let remote = try SavedLibrarySyncRecord.tombstone(
            id: remoteID,
            kind: .savedClip,
            stamp: LamportStamp(counter: 3, deviceID: "mac")
        )
        let sync = SavedLibrarySyncSnapshot(
            isEnabled: true,
            records: [localOnlyID: localOnly, remoteID: remote],
            localLamportCounter: 3,
            status: .idle(lastSuccessfulSync: nil),
            entityStates: [
                localOnlyID: .localOnly(reason: .binaryAssetTransportUnavailable),
                remoteID: .synced(at: .distantPast, deviceID: "mac"),
            ]
        )

        XCTAssertEqual(
            AppModel.managedProjectionIDs(
                in: sync,
                kind: .savedClip,
                protecting: []
            ),
            [remoteID]
        )
    }

    func testCollaborativeEntitiesAreExcludedFromPrivateSyncAcrossAllKnownSources() throws {
        let sharedFolder = try ClipFolder(
            name: "Shared",
            sortOrder: 0,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let localSharedClip = try SavedClip(
            name: "Local shared",
            content: try ClipContent.detect(text: "local"),
            folderID: sharedFolder.id,
            createdAt: Date(timeIntervalSince1970: 2)
        )
        let stalePrivateClip = try SavedClip(
            name: "Stale private",
            content: try ClipContent.detect(text: "stale"),
            folderID: sharedFolder.id,
            createdAt: Date(timeIntervalSince1970: 3)
        )
        let sharedTombstoneID = UUID()

        let exclusion = AppModel.privateSyncSharedExclusion(
            sharedFolderIDs: [sharedFolder.id],
            sharedManagedClipIDs: [sharedTombstoneID],
            local: ClipboardLibrarySnapshot(
                savedClips: [localSharedClip],
                folders: [sharedFolder]
            ),
            privateSavedClips: [stalePrivateClip]
        )

        XCTAssertEqual(exclusion.folderIDs, [sharedFolder.id])
        XCTAssertEqual(
            exclusion.savedClipIDs,
            [localSharedClip.id, stalePrivateClip.id, sharedTombstoneID]
        )

        let movedOut = try SavedClip(
            id: localSharedClip.id,
            name: localSharedClip.name,
            content: localSharedClip.content,
            folderID: nil,
            createdAt: localSharedClip.createdAt
        )
        let movedMutation = PendingSavedLibraryMutation(
            id: movedOut.id,
            kind: .savedClip,
            isDeletion: false,
            modifiedAt: Date(timeIntervalSince1970: 4)
        )
        XCTAssertFalse(
            AppModel.isPrivateSyncExcludedMutation(
                movedMutation,
                sharedFolderIDs: [sharedFolder.id],
                sharedManagedClipIDs: [localSharedClip.id],
                currentClipsByID: [movedOut.id: movedOut]
            )
        )
        let deletedMutation = PendingSavedLibraryMutation(
            id: sharedTombstoneID,
            kind: .savedClip,
            isDeletion: true,
            modifiedAt: Date(timeIntervalSince1970: 5)
        )
        XCTAssertTrue(
            AppModel.isPrivateSyncExcludedMutation(
                deletedMutation,
                sharedFolderIDs: [sharedFolder.id],
                sharedManagedClipIDs: [sharedTombstoneID],
                currentClipsByID: [:]
            )
        )
    }

    func testRemoteSharedSubtreeAppliesNestedFoldersItemsPermissionsAndDeletionAtomically() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SharedNestedProjection-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = makeModel(supportDirectory: directory)
        await model.start()

        let root = try ClipFolder(
            name: "Shared root", sortOrder: 0,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let child = try ClipFolder(
            name: "Child", parentFolderID: root.id, sortOrder: 0,
            createdAt: Date(timeIntervalSince1970: 2)
        )
        let note = try SavedClip(
            kind: .note,
            name: "Remote note",
            content: ClipContent(type: .plainText, text: "body"),
            folderID: child.id,
            createdAt: Date(timeIntervalSince1970: 3)
        )
        let scope = try SharedFolderScope(folderID: root.id, ownerParticipantID: "owner")
        let location = SharedFolderRemoteLocation(
            folderID: root.id, zoneName: scope.zoneName, ownerName: "cloud-owner",
            ownerParticipantID: "owner", shareRecordName: "share",
            databaseScope: .participantShared, title: root.name
        )
        let participants = try [
            SharedFolderCloudParticipant(
                id: "owner", displayName: "Owner", role: .owner, acceptance: .accepted
            ),
            SharedFolderCloudParticipant(
                id: "editor", displayName: "Editor", role: .editor, acceptance: .accepted
            ),
        ]
        let editorProjection = SharedFolderSessionSnapshot(
            location: location,
            currentParticipantID: "editor",
            participants: participants,
            folder: root,
            folders: [child],
            savedClips: [note],
            managedFolderIDs: [root.id, child.id],
            managedSavedClipIDs: [note.id],
            status: .synced(Date())
        )
        try await model.applySharedFolderSnapshot(editorProjection)
        XCTAssertEqual(Set(model.snapshot.folders.map(\.id)), [root.id, child.id])
        XCTAssertEqual(model.snapshot.savedClips, [note])
        XCTAssertFalse(model.canManageSharedFolder(root.id))
        XCTAssertTrue(model.canManageSharedFolder(child.id))
        XCTAssertTrue(model.canEditSharedFolder(child.id))
        XCTAssertFalse(model.canManageFolderSharing(child.id))
        model.refreshSharedFolder(id: child.id)
        XCTAssertEqual(model.errorMessage, SharedFolderError.permissionDenied.localizedDescription)
        XCTAssertFalse(model.canMoveFolder(id: child.id, to: nil))
        model.moveSavedClip(id: note.id, to: nil)
        XCTAssertEqual(
            model.snapshot.savedClips.first(where: { $0.id == note.id })?.folderID,
            child.id
        )
        XCTAssertTrue(model.errorMessage?.contains("separate sync spaces") == true)

        let viewer = try SharedFolderCloudParticipant(
            id: "viewer", displayName: "Viewer", role: .viewer, acceptance: .accepted
        )
        let viewerProjection = SharedFolderSessionSnapshot(
            location: location,
            currentParticipantID: "viewer",
            participants: [participants[0], viewer],
            folder: root,
            folders: [],
            savedClips: [],
            managedFolderIDs: [root.id, child.id],
            managedSavedClipIDs: [note.id],
            status: .synced(Date())
        )
        try await model.applySharedFolderSnapshot(viewerProjection)
        XCTAssertNil(model.snapshot.folders.first(where: { $0.id == child.id }))
        XCTAssertNil(model.snapshot.savedClips.first(where: { $0.id == note.id }))
        XCTAssertFalse(model.canEditSharedFolder(root.id))
        XCTAssertFalse(model.canEditSharedFolder(child.id))

        let exclusion = AppModel.privateSyncSharedExclusion(
            sharedFolderIDs: viewerProjection.managedFolderIDs,
            sharedManagedClipIDs: viewerProjection.managedSavedClipIDs,
            local: model.snapshot,
            privateSavedClips: [note]
        )
        XCTAssertEqual(exclusion.folderIDs, [root.id, child.id])
        XCTAssertTrue(exclusion.savedClipIDs.contains(note.id))
    }

    func testSharedRemoteTombstoneDeletesLocalClipAndPreservesDeviceFolderOrder() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SharedProjection-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = InMemorySharedFolderTransport(participantID: "owner")
        let model = makeModel(
            supportDirectory: directory,
            sharedFolderTransport: transport
        )
        await model.start()
        model.createFolder(named: "Local first")
        try await Task.sleep(for: .milliseconds(50))
        model.createFolder(named: "Shared second")
        try await Task.sleep(for: .milliseconds(50))
        let folder = try XCTUnwrap(model.snapshot.folders.first(where: {
            $0.name == "Shared second"
        }))
        XCTAssertEqual(folder.sortOrder, 1)

        model.capture(
            PasteboardCaptureDraft(
                changeCount: 10,
                typeIdentifiers: ["public.utf8-plain-text"],
                plainText: "delete from another Mac"
            )
        )
        try await Task.sleep(for: .milliseconds(50))
        let historyClip = try XCTUnwrap(model.menuBarRecentClips.first)
        model.saveHistoryClip(historyClip, folderID: folder.id)
        try await Task.sleep(for: .milliseconds(80))
        let saved = try XCTUnwrap(model.snapshot.savedClips.first)

        let scope = try SharedFolderScope(folderID: folder.id, ownerParticipantID: "owner")
        let location = SharedFolderRemoteLocation(
            folderID: folder.id,
            zoneName: scope.zoneName,
            ownerName: "cloud-owner",
            ownerParticipantID: "owner",
            shareRecordName: "zone-wide-share",
            databaseScope: .ownerPrivate,
            title: folder.name
        )
        let remoteFolder = try ClipFolder(
            id: folder.id,
            name: folder.name,
            sortOrder: 0,
            createdAt: folder.createdAt,
            modifiedAt: folder.modifiedAt
        )
        let owner = try SharedFolderCloudParticipant(
            id: "owner",
            displayName: "Owner",
            role: .owner,
            acceptance: .accepted
        )
        let remoteDeletion = SharedFolderSessionSnapshot(
            location: location,
            currentParticipantID: "owner",
            participants: [owner],
            folder: remoteFolder,
            savedClips: [],
            managedSavedClipIDs: [saved.id],
            status: .synced(Date())
        )

        // An unconfirmed local save wins over a remote projection, so it is not silently lost.
        try await model.applySharedFolderSnapshot(remoteDeletion)
        XCTAssertTrue(model.snapshot.savedClips.contains(where: { $0.id == saved.id }))

        // Share creation publishes this exact local value and acknowledges its exact Core token.
        // The same later remote tombstone can now apply.
        model.shareFolder(id: folder.id)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(
            model.snapshot.pendingSavedLibraryMutations.contains(where: {
                $0.id == saved.id
            })
        )
        try await model.applySharedFolderSnapshot(remoteDeletion)

        XCTAssertFalse(model.snapshot.savedClips.contains(where: { $0.id == saved.id }))
        XCTAssertEqual(
            model.snapshot.folders.first(where: { $0.id == folder.id })?.sortOrder,
            1
        )
    }

    func testSharedFolderWorkflowPublishesTruthfulPerFolderStateWithFakeTransport() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SharedFolderAppFlow-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = InMemorySharedFolderTransport(participantID: "owner")
        let model = makeModel(
            supportDirectory: directory,
            sharedFolderTransport: transport
        )
        await model.start()
        model.createFolder(named: "Launch Notes")
        try await Task.sleep(for: .milliseconds(60))
        let folder = try XCTUnwrap(model.snapshot.folders.first)
        model.createFolder(named: "Nested", parentFolderID: folder.id)
        let nestedCreated = await waitUntil {
            model.snapshot.folders.contains(where: { $0.parentFolderID == folder.id })
        }
        XCTAssertTrue(nestedCreated)
        let nested = try XCTUnwrap(model.snapshot.folders.first(where: {
            $0.parentFolderID == folder.id
        }))

        model.shareFolder(id: folder.id)
        try await Task.sleep(for: .milliseconds(80))

        let shared = try XCTUnwrap(model.sharedFolderSnapshot(for: folder.id))
        XCTAssertEqual(shared.folder, folder)
        XCTAssertEqual(shared.currentRole, .owner)
        XCTAssertEqual(shared.folders.map(\.id), [nested.id])
        XCTAssertEqual(shared.participants.map(\.displayName), ["Owner"])
        if case .synced = shared.status {} else {
            XCTFail("Expected per-folder synchronized state")
        }
        XCTAssertTrue(model.sharedFolderMessage?.contains("signed CloudKit build") == true)
        XCTAssertTrue(model.canManageFolderSharing(nested.id))
        XCTAssertEqual(model.sharedFolderSnapshot(for: nested.id)?.location.folderID, folder.id)
        model.refreshSharedFolder(id: nested.id)
        let refreshedThroughRoot = await waitUntil {
            model.statusMessage == "Shared folder refreshed."
        }
        XCTAssertTrue(refreshedThroughRoot)
    }

    func testSharedFolderWorkflowFailsClosedWhenCapabilityIsMissing() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SharedFolderCapability-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = InMemorySharedFolderTransport(
            participantID: "owner",
            capability: .unavailable(.configurationMissing)
        )
        let model = makeModel(
            supportDirectory: directory,
            sharedFolderTransport: transport
        )
        await model.start()
        model.createFolder(named: "Local Only")
        try await Task.sleep(for: .milliseconds(60))
        let folder = try XCTUnwrap(model.snapshot.folders.first)

        model.shareFolder(id: folder.id)
        try await Task.sleep(for: .milliseconds(60))

        XCTAssertNil(model.sharedFolderSnapshot(for: folder.id))
        XCTAssertEqual(
            model.sharedFolderCapability,
            .unavailable(.configurationMissing)
        )
        let createCallCount = await transport.createCallCount
        XCTAssertEqual(createCallCount, 0)
    }

    func testDeveloperProjectPersistsAndAutoCaptureIsExplicitlyOptIn() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeveloperProjectApp-\(UUID())", isDirectory: true)
        let support = root.appendingPathComponent("Support", isDirectory: true)
        let repository = root.appendingPathComponent("SampleRepo", isDirectory: true)
        let git = repository.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        try Data("ref: refs/heads/main\n".utf8).write(
            to: git.appendingPathComponent("HEAD")
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let model = makeModel(supportDirectory: support)
        await model.start()
        let created = await model.createDeveloperProject(
            name: "Sample",
            repositoryRootURL: repository
        )
        XCTAssertTrue(created)
        let project = try XCTUnwrap(model.selectedDeveloperProject)
        XCTAssertFalse(project.autoAddDeveloperClips)
        XCTAssertEqual(project.repository?.branch, "main")
        XCTAssertNil(model.activeDeveloperProject)
        model.setActiveDeveloperProject(project.id)
        let activated = await waitUntil { model.activeDeveloperProject?.id == project.id }
        XCTAssertTrue(activated)

        model.capture(PasteboardCaptureDraft(
            changeCount: 1,
            typeIdentifiers: ["public.utf8-plain-text"],
            plainText: "func first() { print(1) }",
            source: PasteboardCaptureSource(
                applicationBundleIdentifier: "com.example.Editor",
                applicationName: "Example Editor"
            )
        ))
        let capturedFirst = await waitUntil { model.snapshot.history.count == 1 }
        XCTAssertTrue(capturedFirst)
        XCTAssertTrue(model.developerWorkspaceSnapshot.memberships.isEmpty)

        model.setDeveloperSourceApplication(
            "com.example.Editor",
            allowed: true,
            for: project.id
        )
        let sourceApproved = await waitUntil {
            model.activeDeveloperProject?.allowedSourceBundleIdentifiers
                .contains("com.example.Editor") == true
        }
        XCTAssertTrue(sourceApproved)
        model.setDeveloperAutoCapture(true, for: project.id)
        let enabled = await waitUntil {
            model.activeDeveloperProject?.autoAddDeveloperClips == true
        }
        XCTAssertTrue(enabled)
        model.capture(PasteboardCaptureDraft(
            changeCount: 2,
            typeIdentifiers: ["public.utf8-plain-text"],
            plainText: "func second() { print(2) }\nlet value = 2",
            source: PasteboardCaptureSource(
                applicationBundleIdentifier: "com.example.Editor",
                applicationName: "Example Editor"
            )
        ))
        let attributed = await waitUntil {
            model.developerWorkspaceSnapshot.memberships.count == 1
        }
        XCTAssertTrue(attributed)

        let reloaded = makeModel(supportDirectory: support)
        await reloaded.start()
        XCTAssertEqual(reloaded.activeDeveloperProject?.name, "Sample")
        XCTAssertEqual(reloaded.developerWorkspaceSnapshot.memberships.count, 1)
    }

    func testDelayedDeveloperCaptureKeepsObservedProjectAssignment() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeveloperCaptureRace-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstRepository = root.appendingPathComponent("First", isDirectory: true)
        let secondRepository = root.appendingPathComponent("Second", isDirectory: true)
        for repository in [firstRepository, secondRepository] {
            let git = repository.appendingPathComponent(".git", isDirectory: true)
            try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
            try Data("ref: refs/heads/main\n".utf8).write(to: git.appendingPathComponent("HEAD"))
        }
        let model = makeModel(
            ocrService: DelayedOCRService(
                delayMilliseconds: 120,
                result: "func delayedCapture() { fatalError(\"boom\") }"
            ),
            supportDirectory: root.appendingPathComponent("Support", isDirectory: true)
        )
        await model.start()
        let createdFirst = await model.createDeveloperProject(name: "First", repositoryRootURL: firstRepository)
        XCTAssertTrue(createdFirst)
        let first = try XCTUnwrap(model.selectedDeveloperProject)
        let createdSecond = await model.createDeveloperProject(name: "Second", repositoryRootURL: secondRepository)
        XCTAssertTrue(createdSecond)
        let second = try XCTUnwrap(model.selectedDeveloperProject)
        model.setActiveDeveloperProject(first.id)
        let activatedFirst = await waitUntil { model.activeDeveloperProject?.id == first.id }
        XCTAssertTrue(activatedFirst)
        model.setDeveloperSourceApplication("com.example.Editor", allowed: true, for: first.id)
        let approvedFirst = await waitUntil {
            model.activeDeveloperProject?.allowedSourceBundleIdentifiers.contains("com.example.Editor") == true
        }
        XCTAssertTrue(approvedFirst)
        model.setDeveloperAutoCapture(true, for: first.id)
        let enabledFirst = await waitUntil { model.activeDeveloperProject?.autoAddDeveloperClips == true }
        XCTAssertTrue(enabledFirst)

        model.capture(PasteboardCaptureDraft(
            changeCount: 99,
            typeIdentifiers: ["public.png"],
            image: PasteboardImageDraft(
                data: Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Z7aIAAAAASUVORK5CYII=")!,
                uniformTypeIdentifier: "public.png"
            ),
            source: PasteboardCaptureSource(
                applicationBundleIdentifier: "com.example.Editor",
                applicationName: "Example Editor"
            )
        ))
        try await Task.sleep(for: .milliseconds(20))
        model.setActiveDeveloperProject(second.id)
        let activatedSecond = await waitUntil { model.activeDeveloperProject?.id == second.id }
        XCTAssertTrue(activatedSecond)
        let attributed = await waitUntil { model.developerWorkspaceSnapshot.memberships.count == 1 }
        XCTAssertTrue(attributed)
        XCTAssertEqual(model.developerWorkspaceSnapshot.memberships.first?.projectID, first.id)
    }

    func testEnablingDeveloperCaptureDoesNotClaimInFlightClip() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeveloperCaptureOptInRace-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = root.appendingPathComponent("Repo", isDirectory: true)
        let git = repository.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        try Data("ref: refs/heads/main\n".utf8).write(to: git.appendingPathComponent("HEAD"))
        let model = makeModel(
            ocrService: DelayedOCRService(
                delayMilliseconds: 120,
                result: "func observedBeforeOptIn() { print(1) }"
            ),
            supportDirectory: root.appendingPathComponent("Support", isDirectory: true)
        )
        await model.start()
        let created = await model.createDeveloperProject(name: "Project", repositoryRootURL: repository)
        XCTAssertTrue(created)
        let project = try XCTUnwrap(model.selectedDeveloperProject)
        model.setActiveDeveloperProject(project.id)
        let activated = await waitUntil { model.activeDeveloperProject?.id == project.id }
        XCTAssertTrue(activated)
        model.setDeveloperSourceApplication("com.example.Editor", allowed: true, for: project.id)
        let approved = await waitUntil {
            model.activeDeveloperProject?.allowedSourceBundleIdentifiers.contains("com.example.Editor") == true
        }
        XCTAssertTrue(approved)

        model.capture(PasteboardCaptureDraft(
            changeCount: 100,
            typeIdentifiers: ["public.png"],
            image: PasteboardImageDraft(
                data: Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Z7aIAAAAASUVORK5CYII=")!,
                uniformTypeIdentifier: "public.png"
            ),
            source: PasteboardCaptureSource(
                applicationBundleIdentifier: "com.example.Editor",
                applicationName: "Example Editor"
            )
        ))
        try await Task.sleep(for: .milliseconds(20))
        model.setDeveloperAutoCapture(true, for: project.id)
        let enabled = await waitUntil { model.activeDeveloperProject?.autoAddDeveloperClips == true }
        XCTAssertTrue(enabled)
        let captured = await waitUntil { model.snapshot.history.count == 1 }
        XCTAssertTrue(captured)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(model.developerWorkspaceSnapshot.memberships.isEmpty)
    }

    func testDeveloperProjectManualAddRejectsSensitiveClip() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeveloperProjectSensitive-\(UUID())", isDirectory: true)
        let repository = root.appendingPathComponent("Repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let content = try ClipContent.detect(text: "sk-live-abcdefghijklmnopqrstuvwxyz1234567890")
        let item = HistoryItem(
            content: content,
            createdAt: Date(),
            sourceApplicationBundleIdentifier: "com.example.Editor",
            sensitivity: try ClipSensitivityMetadata(
                category: "API key",
                confidence: 99,
                detectorVersion: 1
            )
        )
        let model = makeModel(
            supportDirectory: root.appendingPathComponent("Support"),
            libraryPersistence: InMemoryClipboardLibraryStore(
                snapshot: ClipboardLibrarySnapshot(history: [item])
            )
        )
        await model.start()
        let created = await model.createDeveloperProject(
            name: "Secure",
            repositoryRootURL: repository
        )
        XCTAssertTrue(created)
        let project = try XCTUnwrap(model.selectedDeveloperProject)
        model.setActiveDeveloperProject(project.id)
        let activated = await waitUntil { model.activeDeveloperProject?.id == project.id }
        XCTAssertTrue(activated)

        let sensitive = PresentedClip(
            id: item.id,
            title: "secret",
            content: content,
            date: item.lastCapturedAt,
            sourceBundleIdentifier: "com.example.Editor",
            origin: .history,
            sensitivity: item.sensitivity
        )
        model.addToActiveDeveloperProject(sensitive)

        XCTAssertTrue(model.developerWorkspaceSnapshot.memberships.isEmpty)
        XCTAssertNotNil(model.errorMessage)
    }

    func testDeveloperClipCanBeAddedToSelectedProjectWithoutChangingActiveProject() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeveloperProjectPicker-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstRepository = root.appendingPathComponent("First", isDirectory: true)
        let secondRepository = root.appendingPathComponent("Second", isDirectory: true)
        for repository in [firstRepository, secondRepository] {
            let git = repository.appendingPathComponent(".git", isDirectory: true)
            try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
            try Data("ref: refs/heads/main\n".utf8).write(to: git.appendingPathComponent("HEAD"))
        }
        let history = HistoryItem(
            content: try ClipContent.detect(text: "selected project clip"),
            createdAt: Date(),
            sourceApplicationBundleIdentifier: "com.example.Editor"
        )
        let model = makeModel(
            supportDirectory: root.appendingPathComponent("Support", isDirectory: true),
            libraryPersistence: InMemoryClipboardLibraryStore(
                snapshot: ClipboardLibrarySnapshot(history: [history])
            )
        )
        await model.start()
        let createdFirst = await model.createDeveloperProject(
            name: "First",
            repositoryRootURL: firstRepository
        )
        XCTAssertTrue(createdFirst)
        let first = try XCTUnwrap(model.selectedDeveloperProject)
        let createdSecond = await model.createDeveloperProject(
            name: "Second",
            repositoryRootURL: secondRepository
        )
        XCTAssertTrue(createdSecond)
        let second = try XCTUnwrap(model.selectedDeveloperProject)
        model.setActiveDeveloperProject(second.id)
        let activated = await waitUntil { model.activeDeveloperProject?.id == second.id }
        XCTAssertTrue(activated)

        let clip = try XCTUnwrap(model.menuBarRecentClips.first)
        model.addToDeveloperProject(clip, projectID: first.id)
        let added = await waitUntil {
            model.developerWorkspaceSnapshot.memberships.contains {
                $0.projectID == first.id && $0.clip == .history(history.id)
            }
        }
        XCTAssertTrue(added)
        XCTAssertEqual(model.activeDeveloperProject?.id, second.id)
        XCTAssertFalse(model.developerWorkspaceSnapshot.memberships.contains {
            $0.projectID == second.id
        })
    }

    func testReviewedDebugBundlePublishesAsSanitizedTeamArtifact() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeveloperTeamBundle-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = InMemorySharedFolderTransport(participantID: "owner")
        let model = makeModel(supportDirectory: root, sharedFolderTransport: transport)
        await model.start()
        model.createFolder(named: "Engineering")
        let folderCreated = await waitUntil { model.snapshot.folders.count == 1 }
        XCTAssertTrue(folderCreated)
        let folder = try XCTUnwrap(model.snapshot.folders.first)
        model.shareFolder(id: folder.id)
        let shared = await waitUntil { model.sharedFolderSnapshots[folder.id] != nil }
        XCTAssertTrue(shared)

        model.capture(PasteboardCaptureDraft(
            changeCount: 1,
            typeIdentifiers: ["public.utf8-plain-text"],
            plainText: "func reproduce() { fatalError(\"boom\") }",
            source: PasteboardCaptureSource(
                applicationBundleIdentifier: "com.example.Editor",
                applicationName: "Example Editor",
                sourceURL: URL(fileURLWithPath: "/Users/alice/private/Secret.swift")
            )
        ))
        let captured = await waitUntil { model.snapshot.history.count == 1 }
        XCTAssertTrue(captured)
        let history = try XCTUnwrap(model.snapshot.history.first)
        model.addToDebugBundle(presentedClip(history))
        model.prepareDebugBundleReview()
        let request = try XCTUnwrap(model.pendingDebugBundleReview)

        let published = await model.publishDebugBundleToTeam(
            request,
            projectDisplayName: "Sample Project",
            problemStatement: "Reproduce the crash",
            folderID: folder.id
        )
        XCTAssertTrue(published)
        let note = try XCTUnwrap(
            model.sharedFolderSnapshots[folder.id]?.savedClips.first(where: {
                $0.name == "Debug Bundle — Sample Project"
            })
        )
        XCTAssertEqual(note.kind, .note)
        XCTAssertTrue(note.tags?.contains(AppModel.sharedDebugBundleTag) == true)
        XCTAssertTrue(note.content.text.contains("Project: Sample Project"))
        XCTAssertFalse(note.content.text.contains("/Users/alice"))
        XCTAssertTrue(model.sharedFolderSnapshots[folder.id]?.debugBundles.isEmpty == true)
    }

    func testDebugBundleTeamPublishFailureIsTruthfulAndRetryIsIdempotent() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeveloperTeamBundleRetry-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = InMemorySharedFolderTransport(participantID: "owner")
        let model = makeModel(supportDirectory: root, sharedFolderTransport: transport)
        await model.start()
        model.createFolder(named: "Engineering")
        let folderCreated = await waitUntil { model.snapshot.folders.count == 1 }
        XCTAssertTrue(folderCreated)
        let folder = try XCTUnwrap(model.snapshot.folders.first)
        model.shareFolder(id: folder.id)
        let shared = await waitUntil { model.sharedFolderSnapshots[folder.id] != nil }
        XCTAssertTrue(shared)
        model.capture(PasteboardCaptureDraft(
            changeCount: 1,
            typeIdentifiers: ["public.utf8-plain-text"],
            plainText: "func retry() { fatalError(\"boom\") }"
        ))
        let captured = await waitUntil { model.snapshot.history.count == 1 }
        XCTAssertTrue(captured)
        model.addToDebugBundle(presentedClip(try XCTUnwrap(model.snapshot.history.first)))
        model.prepareDebugBundleReview()
        let request = try XCTUnwrap(model.pendingDebugBundleReview)

        await transport.failNext(.cloudFailure("synthetic offline"))
        let first = await model.publishDebugBundleToTeam(
            request,
            projectDisplayName: "Retry Project",
            problemStatement: "Reproduce",
            folderID: folder.id
        )
        XCTAssertFalse(first)
        XCTAssertTrue(model.errorMessage?.contains("saved locally") == true)
        XCTAssertEqual(
            model.snapshot.savedClips.filter { $0.name == "Debug Bundle — Retry Project" }.count,
            1
        )
        XCTAssertTrue(
            model.sharedFolderSnapshots[folder.id]?.savedClips.allSatisfy {
                $0.name != "Debug Bundle — Retry Project"
            } == true
        )

        let second = await model.publishDebugBundleToTeam(
            request,
            projectDisplayName: "Retry Project",
            problemStatement: "Reproduce",
            folderID: folder.id
        )
        XCTAssertTrue(second)
        XCTAssertEqual(
            model.sharedFolderSnapshots[folder.id]?.savedClips.filter {
                $0.name == "Debug Bundle — Retry Project"
            }.count,
            1
        )
    }

    private func makeModel(
        typedWriter: FakeTypedPasteboardWriter = FakeTypedPasteboardWriter(),
        textWriter: FakeTextPasteboardWriter = FakeTextPasteboardWriter(),
        ocrService: any LocalOCRServicing = DelayedOCRService(delayMilliseconds: 0),
        supportDirectory: URL? = nil,
        quarantineStore: QuarantineStore = QuarantineStore(),
        sharedFolderTransport: (any SharedFolderTransport)? = nil,
        vaultSession: VaultSession? = nil,
        vaultStore: (any VaultStore)? = nil,
        libraryPersistence: (any ClipboardLibraryPersisting)? = nil,
        secureShareKeyProvider: (any SecureShareKeyProvider)? = nil
    ) -> AppModel {
        AppModel(
            defaults: UserDefaults(suiteName: "AppWorkflowIntegrationTests.\(UUID())")!,
            pasteboardWriter: textWriter,
            typedPasteboardWriter: typedWriter,
            hotKey: NoopHotKeyRegistrar(),
            supportDirectory: supportDirectory ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("AppWorkflowIntegrationTests-\(UUID())"),
            quarantineStore: quarantineStore,
            ocrService: ocrService,
            sharedFolderTransport: sharedFolderTransport,
            vaultSession: vaultSession,
            vaultStore: vaultStore,
            libraryPersistence: libraryPersistence,
            secureShareKeyProvider: secureShareKeyProvider
        )
    }

    private func testVaultSession() -> VaultSession {
        VaultSession(
            authenticator: StubVaultAuthenticator(),
            keyProvider: InMemoryVaultKeyProvider()
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

    private func presentedClip(_ text: String) throws -> PresentedClip {
        PresentedClip(
            id: UUID(),
            title: text,
            content: try ClipContent.detect(text: text),
            date: Date(),
            sourceBundleIdentifier: nil,
            origin: .history
        )
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
            pasteboardTypeIdentifiers: item.pasteboardTypeIdentifiers ?? [],
            pasteCount: item.pasteCount ?? 0,
            lastPastedAt: item.lastPastedAt
        )
    }
}

private struct AIDraftPersistenceObservation: Equatable {
    let didSave: Bool
    let generatedCount: Int
    let folderID: UUID?
    let body: String?
}

private struct DebugBundleWorkflowObservation: Equatable {
    let badges: [String]
    let containsProject: Bool
    let containsProblem: Bool
    let copied: Bool
    let copiedMarkdown: String?
    let saved: Bool
    let savedMarkdown: String?
}

private struct DebugBundleStaleObservation: Equatable {
    let copiedCount: Int
    let saved: Bool
    let savedCount: Int
    let errorMessage: String?
}

private struct InsertDefaultDeliveryObservation: Equatable {
    let savedDelivery: InsertAliasDelivery?
    let clipboardWriteCount: Int
    let errorMessage: String?
}

private enum RegressionTestSetupError: Error {
    case aliasWasNotSaved
}

private enum RejectingVaultSaveError: Error {
    case intentionalFailure
}

private actor RejectingVaultSaveStore: VaultStore {
    func load() async throws -> VaultStoreSnapshot { .empty }

    func save(_: VaultStoreSnapshot) async throws {
        throw RejectingVaultSaveError.intentionalFailure
    }
}

private enum FailingToggleClipboardStoreError: Error {
    case intentionalFailure
}

private actor FailingToggleClipboardStore: ClipboardLibraryPersisting {
    private var snapshot: ClipboardLibrarySnapshot
    private var shouldFailSave = false

    init(snapshot: ClipboardLibrarySnapshot) { self.snapshot = snapshot }

    func load() async throws -> ClipboardLibrarySnapshot { snapshot }

    func save(_ snapshot: ClipboardLibrarySnapshot) async throws {
        if shouldFailSave { throw FailingToggleClipboardStoreError.intentionalFailure }
        self.snapshot = snapshot
    }

    func setShouldFailSave(_ value: Bool) { shouldFailSave = value }
}

@MainActor
private final class FakeTypedPasteboardWriter: TypedPasteboardWriting {
    var shouldFail = false
    var delayMilliseconds = 0
    private(set) var writtenContents: [ClipContent] = []
    private(set) var writtenSourceTypeIdentifiers: [[String]] = []
    private(set) var maximumConcurrentWriteCount = 0
    private var concurrentWriteCount = 0

    func write(_ content: ClipContent, mode _: ClipPasteboardWriteMode) async throws {
        try await write(content, sourceTypeIdentifiers: [])
    }

    func write(
        _ content: ClipContent,
        mode _: ClipPasteboardWriteMode,
        sourceTypeIdentifiers: [String]
    ) async throws {
        try await write(content, sourceTypeIdentifiers: sourceTypeIdentifiers)
    }

    private func write(
        _ content: ClipContent,
        sourceTypeIdentifiers: [String]
    ) async throws {
        concurrentWriteCount += 1
        maximumConcurrentWriteCount = max(maximumConcurrentWriteCount, concurrentWriteCount)
        defer { concurrentWriteCount -= 1 }
        if delayMilliseconds > 0 {
            try await Task.sleep(for: .milliseconds(delayMilliseconds))
        }
        if shouldFail { throw FakeClipboardError.failed }
        writtenContents.append(content)
        writtenSourceTypeIdentifiers.append(sourceTypeIdentifiers)
    }
}

private struct DelayedOCRService: LocalOCRServicing {
    let delayMilliseconds: Int
    var result = "ordinary local image text"

    func recognizeText(in _: Data) async throws -> String? {
        if delayMilliseconds > 0 {
            try await Task.sleep(for: .milliseconds(delayMilliseconds))
        }
        return result
    }
}

@MainActor
private final class FakeTextPasteboardWriter: PasteboardWriting {
    private(set) var writtenStrings: [String] = []

    func writeForRouting(_ string: String) -> Bool {
        writtenStrings.append(string)
        return true
    }
}

@MainActor
private final class NoopHotKeyRegistrar: GlobalHotKeyRegistering {
    func register(
        _: GlobalHotKeyDescriptor,
        handler _: @escaping @MainActor () -> Void
    ) throws {}

    func unregister() {}
}

private enum FakeClipboardError: Error {
    case failed
}
