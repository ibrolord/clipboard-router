import CloudKit
import Foundation

public struct CloudKitSharingConfiguration: Equatable, Sendable {
    public let isFeatureEnabled: Bool
    public let hasCloudKitEntitlement: Bool
    public let containerIdentifier: String?

    public init(
        isFeatureEnabled: Bool = false,
        hasCloudKitEntitlement: Bool = false,
        containerIdentifier: String? = nil
    ) {
        self.isFeatureEnabled = isFeatureEnabled
        self.hasCloudKitEntitlement = hasCloudKitEntitlement
        self.containerIdentifier = containerIdentifier
    }

    public static let disabled = CloudKitSharingConfiguration()
}

public struct SharedFolderShareReceipt: Equatable, Sendable {
    public let folderID: UUID
    public let zoneName: String
    public let shareRecordName: String
    public let url: URL?

    public init(folderID: UUID, zoneName: String, shareRecordName: String, url: URL?) {
        self.folderID = folderID
        self.zoneName = zoneName
        self.shareRecordName = shareRecordName
        self.url = url
    }
}

/// The AppKit layer registers this already-saved share with `NSItemProvider` and presents
/// `NSSharingService(.cloudSharing)`. CloudKit classes are SDK-declared Sendable on macOS 14.
public struct CloudKitSharePresentation: Sendable {
    public let share: CKShare
    public let container: CKContainer

    public init(share: CKShare, container: CKContainer) {
        self.share = share
        self.container = container
    }
}

public protocol SharedFolderSharePresentationProviding: Sendable {
    func sharePresentation(
        for location: SharedFolderRemoteLocation
    ) async throws -> CloudKitSharePresentation
}

/// Zone-wide CloudKit collaboration transport. Owners access a shared zone through the private
/// database; accepted participants access the same logical zone through the shared database.
/// No CKContainer is constructed unless both the feature and signed entitlement are present.
public actor CloudKitSharedFolderAdapter:
    SharedFolderTransport,
    SharedFolderSharePresentationProviding
{
    public static let rootRecordType = "ClipboardRouterSharedFolderRootV2"
    public static let entityRecordType = "ClipboardRouterSharedEntityV2"
    public static let rootRecordName = "shared-folder-root-v2"

    private static let folderIDKey = "folderID"
    private static let ownerParticipantIDKey = "ownerParticipantID"
    private static let titleKey = "title"
    private static let payloadKey = "payload"
    private static let stampCounterKey = "stampCounter"
    private static let stampDeviceKey = "stampDevice"

    private let configuration: CloudKitSharingConfiguration
    private let container: CKContainer?
    private let privateDatabase: CKDatabase?
    private let sharedDatabase: CKDatabase?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var readyPrivateZoneIDs: Set<CKRecordZone.ID> = []
    private var lastParticipantID: String?
    private struct ZoneCache {
        var token: CKServerChangeToken?
        var records: [UUID: SharedFolderRecord]
        var authorizations: [UUID: SharedFolderRecordAuthorization]
    }
    private var zoneCaches: [String: ZoneCache] = [:]

    public init(configuration: CloudKitSharingConfiguration = .disabled) {
        self.configuration = configuration
        if configuration.isFeatureEnabled, configuration.hasCloudKitEntitlement {
            let container = configuration.containerIdentifier.map(CKContainer.init(identifier:))
                ?? CKContainer.default()
            self.container = container
            self.privateDatabase = container.privateCloudDatabase
            self.sharedDatabase = container.sharedCloudDatabase
        } else {
            self.container = nil
            self.privateDatabase = nil
            self.sharedDatabase = nil
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        self.decoder = decoder
    }

    public func capability() async -> SharedCloudCapability {
        guard configuration.isFeatureEnabled else {
            return .unavailable(.featureDisabled)
        }
        guard configuration.hasCloudKitEntitlement, let container else {
            return .unavailable(.configurationMissing)
        }
        do {
            return Self.capability(for: try await container.accountStatus())
        } catch {
            return .unavailable(.couldNotDetermine)
        }
    }

    public func currentParticipantID() async throws -> String {
        let (container, _, _) = try await requireAvailableCloudKit()
        do {
            let participantID = try await container.userRecordID().recordName
            if let lastParticipantID, lastParticipantID != participantID {
                readyPrivateZoneIDs.removeAll()
                zoneCaches.removeAll()
            }
            lastParticipantID = participantID
            return participantID
        } catch {
            throw Self.mapCloudError(error)
        }
    }

    /// Creates or reopens one zone-wide share. Zone-wide sharing is intentional: folder clips are
    /// an unbounded collection and therefore must not rely on an incomplete parent hierarchy.
    public func createShare(
        for scope: SharedFolderScope,
        title: String
    ) async throws -> SharedFolderTransportSnapshot {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else {
            throw SharedFolderError.cloudFailure("Share title cannot be empty")
        }
        let currentID = try await currentParticipantID()
        guard currentID == scope.ownerParticipantID else {
            throw SharedFolderError.permissionDenied
        }
        let (_, database, _) = try await requireAvailableCloudKit()
        let zoneID = CKRecordZone.ID(
            zoneName: scope.zoneName,
            ownerName: CKCurrentUserDefaultName
        )
        try await ensurePrivateZone(zoneID, database: database)

        let rootID = CKRecord.ID(recordName: Self.rootRecordName, zoneID: zoneID)
        let root = (try await fetchRecordIfPresent(id: rootID, database: database))
            ?? CKRecord(recordType: Self.rootRecordType, recordID: rootID)
        root[Self.folderIDKey] = scope.folderID.uuidString.lowercased() as CKRecordValue
        root[Self.ownerParticipantIDKey] = currentID as CKRecordValue
        root[Self.titleKey] = cleanTitle as CKRecordValue

        let share: CKShare
        if let existing = try await fetchZoneShare(zoneID: zoneID, database: database) {
            share = existing
        } else {
            share = CKShare(recordZoneID: zoneID)
        }
        share[CKShare.SystemFieldKey.title] = cleanTitle as CKRecordValue

        do {
            let response = try await database.modifyRecords(
                saving: [root, share],
                deleting: [],
                savePolicy: .ifServerRecordUnchanged,
                atomically: true
            )
            guard let rootResult = response.saveResults[rootID] else {
                throw SharedFolderError.cloudFailure("CloudKit returned no folder-root save result")
            }
            _ = try rootResult.get()
            guard let shareResult = response.saveResults[share.recordID] else {
                throw SharedFolderError.cloudFailure("CloudKit returned no share save result")
            }
            guard let savedShare = try shareResult.get() as? CKShare else {
                throw SharedFolderError.cloudFailure("CloudKit returned an invalid share record")
            }
            let location = try location(
                folderID: scope.folderID,
                ownerParticipantID: currentID,
                title: cleanTitle,
                share: savedShare,
                databaseScope: .ownerPrivate
            )
            return try await fetchSnapshot(at: location, database: database)
        } catch let error as SharedFolderError {
            throw error
        } catch {
            throw Self.mapCloudError(error)
        }
    }

    public func synchronize(
        _ records: [SharedFolderRecord],
        at location: SharedFolderRemoteLocation
    ) async throws -> SharedFolderTransportSnapshot {
        let (_, privateDatabase, sharedDatabase) = try await requireAvailableCloudKit()
        let database = location.databaseScope == .ownerPrivate ? privateDatabase : sharedDatabase
        let currentID = try await currentParticipantID()
        let share = try await fetchShare(at: location, database: database)
        let participants = try cloudParticipants(from: share)
        guard let current = participants.first(where: { $0.id == currentID }) else {
            throw SharedFolderError.unknownParticipant(currentID)
        }

        for record in records.sorted(by: Self.recordOrder) {
            guard record.scopeFolderID == location.folderID,
                  record.authorParticipantID == currentID
            else {
                throw SharedFolderError.permissionDenied
            }
            switch record.kind {
            case .rootFolder where current.role != .owner:
                throw SharedFolderError.permissionDenied
            case .folder where !current.role.canEditClips:
                throw SharedFolderError.permissionDenied
            case .savedClip where !current.role.canEditClips:
                throw SharedFolderError.permissionDenied
            case .automationDefinition where current.role != .owner:
                throw SharedFolderError.permissionDenied
            default:
                break
            }
            try await push(record, at: location, database: database)
        }
        return try await fetchSnapshot(at: location, database: database)
    }

    /// Accepts metadata delivered by the macOS app delegate. The invitation is validated as a
    /// zone-wide Clipboard Router v2 share before any remote records are materialized.
    public func acceptShare(
        _ metadata: CKShare.Metadata
    ) async throws -> SharedFolderTransportSnapshot {
        let (container, _, sharedDatabase) = try await requireAvailableCloudKit()
        if let configured = configuration.containerIdentifier,
           metadata.containerIdentifier != configured
        {
            throw SharedFolderError.cloudFailure(
                "The invitation belongs to a different CloudKit container"
            )
        }
        let shareZoneID = metadata.share.recordID.zoneID
        guard metadata.share.recordID.recordName == CKRecordNameZoneWideShare,
              let folderID = Self.folderID(fromV2ZoneName: shareZoneID.zoneName),
              let ownerParticipantID = metadata.ownerIdentity.userRecordID?.recordName
        else {
            throw SharedFolderError.cloudFailure(
                "The invitation is not a zone-wide Clipboard Router v2 folder share"
            )
        }

        do {
            let acceptedShare: CKShare
            if metadata.participantStatus == .pending {
                let response = try await container.accept([metadata])
                guard let result = response[metadata] else {
                    throw SharedFolderError.cloudFailure(
                        "CloudKit returned no share acceptance result"
                    )
                }
                acceptedShare = try result.get()
            } else {
                acceptedShare = metadata.share
            }
            let title = (acceptedShare[CKShare.SystemFieldKey.title] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let location = try location(
                folderID: folderID,
                ownerParticipantID: ownerParticipantID,
                title: title?.isEmpty == false ? title! : "Shared Folder",
                share: acceptedShare,
                databaseScope: .participantShared
            )
            // Fetching and validating the app-owned root is the provenance gate. Zone naming
            // alone is never treated as proof that the share contains Clipboard Router data.
            return try await fetchSnapshot(at: location, database: sharedDatabase)
        } catch let error as SharedFolderError {
            throw error
        } catch {
            throw Self.mapCloudError(error)
        }
    }

    public func sharePresentation(
        for location: SharedFolderRemoteLocation
    ) async throws -> CloudKitSharePresentation {
        let (container, privateDatabase, sharedDatabase) = try await requireAvailableCloudKit()
        let database = location.databaseScope == .ownerPrivate ? privateDatabase : sharedDatabase
        let share = try await fetchShare(at: location, database: database)
        return CloudKitSharePresentation(share: share, container: container)
    }

    public static func folderID(fromV2ZoneName zoneName: String) -> UUID? {
        guard zoneName.hasPrefix(SharedFolderScope.v2ZonePrefix) else { return nil }
        return UUID(uuidString: String(zoneName.dropFirst(SharedFolderScope.v2ZonePrefix.count)))
    }

    private func fetchSnapshot(
        at location: SharedFolderRemoteLocation,
        database: CKDatabase,
        mayRetryExpiredToken: Bool = true
    ) async throws -> SharedFolderTransportSnapshot {
        let zoneID = CKRecordZone.ID(
            zoneName: location.zoneName,
            ownerName: location.ownerName
        )
        let rootID = CKRecord.ID(recordName: Self.rootRecordName, zoneID: zoneID)
        guard let root = try await fetchRecordIfPresent(id: rootID, database: database) else {
            throw SharedFolderError.cloudFailure("The shared folder root is missing")
        }
        try Self.validateRoot(root, location: location)

        let share = try await fetchShare(at: location, database: database)
        let participants = try cloudParticipants(from: share)
        let currentID = try await currentParticipantID()
        let cacheKey = Self.cacheKey(for: location)
        var cache = zoneCaches[cacheKey] ?? ZoneCache(
            token: nil,
            records: [:],
            authorizations: [:]
        )
        var moreComing = true
        do {
            while moreComing {
                let page = try await database.recordZoneChanges(
                    inZoneWith: zoneID,
                    since: cache.token,
                    desiredKeys: nil,
                    resultsLimit: nil
                )
                for result in page.modificationResultsByID.values {
                    let cloudRecord = try result.get().record
                    guard cloudRecord.recordType == Self.entityRecordType else { continue }
                    let authenticated = try decode(cloudRecord, location: location)
                    cache.records[authenticated.record.id] = authenticated.record
                    cache.authorizations[authenticated.record.id] = authenticated.authorization
                }
                cache.token = page.changeToken
                moreComing = page.moreComing
            }
        } catch let cloudError as CKError
            where cloudError.code == .changeTokenExpired && mayRetryExpiredToken
        {
            zoneCaches.removeValue(forKey: cacheKey)
            return try await fetchSnapshot(
                at: location,
                database: database,
                mayRetryExpiredToken: false
            )
        }
        let snapshot = try SharedFolderTransportSnapshot(
            location: location,
            currentParticipantID: currentID,
            participants: participants,
            records: Array(cache.records.values),
            recordAuthorizations: Array(cache.authorizations.values)
        )
        // Advance the in-memory cursor only after the complete batch passes every authorization,
        // scope, participant, and record validation performed by the snapshot initializer.
        zoneCaches[cacheKey] = cache
        return snapshot
    }

    private static func cacheKey(for location: SharedFolderRemoteLocation) -> String {
        [
            location.databaseScope.rawValue,
            location.ownerName,
            location.zoneName,
            location.folderID.uuidString.lowercased(),
        ].joined(separator: "|")
    }

    private func push(
        _ candidate: SharedFolderRecord,
        at location: SharedFolderRemoteLocation,
        database: CKDatabase,
        remainingAttempts: Int = 3
    ) async throws {
        let zoneID = CKRecordZone.ID(
            zoneName: location.zoneName,
            ownerName: location.ownerName
        )
        let recordID = CKRecord.ID(
            recordName: candidate.id.uuidString.lowercased(),
            zoneID: zoneID
        )
        let existing = try await fetchRecordIfPresent(id: recordID, database: database)
        if let existing {
            let remote = try decode(existing, location: location).record
            guard candidate.stamp > remote.stamp else { return }
        }

        let cloudRecord = existing ?? CKRecord(recordType: Self.entityRecordType, recordID: recordID)
        cloudRecord[Self.payloadKey] = try encoder.encode(candidate) as CKRecordValue
        cloudRecord[Self.stampCounterKey] = NSNumber(value: candidate.stamp.counter)
        cloudRecord[Self.stampDeviceKey] = candidate.stamp.deviceID as CKRecordValue
        let response = try await database.modifyRecords(
            saving: [cloudRecord],
            deleting: [],
            savePolicy: .ifServerRecordUnchanged,
            atomically: true
        )
        guard let result = response.saveResults[recordID] else {
            throw SharedFolderError.cloudFailure("CloudKit returned no shared-record save result")
        }
        do {
            _ = try result.get()
        } catch let cloudError as CKError
            where cloudError.code == .serverRecordChanged && remainingAttempts > 1
        {
            try await push(
                candidate,
                at: location,
                database: database,
                remainingAttempts: remainingAttempts - 1
            )
        }
    }

    private func decode(
        _ cloudRecord: CKRecord,
        location: SharedFolderRemoteLocation
    ) throws -> (
        record: SharedFolderRecord,
        authorization: SharedFolderRecordAuthorization
    ) {
        guard cloudRecord.recordType == Self.entityRecordType,
              cloudRecord.recordID.zoneID.zoneName == location.zoneName,
              cloudRecord.recordID.zoneID.ownerName == location.ownerName,
              let data = cloudRecord[Self.payloadKey] as? Data
        else {
            throw SharedFolderError.cloudFailure("A shared record has an invalid CloudKit identity")
        }
        let record = try decoder.decode(SharedFolderRecord.self, from: data)
        guard cloudRecord.recordID.recordName == record.id.uuidString.lowercased(),
              record.scopeFolderID == location.folderID,
              cloudRecord.lastModifiedUserRecordID?.recordName == record.authorParticipantID
        else {
            throw SharedFolderError.cloudFailure(
                "A shared record's author cannot be authenticated by CloudKit"
            )
        }
        let roleAtWrite: SharedFolderRole
        switch record.kind {
        case .rootFolder:
            guard record.authorParticipantID == location.ownerParticipantID else {
                throw SharedFolderError.permissionDenied
            }
            roleAtWrite = .owner
        case .automationDefinition:
            guard record.authorParticipantID == location.ownerParticipantID else {
                throw SharedFolderError.permissionDenied
            }
            roleAtWrite = .owner
        case .folder:
            roleAtWrite = record.authorParticipantID == location.ownerParticipantID
                ? .owner
                : .editor
        case .savedClip:
            // CloudKit authenticates the last modifier and enforces CKShare permission when the
            // write occurs. Preserve that accepted historical fact instead of re-checking the
            // author's possibly downgraded or removed membership from today's CKShare.
            roleAtWrite = record.authorParticipantID == location.ownerParticipantID
                ? .owner
                : .editor
        }
        return (
            record,
            try SharedFolderRecordAuthorization(
                recordID: record.id,
                authorParticipantID: record.authorParticipantID,
                roleAtWrite: roleAtWrite
            )
        )
    }

    private static func validateRoot(
        _ root: CKRecord,
        location: SharedFolderRemoteLocation
    ) throws {
        guard root.recordType == Self.rootRecordType,
              root.recordID.recordName == Self.rootRecordName,
              root.recordID.zoneID.zoneName == location.zoneName,
              root.recordID.zoneID.ownerName == location.ownerName,
              root[Self.folderIDKey] as? String == location.folderID.uuidString.lowercased(),
              root[Self.ownerParticipantIDKey] as? String == location.ownerParticipantID
        else {
            throw SharedFolderError.cloudFailure(
                "The invitation does not contain a valid Clipboard Router folder root"
            )
        }
    }

    private func fetchShare(
        at location: SharedFolderRemoteLocation,
        database: CKDatabase
    ) async throws -> CKShare {
        let zoneID = CKRecordZone.ID(
            zoneName: location.zoneName,
            ownerName: location.ownerName
        )
        let shareID = CKRecord.ID(recordName: location.shareRecordName, zoneID: zoneID)
        guard let record = try await fetchRecordIfPresent(id: shareID, database: database),
              let share = record as? CKShare,
              share.recordID.recordName == CKRecordNameZoneWideShare
        else {
            throw SharedFolderError.cloudFailure("The shared folder's CKShare is missing")
        }
        return share
    }

    private func fetchZoneShare(
        zoneID: CKRecordZone.ID,
        database: CKDatabase
    ) async throws -> CKShare? {
        let response = try await database.recordZones(for: [zoneID])
        guard let result = response[zoneID] else { return nil }
        do {
            let zone = try result.get()
            guard let shareID = zone.share?.recordID else { return nil }
            return try await fetchRecordIfPresent(id: shareID, database: database) as? CKShare
        } catch let cloudError as CKError where cloudError.code == .zoneNotFound {
            return nil
        }
    }

    private func fetchRecordIfPresent(
        id: CKRecord.ID,
        database: CKDatabase
    ) async throws -> CKRecord? {
        let response = try await database.records(for: [id], desiredKeys: nil)
        guard let result = response[id] else { return nil }
        do {
            return try result.get()
        } catch let cloudError as CKError where cloudError.code == .unknownItem {
            return nil
        }
    }

    private func cloudParticipants(
        from share: CKShare
    ) throws -> [SharedFolderCloudParticipant] {
        try share.participants.map { participant in
            guard let id = participant.userIdentity.userRecordID?.recordName else {
                throw SharedFolderError.invalidParticipants
            }
            let role: SharedFolderRole
            if participant.role == .owner {
                role = .owner
            } else {
                role = participant.permission == .readWrite ? .editor : .viewer
            }
            let displayName = participant.userIdentity.nameComponents.map {
                PersonNameComponentsFormatter.localizedString(
                    from: $0,
                    style: .default,
                    options: []
                )
            } ?? (role == .owner ? "Owner" : "Participant")
            return try SharedFolderCloudParticipant(
                id: id,
                displayName: displayName,
                role: role,
                acceptance: Self.acceptance(participant.acceptanceStatus)
            )
        }
    }

    private func location(
        folderID: UUID,
        ownerParticipantID: String,
        title: String,
        share: CKShare,
        databaseScope: SharedFolderDatabaseScope
    ) throws -> SharedFolderRemoteLocation {
        let zoneID = share.recordID.zoneID
        guard share.recordID.recordName == CKRecordNameZoneWideShare,
              zoneID.zoneName == SharedFolderScope.v2ZonePrefix + folderID.uuidString.lowercased()
        else {
            throw SharedFolderError.cloudFailure("CloudKit returned an invalid zone-wide share")
        }
        return SharedFolderRemoteLocation(
            folderID: folderID,
            zoneName: zoneID.zoneName,
            ownerName: zoneID.ownerName,
            ownerParticipantID: ownerParticipantID,
            shareRecordName: share.recordID.recordName,
            databaseScope: databaseScope,
            title: title
        )
    }

    private func requireAvailableCloudKit() async throws -> (CKContainer, CKDatabase, CKDatabase) {
        switch await capability() {
        case .available:
            guard let container, let privateDatabase, let sharedDatabase else {
                throw SharedFolderError.cloudCapabilityUnavailable(.configurationMissing)
            }
            return (container, privateDatabase, sharedDatabase)
        case let .unavailable(issue):
            throw SharedFolderError.cloudCapabilityUnavailable(issue)
        }
    }

    private func ensurePrivateZone(_ zoneID: CKRecordZone.ID, database: CKDatabase) async throws {
        guard !readyPrivateZoneIDs.contains(zoneID) else { return }
        do {
            let response = try await database.modifyRecordZones(
                saving: [CKRecordZone(zoneID: zoneID)],
                deleting: []
            )
            guard let result = response.saveResults[zoneID] else {
                throw SharedFolderError.cloudFailure("CloudKit returned no zone save result")
            }
            _ = try result.get()
            readyPrivateZoneIDs.insert(zoneID)
        } catch let error as SharedFolderError {
            throw error
        } catch {
            throw Self.mapCloudError(error)
        }
    }

    private static func capability(for status: CKAccountStatus) -> SharedCloudCapability {
        switch status {
        case .available: .available
        case .noAccount: .unavailable(.noICloudAccount)
        case .restricted: .unavailable(.restrictedAccount)
        case .temporarilyUnavailable: .unavailable(.temporarilyUnavailable)
        case .couldNotDetermine: .unavailable(.couldNotDetermine)
        @unknown default: .unavailable(.couldNotDetermine)
        }
    }

    private static func acceptance(
        _ status: CKShare.ParticipantAcceptanceStatus
    ) -> SharedFolderParticipantAcceptance {
        switch status {
        case .unknown: .unknown
        case .pending: .pending
        case .accepted: .accepted
        case .removed: .removed
        @unknown default: .unknown
        }
    }

    private static func recordOrder(
        _ lhs: SharedFolderRecord,
        _ rhs: SharedFolderRecord
    ) -> Bool {
        lhs.id.uuidString == rhs.id.uuidString
            ? lhs.stamp < rhs.stamp
            : lhs.id.uuidString < rhs.id.uuidString
    }

    private static func mapCloudError(_ error: any Error) -> SharedFolderError {
        if let sharedError = error as? SharedFolderError { return sharedError }
        guard let cloudError = error as? CKError else {
            return .cloudFailure(String(describing: error))
        }
        switch cloudError.code {
        case .notAuthenticated:
            return .cloudCapabilityUnavailable(.noICloudAccount)
        case .permissionFailure, .badContainer, .missingEntitlement:
            return .cloudCapabilityUnavailable(.configurationMissing)
        case .networkFailure, .networkUnavailable, .serviceUnavailable, .requestRateLimited:
            return .cloudCapabilityUnavailable(.temporarilyUnavailable)
        default:
            return .cloudFailure(cloudError.localizedDescription)
        }
    }
}
