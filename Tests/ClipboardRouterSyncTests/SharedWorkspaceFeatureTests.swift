import ClipboardRouterCore
import Foundation
import XCTest
@testable import ClipboardRouterSync

final class SharedWorkspaceFeatureTests: XCTestCase {
    func testFingerprintIsStableInstallationBoundAndDoesNotExposeAccountID() throws {
        let accountID = "_icloud-user-record-123"
        let first = try SharedAccountFingerprint.derive(
            accountIdentifier: accountID,
            installationSecret: "installation-a"
        )
        let same = try SharedAccountFingerprint.derive(
            accountIdentifier: accountID,
            installationSecret: "installation-a"
        )
        let otherInstall = try SharedAccountFingerprint.derive(
            accountIdentifier: accountID,
            installationSecret: "installation-b"
        )

        XCTAssertEqual(first, same)
        XCTAssertNotEqual(first, otherInstall)
        XCTAssertFalse(first.contains(accountID))
        XCTAssertEqual(first.count, 64)
    }

    func testRegistryRoundTripAndChecksumFailureAreFailClosed() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SharedRegistry-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("registry.json")
        let store = SharedWorkspaceRegistryStore(fileURL: url)
        let folderID = UUID()
        let fingerprint = String(repeating: "a", count: 64)
        let location = SharedFolderRemoteLocation(
            folderID: folderID,
            zoneName: "zone",
            ownerName: "owner",
            ownerParticipantID: "owner-participant",
            shareRecordName: "share",
            databaseScope: .participantShared,
            title: "Account Research"
        )
        let registration = SharedWorkspaceRegistration(
            accountFingerprint: fingerprint,
            location: location,
            managedFolderIDs: [folderID],
            managedSavedClipIDs: [UUID()],
            cursor: SharedZoneCursor(
                accountFingerprint: fingerprint,
                folderID: folderID,
                ownerParticipantID: location.ownerParticipantID,
                zoneName: location.zoneName,
                databaseScope: location.databaseScope,
                serverChangeToken: Data([1, 2, 3]),
                lastSuccessfulFetchAt: Date(timeIntervalSince1970: 100)
            )
        )
        let registry = SharedWorkspaceRegistry(
            accountFingerprint: fingerprint,
            workspaces: [registration]
        )
        try store.save(registry)
        XCTAssertEqual(try store.load(), registry)

        var bytes = try Data(contentsOf: url)
        bytes[bytes.index(before: bytes.endIndex)] ^= 1
        try bytes.write(to: url, options: .atomic)
        XCTAssertThrowsError(try store.load())
    }

    func testLosingLocalSameItemEditBecomesBoundedRecoveryCopy() async throws {
        let createdAt = Date(timeIntervalSince1970: 1_000)
        let folder = try ClipFolder(name: "Research", sortOrder: 0, createdAt: createdAt)
        let initial = try SavedClip(
            name: "Objection",
            content: ClipContent(type: .plainText, text: "Initial"),
            folderID: folder.id,
            createdAt: createdAt
        )
        let transport = ConflictInjectingTransport(folder: folder, clip: initial)
        let session = try await SharedFolderSession.create(
            folder: folder,
            savedClips: [initial],
            deviceID: "local-mac",
            transport: transport
        )
        let edited = try SavedClip(
            id: initial.id,
            name: initial.name,
            content: ClipContent(type: .plainText, text: "Local edit"),
            folderID: folder.id,
            createdAt: initial.createdAt,
            modifiedAt: Date(timeIntervalSince1970: initial.modifiedAt.timeIntervalSince1970 + 10)
        )
        await transport.injectConflictOnNextWrite()
        let result = try await session.synchronizeLocal(folder: folder, savedClips: [edited])

        XCTAssertEqual(result.savedClips.first?.content.text, "Remote edit")
        XCTAssertEqual(result.recoveryCopies.count, 1)
        XCTAssertEqual(result.recoveryCopies.first?.originalItemID, initial.id)
        guard case let .savedClip(recovered, _) = result.recoveryCopies.first?.losingRecord.payload else {
            return XCTFail("Expected a saved-clip recovery record")
        }
        XCTAssertEqual(recovered.content.text, "Local edit")
    }
}

private actor ConflictInjectingTransport: SharedFolderTransport {
    private let participantID = "owner"
    private let location: SharedFolderRemoteLocation
    private let participant: SharedFolderCloudParticipant
    private var records: [UUID: SharedFolderRecord] = [:]
    private var shouldInjectConflict = false

    init(folder: ClipFolder, clip _: SavedClip) {
        location = SharedFolderRemoteLocation(
            folderID: folder.id,
            zoneName: SharedFolderScope.v2ZonePrefix + folder.id.uuidString.lowercased(),
            ownerName: "owner",
            ownerParticipantID: participantID,
            shareRecordName: "share",
            databaseScope: .ownerPrivate,
            title: folder.name
        )
        participant = try! SharedFolderCloudParticipant(
            id: participantID,
            displayName: "Owner",
            role: .owner,
            acceptance: .accepted
        )
    }

    func capability() async -> SharedCloudCapability { .available }
    func currentParticipantID() async throws -> String { participantID }

    func createShare(
        for _: SharedFolderScope,
        title _: String
    ) async throws -> SharedFolderTransportSnapshot {
        try snapshot()
    }

    func synchronize(
        _ candidates: [SharedFolderRecord],
        at _: SharedFolderRemoteLocation
    ) async throws -> SharedFolderTransportSnapshot {
        for candidate in candidates {
            if shouldInjectConflict, candidate.kind == .savedClip,
               case let .savedClip(local, metadata) = candidate.payload
            {
                let remote = try SavedClip(
                    id: local.id,
                    kind: local.kind,
                    name: local.name,
                    content: ClipContent(type: .plainText, text: "Remote edit"),
                    folderID: local.folderID,
                    sourceHistoryItemID: local.sourceHistoryItemID,
                    derivedFromHistoryItemID: local.derivedFromHistoryItemID,
                    createdAt: local.createdAt,
                    modifiedAt: local.modifiedAt.addingTimeInterval(1),
                    pinnedAt: local.pinnedAt,
                    tags: local.tags ?? [],
                    sourceApplicationBundleIdentifier: local.sourceApplicationBundleIdentifier,
                    originatingDeviceIdentifier: local.originatingDeviceIdentifier,
                    captureContext: local.captureContext,
                    originallyCapturedAt: local.originallyCapturedAt,
                    sensitivity: local.sensitivity,
                    pasteboardTypeIdentifiers: local.pasteboardTypeIdentifiers ?? []
                )
                records[candidate.id] = try SharedFolderRecord.live(
                    .savedClip(remote, metadata: metadata),
                    scope: SharedFolderScope(
                        folderID: location.folderID,
                        ownerParticipantID: participantID
                    ),
                    stamp: LamportStamp(
                        counter: candidate.stamp.counter + 1,
                        deviceID: "remote-mac"
                    ),
                    authorParticipantID: participantID
                )
                shouldInjectConflict = false
            } else if records[candidate.id].map({ $0.stamp < candidate.stamp }) ?? true {
                records[candidate.id] = candidate
            }
        }
        return try snapshot()
    }

    func injectConflictOnNextWrite() { shouldInjectConflict = true }

    private func snapshot() throws -> SharedFolderTransportSnapshot {
        try SharedFolderTransportSnapshot(
            location: location,
            currentParticipantID: participantID,
            participants: [participant],
            records: Array(records.values)
        )
    }
}
