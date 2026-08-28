import ClipboardRouterCore
import CloudKit
import Foundation
import XCTest
@testable import ClipboardRouterSync

final class SavedLibrarySyncTests: XCTestCase {
    func testNoteKindAndEditableContentRoundTripThroughPersonalSync() async throws {
        let note = try SavedClip(
            kind: .note,
            name: "Research note",
            content: ClipContent(type: .plainText, text: "first draft"),
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        let transport = InMemorySavedLibrarySyncTransport()
        let sender = SavedLibrarySyncCoordinator(
            deviceID: "sender",
            transport: transport,
            store: InMemorySavedLibrarySyncStateStore()
        )
        try await sender.setEnabled(true)
        _ = try await sender.recordSavedClip(note)
        await sender.synchronize()

        let receiver = SavedLibrarySyncCoordinator(
            deviceID: "receiver",
            transport: transport,
            store: InMemorySavedLibrarySyncStateStore()
        )
        try await receiver.setEnabled(true)
        await receiver.synchronize()
        let materialized = await receiver.materializedLibrary()
        XCTAssertEqual(materialized.savedClips, [note])
        XCTAssertEqual(materialized.savedClips.first?.kind, .note)
        XCTAssertEqual(materialized.savedClips.first?.content.text, "first draft")
    }

    func testDependencyOrderPlacesNestedParentsBeforeChildrenAndItems() throws {
        let root = try ClipFolder(name: "Root", sortOrder: 0, createdAt: .distantPast)
        let child = try ClipFolder(
            name: "Child",
            parentFolderID: root.id,
            sortOrder: 0,
            createdAt: .distantPast
        )
        let item = try SavedClip(
            kind: .note,
            name: "Note",
            content: ClipContent(type: .plainText, text: "body"),
            folderID: child.id,
            createdAt: .distantPast
        )
        let stamp = try LamportStamp(counter: 1, deviceID: "mac")
        let ordered = SavedLibrarySyncRecord.dependencyOrdered([
            try .live(.savedClip(item), stamp: stamp),
            try .live(.folder(child), stamp: stamp),
            try .live(.folder(root), stamp: stamp),
        ])
        XCTAssertEqual(ordered.map(\.id), [root.id, child.id, item.id])
    }

    func testDeletedParentPromotesChildWithStableCorrection() async throws {
        let coordinator = SavedLibrarySyncCoordinator(
            deviceID: "mac",
            transport: InMemorySavedLibrarySyncTransport(),
            store: InMemorySavedLibrarySyncStateStore()
        )
        let root = try ClipFolder(name: "Root", sortOrder: 0, createdAt: .distantPast)
        let child = try ClipFolder(
            name: "Child",
            parentFolderID: root.id,
            sortOrder: 0,
            createdAt: .distantPast
        )
        _ = try await coordinator.recordFolder(root)
        _ = try await coordinator.recordFolder(child)
        _ = try await coordinator.recordDeletion(id: root.id, kind: .folder)
        let snapshot = await coordinator.snapshot()
        guard case let .folder(corrected)? = snapshot.records[child.id]?.payload else {
            return XCTFail("Missing child correction")
        }
        XCTAssertNil(corrected.parentFolderID)
        XCTAssertEqual(snapshot.records[child.id], snapshot.outbox[child.id])
    }
    func testCorruptPersistedCloudKitTokenFallsBackToFullRefetchCursor() {
        XCTAssertNil(
            CloudKitSavedLibraryTransport.decodeServerToken(
                Data("not-a-secure-cloudkit-token".utf8)
            )
        )
        XCTAssertNil(CloudKitSavedLibraryTransport.decodeServerToken(nil))
    }

    func testCloudKitRetryDelayHonorsOnlyRetryableErrors() {
        for code in [CKError.serviceUnavailable, .requestRateLimited] {
            let error = CKError(code, userInfo: [CKErrorRetryAfterKey: NSNumber(value: 2.75)])
            XCTAssertEqual(CloudKitSavedLibraryTransport.retryDelay(for: error), 2.75)
        }
        XCTAssertNil(
            CloudKitSavedLibraryTransport.retryDelay(
                for: CKError(.networkFailure, userInfo: [CKErrorRetryAfterKey: NSNumber(value: 2)])
            )
        )
        XCTAssertNil(
            CloudKitSavedLibraryTransport.retryDelay(
                for: CKError(.serviceUnavailable, userInfo: [CKErrorRetryAfterKey: NSNumber(value: -1)])
            )
        )
    }

    func testCloudKitQuotaErrorsMapToActionableQuotaState() {
        for code in [CKError.quotaExceeded, .limitExceeded] {
            XCTAssertEqual(
                CloudKitSavedLibraryTransport.mapError(CKError(code)),
                .quotaExceeded
            )
        }
        XCTAssertTrue(
            SavedLibrarySyncError.quotaExceeded.localizedDescription.contains("Local changes remain queued")
        )
    }

    func testDisableInvalidatesInFlightSyncAndPreventsLaterFetchOrCommit() async throws {
        let pushEntered = SyncTestGate()
        let releasePush = SyncTestGate()
        let transport = BlockingSyncTransport(pushEntered: pushEntered, releasePush: releasePush)
        let coordinator = SavedLibrarySyncCoordinator(
            deviceID: "mac-a",
            transport: transport,
            store: InMemorySavedLibrarySyncStateStore()
        )
        try await coordinator.setEnabled(true)
        _ = try await coordinator.recordSavedClip(makeClip(text: "queued before opt-out"))

        let firstSync = Task { await coordinator.synchronize() }
        await pushEntered.wait()
        let secondSync = Task { await coordinator.synchronize() }
        await Task.yield()
        let identityCallsBeforeRelease = await transport.identityCallsValue()
        XCTAssertEqual(identityCallsBeforeRelease, 1, "Only one sync run may enter transport")

        try await coordinator.setEnabled(false)
        await releasePush.open()
        await firstSync.value
        await secondSync.value

        let snapshot = await coordinator.snapshot()
        XCTAssertFalse(snapshot.isEnabled)
        XCTAssertEqual(snapshot.status, .disabled)
        XCTAssertEqual(snapshot.outbox.count, 1)
        let fetchCalls = await transport.fetchCallsValue()
        XCTAssertEqual(fetchCalls, 0)
    }

    func testConcurrentLocalMutationWaitsForSyncWithoutLosingOutbox() async throws {
        let pushEntered = SyncTestGate()
        let releasePush = SyncTestGate()
        let transport = BlockingSyncTransport(pushEntered: pushEntered, releasePush: releasePush)
        let coordinator = SavedLibrarySyncCoordinator(
            deviceID: "mac-a",
            transport: transport,
            store: InMemorySavedLibrarySyncStateStore()
        )
        try await coordinator.setEnabled(true)
        _ = try await coordinator.recordSavedClip(makeClip(text: "first"))
        let sync = Task { await coordinator.synchronize() }
        await pushEntered.wait()
        let folder = try makeFolder(name: "Created during sync")
        let localMutation = Task { try await coordinator.recordFolder(folder) }
        await Task.yield()
        await releasePush.open()
        await sync.value
        _ = try await localMutation.value

        let snapshot = await coordinator.snapshot()
        XCTAssertEqual(snapshot.records[folder.id]?.payload, .folder(folder))
        XCTAssertEqual(snapshot.outbox[folder.id]?.payload, .folder(folder))
    }

    func testAccountSwitchRequiresExplicitConfirmationBeforeOldOutboxUpload() async throws {
        let transport = InMemorySavedLibrarySyncTransport(accountFingerprint: "account-a")
        let coordinator = SavedLibrarySyncCoordinator(
            deviceID: "mac-a",
            transport: transport,
            store: InMemorySavedLibrarySyncStateStore()
        )
        try await coordinator.setEnabled(true)
        let folder = try makeFolder(name: "Account A library")
        let clip = try makeClip(text: "account a clip", folderID: folder.id)
        _ = try await coordinator.recordFolder(folder)
        _ = try await coordinator.recordSavedClip(clip)
        await coordinator.synchronize()
        let pushesOnA = await transport.pushCallCount
        let afterInitialSync = await coordinator.snapshot()
        XCTAssertEqual(pushesOnA, 1)
        XCTAssertTrue(afterInitialSync.outbox.isEmpty)

        await transport.resetRemoteRecordsForTesting()
        await transport.setAccountFingerprint("account-b")
        await coordinator.synchronize()
        let pending = await coordinator.snapshot()
        let pushesBeforeConfirmation = await transport.pushCallCount
        XCTAssertEqual(pending.confirmedAccountFingerprint, "account-a")
        XCTAssertEqual(pending.pendingAccountFingerprint, "account-b")
        XCTAssertEqual(pushesBeforeConfirmation, pushesOnA)

        try await coordinator.confirmPendingAccountChange()
        await coordinator.synchronize()
        let confirmed = await coordinator.snapshot()
        let pushesAfterConfirmation = await transport.pushCallCount
        let migratedRemoteIDs = Set(await transport.allRecords().map(\.id))
        XCTAssertEqual(confirmed.confirmedAccountFingerprint, "account-b")
        XCTAssertNil(confirmed.pendingAccountFingerprint)
        XCTAssertGreaterThan(pushesAfterConfirmation, pushesOnA)
        XCTAssertEqual(migratedRemoteIDs, Set([folder.id, clip.id]))
    }

    func testMalformedRecordsAndLamportOverflowFailClosed() async throws {
        let clip = try makeClip(text: "validate me")
        let valid = try SavedLibrarySyncRecord.live(
            .savedClip(clip),
            stamp: try LamportStamp(counter: 1, deviceID: "mac-a")
        )
        let encoder = JSONEncoder()
        let validObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(valid)) as? [String: Any]
        )

        var negativeCounter = validObject
        var negativeStamp = try XCTUnwrap(negativeCounter["stamp"] as? [String: Any])
        negativeStamp["counter"] = -1
        negativeCounter["stamp"] = negativeStamp
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                SavedLibrarySyncRecord.self,
                from: JSONSerialization.data(withJSONObject: negativeCounter)
            )
        )

        var blankDevice = validObject
        var blankStamp = try XCTUnwrap(blankDevice["stamp"] as? [String: Any])
        blankStamp["deviceID"] = " "
        blankDevice["stamp"] = blankStamp
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                SavedLibrarySyncRecord.self,
                from: JSONSerialization.data(withJSONObject: blankDevice)
            )
        )

        var tombstoneWithPayload = validObject
        tombstoneWithPayload["isTombstone"] = true
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                SavedLibrarySyncRecord.self,
                from: JSONSerialization.data(withJSONObject: tombstoneWithPayload)
            )
        )

        var wrongIdentity = validObject
        wrongIdentity["id"] = UUID().uuidString
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                SavedLibrarySyncRecord.self,
                from: JSONSerialization.data(withJSONObject: wrongIdentity)
            )
        )

        var blankName = validObject
        XCTAssertTrue(replaceJSONValue(key: "name", with: "   ", in: &blankName))
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                SavedLibrarySyncRecord.self,
                from: JSONSerialization.data(withJSONObject: blankName)
            )
        )

        let overflowSnapshot = SavedLibrarySyncSnapshot(
            isEnabled: true,
            localLamportCounter: Int64.max - 1,
            status: .idle(lastSuccessfulSync: nil)
        )
        let overflow = SavedLibrarySyncCoordinator(
            deviceID: "mac-a",
            transport: InMemorySavedLibrarySyncTransport(),
            store: InMemorySavedLibrarySyncStateStore(snapshot: overflowSnapshot),
            snapshot: overflowSnapshot
        )
        await XCTAssertThrowsSyncError(try await overflow.recordSavedClip(makeClip(text: "overflow"))) {
            XCTAssertEqual($0, .lamportOverflow)
        }
        let overflowState = await overflow.snapshot()
        XCTAssertTrue(overflowState.records.isEmpty)
    }

    func testCloudIdentityRejectsRecordNameOrZoneMismatch() throws {
        let record = try SavedLibrarySyncRecord.live(
            .savedClip(makeClip(text: "identity")),
            stamp: try LamportStamp(counter: 1, deviceID: "mac-a")
        )
        let expectedZone = CKRecordZone.ID(
            zoneName: CloudKitSavedLibraryTransport.zoneName,
            ownerName: CKCurrentUserDefaultName
        )
        XCTAssertThrowsError(
            try CloudKitSavedLibraryTransport.validateCloudIdentity(
                recordType: CloudKitSavedLibraryTransport.recordType,
                recordID: CKRecord.ID(recordName: UUID().uuidString.lowercased(), zoneID: expectedZone),
                expectedZoneID: expectedZone,
                decodedRecord: record
            )
        )
        XCTAssertNoThrow(
            try CloudKitSavedLibraryTransport.validateCloudIdentity(
                recordType: CloudKitSavedLibraryTransport.recordType,
                recordID: CKRecord.ID(recordName: record.id.uuidString.lowercased(), zoneID: expectedZone),
                expectedZoneID: expectedZone,
                decodedRecord: record
            )
        )
    }

    func testCloudAssetChangeIdentityIsValidatedWithoutDownloadingBlob() throws {
        let digest = String(repeating: "a", count: 64)
        let zone = CKRecordZone.ID(
            zoneName: CloudKitSavedLibraryTransport.zoneName,
            ownerName: CKCurrentUserDefaultName
        )
        let record = CKRecord(
            recordType: CloudKitSavedLibraryTransport.assetRecordType,
            recordID: CKRecord.ID(recordName: digest, zoneID: zone)
        )
        record["digest"] = digest as CKRecordValue
        record["byteCount"] = NSNumber(value: 42)
        XCTAssertNoThrow(
            try CloudKitSavedLibraryTransport.validateAssetChangeIdentity(
                record,
                expectedZoneID: zone
            )
        )
        record["digest"] = String(repeating: "b", count: 64) as CKRecordValue
        XCTAssertThrowsError(
            try CloudKitSavedLibraryTransport.validateAssetChangeIdentity(
                record,
                expectedZoneID: zone
            )
        )
    }

    func testFolderTombstoneCreatesOneStableUnfiledCorrection() async throws {
        let coordinator = SavedLibrarySyncCoordinator(
            deviceID: "mac-a",
            transport: InMemorySavedLibrarySyncTransport(),
            store: InMemorySavedLibrarySyncStateStore()
        )
        let folder = try makeFolder(name: "Temporary")
        let clip = try makeClip(text: "linked", folderID: folder.id)
        _ = try await coordinator.recordFolder(folder)
        _ = try await coordinator.recordSavedClip(clip)
        _ = try await coordinator.recordDeletion(id: folder.id, kind: .folder)
        let afterDelete = await coordinator.snapshot()
        let correctedCounter = try XCTUnwrap(afterDelete.records[clip.id]?.stamp.counter)
        let firstProjection = await coordinator.materializedLibrary()
        XCTAssertNil(firstProjection.savedClips.first?.folderID)
        _ = await coordinator.materializedLibrary()
        let afterProjection = await coordinator.snapshot()
        XCTAssertEqual(afterProjection.records[clip.id]?.stamp.counter, correctedCounter)
        XCTAssertEqual(afterProjection.records[clip.id], afterProjection.outbox[clip.id])
    }

    func testClipArrivingBeforeFolderDoesNotUploadPrematureUnfiledCorrection() async throws {
        let folder = try makeFolder(name: "Eventually arrives")
        let clip = try makeClip(text: "keep folder reference", folderID: folder.id)
        let clipRecord = try SavedLibrarySyncRecord.live(
            .savedClip(clip),
            stamp: try LamportStamp(counter: 1, deviceID: "remote")
        )
        let transport = InMemorySavedLibrarySyncTransport(records: [clipRecord])
        let coordinator = SavedLibrarySyncCoordinator(
            deviceID: "local",
            transport: transport,
            store: InMemorySavedLibrarySyncStateStore()
        )
        try await coordinator.setEnabled(true)
        await coordinator.synchronize()
        let clipOnlySnapshot = await coordinator.snapshot()
        let remoteClipPayload = await transport.allRecords().first?.payload
        XCTAssertTrue(clipOnlySnapshot.outbox.isEmpty)
        XCTAssertEqual(remoteClipPayload, .savedClip(clip))

        let folderRecord = try SavedLibrarySyncRecord.live(
            .folder(folder),
            stamp: try LamportStamp(counter: 2, deviceID: "remote")
        )
        try await transport.push([folderRecord])
        await coordinator.synchronize()
        let materialized = await coordinator.materializedLibrary()
        XCTAssertEqual(materialized.folders, [folder])
        XCTAssertEqual(materialized.savedClips, [clip])
    }

    func testSyncIsExplicitlyDisabledByDefaultAndRetainsQueuedChanges() async throws {
        let transport = InMemorySavedLibrarySyncTransport()
        let coordinator = SavedLibrarySyncCoordinator(
            deviceID: "mac-a",
            transport: transport,
            store: InMemorySavedLibrarySyncStateStore()
        )
        let clip = try makeClip(text: "saved, not history")
        _ = try await coordinator.recordSavedClip(clip)

        await coordinator.synchronize()
        var snapshot = await coordinator.snapshot()
        XCTAssertFalse(snapshot.isEnabled)
        XCTAssertEqual(snapshot.status, .disabled)
        XCTAssertEqual(snapshot.outbox.count, 1)
        let disabledRemoteRecords = await transport.allRecords()
        XCTAssertTrue(disabledRemoteRecords.isEmpty)

        try await coordinator.setEnabled(true)
        await coordinator.synchronize()
        snapshot = await coordinator.snapshot()
        XCTAssertTrue(snapshot.outbox.isEmpty)
        let enabledRemoteRecords = await transport.allRecords()
        XCTAssertEqual(enabledRemoteRecords.first?.payload, .savedClip(clip))
    }

    func testOfflineOutboxSurvivesAndFlushesAfterReconnect() async throws {
        let transport = InMemorySavedLibrarySyncTransport(online: false)
        let stateStore = InMemorySavedLibrarySyncStateStore()
        let coordinator = SavedLibrarySyncCoordinator(
            deviceID: "mac-a",
            transport: transport,
            store: stateStore
        )
        try await coordinator.setEnabled(true)
        let folder = try makeFolder(name: "Leads")
        _ = try await coordinator.recordFolder(folder)

        await coordinator.synchronize()
        let offlineSnapshot = await coordinator.snapshot()
        XCTAssertEqual(offlineSnapshot.status, .offline)
        XCTAssertEqual(offlineSnapshot.outbox.count, 1)

        await transport.setOnline(true)
        await coordinator.synchronize()
        let final = await coordinator.snapshot()
        let remoteRecordCount = await transport.allRecords().count
        XCTAssertTrue(final.outbox.isEmpty)
        XCTAssertEqual(remoteRecordCount, 1)
        guard case .idle = final.status else { return XCTFail("Expected idle status") }
    }

    func testLamportCounterAndDeviceIDResolveConcurrentEditsDeterministically() async throws {
        let id = UUID()
        let earlierDeviceClip = try makeClip(id: id, name: "A", text: "from a")
        let laterDeviceClip = try makeClip(id: id, name: "Z", text: "from z")
        let a = try SavedLibrarySyncRecord.live(
            .savedClip(earlierDeviceClip),
            stamp: LamportStamp(counter: 7, deviceID: "device-a")
        )
        let z = try SavedLibrarySyncRecord.live(
            .savedClip(laterDeviceClip),
            stamp: LamportStamp(counter: 7, deviceID: "device-z")
        )
        let transport = InMemorySavedLibrarySyncTransport(records: [a])
        try await transport.push([z])

        let records = await transport.allRecords()
        XCTAssertEqual(records, [z])
    }

    func testEqualLamportStampWithDifferentPayloadFailsWithoutAdvancingToken() async throws {
        let id = UUID()
        let stamp = try LamportStamp(counter: 7, deviceID: "mac-a")
        let local = try SavedLibrarySyncRecord.live(
            .savedClip(makeClip(id: id, name: "Local", text: "local")),
            stamp: stamp
        )
        let remote = try SavedLibrarySyncRecord.live(
            .savedClip(makeClip(id: id, name: "Remote", text: "remote")),
            stamp: stamp
        )
        let originalToken = Data(repeating: 0, count: MemoryLayout<Int64>.size)
        let snapshot = SavedLibrarySyncSnapshot(
            isEnabled: true,
            records: [id: local],
            changeToken: originalToken,
            localLamportCounter: 7,
            status: .idle(lastSuccessfulSync: nil),
            confirmedAccountFingerprint: "test-account-a",
            entityStates: [id: .synced(at: Date(timeIntervalSince1970: 1), deviceID: "mac-a")]
        )
        let coordinator = SavedLibrarySyncCoordinator(
            deviceID: "mac-a",
            transport: InMemorySavedLibrarySyncTransport(records: [remote]),
            store: InMemorySavedLibrarySyncStateStore(snapshot: snapshot),
            snapshot: snapshot
        )

        await coordinator.synchronize()

        let after = await coordinator.snapshot()
        XCTAssertEqual(after.changeToken, originalToken)
        XCTAssertEqual(after.records[id], local)
        guard case let .failed(message) = after.status else {
            return XCTFail("Expected stamp collision failure, got \(after.status)")
        }
        XCTAssertTrue(message.contains("reused a Lamport stamp"))
    }

    func testInMemoryTransportRejectsEqualStampWithDifferentPayload() async throws {
        let id = UUID()
        let stamp = try LamportStamp(counter: 3, deviceID: "mac-a")
        let remote = try SavedLibrarySyncRecord.live(
            .savedClip(makeClip(id: id, name: "Remote", text: "remote")),
            stamp: stamp
        )
        let candidate = try SavedLibrarySyncRecord.live(
            .savedClip(makeClip(id: id, name: "Local", text: "local")),
            stamp: stamp
        )
        let transport = InMemorySavedLibrarySyncTransport(records: [remote])

        await XCTAssertThrowsSyncError(try await transport.push([candidate])) {
            XCTAssertEqual($0, .stampCollision(id))
        }
        let remainingRecords = await transport.allRecords()
        XCTAssertEqual(remainingRecords, [remote])
    }

    func testTombstoneWinsAndIsRetainedIndefinitelyInMaterializedState() async throws {
        let clip = try makeClip(text: "delete everywhere")
        let live = try SavedLibrarySyncRecord.live(
            .savedClip(clip),
            stamp: LamportStamp(counter: 1, deviceID: "mac-a")
        )
        let tombstone = try SavedLibrarySyncRecord.tombstone(
            id: clip.id,
            kind: .savedClip,
            stamp: LamportStamp(counter: 2, deviceID: "mac-b")
        )
        let transport = InMemorySavedLibrarySyncTransport(records: [live, tombstone])
        let coordinator = SavedLibrarySyncCoordinator(
            deviceID: "mac-c",
            transport: transport,
            store: InMemorySavedLibrarySyncStateStore()
        )
        try await coordinator.setEnabled(true)
        await coordinator.synchronize()

        let snapshot = await coordinator.snapshot()
        let materialized = await coordinator.materializedLibrary()
        XCTAssertEqual(snapshot.records[clip.id], tombstone)
        XCTAssertTrue(materialized.savedClips.isEmpty)
        XCTAssertEqual(snapshot.records.values.filter(\.isTombstone).count, 1)
    }

    func testOversizedSavedClipIsRejectedBeforeEnteringOutbox() async throws {
        let coordinator = SavedLibrarySyncCoordinator(
            deviceID: "mac-a",
            transport: InMemorySavedLibrarySyncTransport(),
            store: InMemorySavedLibrarySyncStateStore()
        )
        let oversized = try makeClip(text: String(repeating: "x", count: 300_000))
        await XCTAssertThrowsSyncError(try await coordinator.recordSavedClip(oversized)) { error in
            guard case .recordTooLarge(oversized.id, _) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let snapshot = await coordinator.snapshot()
        XCTAssertTrue(snapshot.outbox.isEmpty)
    }

    func testTwoMacsConvergeAndFolderAndClipAreTheOnlyMaterializedTypes() async throws {
        let transport = InMemorySavedLibrarySyncTransport()
        let macA = SavedLibrarySyncCoordinator(
            deviceID: "mac-a",
            transport: transport,
            store: InMemorySavedLibrarySyncStateStore()
        )
        let macB = SavedLibrarySyncCoordinator(
            deviceID: "mac-b",
            transport: transport,
            store: InMemorySavedLibrarySyncStateStore()
        )
        try await macA.setEnabled(true)
        try await macB.setEnabled(true)
        let folder = try makeFolder(name: "Research")
        let clip = try makeClip(text: "market notes", folderID: folder.id)
        _ = try await macA.recordFolder(folder)
        _ = try await macA.recordSavedClip(clip)
        await macA.synchronize()
        await macB.synchronize()

        let materialized = await macB.materializedLibrary()
        XCTAssertEqual(materialized.folders, [folder])
        XCTAssertEqual(materialized.savedClips, [clip])
    }

    func testUnavailableAccountReportsStatusWithoutDroppingOutbox() async throws {
        let transport = InMemorySavedLibrarySyncTransport(accountState: .noAccount)
        let coordinator = SavedLibrarySyncCoordinator(
            deviceID: "mac-a",
            transport: transport,
            store: InMemorySavedLibrarySyncStateStore()
        )
        try await coordinator.setEnabled(true)
        _ = try await coordinator.recordFolder(makeFolder(name: "Keep queued"))
        await coordinator.synchronize()

        let snapshot = await coordinator.snapshot()
        XCTAssertEqual(snapshot.status, .accountUnavailable(.noAccount))
        XCTAssertEqual(snapshot.outbox.count, 1)
    }

    private func makeClip(
        id: UUID = UUID(),
        name: String = "Saved",
        text: String,
        folderID: UUID? = nil
    ) throws -> SavedClip {
        try SavedClip(
            id: id,
            name: name,
            content: ClipContent(type: .plainText, text: text),
            folderID: folderID,
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    private func makeFolder(id: UUID = UUID(), name: String) throws -> ClipFolder {
        try ClipFolder(id: id, name: name, sortOrder: 0, createdAt: Date(timeIntervalSince1970: 1_000))
    }
}

private actor SyncTestGate {
    private var openState = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        guard !openState else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        openState = true
        let values = waiters
        waiters.removeAll()
        values.forEach { $0.resume() }
    }
}

private actor BlockingSyncTransport: SavedLibrarySyncTransport {
    let pushEntered: SyncTestGate
    let releasePush: SyncTestGate
    private var identityCalls = 0
    private var fetchCalls = 0

    init(pushEntered: SyncTestGate, releasePush: SyncTestGate) {
        self.pushEntered = pushEntered
        self.releasePush = releasePush
    }
    func accountIdentity() async throws -> SyncAccountIdentity {
        identityCalls += 1
        return SyncAccountIdentity(state: .available, fingerprint: "account-a")
    }
    func fetchChanges(after token: Data?) async throws -> SyncFetchBatch {
        fetchCalls += 1
        return SyncFetchBatch(records: [], changeToken: token)
    }
    func push(_ records: [SavedLibrarySyncRecord]) async throws {
        await pushEntered.open()
        await releasePush.wait()
    }
    func identityCallsValue() -> Int { identityCalls }
    func fetchCallsValue() -> Int { fetchCalls }
}

@discardableResult
private func replaceJSONValue(
    key: String,
    with replacement: Any,
    in object: inout [String: Any]
) -> Bool {
    if object[key] != nil {
        object[key] = replacement
        return true
    }
    for (entryKey, value) in object {
        if var dictionary = value as? [String: Any],
           replaceJSONValue(key: key, with: replacement, in: &dictionary) {
            object[entryKey] = dictionary
            return true
        }
        if var array = value as? [[String: Any]] {
            for index in array.indices where replaceJSONValue(
                key: key,
                with: replacement,
                in: &array[index]
            ) {
                object[entryKey] = array
                return true
            }
        }
    }
    return false
}

private func XCTAssertThrowsSyncError<T>(
    _ expression: @autoclosure () async throws -> T,
    _ handler: (SavedLibrarySyncError) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("Expected sync error")
    } catch let error as SavedLibrarySyncError {
        handler(error)
    } catch {
        XCTFail("Unexpected error: \(error)")
    }
}
