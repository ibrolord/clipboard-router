import ClipboardRouterCore
import Foundation

public struct LamportStamp: Codable, Equatable, Hashable, Comparable, Sendable {
    public static let maximumDeviceIDBytes = 128
    public let counter: Int64
    public let deviceID: String

    public init(counter: Int64, deviceID: String) throws {
        guard counter >= 0, counter < Int64.max else {
            throw SavedLibrarySyncError.invalidLamportStamp
        }
        let normalizedDeviceID = deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedDeviceID.isEmpty,
              normalizedDeviceID.lengthOfBytes(using: .utf8) <= Self.maximumDeviceIDBytes,
              normalizedDeviceID == deviceID
        else { throw SavedLibrarySyncError.invalidLamportStamp }
        self.counter = counter
        self.deviceID = deviceID
    }

    private enum CodingKeys: String, CodingKey { case counter, deviceID }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            counter: container.decode(Int64.self, forKey: .counter),
            deviceID: container.decode(String.self, forKey: .deviceID)
        )
    }

    public static func < (lhs: LamportStamp, rhs: LamportStamp) -> Bool {
        lhs.counter == rhs.counter
            ? lhs.deviceID.lexicographicallyPrecedes(rhs.deviceID)
            : lhs.counter < rhs.counter
    }
}

public enum SyncEntityKind: String, Codable, Sendable {
    case savedClip
    case folder
}

/// Deliberately has no HistoryItem or VaultItem case.
public enum SavedLibraryPayload: Codable, Equatable, Sendable {
    case savedClip(SavedClip)
    case folder(ClipFolder)

    public var id: UUID {
        switch self {
        case let .savedClip(clip): clip.id
        case let .folder(folder): folder.id
        }
    }

    public var kind: SyncEntityKind {
        switch self {
        case .savedClip: .savedClip
        case .folder: .folder
        }
    }
}

public struct SavedLibrarySyncRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let kind: SyncEntityKind
    public let stamp: LamportStamp
    public let isTombstone: Bool
    public let payload: SavedLibraryPayload?
    /// Present only for saved clips. Pending analysis is never a valid record state.
    public let savedClipMetadata: SavedClipSyncMetadata?
    /// Immutable, content-addressed manifest for original rich/image representations.
    public let assetManifest: [SavedLibrarySyncAssetDescriptor]

    public init(
        id: UUID,
        kind: SyncEntityKind,
        stamp: LamportStamp,
        isTombstone: Bool,
        payload: SavedLibraryPayload?,
        savedClipMetadata: SavedClipSyncMetadata? = nil,
        assetManifest: [SavedLibrarySyncAssetDescriptor] = []
    ) throws {
        if isTombstone {
            guard payload == nil, savedClipMetadata == nil, assetManifest.isEmpty else {
                throw SavedLibrarySyncError.invalidRecord(id)
            }
        } else {
            guard let payload, payload.id == id, payload.kind == kind else {
                throw SavedLibrarySyncError.invalidRecord(id)
            }
            switch payload {
            case .folder:
                guard savedClipMetadata == nil, assetManifest.isEmpty else {
                    throw SavedLibrarySyncError.invalidRecord(id)
                }
            case .savedClip:
                guard savedClipMetadata?.analysisState != .pending else {
                    throw SavedLibrarySyncError.invalidRecord(id)
                }
            }
        }
        self.id = id
        self.kind = kind
        self.stamp = stamp
        self.isTombstone = isTombstone
        self.payload = payload
        self.savedClipMetadata = savedClipMetadata
        self.assetManifest = assetManifest.sorted(
            by: SavedLibrarySyncAssetDescriptor.deterministicOrder
        )
        try Self.validatePayload(payload)
        try Self.validateAssetManifest(self.assetManifest, for: payload)
        try Self.validateSize(self)
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, stamp, isTombstone, payload, savedClipMetadata, assetManifest
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            kind: container.decode(SyncEntityKind.self, forKey: .kind),
            stamp: container.decode(LamportStamp.self, forKey: .stamp),
            isTombstone: container.decode(Bool.self, forKey: .isTombstone),
            payload: container.decodeIfPresent(SavedLibraryPayload.self, forKey: .payload),
            savedClipMetadata: container.decodeIfPresent(
                SavedClipSyncMetadata.self,
                forKey: .savedClipMetadata
            ),
            assetManifest: container.decodeIfPresent(
                [SavedLibrarySyncAssetDescriptor].self,
                forKey: .assetManifest
            ) ?? []
        )
    }

    public static func live(
        _ payload: SavedLibraryPayload,
        stamp: LamportStamp,
        savedClipMetadata: SavedClipSyncMetadata? = nil,
        assetManifest: [SavedLibrarySyncAssetDescriptor] = []
    ) throws -> Self {
        try Self(
            id: payload.id,
            kind: payload.kind,
            stamp: stamp,
            isTombstone: false,
            payload: payload,
            savedClipMetadata: savedClipMetadata,
            assetManifest: assetManifest
        )
    }

    public static func tombstone(
        id: UUID,
        kind: SyncEntityKind,
        stamp: LamportStamp
    ) throws -> Self {
        try Self(
            id: id,
            kind: kind,
            stamp: stamp,
            isTombstone: true,
            payload: nil,
            savedClipMetadata: nil,
            assetManifest: []
        )
    }

    public static let maximumEncodedBytes = 256 * 1024

    public static func validateSize(_ record: SavedLibrarySyncRecord) throws {
        let size = try JSONEncoder.syncEncoder.encode(record).count
        guard size <= maximumEncodedBytes else {
            throw SavedLibrarySyncError.recordTooLarge(record.id, size)
        }
    }

    public static func validate(_ record: SavedLibrarySyncRecord) throws {
        guard record.stamp.counter >= 0, record.stamp.counter < Int64.max,
              !record.stamp.deviceID.isEmpty,
              record.stamp.deviceID == record.stamp.deviceID.trimmingCharacters(in: .whitespacesAndNewlines),
              record.stamp.deviceID.lengthOfBytes(using: .utf8) <= LamportStamp.maximumDeviceIDBytes
        else { throw SavedLibrarySyncError.invalidLamportStamp }
        if record.isTombstone {
            guard record.payload == nil, record.savedClipMetadata == nil,
                  record.assetManifest.isEmpty
            else {
                throw SavedLibrarySyncError.invalidRecord(record.id)
            }
        } else {
            guard let payload = record.payload,
                  payload.id == record.id,
                  payload.kind == record.kind
            else { throw SavedLibrarySyncError.invalidRecord(record.id) }
            switch payload {
            case .folder:
                guard record.savedClipMetadata == nil, record.assetManifest.isEmpty else {
                    throw SavedLibrarySyncError.invalidRecord(record.id)
                }
            case .savedClip:
                guard record.savedClipMetadata?.analysisState != .pending else {
                    throw SavedLibrarySyncError.invalidRecord(record.id)
                }
            }
        }
        try validatePayload(record.payload)
        try validateAssetManifest(record.assetManifest, for: record.payload)
        try validateSize(record)
    }

    /// A Lamport stamp identifies one immutable version of an entity. Reusing it for different
    /// content is corruption, not a tie that callers may resolve by advancing their change token.
    static func rejectStampCollision(
        between lhs: SavedLibrarySyncRecord,
        and rhs: SavedLibrarySyncRecord
    ) throws {
        guard lhs.id == rhs.id, lhs.stamp == rhs.stamp, lhs != rhs else { return }
        throw SavedLibrarySyncError.stampCollision(lhs.id)
    }

    private static func validatePayload(_ payload: SavedLibraryPayload?) throws {
        guard let payload else { return }
        switch payload {
        case let .savedClip(clip):
            guard !clip.content.text.isEmpty,
                  !clip.name.isEmpty,
                  clip.name == clip.name.trimmingCharacters(in: .whitespacesAndNewlines)
            else { throw SavedLibrarySyncError.invalidRecord(clip.id) }
        case let .folder(folder):
            guard !folder.name.isEmpty,
                  folder.name == folder.name.trimmingCharacters(in: .whitespacesAndNewlines),
                  folder.sortOrder >= 0
            else { throw SavedLibrarySyncError.invalidRecord(folder.id) }
        }
    }

    private static func validateAssetManifest(
        _ manifest: [SavedLibrarySyncAssetDescriptor],
        for payload: SavedLibraryPayload?
    ) throws {
        guard manifest.count <= SavedLibrarySyncAssetPolicy.maximumAssetsPerClip,
              manifest.reduce(0, { $0 + $1.byteCount })
                <= SavedLibrarySyncAssetPolicy.maximumBytesPerClip,
              Set(manifest).count == manifest.count
        else { throw SavedLibrarySyncError.invalidAssetManifest }
        guard case let .savedClip(clip) = payload else {
            guard manifest.isEmpty else { throw SavedLibrarySyncError.invalidAssetManifest }
            return
        }
        let expected = try SavedLibrarySyncAssetDescriptor.manifest(for: clip)
        guard manifest.sorted(by: SavedLibrarySyncAssetDescriptor.deterministicOrder) == expected
        else { throw SavedLibrarySyncError.invalidAssetManifest }
    }

    /// Orders a complete batch so live parent folders are written before descendants and saved
    /// items. Tombstones remain deterministic and are applied after live corrections.
    public static func dependencyOrdered(
        _ records: some Sequence<SavedLibrarySyncRecord>
    ) -> [SavedLibrarySyncRecord] {
        let values = Array(records)
        var folders: [UUID: ClipFolder] = [:]
        var folderStamps: [UUID: LamportStamp] = [:]
        for record in values {
            guard !record.isTombstone, case let .folder(folder) = record.payload,
                  folderStamps[folder.id].map({ $0 < record.stamp }) ?? true
            else { continue }
            folders[folder.id] = folder
            folderStamps[folder.id] = record.stamp
        }
        func depth(_ folder: ClipFolder) -> Int {
            var seen: Set<UUID> = [folder.id]
            var cursor = folder.parentFolderID
            var result = 0
            while let id = cursor, let parent = folders[id], seen.insert(id).inserted {
                result += 1
                cursor = parent.parentFolderID
            }
            return result
        }
        return values.sorted { lhs, rhs in
            func rank(_ record: SavedLibrarySyncRecord) -> (Int, Int, String) {
                if record.isTombstone { return (3, 0, record.id.uuidString) }
                switch record.payload {
                case let .folder(folder): return (0, depth(folder), record.id.uuidString)
                case .savedClip: return (2, 0, record.id.uuidString)
                case nil: return (3, 0, record.id.uuidString)
                }
            }
            let l = rank(lhs), r = rank(rhs)
            if l.0 != r.0 { return l.0 < r.0 }
            if l.1 != r.1 { return l.1 < r.1 }
            if l.2 != r.2 { return l.2 < r.2 }
            return lhs.stamp < rhs.stamp
        }
    }
}

public enum SyncAccountState: String, Codable, Equatable, Sendable {
    case available
    case noAccount
    case restricted
    case couldNotDetermine
    case temporarilyUnavailable
}

public enum SavedLibrarySyncStatus: Codable, Equatable, Sendable {
    case disabled
    case idle(lastSuccessfulSync: Date?)
    case syncing
    case offline
    case accountUnavailable(SyncAccountState)
    case failed(String)
}

public enum SyncEntityState: Codable, Equatable, Sendable {
    case localOnly(reason: SyncLocalOnlyReason)
    case queued
    case preparingAssets
    case uploadingAssets
    case downloadingAssets
    case uploading
    case synced(at: Date, deviceID: String)
    case conflict(local: LamportStamp, remote: LamportStamp)
    case failed(String)
}

public struct SavedLibrarySyncSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var isEnabled: Bool
    /// Tombstones are retained in this map indefinitely.
    public var records: [UUID: SavedLibrarySyncRecord]
    /// Latest pending version per entity. Never contains clipboard history or vault data.
    public var outbox: [UUID: SavedLibrarySyncRecord]
    public var changeToken: Data?
    public var localLamportCounter: Int64
    public var status: SavedLibrarySyncStatus
    /// Hash/fingerprint of the iCloud account the user last approved for uploads.
    public var confirmedAccountFingerprint: String?
    public var pendingAccountFingerprint: String?
    /// UI-safe per-entity lifecycle metadata. It never contains clip content.
    public var entityStates: [UUID: SyncEntityState]
    /// Content-blind remote GC receipts. Digests remain until the grace period passes and the
    /// transport confirms deletion; a live manifest always cancels its receipt.
    public var assetGarbage: [String: Date]

    public init(
        schemaVersion: Int = currentSchemaVersion,
        isEnabled: Bool = false,
        records: [UUID: SavedLibrarySyncRecord] = [:],
        outbox: [UUID: SavedLibrarySyncRecord] = [:],
        changeToken: Data? = nil,
        localLamportCounter: Int64 = 0,
        status: SavedLibrarySyncStatus = .disabled,
        confirmedAccountFingerprint: String? = nil,
        pendingAccountFingerprint: String? = nil,
        entityStates: [UUID: SyncEntityState] = [:],
        assetGarbage: [String: Date] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.isEnabled = isEnabled
        self.records = records
        self.outbox = outbox
        self.changeToken = changeToken
        self.localLamportCounter = localLamportCounter
        self.status = status
        self.confirmedAccountFingerprint = confirmedAccountFingerprint
        self.pendingAccountFingerprint = pendingAccountFingerprint
        self.entityStates = entityStates
        self.assetGarbage = assetGarbage
    }

    public static let disabled = SavedLibrarySyncSnapshot()

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, isEnabled, records, outbox, changeToken
        case localLamportCounter, status, confirmedAccountFingerprint, pendingAccountFingerprint
        case entityStates
        case assetGarbage
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            schemaVersion: try container.decode(Int.self, forKey: .schemaVersion),
            isEnabled: try container.decode(Bool.self, forKey: .isEnabled),
            records: try container.decode([UUID: SavedLibrarySyncRecord].self, forKey: .records),
            outbox: try container.decode([UUID: SavedLibrarySyncRecord].self, forKey: .outbox),
            changeToken: try container.decodeIfPresent(Data.self, forKey: .changeToken),
            localLamportCounter: try container.decode(Int64.self, forKey: .localLamportCounter),
            status: try container.decode(SavedLibrarySyncStatus.self, forKey: .status),
            confirmedAccountFingerprint: try container.decodeIfPresent(
                String.self,
                forKey: .confirmedAccountFingerprint
            ),
            pendingAccountFingerprint: try container.decodeIfPresent(
                String.self,
                forKey: .pendingAccountFingerprint
            ),
            entityStates: try container.decodeIfPresent(
                [UUID: SyncEntityState].self,
                forKey: .entityStates
            ) ?? [:],
            assetGarbage: try container.decodeIfPresent(
                [String: Date].self,
                forKey: .assetGarbage
            ) ?? [:]
        )
    }
}

public struct SyncAccountIdentity: Equatable, Sendable {
    public let state: SyncAccountState
    public let fingerprint: String?

    public init(state: SyncAccountState, fingerprint: String?) {
        self.state = state
        self.fingerprint = fingerprint
    }
}

public struct SyncFetchBatch: Sendable {
    public let records: [SavedLibrarySyncRecord]
    public let changeToken: Data?

    public init(records: [SavedLibrarySyncRecord], changeToken: Data?) {
        self.records = records
        self.changeToken = changeToken
    }
}

public enum SavedLibrarySyncError: Error, Equatable, LocalizedError, Sendable {
    case disabled
    case offline
    case accountUnavailable(SyncAccountState)
    case accountIdentityUnavailable
    case accountConfirmationNotPending
    case invalidRecord(UUID)
    case invalidLamportStamp
    case stampCollision(UUID)
    case lamportOverflow
    case recordTooLarge(UUID, Int)
    case unsupportedSnapshotVersion(Int)
    case persistenceFailure(String)
    case transportFailure(String)
    case quotaExceeded
    case cloudKitConfigurationRequired
    case ineligible(UUID, SyncLocalOnlyReason)
    case invalidAssetManifest
    case assetTransportUnavailable
    case assetQuotaExceeded
    case assetMissing(String)
    case assetSizeMismatch(String)
    case assetDigestMismatch(String)
    case invalidAssetStagingFile

    public var errorDescription: String? {
        switch self {
        case .disabled: "Saved-library sync is disabled."
        case .offline: "Saved-library sync is offline."
        case let .accountUnavailable(state): "The iCloud account is unavailable (\(state.rawValue))."
        case .accountIdentityUnavailable: "The iCloud account identity could not be verified."
        case .accountConfirmationNotPending: "There is no pending iCloud account change to confirm."
        case let .invalidRecord(id): "Sync record \(id) is invalid."
        case .invalidLamportStamp: "The sync record has an invalid Lamport stamp."
        case let .stampCollision(id):
            "Sync record \(id) reused a Lamport stamp for different content. Sync stopped before advancing."
        case .lamportOverflow: "The sync logical clock is exhausted."
        case let .recordTooLarge(id, size):
            "Sync record \(id) is \(size) bytes; the limit is \(SavedLibrarySyncRecord.maximumEncodedBytes)."
        case let .unsupportedSnapshotVersion(version):
            "Sync snapshot schema version \(version) is unsupported."
        case let .persistenceFailure(reason): "Sync state cannot be persisted: \(reason)"
        case let .transportFailure(reason): "Sync transport failed: \(reason)"
        case .quotaExceeded:
            "iCloud storage is full. Free iCloud space or upgrade your storage, then choose Sync Now. Local changes remain queued."
        case .cloudKitConfigurationRequired:
            "CloudKit sync requires an Apple Developer-signed app and configured iCloud container."
        case let .ineligible(id, reason):
            "Sync entity \(id) remains local-only (\(reason.rawValue))."
        case .invalidAssetManifest: "The saved clip has an invalid sync asset manifest."
        case .assetTransportUnavailable: "Binary saved-clip sync is unavailable in this build."
        case .assetQuotaExceeded: "Saved-clip assets exceed the sync size or staging quota."
        case let .assetMissing(digest): "Saved-clip asset \(digest) is unavailable."
        case let .assetSizeMismatch(digest): "Saved-clip asset \(digest) has an unexpected size."
        case let .assetDigestMismatch(digest): "Saved-clip asset \(digest) failed integrity verification."
        case .invalidAssetStagingFile: "A saved-clip sync staging file is unsafe or invalid."
        }
    }
}

extension JSONEncoder {
    fileprivate static var syncEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }
}
