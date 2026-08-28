import ClipboardRouterCore
import Foundation

public enum SharedFolderDatabaseScope: String, Codable, Equatable, Sendable {
    /// The owner writes the shared zone through their private database.
    case ownerPrivate
    /// An invited participant reads and writes the accepted zone through their shared database.
    case participantShared
}

public struct SharedFolderRemoteLocation: Codable, Equatable, Hashable, Sendable {
    public let folderID: UUID
    public let zoneName: String
    public let ownerName: String
    public let ownerParticipantID: String
    public let shareRecordName: String
    public let databaseScope: SharedFolderDatabaseScope
    public let title: String

    public init(
        folderID: UUID,
        zoneName: String,
        ownerName: String,
        ownerParticipantID: String,
        shareRecordName: String,
        databaseScope: SharedFolderDatabaseScope,
        title: String
    ) {
        self.folderID = folderID
        self.zoneName = zoneName
        self.ownerName = ownerName
        self.ownerParticipantID = ownerParticipantID
        self.shareRecordName = shareRecordName
        self.databaseScope = databaseScope
        self.title = title
    }
}

public enum SharedFolderParticipantAcceptance: String, Codable, Equatable, Sendable {
    case unknown
    case pending
    case accepted
    case removed
}

public struct SharedFolderCloudParticipant: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let role: SharedFolderRole
    public let acceptance: SharedFolderParticipantAcceptance

    public init(
        id: String,
        displayName: String,
        role: SharedFolderRole,
        acceptance: SharedFolderParticipantAcceptance
    ) throws {
        _ = try SharedFolderParticipant(id: id, role: role)
        let cleanName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.id = id
        self.displayName = cleanName.isEmpty ? "Participant" : cleanName
        self.role = role
        self.acceptance = acceptance
    }

    public var coordinatorParticipant: SharedFolderParticipant {
        // Construction validated the same identifier and role invariants.
        try! SharedFolderParticipant(id: id, role: role)
    }
}

/// Immutable proof that a server-authenticated participant was authorized to write a record.
/// Current membership still controls new writes; this evidence exists only so an accepted
/// historical record does not become unreadable after its author is downgraded or removed.
public struct SharedFolderRecordAuthorization: Equatable, Sendable {
    public let recordID: UUID
    public let authorParticipantID: String
    public let roleAtWrite: SharedFolderRole

    public init(
        recordID: UUID,
        authorParticipantID: String,
        roleAtWrite: SharedFolderRole
    ) throws {
        _ = try SharedFolderParticipant(id: authorParticipantID, role: roleAtWrite)
        self.recordID = recordID
        self.authorParticipantID = authorParticipantID
        self.roleAtWrite = roleAtWrite
    }
}

public struct SharedFolderTransportSnapshot: Equatable, Sendable {
    public let location: SharedFolderRemoteLocation
    public let currentParticipantID: String
    public let participants: [SharedFolderCloudParticipant]
    public let records: [SharedFolderRecord]
    public let recordAuthorizations: [UUID: SharedFolderRecordAuthorization]

    public init(
        location: SharedFolderRemoteLocation,
        currentParticipantID: String,
        participants: [SharedFolderCloudParticipant],
        records: [SharedFolderRecord],
        recordAuthorizations: [SharedFolderRecordAuthorization]? = nil
    ) throws {
        guard participants.contains(where: { $0.id == currentParticipantID }),
              participants.contains(where: {
                  $0.id == location.ownerParticipantID && $0.role == .owner
              }),
              participants.filter({ $0.role == .owner }).count == 1
        else {
            throw SharedFolderError.invalidParticipants
        }
        let authorizations: [SharedFolderRecordAuthorization]
        if let recordAuthorizations {
            authorizations = recordAuthorizations
        } else {
            authorizations = try records.map { record in
                guard let participant = participants.first(where: {
                    $0.id == record.authorParticipantID
                }) else {
                    throw SharedFolderError.cloudFailure(
                        "A shared record has no authorization-at-write evidence"
                    )
                }
                return try SharedFolderRecordAuthorization(
                    recordID: record.id,
                    authorParticipantID: record.authorParticipantID,
                    roleAtWrite: participant.role
                )
            }
        }
        var mappedAuthorizations: [UUID: SharedFolderRecordAuthorization] = [:]
        for authorization in authorizations {
            guard mappedAuthorizations.updateValue(
                authorization,
                forKey: authorization.recordID
            ) == nil else {
                throw SharedFolderError.cloudFailure(
                    "A shared record has duplicate authorization-at-write evidence"
                )
            }
        }
        guard Set(mappedAuthorizations.keys) == Set(records.map(\.id)) else {
            throw SharedFolderError.cloudFailure(
                "A shared record has missing or extraneous authorization-at-write evidence"
            )
        }
        for record in records {
            guard let authorization = mappedAuthorizations[record.id],
                  authorization.authorParticipantID == record.authorParticipantID
            else {
                throw SharedFolderError.cloudFailure(
                    "A shared record's authorization-at-write evidence does not match its author"
                )
            }
            switch record.kind {
            case .rootFolder:
                guard authorization.roleAtWrite == .owner,
                      authorization.authorParticipantID == location.ownerParticipantID
                else { throw SharedFolderError.permissionDenied }
            case .automationDefinition:
                guard authorization.roleAtWrite == .owner,
                      authorization.authorParticipantID == location.ownerParticipantID
                else { throw SharedFolderError.permissionDenied }
            case .folder:
                guard authorization.roleAtWrite.canEditClips else {
                    throw SharedFolderError.permissionDenied
                }
            case .savedClip:
                guard authorization.roleAtWrite.canEditClips else {
                    throw SharedFolderError.permissionDenied
                }
            }
        }
        self.location = location
        self.currentParticipantID = currentParticipantID
        self.participants = participants.sorted { lhs, rhs in
            if lhs.role != rhs.role { return Self.roleOrder(lhs.role) < Self.roleOrder(rhs.role) }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
        self.records = records.sorted(by: Self.recordOrder)
        self.recordAuthorizations = mappedAuthorizations
    }

    private static func roleOrder(_ role: SharedFolderRole) -> Int {
        switch role {
        case .owner: 0
        case .editor: 1
        case .viewer: 2
        }
    }

    private static func recordOrder(_ lhs: SharedFolderRecord, _ rhs: SharedFolderRecord) -> Bool {
        lhs.id.uuidString == rhs.id.uuidString
            ? lhs.stamp < rhs.stamp
            : lhs.id.uuidString < rhs.id.uuidString
    }
}

public protocol SharedFolderTransport: Sendable {
    func capability() async -> SharedCloudCapability
    func currentParticipantID() async throws -> String
    func createShare(
        for scope: SharedFolderScope,
        title: String
    ) async throws -> SharedFolderTransportSnapshot
    func synchronize(
        _ records: [SharedFolderRecord],
        at location: SharedFolderRemoteLocation
    ) async throws -> SharedFolderTransportSnapshot
}

public enum SharedFolderSessionStatus: Equatable, Sendable {
    case idle
    case syncing
    case synced(Date)
    case failed(String)
}

public struct SharedFolderSessionSnapshot: Equatable, Sendable {
    public let location: SharedFolderRemoteLocation
    public let currentParticipantID: String
    public let participants: [SharedFolderCloudParticipant]
    public let folder: ClipFolder?
    /// Descendants only; the shared root remains in `folder` for source compatibility.
    public let folders: [ClipFolder]
    public let savedClips: [SavedClip]
    public let automationDefinitions: [ClipFlow]
    /// Review-only arrivals. Merely materializing this array has no execution side effect.
    public let debugBundles: [SharedDebugBundlePublication]
    public let managedFolderIDs: Set<UUID>
    public let managedSavedClipIDs: Set<UUID>
    public let managedAutomationDefinitionIDs: Set<UUID>
    public let managedDebugBundleIDs: Set<UUID>
    public let recoveryCopies: [SharedConflictRecoveryCopy]
    public let status: SharedFolderSessionStatus

    public var currentRole: SharedFolderRole {
        participants.first(where: { $0.id == currentParticipantID })?.role ?? .viewer
    }

    public init(
        location: SharedFolderRemoteLocation,
        currentParticipantID: String,
        participants: [SharedFolderCloudParticipant],
        folder: ClipFolder?,
        folders: [ClipFolder] = [],
        savedClips: [SavedClip],
        automationDefinitions: [ClipFlow] = [],
        debugBundles: [SharedDebugBundlePublication] = [],
        managedFolderIDs: Set<UUID>? = nil,
        managedSavedClipIDs: Set<UUID>? = nil,
        managedAutomationDefinitionIDs: Set<UUID>? = nil,
        managedDebugBundleIDs: Set<UUID>? = nil,
        recoveryCopies: [SharedConflictRecoveryCopy] = [],
        status: SharedFolderSessionStatus
    ) {
        self.location = location
        self.currentParticipantID = currentParticipantID
        self.participants = participants
        self.folder = folder
        self.folders = folders.sorted { $0.id.uuidString < $1.id.uuidString }
        self.savedClips = savedClips
        self.automationDefinitions = automationDefinitions.sorted { $0.id.uuidString < $1.id.uuidString }
        self.debugBundles = debugBundles.sorted { lhs, rhs in
            lhs.publishedAt == rhs.publishedAt
                ? lhs.id.uuidString < rhs.id.uuidString
                : lhs.publishedAt > rhs.publishedAt
        }
        self.managedFolderIDs = managedFolderIDs
            ?? Set(folders.map(\.id)).union(folder.map { [$0.id] } ?? [])
        self.managedSavedClipIDs = managedSavedClipIDs ?? Set(savedClips.map(\.id))
        self.managedAutomationDefinitionIDs = managedAutomationDefinitionIDs
            ?? Set(automationDefinitions.map(\.id))
        self.managedDebugBundleIDs = managedDebugBundleIDs ?? Set(debugBundles.map(\.id))
        self.recoveryCopies = recoveryCopies
        self.status = status
    }
}

/// Owns deterministic folder records while delegating CloudKit/private-vs-shared database access
/// to a transport. Every network result is validated again by `SharedFolderCoordinator` before it
/// becomes materialized app state.
public actor SharedFolderSession {
    private let transport: any SharedFolderTransport
    private let deviceID: String
    private var coordinator: SharedFolderCoordinator
    private var state: SharedFolderSessionSnapshot
    private var pendingLocalRecordIDs: Set<UUID> = []

    private init(
        transport: any SharedFolderTransport,
        deviceID: String,
        remote: SharedFolderTransportSnapshot,
        status: SharedFolderSessionStatus
    ) throws {
        self.transport = transport
        self.deviceID = deviceID
        let scope = try SharedFolderScope(
            folderID: remote.location.folderID,
            ownerParticipantID: remote.location.ownerParticipantID
        )
        let maximumCounter = remote.records.map(\.stamp.counter).max() ?? 0
        let coordinator = try SharedFolderCoordinator(
            scope: scope,
            currentParticipantID: remote.currentParticipantID,
            deviceID: deviceID,
            participants: try Self.coordinatorParticipants(for: remote),
            records: remote.records,
            localLamportCounter: maximumCounter
        )
        self.coordinator = coordinator
        self.state = SharedFolderSessionSnapshot(
            location: remote.location,
            currentParticipantID: remote.currentParticipantID,
            participants: remote.participants,
            folder: nil,
            folders: [],
            savedClips: [],
            managedFolderIDs: Set(
                remote.records.filter { $0.kind == .rootFolder || $0.kind == .folder }.map(\.id)
            ),
            managedSavedClipIDs: Set(
                remote.records.filter { $0.kind == .savedClip }.map(\.id)
            ),
            managedAutomationDefinitionIDs: Set(
                remote.records.filter { $0.kind == .automationDefinition }.map(\.id)
            ),
            managedDebugBundleIDs: [],
            status: status
        )
    }

    public static func create(
        folder: ClipFolder,
        folders: [ClipFolder] = [],
        savedClips: [SavedClip],
        deviceID: String,
        transport: any SharedFolderTransport
    ) async throws -> SharedFolderSession {
        let participantID = try await transport.currentParticipantID()
        let scope = try SharedFolderScope(
            folderID: folder.id,
            ownerParticipantID: participantID
        )
        // Validate every local payload and permission before the transport creates a persistent
        // CKShare. An ineligible clip must not leave an orphaned remote share behind.
        let owner = try SharedFolderParticipant(id: participantID, role: .owner)
        let preflight = try SharedFolderCoordinator(
            scope: scope,
            currentParticipantID: participantID,
            deviceID: deviceID,
            participants: [owner]
        )
        _ = try await preflight.recordRootFolder(canonicalSharedFolder(folder))
        for child in try orderedDescendantFolders(rootID: folder.id, folders: folders) {
            _ = try await preflight.recordFolder(canonicalSharedFolder(child))
        }
        for clip in savedClips.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            _ = try await preflight.recordSavedClip(clip)
        }
        let remote = try await transport.createShare(for: scope, title: folder.name)
        let session = try SharedFolderSession(
            transport: transport,
            deviceID: deviceID,
            remote: remote,
            status: .idle
        )
        _ = try await session.synchronizeLocal(
            folder: folder,
            folders: folders,
            savedClips: savedClips
        )
        return session
    }

    public static func open(
        remote: SharedFolderTransportSnapshot,
        deviceID: String,
        transport: any SharedFolderTransport
    ) async throws -> SharedFolderSession {
        let session = try SharedFolderSession(
            transport: transport,
            deviceID: deviceID,
            remote: remote,
            status: .idle
        )
        try await session.replaceRemoteState(remote, status: .synced(Date()))
        return session
    }

    public func snapshot() -> SharedFolderSessionSnapshot { state }

    @discardableResult
    public func refresh() async throws -> SharedFolderSessionSnapshot {
        state = snapshot(status: .syncing)
        do {
            let remote = try await transport.synchronize([], at: state.location)
            try await replaceRemoteState(remote, status: .synced(Date()))
            return state
        } catch {
            state = snapshot(status: .failed(error.localizedDescription))
            throw error
        }
    }

    @discardableResult
    public func synchronizeLocal(
        folder: ClipFolder?,
        folders: [ClipFolder]? = nil,
        savedClips: [SavedClip]
    ) async throws -> SharedFolderSessionSnapshot {
        state = snapshot(status: .syncing)
        do {
            pendingLocalRecordIDs.formUnion(
                try await recordLocalDelta(folder: folder, folders: folders, savedClips: savedClips)
            )
            let outgoing = await coordinator.recordsForUpload().filter {
                pendingLocalRecordIDs.contains($0.id)
                    && $0.authorParticipantID == state.currentParticipantID
            }
            let remote = try await transport.synchronize(outgoing, at: state.location)
            appendRecoveryCopies(for: outgoing, remote: remote)
            try await replaceRemoteState(remote, status: .synced(Date()))
            pendingLocalRecordIDs.subtract(outgoing.map(\.id))
            return state
        } catch {
            state = snapshot(status: .failed(error.localizedDescription))
            throw error
        }
    }

    /// Synchronizes portable team definitions only. A receiving Mac treats them as disabled
    /// templates until its user explicitly installs them; no remote callback executes a flow.
    @discardableResult
    public func synchronizeAutomationDefinitions(
        _ definitions: [ClipFlow]
    ) async throws -> SharedFolderSessionSnapshot {
        guard state.currentRole.canManageFolder else { throw SharedFolderError.permissionDenied }
        state = snapshot(status: .syncing)
        do {
            let before = await coordinator.snapshot()
            let incomingIDs = Set(definitions.map(\.id))
            guard incomingIDs.count == definitions.count else {
                throw SharedFolderError.invalidRecord(state.location.folderID)
            }
            for definition in definitions.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
                guard definition.sharedFolderID == state.location.folderID,
                      definition.steps.allSatisfy(\.isPortable)
                else { throw SharedFolderError.invalidRecord(definition.id) }
                if before.records[definition.id]?.payload != .automationDefinition(definition) {
                    _ = try await coordinator.recordAutomationDefinition(definition)
                    pendingLocalRecordIDs.insert(definition.id)
                }
            }
            for record in before.records.values
                where record.kind == .automationDefinition
                    && !record.isTombstone
                    && !incomingIDs.contains(record.id)
            {
                _ = try await coordinator.recordDeletion(id: record.id, kind: .automationDefinition)
                pendingLocalRecordIDs.insert(record.id)
            }
            let outgoing = await coordinator.recordsForUpload().filter {
                pendingLocalRecordIDs.contains($0.id)
                    && $0.authorParticipantID == state.currentParticipantID
            }
            let remote = try await transport.synchronize(outgoing, at: state.location)
            appendRecoveryCopies(for: outgoing, remote: remote)
            try await replaceRemoteState(remote, status: .synced(Date()))
            pendingLocalRecordIDs.subtract(outgoing.map(\.id))
            return state
        } catch {
            state = snapshot(status: .failed(error.localizedDescription))
            throw error
        }
    }

    private func recordLocalDelta(
        folder: ClipFolder?,
        folders: [ClipFolder]?,
        savedClips: [SavedClip]
    ) async throws -> Set<UUID> {
        let before = await coordinator.snapshot()
        let role = state.currentRole
        var changedRecordIDs: Set<UUID> = []

        if let folder {
            guard folder.id == state.location.folderID else {
                throw SharedFolderError.wrongScope(
                    expected: state.location.folderID,
                    actual: folder.id
                )
            }
            let canonical = Self.canonicalSharedFolder(folder)
            let remoteFolder: ClipFolder?
            if case let .rootFolder(value) = before.records[folder.id]?.payload {
                remoteFolder = value
            } else {
                remoteFolder = nil
            }
            let collaborativeFolderChanged = remoteFolder.map {
                $0.name != canonical.name || $0.createdAt != canonical.createdAt
            } ?? true
            if collaborativeFolderChanged {
                guard role.canManageFolder else { throw SharedFolderError.permissionDenied }
                _ = try await coordinator.recordRootFolder(canonical)
                changedRecordIDs.insert(folder.id)
            }
        }

        let orderedFolders = try folders.map {
            try Self.orderedDescendantFolders(rootID: state.location.folderID, folders: $0)
        }
        if let orderedFolders {
            let incomingIDs = Set(orderedFolders.map(\.id))
            if role.canEditClips {
                for child in orderedFolders {
                    let expected = SharedFolderPayload.folder(Self.canonicalSharedFolder(child))
                    if before.records[child.id]?.payload != expected {
                        _ = try await coordinator.recordFolder(Self.canonicalSharedFolder(child))
                        changedRecordIDs.insert(child.id)
                    }
                }
            } else {
                let remoteIDs = Set(before.records.values.filter {
                    $0.kind == .folder && !$0.isTombstone
                }.map(\.id))
                let changed = orderedFolders.contains {
                    before.records[$0.id]?.payload != .folder(Self.canonicalSharedFolder($0))
                }
                guard incomingIDs == remoteIDs, !changed else {
                    throw SharedFolderError.permissionDenied
                }
            }
        }

        let clips = savedClips
        let liveClipIDs = Set(clips.map(\.id))
        if role.canEditClips {
            for clip in clips.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
                let expected = SharedFolderPayload.savedClip(clip, metadata: .ready)
                if before.records[clip.id]?.payload != expected {
                    _ = try await coordinator.recordSavedClip(clip)
                    changedRecordIDs.insert(clip.id)
                }
            }
            for record in before.records.values
                where record.kind == .savedClip
                    && !record.isTombstone
                    && !liveClipIDs.contains(record.id)
            {
                _ = try await coordinator.recordDeletion(id: record.id, kind: .savedClip)
                changedRecordIDs.insert(record.id)
            }
        } else {
            let remoteLiveClipIDs = Set(
                before.records.values
                    .filter { $0.kind == .savedClip && !$0.isTombstone }
                    .map(\.id)
            )
            let hasChangedPayload = clips.contains { clip in
                before.records[clip.id]?.payload != .savedClip(clip, metadata: .ready)
            }
            guard liveClipIDs == remoteLiveClipIDs, !hasChangedPayload else {
                throw SharedFolderError.permissionDenied
            }
        }

        // Delete descendants only when the caller supplied an authoritative complete subtree.
        // Clip tombstones above run first so no live item can dangle outside the validated tree.
        if let orderedFolders, role.canEditClips {
            let liveFolderIDs = Set(orderedFolders.map(\.id))
            let stale = before.records.values.compactMap { record -> ClipFolder? in
                guard record.kind == .folder, !record.isTombstone,
                      !liveFolderIDs.contains(record.id),
                      case let .folder(folder) = record.payload
                else { return nil }
                return folder
            }
            for child in Self.deepestFirst(stale) {
                _ = try await coordinator.recordDeletion(id: child.id, kind: .folder)
                changedRecordIDs.insert(child.id)
            }
        }

        if folder == nil, before.records[state.location.folderID]?.isTombstone != true {
            guard role.canManageFolder else { throw SharedFolderError.permissionDenied }
            _ = try await coordinator.recordDeletion(
                id: state.location.folderID,
                kind: .rootFolder
            )
            changedRecordIDs.insert(state.location.folderID)
        }
        return changedRecordIDs
    }

    private func replaceRemoteState(
        _ remote: SharedFolderTransportSnapshot,
        status: SharedFolderSessionStatus
    ) async throws {
        guard remote.location == state.location else {
            throw SharedFolderError.wrongScope(
                expected: state.location.folderID,
                actual: remote.location.folderID
            )
        }
        let scope = try SharedFolderScope(
            folderID: remote.location.folderID,
            ownerParticipantID: remote.location.ownerParticipantID
        )
        let maximumCounter = remote.records.map(\.stamp.counter).max() ?? 0
        let replacement = try SharedFolderCoordinator(
            scope: scope,
            currentParticipantID: remote.currentParticipantID,
            deviceID: deviceID,
            participants: try Self.coordinatorParticipants(for: remote),
            records: remote.records,
            localLamportCounter: maximumCounter
        )
        coordinator = replacement
        let materialized = await replacement.materializedSubtree()
        state = SharedFolderSessionSnapshot(
            location: remote.location,
            currentParticipantID: remote.currentParticipantID,
            participants: remote.participants,
            folder: materialized.root,
            folders: materialized.folders,
            savedClips: materialized.savedItems,
            automationDefinitions: materialized.automationDefinitions,
            debugBundles: materialized.debugBundles,
            managedFolderIDs: Set(
                remote.records.filter { $0.kind == .rootFolder || $0.kind == .folder }.map(\.id)
            ),
            managedSavedClipIDs: Set(
                remote.records.filter { $0.kind == .savedClip }.map(\.id)
            ),
            managedAutomationDefinitionIDs: Set(
                remote.records.filter { $0.kind == .automationDefinition }.map(\.id)
            ),
            managedDebugBundleIDs: [],
            recoveryCopies: state.recoveryCopies,
            status: status
        )
    }

    private func snapshot(status: SharedFolderSessionStatus) -> SharedFolderSessionSnapshot {
        SharedFolderSessionSnapshot(
            location: state.location,
            currentParticipantID: state.currentParticipantID,
            participants: state.participants,
            folder: state.folder,
            folders: state.folders,
            savedClips: state.savedClips,
            automationDefinitions: state.automationDefinitions,
            debugBundles: state.debugBundles,
            managedFolderIDs: state.managedFolderIDs,
            managedSavedClipIDs: state.managedSavedClipIDs,
            managedAutomationDefinitionIDs: state.managedAutomationDefinitionIDs,
            managedDebugBundleIDs: state.managedDebugBundleIDs,
            recoveryCopies: state.recoveryCopies,
            status: status
        )
    }

    private func appendRecoveryCopies(
        for outgoing: [SharedFolderRecord],
        remote: SharedFolderTransportSnapshot
    ) {
        let remoteByID = Dictionary(uniqueKeysWithValues: remote.records.map { ($0.id, $0) })
        var copies = state.recoveryCopies
        for local in outgoing {
            guard !local.isTombstone,
                  let winner = remoteByID[local.id],
                  !winner.isTombstone,
                  winner.stamp > local.stamp,
                  winner.payload != local.payload
            else { continue }
            copies.append(SharedConflictRecoveryCopy(
                originalItemID: local.id,
                workspaceID: state.location.folderID,
                losingRecord: local,
                winningStamp: winner.stamp
            ))
        }
        let newestFirst = copies.sorted { $0.detectedAt > $1.detectedAt }
        var countsByItem: [UUID: Int] = [:]
        var accepted: [SharedConflictRecoveryCopy] = []
        for copy in newestFirst {
            guard accepted.count < 100,
                  countsByItem[copy.originalItemID, default: 0] < 3
            else { continue }
            countsByItem[copy.originalItemID, default: 0] += 1
            accepted.append(copy)
        }
        state = SharedFolderSessionSnapshot(
            location: state.location,
            currentParticipantID: state.currentParticipantID,
            participants: state.participants,
            folder: state.folder,
            folders: state.folders,
            savedClips: state.savedClips,
            automationDefinitions: state.automationDefinitions,
            debugBundles: state.debugBundles,
            managedFolderIDs: state.managedFolderIDs,
            managedSavedClipIDs: state.managedSavedClipIDs,
            managedAutomationDefinitionIDs: state.managedAutomationDefinitionIDs,
            managedDebugBundleIDs: state.managedDebugBundleIDs,
            recoveryCopies: accepted.sorted { $0.detectedAt < $1.detectedAt },
            status: state.status
        )
    }

    private static func canonicalSharedFolder(_ folder: ClipFolder) -> ClipFolder {
        // Folder order is a device-local presentation preference. The shared record only carries
        // collaborative identity/name/timestamps and therefore has one deterministic order.
        try! ClipFolder(
            id: folder.id,
            name: folder.name,
            parentFolderID: folder.parentFolderID,
            sortOrder: 0,
            createdAt: folder.createdAt,
            modifiedAt: folder.modifiedAt
        )
    }

    private static func orderedDescendantFolders(
        rootID: UUID,
        folders: [ClipFolder]
    ) throws -> [ClipFolder] {
        guard Set(folders.map(\.id)).count == folders.count,
              !folders.contains(where: { $0.id == rootID })
        else { throw SharedFolderError.invalidRecord(rootID) }
        var remaining = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        var available: Set<UUID> = [rootID]
        var result: [ClipFolder] = []
        while !remaining.isEmpty {
            let ready = remaining.values.filter {
                $0.parentFolderID.map(available.contains) == true
            }.sorted { $0.id.uuidString < $1.id.uuidString }
            guard !ready.isEmpty else {
                let id = remaining.keys.min(by: { $0.uuidString < $1.uuidString }) ?? rootID
                throw SharedFolderError.hierarchyCycle(id)
            }
            for folder in ready {
                remaining.removeValue(forKey: folder.id)
                available.insert(folder.id)
                result.append(folder)
            }
        }
        return result
    }

    private static func deepestFirst(_ folders: [ClipFolder]) -> [ClipFolder] {
        let byID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        func depth(_ folder: ClipFolder) -> Int {
            var seen: Set<UUID> = [folder.id]
            var cursor = folder.parentFolderID
            var result = 0
            while let id = cursor, let parent = byID[id], seen.insert(id).inserted {
                result += 1
                cursor = parent.parentFolderID
            }
            return result
        }
        return folders.sorted {
            let lhs = depth($0), rhs = depth($1)
            return lhs == rhs ? $0.id.uuidString < $1.id.uuidString : lhs > rhs
        }
    }

    private static func coordinatorParticipants(
        for remote: SharedFolderTransportSnapshot
    ) throws -> [SharedFolderParticipant] {
        var roles = Dictionary(uniqueKeysWithValues: remote.participants.map { ($0.id, $0.role) })
        for authorization in remote.recordAuthorizations.values {
            let existing = roles[authorization.authorParticipantID]
            if authorization.roleAtWrite == .owner {
                guard authorization.authorParticipantID == remote.location.ownerParticipantID else {
                    throw SharedFolderError.permissionDenied
                }
                roles[authorization.authorParticipantID] = .owner
            } else if authorization.roleAtWrite == .editor, existing != .owner {
                roles[authorization.authorParticipantID] = .editor
            } else if existing == nil {
                roles[authorization.authorParticipantID] = .viewer
            }
        }
        return try roles.map { try SharedFolderParticipant(id: $0.key, role: $0.value) }
    }
}

/// Deterministic, process-local CloudKit substitute. It deliberately preserves the same
/// role/scope validation boundary as the live transport and never pretends to prove CloudKit.
public actor InMemorySharedFolderTransport: SharedFolderTransport {
    private struct RemoteFolder: Sendable {
        var location: SharedFolderRemoteLocation
        var participants: [SharedFolderCloudParticipant]
        var records: [UUID: SharedFolderRecord]
        var recordAuthorizations: [UUID: SharedFolderRecordAuthorization]
    }

    private let participantID: String
    private var folders: [UUID: RemoteFolder]
    private var configuredCapability: SharedCloudCapability
    private var nextError: SharedFolderError?
    public private(set) var createCallCount = 0
    public private(set) var synchronizeCallCount = 0

    public init(
        participantID: String = "owner",
        capability: SharedCloudCapability = .available,
        snapshots: [SharedFolderTransportSnapshot] = []
    ) {
        self.participantID = participantID
        self.configuredCapability = capability
        self.folders = Dictionary(uniqueKeysWithValues: snapshots.map { snapshot in
            (
                snapshot.location.folderID,
                RemoteFolder(
                    location: snapshot.location,
                    participants: snapshot.participants,
                    records: Dictionary(uniqueKeysWithValues: snapshot.records.map { ($0.id, $0) }),
                    recordAuthorizations: snapshot.recordAuthorizations
                )
            )
        })
    }

    public func capability() async -> SharedCloudCapability { configuredCapability }

    public func currentParticipantID() async throws -> String {
        try requireAvailable()
        return participantID
    }

    public func createShare(
        for scope: SharedFolderScope,
        title: String
    ) async throws -> SharedFolderTransportSnapshot {
        try requireAvailable()
        if let nextError {
            self.nextError = nil
            throw nextError
        }
        createCallCount += 1
        guard folders[scope.folderID] == nil else {
            throw SharedFolderError.cloudFailure("This folder already has a share")
        }
        guard scope.ownerParticipantID == participantID else {
            throw SharedFolderError.permissionDenied
        }
        let owner = try SharedFolderCloudParticipant(
            id: participantID,
            displayName: "Owner",
            role: .owner,
            acceptance: .accepted
        )
        let location = SharedFolderRemoteLocation(
            folderID: scope.folderID,
            zoneName: scope.zoneName,
            ownerName: "test-owner",
            ownerParticipantID: participantID,
            shareRecordName: "zone-wide-share",
            databaseScope: .ownerPrivate,
            title: title
        )
        folders[scope.folderID] = RemoteFolder(
            location: location,
            participants: [owner],
            records: [:],
            recordAuthorizations: [:]
        )
        return try snapshot(for: scope.folderID)
    }

    public func synchronize(
        _ records: [SharedFolderRecord],
        at location: SharedFolderRemoteLocation
    ) async throws -> SharedFolderTransportSnapshot {
        try requireAvailable()
        if let nextError {
            self.nextError = nil
            throw nextError
        }
        synchronizeCallCount += 1
        guard var remote = folders[location.folderID], remote.location == location else {
            throw SharedFolderError.cloudFailure("The shared folder is not available")
        }
        guard let participant = remote.participants.first(where: { $0.id == participantID }) else {
            throw SharedFolderError.unknownParticipant(participantID)
        }
        for candidate in records {
            guard candidate.scopeFolderID == location.folderID,
                  candidate.authorParticipantID == participantID
            else {
                throw SharedFolderError.permissionDenied
            }
            switch candidate.kind {
            case .rootFolder where !participant.role.canManageFolder:
                throw SharedFolderError.permissionDenied
            case .folder where !participant.role.canEditClips:
                throw SharedFolderError.permissionDenied
            case .savedClip where !participant.role.canEditClips:
                throw SharedFolderError.permissionDenied
            default:
                break
            }
            if let existing = remote.records[candidate.id], existing.stamp >= candidate.stamp {
                continue
            }
            remote.records[candidate.id] = candidate
            remote.recordAuthorizations[candidate.id] = try SharedFolderRecordAuthorization(
                recordID: candidate.id,
                authorParticipantID: participantID,
                roleAtWrite: participant.role
            )
        }
        folders[location.folderID] = remote
        return try snapshot(for: location.folderID)
    }

    public func failNext(_ error: SharedFolderError) { nextError = error }
    public func setCapability(_ capability: SharedCloudCapability) {
        configuredCapability = capability
    }

    public func setParticipants(
        _ participants: [SharedFolderCloudParticipant],
        for folderID: UUID
    ) throws {
        guard var remote = folders[folderID] else {
            throw SharedFolderError.cloudFailure("The shared folder is not available")
        }
        remote.participants = participants
        folders[folderID] = remote
    }

    private func requireAvailable() throws {
        if case let .unavailable(issue) = configuredCapability {
            throw SharedFolderError.cloudCapabilityUnavailable(issue)
        }
    }

    private func snapshot(for folderID: UUID) throws -> SharedFolderTransportSnapshot {
        guard let remote = folders[folderID] else {
            throw SharedFolderError.cloudFailure("The shared folder is not available")
        }
        return try SharedFolderTransportSnapshot(
            location: remote.location,
            currentParticipantID: participantID,
            participants: remote.participants,
            records: Array(remote.records.values),
            recordAuthorizations: Array(remote.recordAuthorizations.values)
        )
    }
}
