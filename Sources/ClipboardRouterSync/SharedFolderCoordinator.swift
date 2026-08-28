import ClipboardRouterCore
import Foundation

/// Deterministic, transport-independent collaboration engine for exactly one folder scope.
public actor SharedFolderCoordinator {
    private let currentParticipantID: String
    private let deviceID: String
    private let eligibilityPolicy: SyncEligibilityPolicy
    private var state: SharedFolderSnapshot

    public init(
        scope: SharedFolderScope,
        currentParticipantID: String,
        deviceID: String,
        participants: [SharedFolderParticipant],
        records: [SharedFolderRecord] = [],
        localLamportCounter: Int64 = 0,
        eligibilityPolicy: SyncEligibilityPolicy = SyncEligibilityPolicy()
    ) throws {
        _ = try LamportStamp(counter: 0, deviceID: deviceID)
        var mappedParticipants: [String: SharedFolderParticipant] = [:]
        for participant in participants {
            guard mappedParticipants.updateValue(participant, forKey: participant.id) == nil else {
                throw SharedFolderError.invalidParticipants
            }
        }
        guard mappedParticipants[currentParticipantID] != nil,
              mappedParticipants[scope.ownerParticipantID]?.role == .owner,
              mappedParticipants.values.filter({ $0.role == .owner }).count == 1,
              localLamportCounter >= 0,
              localLamportCounter < Int64.max
        else {
            throw SharedFolderError.invalidParticipants
        }

        var mappedRecords: [UUID: SharedFolderRecord] = [:]
        var stampOwners: [LamportStamp: UUID] = [:]
        var maximumRecordCounter: Int64 = 0
        for record in records {
            try Self.validate(
                record,
                scope: scope,
                participants: mappedParticipants,
                eligibilityPolicy: eligibilityPolicy
            )
            guard mappedRecords.updateValue(record, forKey: record.id) == nil else {
                throw SharedFolderError.invalidRecord(record.id)
            }
            if let otherID = stampOwners.updateValue(record.id, forKey: record.stamp),
               otherID != record.id
            {
                throw SharedFolderError.stampCollision(record.id)
            }
            maximumRecordCounter = max(maximumRecordCounter, record.stamp.counter)
        }
        guard localLamportCounter >= maximumRecordCounter else {
            throw SharedFolderError.invalidRecord(scope.folderID)
        }
        try Self.validateSubtree(records: mappedRecords, scope: scope)

        self.currentParticipantID = currentParticipantID
        self.deviceID = deviceID
        self.eligibilityPolicy = eligibilityPolicy
        self.state = SharedFolderSnapshot(
            scope: scope,
            participants: mappedParticipants,
            records: mappedRecords,
            localLamportCounter: localLamportCounter
        )
    }

    public func snapshot() -> SharedFolderSnapshot { state }

    public func currentRole() -> SharedFolderRole {
        // Validated at initialization and owner removal is forbidden.
        state.participants[currentParticipantID]?.role ?? .viewer
    }

    public func setRole(_ role: SharedFolderRole, for participantID: String) throws {
        guard currentRole().canManageParticipants else {
            throw SharedFolderError.permissionDenied
        }
        if participantID == state.scope.ownerParticipantID || role == .owner {
            throw SharedFolderError.ownerRoleIsImmutable
        }
        state.participants[participantID] = try SharedFolderParticipant(
            id: participantID,
            role: role
        )
    }

    public func removeParticipant(id: String) throws {
        guard currentRole().canManageParticipants else {
            throw SharedFolderError.permissionDenied
        }
        guard id != state.scope.ownerParticipantID else {
            throw SharedFolderError.ownerRoleIsImmutable
        }
        guard state.participants.removeValue(forKey: id) != nil else {
            throw SharedFolderError.unknownParticipant(id)
        }
    }

    @discardableResult
    public func recordRootFolder(_ folder: ClipFolder) throws -> SharedFolderRecord {
        guard currentRole().canManageFolder else { throw SharedFolderError.permissionDenied }
        guard folder.id == state.scope.folderID else {
            throw SharedFolderError.wrongScope(
                expected: state.scope.folderID,
                actual: folder.id
            )
        }
        return try record(.rootFolder(folder))
    }

    @discardableResult
    public func recordFolder(_ folder: ClipFolder) throws -> SharedFolderRecord {
        guard currentRole().canEditClips else { throw SharedFolderError.permissionDenied }
        guard folder.id != state.scope.folderID else {
            throw SharedFolderError.wrongScope(expected: state.scope.folderID, actual: folder.id)
        }
        return try record(.folder(folder))
    }

    @discardableResult
    public func recordSavedClip(
        _ clip: SavedClip,
        metadata: SavedClipSyncMetadata = .ready
    ) throws -> SharedFolderRecord {
        guard currentRole().canEditClips else { throw SharedFolderError.permissionDenied }
        if case let .localOnly(reason) = eligibilityPolicy.evaluate(
            .savedClip(clip, metadata: metadata)
        ) {
            throw SharedFolderError.ineligible(clip.id, reason)
        }
        guard let folderID = clip.folderID, Self.isInScope(folderID, records: state.records, scope: state.scope) else {
            throw SharedFolderError.wrongScope(
                expected: state.scope.folderID,
                actual: clip.folderID
            )
        }
        return try record(.savedClip(clip, metadata: metadata))
    }

    @discardableResult
    public func recordAutomationDefinition(_ flow: ClipFlow) throws -> SharedFolderRecord {
        guard currentRole().canManageFolder,
              flow.sharedFolderID == state.scope.folderID,
              !flow.isEnabled,
              flow.steps.allSatisfy(\.isPortable)
        else { throw SharedFolderError.permissionDenied }
        return try record(.automationDefinition(flow))
    }

    @discardableResult
    public func recordDeletion(
        id: UUID,
        kind: SharedFolderEntityKind
    ) throws -> SharedFolderRecord {
        switch kind {
        case .rootFolder:
            guard currentRole().canManageFolder else { throw SharedFolderError.permissionDenied }
            guard id == state.scope.folderID else {
                throw SharedFolderError.wrongScope(
                    expected: state.scope.folderID,
                    actual: id
                )
            }
        case .savedClip:
            guard currentRole().canEditClips else { throw SharedFolderError.permissionDenied }
        case .folder:
            guard currentRole().canEditClips else { throw SharedFolderError.permissionDenied }
            guard id != state.scope.folderID else {
                throw SharedFolderError.wrongScope(expected: state.scope.folderID, actual: id)
            }
        case .automationDefinition:
            guard currentRole().canManageFolder else { throw SharedFolderError.permissionDenied }
        }
        var next = state
        let stamp = try nextStamp(for: id, in: &next)
        let tombstone = try SharedFolderRecord.tombstone(
            id: id,
            kind: kind,
            scope: state.scope,
            stamp: stamp,
            authorParticipantID: currentParticipantID
        )
        next.records[id] = tombstone
        try Self.validateSubtree(records: next.records, scope: next.scope)
        state = next
        return tombstone
    }

    /// Merges an atomic batch. Any invalid scope, role, policy, or stamp collision rejects all.
    public func merge(_ incoming: [SharedFolderRecord]) throws {
        var next = state
        var stampOwners = Dictionary(
            uniqueKeysWithValues: next.records.values.map { ($0.stamp, $0.id) }
        )
        let ordered = incoming.sorted { lhs, rhs in
            if lhs.id != rhs.id { return lhs.id.uuidString < rhs.id.uuidString }
            if lhs.stamp != rhs.stamp { return lhs.stamp < rhs.stamp }
            return lhs.authorParticipantID < rhs.authorParticipantID
        }

        for remote in ordered {
            try Self.validate(
                remote,
                scope: next.scope,
                participants: next.participants,
                eligibilityPolicy: eligibilityPolicy
            )
            if let otherID = stampOwners[remote.stamp], otherID != remote.id {
                throw SharedFolderError.stampCollision(remote.id)
            }
            stampOwners[remote.stamp] = remote.id

            next.localLamportCounter = max(next.localLamportCounter, remote.stamp.counter)
            if let local = next.records[remote.id] {
                if remote.stamp == local.stamp, remote != local {
                    throw SharedFolderError.stampCollision(remote.id)
                }
                if remote.stamp > local.stamp {
                    next.records[remote.id] = remote
                }
            } else {
                next.records[remote.id] = remote
            }
        }
        try Self.validateSubtree(records: next.records, scope: next.scope)
        state = next
    }

    public func recordsForUpload() -> [SharedFolderRecord] {
        state.records.values.sorted { lhs, rhs in
            lhs.id.uuidString == rhs.id.uuidString
                ? lhs.stamp < rhs.stamp
                : lhs.id.uuidString < rhs.id.uuidString
        }
    }

    public func materialized() -> (folder: ClipFolder?, savedClips: [SavedClip]) {
        var folder: ClipFolder?
        var clips: [SavedClip] = []
        for record in state.records.values where !record.isTombstone {
            switch record.payload {
            case let .rootFolder(value): folder = value
            case .folder: break
            case let .savedClip(clip, _): clips.append(clip)
            case .automationDefinition: break
            case nil: break
            }
        }
        clips.sort { $0.id.uuidString < $1.id.uuidString }
        return (folder, clips)
    }

    public func materializedSubtree() -> (root: ClipFolder?, folders: [ClipFolder], savedItems: [SavedClip], automationDefinitions: [ClipFlow], debugBundles: [SharedDebugBundlePublication]) {
        var root: ClipFolder?
        var folders: [ClipFolder] = []
        var items: [SavedClip] = []
        var definitions: [ClipFlow] = []
        var debugBundles: [SharedDebugBundlePublication] = []
        for record in state.records.values where !record.isTombstone {
            switch record.payload {
            case let .rootFolder(folder): root = folder
            case let .folder(folder): folders.append(folder)
            case let .savedClip(item, _): items.append(item)
            case let .automationDefinition(flow): definitions.append(flow)
            case nil: break
            }
        }
        folders.sort { $0.id.uuidString < $1.id.uuidString }
        items.sort { $0.id.uuidString < $1.id.uuidString }
        definitions.sort { $0.id.uuidString < $1.id.uuidString }
        debugBundles.sort { lhs, rhs in
            lhs.publishedAt == rhs.publishedAt
                ? lhs.id.uuidString < rhs.id.uuidString
                : lhs.publishedAt > rhs.publishedAt
        }
        return (root, folders, items, definitions, debugBundles)
    }

    private func record(_ payload: SharedFolderPayload) throws -> SharedFolderRecord {
        var next = state
        let stamp = try nextStamp(for: payload.id, in: &next)
        let record = try SharedFolderRecord.live(
            payload,
            scope: next.scope,
            stamp: stamp,
            authorParticipantID: currentParticipantID
        )
        next.records[payload.id] = record
        try Self.validateSubtree(records: next.records, scope: next.scope)
        state = next
        return record
    }

    private func nextStamp(
        for id: UUID,
        in snapshot: inout SharedFolderSnapshot
    ) throws -> LamportStamp {
        let entityCounter = snapshot.records[id]?.stamp.counter ?? 0
        let current = max(snapshot.localLamportCounter, entityCounter)
        guard current < Int64.max - 1 else { throw SharedFolderError.lamportOverflow }
        snapshot.localLamportCounter = current + 1
        return try LamportStamp(counter: snapshot.localLamportCounter, deviceID: deviceID)
    }

    private static func validate(
        _ record: SharedFolderRecord,
        scope: SharedFolderScope,
        participants: [String: SharedFolderParticipant],
        eligibilityPolicy: SyncEligibilityPolicy
    ) throws {
        guard record.scopeFolderID == scope.folderID else {
            throw SharedFolderError.wrongScope(
                expected: scope.folderID,
                actual: record.scopeFolderID
            )
        }
        let reconstructedStamp = try LamportStamp(
            counter: record.stamp.counter,
            deviceID: record.stamp.deviceID
        )
        guard reconstructedStamp == record.stamp else {
            throw SharedFolderError.invalidRecord(record.id)
        }
        guard let participant = participants[record.authorParticipantID] else {
            throw SharedFolderError.unknownParticipant(record.authorParticipantID)
        }
        switch record.kind {
        case .rootFolder:
            guard participant.role.canManageFolder, record.id == scope.folderID else {
                throw SharedFolderError.permissionDenied
            }
        case .savedClip:
            guard participant.role.canEditClips else {
                throw SharedFolderError.permissionDenied
            }
        case .folder:
            guard participant.role.canEditClips else {
                throw SharedFolderError.permissionDenied
            }
        case .automationDefinition:
            guard participant.role.canManageFolder else {
                throw SharedFolderError.permissionDenied
            }
        }
        if case let .savedClip(clip, metadata) = record.payload,
           case let .localOnly(reason) = eligibilityPolicy.evaluate(
               .savedClip(clip, metadata: metadata)
           )
        {
            throw SharedFolderError.ineligible(clip.id, reason)
        }
    }

    private static func isInScope(
        _ folderID: UUID,
        records: [UUID: SharedFolderRecord],
        scope: SharedFolderScope
    ) -> Bool {
        if folderID == scope.folderID { return true }
        var seen: Set<UUID> = []
        var cursor: UUID? = folderID
        while let id = cursor, seen.insert(id).inserted {
            guard let record = records[id], !record.isTombstone,
                  case let .folder(folder) = record.payload
            else { return false }
            if folder.parentFolderID == scope.folderID { return true }
            cursor = folder.parentFolderID
        }
        return false
    }

    private static func validateSubtree(
        records: [UUID: SharedFolderRecord],
        scope: SharedFolderScope
    ) throws {
        for record in records.values where !record.isTombstone {
            switch record.payload {
            case let .rootFolder(folder):
                guard folder.id == scope.folderID, folder.parentFolderID == nil else {
                    throw SharedFolderError.wrongScope(expected: scope.folderID, actual: folder.parentFolderID)
                }
            case let .folder(folder):
                guard isInScope(folder.id, records: records, scope: scope) else {
                    var seen: Set<UUID> = []
                    var cursor: UUID? = folder.id
                    var cycleID: UUID?
                    while let id = cursor {
                        guard seen.insert(id).inserted else {
                            cycleID = id
                            break
                        }
                        guard let candidate = records[id], !candidate.isTombstone,
                              case let .folder(value) = candidate.payload
                        else { break }
                        cursor = value.parentFolderID
                    }
                    if let cycleID {
                        throw SharedFolderError.hierarchyCycle(cycleID)
                    }
                    throw SharedFolderError.wrongScope(expected: scope.folderID, actual: folder.parentFolderID)
                }
            case let .savedClip(item, _):
                guard let folderID = item.folderID,
                      isInScope(folderID, records: records, scope: scope)
                else { throw SharedFolderError.wrongScope(expected: scope.folderID, actual: item.folderID) }
            case let .automationDefinition(flow):
                guard flow.sharedFolderID == scope.folderID,
                      !flow.isEnabled,
                      flow.steps.allSatisfy(\.isPortable)
                else { throw SharedFolderError.invalidRecord(flow.id) }
                for step in flow.steps {
                    if case let .moveToFolder(_, folderID) = step {
                        guard let folderID,
                              isInScope(folderID, records: records, scope: scope)
                        else { throw SharedFolderError.wrongScope(expected: scope.folderID, actual: folderID) }
                    }
                }
            case nil: break
            }
        }
    }
}
