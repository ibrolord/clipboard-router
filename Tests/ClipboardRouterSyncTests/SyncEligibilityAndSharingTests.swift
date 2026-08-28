import ClipboardRouterCore
import CloudKit
import Foundation
import XCTest
@testable import ClipboardRouterSync

final class SyncEligibilityAndSharingTests: XCTestCase {
    func testPolicyRejectsEveryLocalOnlyOriginWithTypedReason() {
        let policy = SyncEligibilityPolicy()
        let id = UUID()
        let fixtures: [(SyncEligibilityCandidate, SyncLocalOnlyReason)] = [
            (.history(id: id), .historyIsDeviceLocal),
            (.vault(id: id), .vaultIsDeviceLocal),
            (.quarantine(id: id), .quarantineIsMemoryOnly),
            (.privateSession(id: id), .privateSessionIsMemoryOnly),
            (.unsupported(id: id), .unsupportedEntityType),
        ]

        for (candidate, reason) in fixtures {
            XCTAssertEqual(policy.evaluate(candidate), .localOnly(reason))
        }
    }

    func testOnlyReadySavedClipsAndFoldersAreEligibleByDefault() throws {
        let policy = SyncEligibilityPolicy()
        let folder = try makeFolder()
        let ready = try makeClip(folderID: folder.id, text: "ready")
        let location = try CoarseLocationContext(label: "Toronto", geohash: "dpz83")

        XCTAssertEqual(policy.evaluate(.folder(folder)), .eligible)
        XCTAssertEqual(
            policy.evaluate(.savedClip(ready, metadata: .ready)),
            .eligible
        )
        XCTAssertEqual(
            policy.evaluate(
                .savedClip(
                    ready,
                    metadata: SavedClipSyncMetadata(analysisState: .pending)
                )
            ),
            .localOnly(.pendingSafetyAnalysis)
        )
        XCTAssertEqual(
            policy.evaluate(.savedClip(try makeFileClip(folderID: folder.id), metadata: .ready)),
            .localOnly(.fileReferenceIsDeviceLocal)
        )
        XCTAssertEqual(
            policy.evaluate(.savedClip(try makeAssetClip(folderID: folder.id), metadata: .ready)),
            .eligible
        )
        XCTAssertEqual(
            SyncEligibilityPolicy(allowsLocation: true).evaluate(
                .savedClip(
                    try makeAssetClip(folderID: folder.id, location: location),
                    metadata: .ready
                )
            ),
            .localOnly(.locationSharingDisabled)
        )
        XCTAssertEqual(
            policy.evaluate(
                .savedClip(
                    ready,
                    metadata: SavedClipSyncMetadata(coarseLocation: location)
                )
            ),
            .localOnly(.locationSharingDisabled)
        )
        XCTAssertEqual(
            SyncEligibilityPolicy(allowsLocation: true).evaluate(
                .savedClip(
                    ready,
                    metadata: SavedClipSyncMetadata(coarseLocation: location)
                )
            ),
            .eligible
        )
        let embeddedLocation = try SavedClip(
            name: "Located",
            content: ClipContent(type: .plainText, text: "located"),
            folderID: folder.id,
            createdAt: Date(timeIntervalSince1970: 1_000),
            captureContext: ClipCaptureContext(coarseLocation: location)
        )
        XCTAssertEqual(
            policy.evaluate(.savedClip(embeddedLocation, metadata: .ready)),
            .localOnly(.locationSharingDisabled)
        )
    }

    func testPendingAnalysisWinsDeterministicallyOverOtherClipReasons() throws {
        let folder = try makeFolder()
        let location = try CoarseLocationContext(label: "Toronto")
        let result = SyncEligibilityPolicy().evaluate(
            .savedClip(
                try makeFileClip(folderID: folder.id),
                metadata: SavedClipSyncMetadata(
                    analysisState: .pending,
                    coarseLocation: location
                )
            )
        )
        XCTAssertEqual(result, .localOnly(.pendingSafetyAnalysis))
    }

    func testCoordinatorRejectsBeforeOutboxAndPersistsOnlyLocalReason() async throws {
        let coordinator = SavedLibrarySyncCoordinator(
            deviceID: "mac-a",
            transport: InMemorySavedLibrarySyncTransport(),
            store: InMemorySavedLibrarySyncStateStore()
        )
        let folder = try makeFolder()
        let clip = try makeFileClip(folderID: folder.id)

        await assertSyncError(try await coordinator.recordSavedClip(clip)) { error in
            XCTAssertEqual(error, .ineligible(clip.id, .fileReferenceIsDeviceLocal))
        }

        let snapshot = await coordinator.snapshot()
        XCTAssertTrue(snapshot.records.isEmpty)
        XCTAssertTrue(snapshot.outbox.isEmpty)
        XCTAssertEqual(
            snapshot.entityStates[clip.id],
            .localOnly(reason: .fileReferenceIsDeviceLocal)
        )
    }

    func testMarkLocalOnlyStoresNoEntityPayload() async throws {
        let coordinator = SavedLibrarySyncCoordinator(
            deviceID: "mac-a",
            transport: InMemorySavedLibrarySyncTransport(),
            store: InMemorySavedLibrarySyncStateStore()
        )
        let id = UUID()

        let decision = try await coordinator.markLocalOnly(.quarantine(id: id))

        XCTAssertEqual(decision, .localOnly(.quarantineIsMemoryOnly))
        let snapshot = await coordinator.snapshot()
        XCTAssertEqual(
            snapshot.entityStates,
            [id: .localOnly(reason: .quarantineIsMemoryOnly)]
        )
        XCTAssertTrue(snapshot.records.isEmpty)
        XCTAssertTrue(snapshot.outbox.isEmpty)
    }

    func testPreviouslySyncedClipBecomingLocalOnlyTombstonesAndCannotResurrect() async throws {
        let transport = InMemorySavedLibrarySyncTransport()
        let coordinator = SavedLibrarySyncCoordinator(
            deviceID: "mac-a",
            transport: transport,
            store: InMemorySavedLibrarySyncStateStore()
        )
        try await coordinator.setEnabled(true)
        let folder = try makeFolder()
        let clip = try makeClip(folderID: folder.id, text: "previously synced")
        _ = try await coordinator.recordFolder(folder)
        _ = try await coordinator.recordSavedClip(clip)
        await coordinator.synchronize()
        let initiallyRemote = await transport.allRecords()
        XCTAssertFalse(try XCTUnwrap(initiallyRemote.first { $0.id == clip.id }).isTombstone)

        let localFileVersion = try makeFileClip(id: clip.id, folderID: folder.id)
        await assertSyncError(try await coordinator.recordSavedClip(localFileVersion)) {
            XCTAssertEqual($0, .ineligible(clip.id, .fileReferenceIsDeviceLocal))
        }
        var excluded = await coordinator.snapshot()
        XCTAssertTrue(excluded.records[clip.id]?.isTombstone == true)
        XCTAssertTrue(excluded.outbox[clip.id]?.isTombstone == true)
        XCTAssertEqual(
            excluded.entityStates[clip.id],
            .localOnly(reason: .fileReferenceIsDeviceLocal)
        )
        let excludedMaterialized = await coordinator.materializedLibrary()
        XCTAssertFalse(excludedMaterialized.savedClips.contains { $0.id == clip.id })

        await coordinator.synchronize()
        excluded = await coordinator.snapshot()
        XCTAssertEqual(
            excluded.entityStates[clip.id],
            .localOnly(reason: .fileReferenceIsDeviceLocal)
        )
        let tombstonedRemote = await transport.allRecords()
        XCTAssertTrue(try XCTUnwrap(tombstonedRemote.first { $0.id == clip.id }).isTombstone)

        let remoteLive = try SavedLibrarySyncRecord.live(
            .savedClip(try makeClip(id: clip.id, folderID: folder.id, text: "remote resurrection")),
            stamp: LamportStamp(
                counter: try XCTUnwrap(excluded.records[clip.id]).stamp.counter + 1,
                deviceID: "mac-z"
            )
        )
        try await transport.push([remoteLive])
        await coordinator.synchronize()

        let afterRemoteLive = await coordinator.snapshot()
        let remoteAfterExclusion = await transport.allRecords()
        let remoteWinner = try XCTUnwrap(remoteAfterExclusion.first { $0.id == clip.id })
        XCTAssertTrue(afterRemoteLive.records[clip.id]?.isTombstone == true)
        XCTAssertTrue(remoteWinner.isTombstone)
        XCTAssertGreaterThan(remoteWinner.stamp, remoteLive.stamp)
        XCTAssertEqual(
            afterRemoteLive.entityStates[clip.id],
            .localOnly(reason: .fileReferenceIsDeviceLocal)
        )
        let afterRemoteMaterialized = await coordinator.materializedLibrary()
        XCTAssertFalse(afterRemoteMaterialized.savedClips.contains { $0.id == clip.id })
    }

    func testPreviouslySyncedFolderMarkedLocalOnlyUsesTombstoneButKeepsReason() async throws {
        let transport = InMemorySavedLibrarySyncTransport()
        let coordinator = SavedLibrarySyncCoordinator(
            deviceID: "mac-a",
            transport: transport,
            store: InMemorySavedLibrarySyncStateStore()
        )
        try await coordinator.setEnabled(true)
        let folder = try makeFolder()
        _ = try await coordinator.recordFolder(folder)
        await coordinator.synchronize()

        let decision = try await coordinator.markLocalOnly(.unsupported(id: folder.id))
        XCTAssertEqual(decision, .localOnly(.unsupportedEntityType))
        await coordinator.synchronize()

        let snapshot = await coordinator.snapshot()
        let materialized = await coordinator.materializedLibrary()
        XCTAssertTrue(snapshot.records[folder.id]?.isTombstone == true)
        XCTAssertEqual(
            snapshot.entityStates[folder.id],
            .localOnly(reason: .unsupportedEntityType)
        )
        XCTAssertFalse(materialized.folders.contains { $0.id == folder.id })
        let remoteFolders = await transport.allRecords()
        XCTAssertTrue(try XCTUnwrap(remoteFolders.first { $0.id == folder.id }).isTombstone)
    }

    func testRestoredLocalOnlyLiveOutboxIsTombstonedBeforeFirstUpload() async throws {
        let clip = try makeClip(folderID: nil, text: "must not upload")
        let live = try SavedLibrarySyncRecord.live(
            .savedClip(clip),
            stamp: LamportStamp(counter: 1, deviceID: "mac-a")
        )
        let restored = SavedLibrarySyncSnapshot(
            isEnabled: true,
            records: [clip.id: live],
            outbox: [clip.id: live],
            localLamportCounter: 1,
            status: .idle(lastSuccessfulSync: nil),
            entityStates: [
                clip.id: .localOnly(reason: .pendingSafetyAnalysis),
            ]
        )
        let transport = InMemorySavedLibrarySyncTransport()
        let coordinator = SavedLibrarySyncCoordinator(
            deviceID: "mac-a",
            transport: transport,
            store: InMemorySavedLibrarySyncStateStore(snapshot: restored),
            snapshot: restored
        )

        await coordinator.synchronize()

        let remoteRecords = await transport.allRecords()
        let remote = try XCTUnwrap(remoteRecords.first { $0.id == clip.id })
        let snapshot = await coordinator.snapshot()
        XCTAssertTrue(remote.isTombstone)
        XCTAssertTrue(snapshot.records[clip.id]?.isTombstone == true)
        XCTAssertEqual(
            snapshot.entityStates[clip.id],
            .localOnly(reason: .pendingSafetyAnalysis)
        )
    }

    func testPerEntityStateMovesQueuedUploadingSynced() async throws {
        let entered = SharingTestGate()
        let release = SharingTestGate()
        let transport = StateBlockingTransport(entered: entered, release: release)
        let syncedAt = Date(timeIntervalSince1970: 5_000)
        let coordinator = SavedLibrarySyncCoordinator(
            deviceID: "mac-a",
            transport: transport,
            store: InMemorySavedLibrarySyncStateStore(),
            now: { syncedAt }
        )
        try await coordinator.setEnabled(true)
        let clip = try makeClip(folderID: nil, text: "stateful")
        _ = try await coordinator.recordSavedClip(clip)
        let queuedState = await coordinator.entityState(for: clip.id)
        XCTAssertEqual(queuedState, .queued)

        let sync = Task { await coordinator.synchronize() }
        await entered.wait()
        let uploadingState = await coordinator.entityState(for: clip.id)
        XCTAssertEqual(uploadingState, .uploading)
        await release.open()
        await sync.value

        let syncedState = await coordinator.entityState(for: clip.id)
        XCTAssertEqual(syncedState, .synced(at: syncedAt, deviceID: "mac-a"))
    }

    func testPerEntityFailureAndConflictAreVisible() async throws {
        let failedCoordinator = SavedLibrarySyncCoordinator(
            deviceID: "mac-a",
            transport: FailingPushTransport(),
            store: InMemorySavedLibrarySyncStateStore()
        )
        try await failedCoordinator.setEnabled(true)
        let failedClip = try makeClip(folderID: nil, text: "fails")
        _ = try await failedCoordinator.recordSavedClip(failedClip)
        await failedCoordinator.synchronize()
        let failedState = await failedCoordinator.entityState(for: failedClip.id)
        guard case .failed = failedState else {
            return XCTFail("Expected an entity-level failed state")
        }

        let conflictID = UUID()
        let remoteClip = try makeClip(id: conflictID, folderID: nil, text: "remote wins")
        let remote = try SavedLibrarySyncRecord.live(
            .savedClip(remoteClip),
            stamp: LamportStamp(counter: 2, deviceID: "mac-z")
        )
        let conflictCoordinator = SavedLibrarySyncCoordinator(
            deviceID: "mac-a",
            transport: InMemorySavedLibrarySyncTransport(records: [remote]),
            store: InMemorySavedLibrarySyncStateStore()
        )
        try await conflictCoordinator.setEnabled(true)
        _ = try await conflictCoordinator.recordSavedClip(
            makeClip(id: conflictID, folderID: nil, text: "local loses")
        )
        await conflictCoordinator.synchronize()
        let conflictState = await conflictCoordinator.entityState(
            for: conflictID
        )
        guard case let .conflict(local, winningRemote) = conflictState else {
            return XCTFail("Expected an entity-level conflict state")
        }
        XCTAssertEqual(local.deviceID, "mac-a")
        XCTAssertEqual(winningRemote, remote.stamp)
    }

    func testSnapshotWithoutEntityStatesStillDecodesAsV1() throws {
        let data = try JSONEncoder().encode(SavedLibrarySyncSnapshot.disabled)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object.removeValue(forKey: "entityStates")

        let decoded = try JSONDecoder().decode(
            SavedLibrarySyncSnapshot.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertTrue(decoded.entityStates.isEmpty)
    }

    func testV2CloudIdentifiersCannotOverlapLegacySchema() {
        XCTAssertNotEqual(
            CloudKitSavedLibraryTransport.recordType,
            CloudKitSavedLibraryTransport.legacyV1RecordType
        )
        XCTAssertNotEqual(
            CloudKitSavedLibraryTransport.zoneName,
            CloudKitSavedLibraryTransport.legacyV1ZoneName
        )
        XCTAssertTrue(CloudKitSavedLibraryTransport.recordType.hasSuffix("V2"))
        XCTAssertTrue(CloudKitSavedLibraryTransport.zoneName.hasSuffix("V2"))
        XCTAssertTrue(CloudKitSharedFolderAdapter.entityRecordType.hasSuffix("V2"))
    }

    func testSharedFolderScopeMapsOneFolderToOneV2Zone() throws {
        let firstID = UUID()
        let secondID = UUID()
        let first = try SharedFolderScope(folderID: firstID, ownerParticipantID: "owner")
        let same = try SharedFolderScope(folderID: firstID, ownerParticipantID: "owner")
        let second = try SharedFolderScope(folderID: secondID, ownerParticipantID: "owner")

        XCTAssertEqual(first.zoneName, same.zoneName)
        XCTAssertNotEqual(first.zoneName, second.zoneName)
        XCTAssertEqual(CloudKitSharedFolderAdapter.folderID(fromV2ZoneName: first.zoneName), firstID)
        XCTAssertNil(CloudKitSharedFolderAdapter.folderID(fromV2ZoneName: "legacy-zone"))
    }

    func testOwnerEditorViewerPermissions() async throws {
        let scope = try SharedFolderScope(folderID: UUID(), ownerParticipantID: "owner")
        let participants = try [
            SharedFolderParticipant(id: "owner", role: .owner),
            SharedFolderParticipant(id: "editor", role: .editor),
            SharedFolderParticipant(id: "viewer", role: .viewer),
        ]
        let folder = try makeFolder(id: scope.folderID)
        let clip = try makeClip(folderID: scope.folderID, text: "shared")

        let owner = try SharedFolderCoordinator(
            scope: scope,
            currentParticipantID: "owner",
            deviceID: "owner-mac",
            participants: participants
        )
        _ = try await owner.recordRootFolder(folder)
        try await owner.setRole(.viewer, for: "editor")
        let ownerSnapshot = await owner.snapshot()
        XCTAssertEqual(ownerSnapshot.participants["editor"]?.role, .viewer)
        await assertSharedError(try await owner.setRole(.owner, for: "viewer")) {
            XCTAssertEqual($0, .ownerRoleIsImmutable)
        }

        let editor = try SharedFolderCoordinator(
            scope: scope,
            currentParticipantID: "editor",
            deviceID: "editor-mac",
            participants: participants
        )
        _ = try await editor.recordSavedClip(clip)
        _ = try await editor.recordDeletion(id: clip.id, kind: .savedClip)
        await assertSharedError(try await editor.recordRootFolder(folder)) {
            XCTAssertEqual($0, .permissionDenied)
        }

        let viewer = try SharedFolderCoordinator(
            scope: scope,
            currentParticipantID: "viewer",
            deviceID: "viewer-mac",
            participants: participants
        )
        await assertSharedError(try await viewer.recordSavedClip(clip)) {
            XCTAssertEqual($0, .permissionDenied)
        }
        await assertSharedError(try await viewer.recordDeletion(id: clip.id, kind: .savedClip)) {
            XCTAssertEqual($0, .permissionDenied)
        }
    }

    func testSharedFolderValidatesNestedSubtreeAndNotePayload() async throws {
        let scope = try SharedFolderScope(folderID: UUID(), ownerParticipantID: "owner")
        let participants = try [SharedFolderParticipant(id: "owner", role: .owner)]
        let coordinator = try SharedFolderCoordinator(
            scope: scope,
            currentParticipantID: "owner",
            deviceID: "owner-mac",
            participants: participants
        )
        _ = try await coordinator.recordRootFolder(makeFolder(id: scope.folderID))
        let child = try ClipFolder(
            name: "Nested",
            parentFolderID: scope.folderID,
            sortOrder: 0,
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        _ = try await coordinator.recordFolder(child)
        let note = try SavedClip(
            kind: .note,
            name: "Shared note",
            content: ClipContent(type: .plainText, text: "editable"),
            folderID: child.id,
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        _ = try await coordinator.recordSavedClip(note)
        let subtree = await coordinator.materializedSubtree()
        XCTAssertEqual(subtree.folders, [child])
        XCTAssertEqual(subtree.savedItems, [note])
    }

    func testSharedMergeRejectsEscapingAndCyclicFoldersAtomically() async throws {
        let scope = try SharedFolderScope(folderID: UUID(), ownerParticipantID: "owner")
        let participants = try [SharedFolderParticipant(id: "owner", role: .owner)]
        let coordinator = try SharedFolderCoordinator(
            scope: scope,
            currentParticipantID: "owner",
            deviceID: "owner-mac",
            participants: participants
        )
        let before = await coordinator.snapshot()
        let externalParent = UUID()
        let escaped = try ClipFolder(
            name: "Escape",
            parentFolderID: externalParent,
            sortOrder: 0,
            createdAt: .distantPast
        )
        let escapeRecord = try SharedFolderRecord.live(
            .folder(escaped),
            scope: scope,
            stamp: LamportStamp(counter: 1, deviceID: "remote"),
            authorParticipantID: "owner"
        )
        await assertSharedError(try await coordinator.merge([escapeRecord])) {
            guard case .wrongScope = $0 else { return XCTFail("Unexpected error: \($0)") }
        }
        let afterEscape = await coordinator.snapshot()
        XCTAssertEqual(afterEscape, before)

        let firstID = UUID(), secondID = UUID()
        let first = try ClipFolder(
            id: firstID, name: "First", parentFolderID: secondID,
            sortOrder: 0, createdAt: .distantPast
        )
        let second = try ClipFolder(
            id: secondID, name: "Second", parentFolderID: firstID,
            sortOrder: 0, createdAt: .distantPast
        )
        let cyclic = try [
            SharedFolderRecord.live(
                .folder(first), scope: scope,
                stamp: LamportStamp(counter: 2, deviceID: "remote"),
                authorParticipantID: "owner"
            ),
            SharedFolderRecord.live(
                .folder(second), scope: scope,
                stamp: LamportStamp(counter: 3, deviceID: "remote"),
                authorParticipantID: "owner"
            ),
        ]
        await assertSharedError(try await coordinator.merge(cyclic)) {
            guard case .hierarchyCycle = $0 else { return XCTFail("Unexpected error: \($0)") }
        }
        let afterCycle = await coordinator.snapshot()
        XCTAssertEqual(afterCycle, before)
    }

    func testSharedFolderReplicasConvergeForConcurrentEditsAndTombstones() async throws {
        let scope = try SharedFolderScope(folderID: UUID(), ownerParticipantID: "owner")
        let participants = try [SharedFolderParticipant(id: "owner", role: .owner)]
        let a = try SharedFolderCoordinator(
            scope: scope,
            currentParticipantID: "owner",
            deviceID: "device-a",
            participants: participants
        )
        let z = try SharedFolderCoordinator(
            scope: scope,
            currentParticipantID: "owner",
            deviceID: "device-z",
            participants: participants
        )
        let folder = try makeFolder(id: scope.folderID)
        _ = try await a.recordRootFolder(folder)
        _ = try await z.recordRootFolder(folder)
        let clipID = UUID()
        _ = try await a.recordSavedClip(
            makeClip(id: clipID, folderID: scope.folderID, text: "from a")
        )
        let expectedWinner = try makeClip(
            id: clipID,
            folderID: scope.folderID,
            text: "from z"
        )
        _ = try await z.recordSavedClip(expectedWinner)

        let recordsA = await a.recordsForUpload()
        let recordsZ = await z.recordsForUpload()
        try await a.merge(recordsZ)
        try await z.merge(recordsA)

        let convergedA = await a.snapshot()
        let convergedZ = await z.snapshot()
        let materializedWinner = await a.materialized()
        XCTAssertEqual(convergedA, convergedZ)
        XCTAssertEqual(materializedWinner.savedClips, [expectedWinner])

        let tombstone = try await z.recordDeletion(id: clipID, kind: .savedClip)
        try await a.merge([tombstone])
        let deletedA = await a.snapshot()
        let deletedZ = await z.snapshot()
        let afterDelete = await a.materialized()
        XCTAssertEqual(deletedA, deletedZ)
        XCTAssertTrue(afterDelete.savedClips.isEmpty)
    }

    func testSharedMergeRejectsWrongScopeAndViewerAuthoredBatchAtomically() async throws {
        let scope = try SharedFolderScope(folderID: UUID(), ownerParticipantID: "owner")
        let participants = try [
            SharedFolderParticipant(id: "owner", role: .owner),
            SharedFolderParticipant(id: "viewer", role: .viewer),
        ]
        let coordinator = try SharedFolderCoordinator(
            scope: scope,
            currentParticipantID: "owner",
            deviceID: "owner-mac",
            participants: participants
        )
        let original = await coordinator.snapshot()

        let otherScope = try SharedFolderScope(folderID: UUID(), ownerParticipantID: "owner")
        let wrongFolder = try makeFolder(id: otherScope.folderID)
        let wrongRecord = try SharedFolderRecord.live(
            .rootFolder(wrongFolder),
            scope: otherScope,
            stamp: LamportStamp(counter: 1, deviceID: "remote"),
            authorParticipantID: "owner"
        )
        await assertSharedError(try await coordinator.merge([wrongRecord])) { error in
            guard case .wrongScope = error else { return XCTFail("Unexpected error: \(error)") }
        }
        let afterWrongScope = await coordinator.snapshot()
        XCTAssertEqual(afterWrongScope, original)

        let viewerClip = try makeClip(folderID: scope.folderID, text: "unauthorized")
        let viewerRecord = try SharedFolderRecord.live(
            .savedClip(viewerClip, metadata: .ready),
            scope: scope,
            stamp: LamportStamp(counter: 1, deviceID: "viewer-mac"),
            authorParticipantID: "viewer"
        )
        await assertSharedError(try await coordinator.merge([viewerRecord])) {
            XCTAssertEqual($0, .permissionDenied)
        }
        let afterViewerRecord = await coordinator.snapshot()
        XCTAssertEqual(afterViewerRecord, original)
    }

    func testSharedCoordinatorAppliesEligibilityToLocalAndRemoteClips() async throws {
        let scope = try SharedFolderScope(folderID: UUID(), ownerParticipantID: "owner")
        let participants = try [SharedFolderParticipant(id: "owner", role: .owner)]
        let coordinator = try SharedFolderCoordinator(
            scope: scope,
            currentParticipantID: "owner",
            deviceID: "owner-mac",
            participants: participants
        )
        let fileClip = try makeFileClip(folderID: scope.folderID)

        await assertSharedError(try await coordinator.recordSavedClip(fileClip)) {
            XCTAssertEqual($0, .ineligible(fileClip.id, .fileReferenceIsDeviceLocal))
        }

        let locatedClip = try makeClip(folderID: scope.folderID, text: "located")
        let location = try CoarseLocationContext(label: "Toronto", geohash: "dpz83")
        let remoteLocatedRecord = try SharedFolderRecord.live(
            .savedClip(
                locatedClip,
                metadata: SavedClipSyncMetadata(coarseLocation: location)
            ),
            scope: scope,
            stamp: LamportStamp(counter: 1, deviceID: "remote-owner-mac"),
            authorParticipantID: "owner"
        )
        await assertSharedError(try await coordinator.merge([remoteLocatedRecord])) {
            XCTAssertEqual($0, .ineligible(locatedClip.id, .locationSharingDisabled))
        }
    }

    func testSharedFolderRestorationValidatesRecordsLikeLiveMerge() async throws {
        let scope = try SharedFolderScope(folderID: UUID(), ownerParticipantID: "owner")
        let participants = try [
            SharedFolderParticipant(id: "owner", role: .owner),
            SharedFolderParticipant(id: "editor", role: .editor),
            SharedFolderParticipant(id: "viewer", role: .viewer),
        ]
        let root = try SharedFolderRecord.live(
            .rootFolder(try makeFolder(id: scope.folderID)),
            scope: scope,
            stamp: LamportStamp(counter: 1, deviceID: "owner-mac"),
            authorParticipantID: "owner"
        )
        let clip = try makeClip(folderID: scope.folderID, text: "valid")
        let validClip = try SharedFolderRecord.live(
            .savedClip(clip, metadata: .ready),
            scope: scope,
            stamp: LamportStamp(counter: 2, deviceID: "editor-mac"),
            authorParticipantID: "editor"
        )
        XCTAssertNoThrow(
            try SharedFolderCoordinator(
                scope: scope,
                currentParticipantID: "owner",
                deviceID: "restore-mac",
                participants: participants,
                records: [root, validClip],
                localLamportCounter: 2
            )
        )

        let unknownAuthor = try SharedFolderRecord.live(
            .savedClip(clip, metadata: .ready),
            scope: scope,
            stamp: LamportStamp(counter: 2, deviceID: "stranger-mac"),
            authorParticipantID: "stranger"
        )
        XCTAssertThrowsError(
            try SharedFolderCoordinator(
                scope: scope,
                currentParticipantID: "owner",
                deviceID: "restore-mac",
                participants: participants,
                records: [unknownAuthor],
                localLamportCounter: 2
            )
        ) { XCTAssertEqual($0 as? SharedFolderError, .unknownParticipant("stranger")) }

        let viewerAuthored = try SharedFolderRecord.live(
            .savedClip(clip, metadata: .ready),
            scope: scope,
            stamp: LamportStamp(counter: 2, deviceID: "viewer-mac"),
            authorParticipantID: "viewer"
        )
        XCTAssertThrowsError(
            try SharedFolderCoordinator(
                scope: scope,
                currentParticipantID: "owner",
                deviceID: "restore-mac",
                participants: participants,
                records: [viewerAuthored],
                localLamportCounter: 2
            )
        ) { XCTAssertEqual($0 as? SharedFolderError, .permissionDenied) }

        let location = try CoarseLocationContext(label: "Toronto")
        let located = try SharedFolderRecord.live(
            .savedClip(clip, metadata: SavedClipSyncMetadata(coarseLocation: location)),
            scope: scope,
            stamp: LamportStamp(counter: 2, deviceID: "editor-mac"),
            authorParticipantID: "editor"
        )
        XCTAssertThrowsError(
            try SharedFolderCoordinator(
                scope: scope,
                currentParticipantID: "owner",
                deviceID: "restore-mac",
                participants: participants,
                records: [located],
                localLamportCounter: 2
            )
        ) {
            XCTAssertEqual(
                $0 as? SharedFolderError,
                .ineligible(clip.id, .locationSharingDisabled)
            )
        }

        let otherScope = try SharedFolderScope(folderID: UUID(), ownerParticipantID: "owner")
        let wrongScope = try SharedFolderRecord.live(
            .rootFolder(try makeFolder(id: otherScope.folderID)),
            scope: otherScope,
            stamp: LamportStamp(counter: 1, deviceID: "owner-mac"),
            authorParticipantID: "owner"
        )
        XCTAssertThrowsError(
            try SharedFolderCoordinator(
                scope: scope,
                currentParticipantID: "owner",
                deviceID: "restore-mac",
                participants: participants,
                records: [wrongScope],
                localLamportCounter: 1
            )
        ) { error in
            guard let sharedError = error as? SharedFolderError,
                  case .wrongScope = sharedError
            else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testSharedFolderRestorationRejectsInconsistentLamportState() throws {
        let scope = try SharedFolderScope(folderID: UUID(), ownerParticipantID: "owner")
        let participants = try [SharedFolderParticipant(id: "owner", role: .owner)]
        let root = try SharedFolderRecord.live(
            .rootFolder(try makeFolder(id: scope.folderID)),
            scope: scope,
            stamp: LamportStamp(counter: 2, deviceID: "owner-mac"),
            authorParticipantID: "owner"
        )
        XCTAssertThrowsError(
            try SharedFolderCoordinator(
                scope: scope,
                currentParticipantID: "owner",
                deviceID: "restore-mac",
                participants: participants,
                records: [root],
                localLamportCounter: 1
            )
        )

        let sameStamp = try LamportStamp(counter: 2, deviceID: "owner-mac")
        let clip = try SharedFolderRecord.live(
            .savedClip(
                try makeClip(folderID: scope.folderID, text: "duplicate stamp"),
                metadata: .ready
            ),
            scope: scope,
            stamp: sameStamp,
            authorParticipantID: "owner"
        )
        XCTAssertThrowsError(
            try SharedFolderCoordinator(
                scope: scope,
                currentParticipantID: "owner",
                deviceID: "restore-mac",
                participants: participants,
                records: [root, clip],
                localLamportCounter: 2
            )
        ) { error in
            guard let sharedError = error as? SharedFolderError,
                  case .stampCollision = sharedError
            else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testSharedLiveMergeRejectsStampReuseAcrossEntitiesAtomically() async throws {
        let scope = try SharedFolderScope(folderID: UUID(), ownerParticipantID: "owner")
        let participants = try [SharedFolderParticipant(id: "owner", role: .owner)]
        let rootStamp = try LamportStamp(counter: 1, deviceID: "owner-mac")
        let root = try SharedFolderRecord.live(
            .rootFolder(try makeFolder(id: scope.folderID)),
            scope: scope,
            stamp: rootStamp,
            authorParticipantID: "owner"
        )
        let coordinator = try SharedFolderCoordinator(
            scope: scope,
            currentParticipantID: "owner",
            deviceID: "restore-mac",
            participants: participants,
            records: [root],
            localLamportCounter: 1
        )
        let reused = try SharedFolderRecord.live(
            .savedClip(
                try makeClip(folderID: scope.folderID, text: "reused"),
                metadata: .ready
            ),
            scope: scope,
            stamp: rootStamp,
            authorParticipantID: "owner"
        )
        let before = await coordinator.snapshot()

        await assertSharedError(try await coordinator.merge([reused])) { error in
            guard case .stampCollision = error else { return XCTFail("Unexpected error: \(error)") }
        }
        let after = await coordinator.snapshot()
        XCTAssertEqual(after, before)
    }

    func testCloudKitSharingIsCapabilityGatedWithoutNetwork() async throws {
        let adapter = CloudKitSharedFolderAdapter(configuration: .disabled)
        let capability = await adapter.capability()
        XCTAssertEqual(capability, .unavailable(.featureDisabled))
        let scope = try SharedFolderScope(folderID: UUID(), ownerParticipantID: "owner")

        await assertSharedError(try await adapter.createShare(for: scope, title: "Research")) {
            XCTAssertEqual($0, .cloudCapabilityUnavailable(.featureDisabled))
        }
    }

    func testInMemorySharedFolderSessionCreatesAndSynchronizesExactFolderScope() async throws {
        let transport = InMemorySharedFolderTransport(participantID: "owner")
        let folder = try makeFolder()
        let clip = try makeClip(folderID: folder.id, text: "shared")

        let session = try await SharedFolderSession.create(
            folder: folder,
            savedClips: [clip],
            deviceID: "owner-mac",
            transport: transport
        )
        let snapshot = await session.snapshot()

        XCTAssertEqual(snapshot.folder, folder)
        XCTAssertEqual(snapshot.savedClips, [clip])
        XCTAssertEqual(snapshot.currentRole, .owner)
        XCTAssertEqual(snapshot.location.databaseScope, .ownerPrivate)
        XCTAssertEqual(snapshot.participants.map(\.role), [.owner])
        if case .synced = snapshot.status {} else {
            XCTFail("Expected synchronized shared-folder state")
        }
        let createCallCount = await transport.createCallCount
        let synchronizeCallCount = await transport.synchronizeCallCount
        XCTAssertEqual(createCallCount, 1)
        XCTAssertEqual(synchronizeCallCount, 1)
    }

    func testSharedSessionSynchronizesCompleteNestedSubtreeAndSafeReparentDeletion() async throws {
        let root = try makeFolder()
        let child = try ClipFolder(
            name: "Child",
            parentFolderID: root.id,
            sortOrder: 1,
            createdAt: Date(timeIntervalSince1970: 1_001)
        )
        let grandchild = try ClipFolder(
            name: "Grandchild",
            parentFolderID: child.id,
            sortOrder: 2,
            createdAt: Date(timeIntervalSince1970: 1_002)
        )
        let note = try SavedClip(
            kind: .note,
            name: "Nested note",
            content: ClipContent(type: .plainText, text: "shared body"),
            folderID: grandchild.id,
            createdAt: Date(timeIntervalSince1970: 1_003)
        )
        let transport = InMemorySharedFolderTransport(participantID: "owner")
        let session = try await SharedFolderSession.create(
            folder: root,
            folders: [grandchild, child],
            savedClips: [note],
            deviceID: "owner-mac",
            transport: transport
        )
        var snapshot = await session.snapshot()
        XCTAssertEqual(Set(snapshot.folders.map(\.id)), [child.id, grandchild.id])
        XCTAssertEqual(snapshot.savedClips, [note])
        XCTAssertEqual(snapshot.managedFolderIDs, [root.id, child.id, grandchild.id])

        let reparentedGrandchild = try ClipFolder(
            id: grandchild.id,
            name: grandchild.name,
            parentFolderID: root.id,
            sortOrder: grandchild.sortOrder,
            createdAt: grandchild.createdAt,
            modifiedAt: Date(timeIntervalSince1970: 2_000)
        )
        let movedNote = try SavedClip(
            id: note.id,
            kind: .note,
            name: note.name,
            content: note.content,
            folderID: reparentedGrandchild.id,
            createdAt: note.createdAt,
            modifiedAt: Date(timeIntervalSince1970: 2_000)
        )
        snapshot = try await session.synchronizeLocal(
            folder: root,
            folders: [reparentedGrandchild],
            savedClips: [movedNote]
        )
        let expectedRemoteGrandchild = try ClipFolder(
            id: reparentedGrandchild.id,
            name: reparentedGrandchild.name,
            parentFolderID: root.id,
            sortOrder: 0,
            createdAt: reparentedGrandchild.createdAt,
            modifiedAt: reparentedGrandchild.modifiedAt
        )
        XCTAssertEqual(snapshot.folders, [expectedRemoteGrandchild])
        XCTAssertEqual(snapshot.savedClips, [movedNote])
        XCTAssertTrue(snapshot.managedFolderIDs.contains(child.id), "tombstones stay managed")

        let reopened = try await SharedFolderSession.open(
            remote: try await transport.synchronize([], at: snapshot.location),
            deviceID: "second-mac",
            transport: transport
        )
        let remote = await reopened.snapshot()
        XCTAssertEqual(remote.folders, [expectedRemoteGrandchild])
        XCTAssertEqual(remote.savedClips, [movedNote])
    }

    func testSharedFolderSessionPublishesTombstonesAndSurfacesTransportFailure() async throws {
        let transport = InMemorySharedFolderTransport(participantID: "owner")
        let folder = try makeFolder()
        let clip = try makeClip(folderID: folder.id, text: "delete me")
        let session = try await SharedFolderSession.create(
            folder: folder,
            savedClips: [clip],
            deviceID: "owner-mac",
            transport: transport
        )

        let afterDelete = try await session.synchronizeLocal(folder: folder, savedClips: [])
        XCTAssertTrue(afterDelete.savedClips.isEmpty)
        XCTAssertEqual(afterDelete.managedSavedClipIDs, [clip.id])

        await transport.failNext(.cloudCapabilityUnavailable(.temporarilyUnavailable))
        await assertSharedError(try await session.refresh()) {
            XCTAssertEqual($0, .cloudCapabilityUnavailable(.temporarilyUnavailable))
        }
        let failed = await session.snapshot()
        guard case let .failed(message) = failed.status else {
            return XCTFail("Expected per-folder failure state")
        }
        XCTAssertTrue(message.contains("temporarilyUnavailable"))
    }

    func testViewerSessionRejectsLocalMutationBeforeTransport() async throws {
        let folder = try makeFolder()
        let scope = try SharedFolderScope(folderID: folder.id, ownerParticipantID: "owner")
        let root = try SharedFolderRecord.live(
            .rootFolder(folder),
            scope: scope,
            stamp: LamportStamp(counter: 1, deviceID: "owner-mac"),
            authorParticipantID: "owner"
        )
        let location = SharedFolderRemoteLocation(
            folderID: folder.id,
            zoneName: scope.zoneName,
            ownerName: "cloud-owner",
            ownerParticipantID: "owner",
            shareRecordName: "zone-wide-share",
            databaseScope: .participantShared,
            title: folder.name
        )
        let participants = try [
            SharedFolderCloudParticipant(
                id: "owner",
                displayName: "Owner",
                role: .owner,
                acceptance: .accepted
            ),
            SharedFolderCloudParticipant(
                id: "viewer",
                displayName: "Viewer",
                role: .viewer,
                acceptance: .accepted
            ),
        ]
        let remote = try SharedFolderTransportSnapshot(
            location: location,
            currentParticipantID: "viewer",
            participants: participants,
            records: [root]
        )
        let transport = InMemorySharedFolderTransport(
            participantID: "viewer",
            snapshots: [remote]
        )
        let session = try await SharedFolderSession.open(
            remote: remote,
            deviceID: "viewer-mac",
            transport: transport
        )
        let unauthorized = try makeClip(folderID: folder.id, text: "must not upload")

        await assertSharedError(
            try await session.synchronizeLocal(folder: folder, savedClips: [unauthorized])
        ) {
            XCTAssertEqual($0, .permissionDenied)
        }
        let synchronizeCallCount = await transport.synchronizeCallCount
        XCTAssertEqual(synchronizeCallCount, 0)
    }

    func testHistoricalEditorRecordsSurviveDowngradeAndRemovalButCannotBeRewritten() async throws {
        let folder = try makeFolder()
        let clip = try makeClip(folderID: folder.id, text: "historical")
        let scope = try SharedFolderScope(folderID: folder.id, ownerParticipantID: "owner")
        let root = try SharedFolderRecord.live(
            .rootFolder(folder),
            scope: scope,
            stamp: LamportStamp(counter: 1, deviceID: "owner-mac"),
            authorParticipantID: "owner"
        )
        let editorRecord = try SharedFolderRecord.live(
            .savedClip(clip, metadata: .ready),
            scope: scope,
            stamp: LamportStamp(counter: 2, deviceID: "editor-mac"),
            authorParticipantID: "former-editor"
        )
        let location = SharedFolderRemoteLocation(
            folderID: folder.id,
            zoneName: scope.zoneName,
            ownerName: "cloud-owner",
            ownerParticipantID: "owner",
            shareRecordName: "zone-wide-share",
            databaseScope: .participantShared,
            title: folder.name
        )
        let owner = try SharedFolderCloudParticipant(
            id: "owner",
            displayName: "Owner",
            role: .owner,
            acceptance: .accepted
        )
        let downgraded = try SharedFolderCloudParticipant(
            id: "former-editor",
            displayName: "Former editor",
            role: .viewer,
            acceptance: .accepted
        )
        let authorizations = try [
            SharedFolderRecordAuthorization(
                recordID: root.id,
                authorParticipantID: "owner",
                roleAtWrite: .owner
            ),
            SharedFolderRecordAuthorization(
                recordID: editorRecord.id,
                authorParticipantID: "former-editor",
                roleAtWrite: .editor
            ),
        ]
        let downgradedRemote = try SharedFolderTransportSnapshot(
            location: location,
            currentParticipantID: "former-editor",
            participants: [owner, downgraded],
            records: [root, editorRecord],
            recordAuthorizations: authorizations
        )
        let downgradedTransport = InMemorySharedFolderTransport(
            participantID: "former-editor",
            snapshots: [downgradedRemote]
        )
        let downgradedSession = try await SharedFolderSession.open(
            remote: downgradedRemote,
            deviceID: "former-editor-new-mac",
            transport: downgradedTransport
        )

        let unchanged = try await downgradedSession.synchronizeLocal(
            folder: folder,
            savedClips: [clip]
        )
        XCTAssertEqual(unchanged.savedClips, [clip])
        let changed = try makeClip(id: clip.id, folderID: folder.id, text: "forbidden rewrite")
        await assertSharedError(
            try await downgradedSession.synchronizeLocal(folder: folder, savedClips: [changed])
        ) {
            XCTAssertEqual($0, .permissionDenied)
        }

        let viewer = try SharedFolderCloudParticipant(
            id: "viewer",
            displayName: "Viewer",
            role: .viewer,
            acceptance: .accepted
        )
        let removedAuthorRemote = try SharedFolderTransportSnapshot(
            location: location,
            currentParticipantID: "viewer",
            participants: [owner, viewer],
            records: [root, editorRecord],
            recordAuthorizations: authorizations
        )
        let removedAuthorSession = try await SharedFolderSession.open(
            remote: removedAuthorRemote,
            deviceID: "viewer-mac",
            transport: InMemorySharedFolderTransport(
                participantID: "viewer",
                snapshots: [removedAuthorRemote]
            )
        )
        let removedAuthorSnapshot = await removedAuthorSession.snapshot()
        XCTAssertEqual(removedAuthorSnapshot.savedClips, [clip])
    }

    func testHistoricalAuthorizationEvidenceFailsClosedWhenMissingOrForged() throws {
        let folder = try makeFolder()
        let clip = try makeClip(folderID: folder.id, text: "historical")
        let scope = try SharedFolderScope(folderID: folder.id, ownerParticipantID: "owner")
        let root = try SharedFolderRecord.live(
            .rootFolder(folder),
            scope: scope,
            stamp: LamportStamp(counter: 1, deviceID: "owner-mac"),
            authorParticipantID: "owner"
        )
        let editorRecord = try SharedFolderRecord.live(
            .savedClip(clip, metadata: .ready),
            scope: scope,
            stamp: LamportStamp(counter: 2, deviceID: "editor-mac"),
            authorParticipantID: "removed-editor"
        )
        let location = SharedFolderRemoteLocation(
            folderID: folder.id,
            zoneName: scope.zoneName,
            ownerName: "cloud-owner",
            ownerParticipantID: "owner",
            shareRecordName: "zone-wide-share",
            databaseScope: .participantShared,
            title: folder.name
        )
        let participants = try [
            SharedFolderCloudParticipant(
                id: "owner",
                displayName: "Owner",
                role: .owner,
                acceptance: .accepted
            ),
            SharedFolderCloudParticipant(
                id: "viewer",
                displayName: "Viewer",
                role: .viewer,
                acceptance: .accepted
            ),
        ]

        XCTAssertThrowsError(
            try SharedFolderTransportSnapshot(
                location: location,
                currentParticipantID: "viewer",
                participants: participants,
                records: [root, editorRecord]
            )
        )
        let forged = try [
            SharedFolderRecordAuthorization(
                recordID: root.id,
                authorParticipantID: "owner",
                roleAtWrite: .owner
            ),
            SharedFolderRecordAuthorization(
                recordID: editorRecord.id,
                authorParticipantID: "removed-editor",
                roleAtWrite: .viewer
            ),
        ]
        XCTAssertThrowsError(
            try SharedFolderTransportSnapshot(
                location: location,
                currentParticipantID: "viewer",
                participants: participants,
                records: [root, editorRecord],
                recordAuthorizations: forged
            )
        ) { error in
            XCTAssertEqual(error as? SharedFolderError, .permissionDenied)
        }
    }

    func testFolderSortOrderIsDeviceLocalForViewerSessions() async throws {
        let folder = try makeFolder()
        let scope = try SharedFolderScope(folderID: folder.id, ownerParticipantID: "owner")
        let root = try SharedFolderRecord.live(
            .rootFolder(folder),
            scope: scope,
            stamp: LamportStamp(counter: 1, deviceID: "owner-mac"),
            authorParticipantID: "owner"
        )
        let location = SharedFolderRemoteLocation(
            folderID: folder.id,
            zoneName: scope.zoneName,
            ownerName: "cloud-owner",
            ownerParticipantID: "owner",
            shareRecordName: "zone-wide-share",
            databaseScope: .participantShared,
            title: folder.name
        )
        let participants = try [
            SharedFolderCloudParticipant(
                id: "owner",
                displayName: "Owner",
                role: .owner,
                acceptance: .accepted
            ),
            SharedFolderCloudParticipant(
                id: "viewer",
                displayName: "Viewer",
                role: .viewer,
                acceptance: .accepted
            ),
        ]
        let remote = try SharedFolderTransportSnapshot(
            location: location,
            currentParticipantID: "viewer",
            participants: participants,
            records: [root]
        )
        let transport = InMemorySharedFolderTransport(
            participantID: "viewer",
            snapshots: [remote]
        )
        let session = try await SharedFolderSession.open(
            remote: remote,
            deviceID: "viewer-mac",
            transport: transport
        )
        let locallyOrdered = try ClipFolder(
            id: folder.id,
            name: folder.name,
            sortOrder: 42,
            createdAt: folder.createdAt,
            modifiedAt: folder.modifiedAt.addingTimeInterval(100)
        )

        let synchronized = try await session.synchronizeLocal(
            folder: locallyOrdered,
            savedClips: []
        )

        XCTAssertEqual(synchronized.folder?.sortOrder, 0)
        let synchronizeCallCount = await transport.synchronizeCallCount
        XCTAssertEqual(synchronizeCallCount, 1)
    }

    func testInMemorySharedFolderTransportFailsClosedWhenCapabilityMissing() async throws {
        let transport = InMemorySharedFolderTransport(
            participantID: "owner",
            capability: .unavailable(.configurationMissing)
        )

        await assertSharedError(
            try await SharedFolderSession.create(
                folder: makeFolder(),
                savedClips: [],
                deviceID: "owner-mac",
                transport: transport
            )
        ) {
            XCTAssertEqual($0, .cloudCapabilityUnavailable(.configurationMissing))
        }
        let createCallCount = await transport.createCallCount
        let synchronizeCallCount = await transport.synchronizeCallCount
        XCTAssertEqual(createCallCount, 0)
        XCTAssertEqual(synchronizeCallCount, 0)
    }

    func testSharedFolderSessionPreflightsEveryClipBeforeCreatingRemoteShare() async throws {
        let folder = try makeFolder()
        let localFile = try makeFileClip(folderID: folder.id)
        let transport = InMemorySharedFolderTransport(participantID: "owner")

        await assertSharedError(
            try await SharedFolderSession.create(
                folder: folder,
                savedClips: [localFile],
                deviceID: "owner-mac",
                transport: transport
            )
        ) {
            XCTAssertEqual(
                $0,
                .ineligible(localFile.id, .fileReferenceIsDeviceLocal)
            )
        }
        let createCallCount = await transport.createCallCount
        XCTAssertEqual(createCallCount, 0)
    }

    private func makeFolder(id: UUID = UUID()) throws -> ClipFolder {
        try ClipFolder(
            id: id,
            name: "Research",
            sortOrder: 0,
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    private func makeClip(
        id: UUID = UUID(),
        folderID: UUID?,
        text: String
    ) throws -> SavedClip {
        try SavedClip(
            id: id,
            name: "Saved",
            content: ClipContent(type: .plainText, text: text),
            folderID: folderID,
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    private func makeFileClip(id: UUID = UUID(), folderID: UUID) throws -> SavedClip {
        let reference = try ClipFileReference(
            url: URL(fileURLWithPath: "/tmp/clipboard-router-local-file.txt")
        )
        let content = try ClipContent(
            type: .fileURLs,
            text: reference.displayName,
            representations: ClipRepresentations(files: [reference])
        )
        return try SavedClip(
            id: id,
            name: "Local file",
            content: content,
            folderID: folderID,
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    private func makeAssetClip(
        folderID: UUID,
        location: CoarseLocationContext? = nil
    ) throws -> SavedClip {
        let reference = try ClipAssetReference(
            digest: String(repeating: "a", count: 64),
            kind: .image,
            uniformTypeIdentifier: "public.png",
            byteCount: 4,
            relativePath: "aa/image.png"
        )
        let content = try ClipContent(
            type: .image,
            text: "image",
            representations: ClipRepresentations(image: reference)
        )
        return try SavedClip(
            name: "Local image",
            content: content,
            folderID: folderID,
            createdAt: Date(timeIntervalSince1970: 1_000),
            captureContext: location.map { ClipCaptureContext(coarseLocation: $0) }
        )
    }
}

private actor SharingTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor StateBlockingTransport: SavedLibrarySyncTransport {
    let entered: SharingTestGate
    let release: SharingTestGate

    init(entered: SharingTestGate, release: SharingTestGate) {
        self.entered = entered
        self.release = release
    }

    func accountIdentity() async throws -> SyncAccountIdentity {
        SyncAccountIdentity(state: .available, fingerprint: "account")
    }

    func fetchChanges(after token: Data?) async throws -> SyncFetchBatch {
        SyncFetchBatch(records: [], changeToken: token)
    }

    func push(_ records: [SavedLibrarySyncRecord]) async throws {
        await entered.open()
        await release.wait()
    }
}

private actor FailingPushTransport: SavedLibrarySyncTransport {
    func accountIdentity() async throws -> SyncAccountIdentity {
        SyncAccountIdentity(state: .available, fingerprint: "account")
    }

    func fetchChanges(after token: Data?) async throws -> SyncFetchBatch {
        SyncFetchBatch(records: [], changeToken: token)
    }

    func push(_ records: [SavedLibrarySyncRecord]) async throws {
        throw SavedLibrarySyncError.transportFailure("simulated push failure")
    }
}

private func assertSyncError<T>(
    _ expression: @autoclosure () async throws -> T,
    _ handler: (SavedLibrarySyncError) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("Expected SavedLibrarySyncError")
    } catch let error as SavedLibrarySyncError {
        handler(error)
    } catch {
        XCTFail("Unexpected error: \(error)")
    }
}

private func assertSharedError<T>(
    _ expression: @autoclosure () async throws -> T,
    _ handler: (SharedFolderError) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("Expected SharedFolderError")
    } catch let error as SharedFolderError {
        handler(error)
    } catch {
        XCTFail("Unexpected error: \(error)")
    }
}
