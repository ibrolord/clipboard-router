import ClipboardRouterCore
import Foundation

public enum SharedFolderRole: String, Codable, CaseIterable, Equatable, Sendable {
    case owner
    case editor
    case viewer

    public var canEditClips: Bool { self == .owner || self == .editor }
    public var canManageFolder: Bool { self == .owner }
    public var canManageParticipants: Bool { self == .owner }
}

public struct SharedFolderParticipant: Codable, Equatable, Identifiable, Sendable {
    public static let maximumIdentifierBytes = 256

    public let id: String
    public var role: SharedFolderRole

    public init(id: String, role: SharedFolderRole) throws {
        guard !id.isEmpty,
              id == id.trimmingCharacters(in: .whitespacesAndNewlines),
              id.lengthOfBytes(using: .utf8) <= Self.maximumIdentifierBytes
        else {
            throw SharedFolderError.invalidParticipantID
        }
        self.id = id
        self.role = role
    }

    private enum CodingKeys: String, CodingKey { case id, role }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(String.self, forKey: .id),
            role: container.decode(SharedFolderRole.self, forKey: .role)
        )
    }
}

/// Exactly one deterministic CloudKit scope and zone is assigned to each shared folder.
public struct SharedFolderScope: Codable, Equatable, Hashable, Sendable {
    public static let v2ZonePrefix = "ClipboardRouterSharedFolderV2-"

    public let folderID: UUID
    public let ownerParticipantID: String

    public init(folderID: UUID, ownerParticipantID: String) throws {
        _ = try SharedFolderParticipant(id: ownerParticipantID, role: .owner)
        self.folderID = folderID
        self.ownerParticipantID = ownerParticipantID
    }

    public var zoneName: String {
        Self.v2ZonePrefix + folderID.uuidString.lowercased()
    }
}

public enum SharedFolderEntityKind: String, Codable, Equatable, Sendable {
    case rootFolder
    case folder
    case savedClip
    case automationDefinition
}

public enum SharedFolderPayload: Codable, Equatable, Sendable {
    case rootFolder(ClipFolder)
    case folder(ClipFolder)
    case savedClip(SavedClip, metadata: SavedClipSyncMetadata)
    case automationDefinition(ClipFlow)

    public var id: UUID {
        switch self {
        case let .rootFolder(folder): folder.id
        case let .folder(folder): folder.id
        case let .savedClip(clip, _): clip.id
        case let .automationDefinition(flow): flow.id
        }
    }

    public var kind: SharedFolderEntityKind {
        switch self {
        case .rootFolder: .rootFolder
        case .folder: .folder
        case .savedClip: .savedClip
        case .automationDefinition: .automationDefinition
        }
    }
}

/// A Lamport/tombstone record scoped to one shared-folder v2 zone.
public struct SharedFolderRecord: Codable, Equatable, Identifiable, Sendable {
    public static let maximumEncodedBytes = SavedLibrarySyncRecord.maximumEncodedBytes

    public let id: UUID
    public let scopeFolderID: UUID
    public let kind: SharedFolderEntityKind
    public let stamp: LamportStamp
    public let authorParticipantID: String
    public let isTombstone: Bool
    public let payload: SharedFolderPayload?

    public init(
        id: UUID,
        scopeFolderID: UUID,
        kind: SharedFolderEntityKind,
        stamp: LamportStamp,
        authorParticipantID: String,
        isTombstone: Bool,
        payload: SharedFolderPayload?
    ) throws {
        _ = try SharedFolderParticipant(id: authorParticipantID, role: .viewer)
        if isTombstone {
            guard payload == nil else { throw SharedFolderError.invalidRecord(id) }
        } else {
            guard let payload, payload.id == id, payload.kind == kind else {
                throw SharedFolderError.invalidRecord(id)
            }
            switch payload {
            case let .rootFolder(folder):
                guard folder.id == scopeFolderID, folder.parentFolderID == nil else {
                    throw SharedFolderError.wrongScope(expected: scopeFolderID, actual: folder.id)
                }
            case let .folder(folder):
                guard folder.id != scopeFolderID,
                      let parentID = folder.parentFolderID,
                      parentID != folder.id
                else { throw SharedFolderError.invalidRecord(folder.id) }
            case let .savedClip(clip, metadata):
                guard clip.folderID != nil else {
                    throw SharedFolderError.wrongScope(expected: scopeFolderID, actual: nil)
                }
                let permissiveLocationPolicy = SyncEligibilityPolicy(allowsLocation: true)
                if case let .localOnly(reason) = permissiveLocationPolicy.evaluate(
                    .savedClip(clip, metadata: metadata)
                ) {
                    throw SharedFolderError.ineligible(clip.id, reason)
                }
            case let .automationDefinition(flow):
                guard flow.sharedFolderID == scopeFolderID,
                      !flow.isEnabled,
                      flow.steps.allSatisfy(\.isPortable),
                      flow.steps.allSatisfy({ step in
                          if case let .moveToFolder(_, folderID) = step { return folderID != nil }
                          return true
                      })
                else { throw SharedFolderError.invalidRecord(flow.id) }
            }
        }

        self.id = id
        self.scopeFolderID = scopeFolderID
        self.kind = kind
        self.stamp = stamp
        self.authorParticipantID = authorParticipantID
        self.isTombstone = isTombstone
        self.payload = payload

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let size = try encoder.encode(self).count
        guard size <= Self.maximumEncodedBytes else {
            throw SharedFolderError.recordTooLarge(id, size)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, scopeFolderID, kind, stamp, authorParticipantID, isTombstone, payload
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            scopeFolderID: container.decode(UUID.self, forKey: .scopeFolderID),
            kind: container.decode(SharedFolderEntityKind.self, forKey: .kind),
            stamp: container.decode(LamportStamp.self, forKey: .stamp),
            authorParticipantID: container.decode(String.self, forKey: .authorParticipantID),
            isTombstone: container.decode(Bool.self, forKey: .isTombstone),
            payload: container.decodeIfPresent(SharedFolderPayload.self, forKey: .payload)
        )
    }

    public static func live(
        _ payload: SharedFolderPayload,
        scope: SharedFolderScope,
        stamp: LamportStamp,
        authorParticipantID: String
    ) throws -> SharedFolderRecord {
        try SharedFolderRecord(
            id: payload.id,
            scopeFolderID: scope.folderID,
            kind: payload.kind,
            stamp: stamp,
            authorParticipantID: authorParticipantID,
            isTombstone: false,
            payload: payload
        )
    }

    public static func tombstone(
        id: UUID,
        kind: SharedFolderEntityKind,
        scope: SharedFolderScope,
        stamp: LamportStamp,
        authorParticipantID: String
    ) throws -> SharedFolderRecord {
        try SharedFolderRecord(
            id: id,
            scopeFolderID: scope.folderID,
            kind: kind,
            stamp: stamp,
            authorParticipantID: authorParticipantID,
            isTombstone: true,
            payload: nil
        )
    }
}

public struct SharedFolderSnapshot: Codable, Equatable, Sendable {
    public let scope: SharedFolderScope
    public var participants: [String: SharedFolderParticipant]
    public var records: [UUID: SharedFolderRecord]
    public var localLamportCounter: Int64

    public init(
        scope: SharedFolderScope,
        participants: [String: SharedFolderParticipant],
        records: [UUID: SharedFolderRecord] = [:],
        localLamportCounter: Int64 = 0
    ) {
        self.scope = scope
        self.participants = participants
        self.records = records
        self.localLamportCounter = localLamportCounter
    }
}

public enum SharedCloudCapabilityIssue: String, Codable, Equatable, Sendable {
    case featureDisabled
    case configurationMissing
    case noICloudAccount
    case restrictedAccount
    case temporarilyUnavailable
    case couldNotDetermine
}

public enum SharedCloudCapability: Equatable, Sendable {
    case available
    case unavailable(SharedCloudCapabilityIssue)
}

public enum SharedFolderError: Error, Equatable, LocalizedError, Sendable {
    case invalidParticipantID
    case invalidParticipants
    case unknownParticipant(String)
    case permissionDenied
    case ownerRoleIsImmutable
    case wrongScope(expected: UUID, actual: UUID?)
    case hierarchyCycle(UUID)
    case invalidRecord(UUID)
    case stampCollision(UUID)
    case lamportOverflow
    case ineligible(UUID, SyncLocalOnlyReason)
    case recordTooLarge(UUID, Int)
    case cloudCapabilityUnavailable(SharedCloudCapabilityIssue)
    case cloudFailure(String)

    public var errorDescription: String? {
        switch self {
        case .invalidParticipantID: "The shared-folder participant identifier is invalid."
        case .invalidParticipants: "The shared folder must have exactly one matching owner."
        case let .unknownParticipant(id): "Shared-folder participant \(id) is unknown."
        case .permissionDenied: "This shared-folder role cannot perform that operation."
        case .ownerRoleIsImmutable: "The shared-folder owner role cannot be reassigned locally."
        case let .wrongScope(expected, actual):
            "The record belongs to folder \(actual?.uuidString ?? "none"), not \(expected.uuidString)."
        case let .hierarchyCycle(id): "Shared-folder hierarchy contains a cycle at \(id)."
        case let .invalidRecord(id): "Shared-folder record \(id) is invalid."
        case let .stampCollision(id): "Shared-folder record \(id) reused a Lamport stamp."
        case .lamportOverflow: "The shared-folder logical clock is exhausted."
        case let .ineligible(id, reason):
            "Shared-folder entity \(id) remains local-only (\(reason.rawValue))."
        case let .recordTooLarge(id, size):
            "Shared-folder record \(id) is \(size) bytes and exceeds the sync limit."
        case let .cloudCapabilityUnavailable(issue):
            "CloudKit sharing is unavailable (\(issue.rawValue))."
        case let .cloudFailure(reason): "CloudKit sharing failed: \(reason)"
        }
    }
}
