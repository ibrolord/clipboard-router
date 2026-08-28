import CloudKit
import CryptoKit
import Foundation

/// Private-database CloudKit transport. Tombstones are records, not CK deletions, so deletion
/// knowledge is retained indefinitely. Live use requires an Apple Developer-signed build whose
/// iCloud entitlement contains the configured container.
public actor CloudKitSavedLibraryTransport: SavedLibrarySyncTransport {
    /// Kept only as migration/documentation markers. This client never reads or writes them.
    public static let legacyV1RecordType = "ClipboardRouterSavedEntity"
    public static let legacyV1ZoneName = "ClipboardRouterSavedLibraryZone"
    /// Typed ClipContent records live in an isolated schema so v1 clients never decode them.
    public static let recordType = "ClipboardRouterSavedEntityV2"
    public static let zoneName = "ClipboardRouterSavedLibraryZoneV2"
    public static let assetRecordType = "ClipboardRouterSavedAssetV2"

    private static let payloadKey = "payload"
    private static let stampCounterKey = "stampCounter"
    private static let stampDeviceKey = "stampDevice"
    private static let assetDigestKey = "digest"
    private static let assetByteCountKey = "byteCount"
    private static let assetBlobKey = "blob"

    public let containerIdentifier: String?
    private let container: CKContainer
    private let database: CKDatabase
    private let zoneID: CKRecordZone.ID
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var zoneIsReady = false
    private var lastAccountFingerprint: String?

    /// Pass `nil` only when the app's default CKContainer is configured by its entitlements.
    public init(containerIdentifier: String?) {
        self.containerIdentifier = containerIdentifier
        let container = containerIdentifier.map(CKContainer.init(identifier:)) ?? CKContainer.default()
        self.container = container
        self.database = container.privateCloudDatabase
        self.zoneID = CKRecordZone.ID(zoneName: Self.zoneName, ownerName: CKCurrentUserDefaultName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        self.decoder = decoder
    }

    public func accountIdentity() async throws -> SyncAccountIdentity {
        do {
            let status = try await withCloudKitRetryAfter {
                try await container.accountStatus()
            }
            switch status {
            case .available:
                let recordID = try await withCloudKitRetryAfter {
                    try await container.userRecordID()
                }
                let fingerprint = SHA256.hash(data: Data(recordID.recordName.utf8))
                    .map { String(format: "%02x", $0) }
                    .joined()
                if lastAccountFingerprint != fingerprint { zoneIsReady = false }
                lastAccountFingerprint = fingerprint
                return SyncAccountIdentity(state: .available, fingerprint: fingerprint)
            case .noAccount:
                zoneIsReady = false
                lastAccountFingerprint = nil
                return SyncAccountIdentity(state: .noAccount, fingerprint: nil)
            case .restricted:
                zoneIsReady = false
                return SyncAccountIdentity(state: .restricted, fingerprint: nil)
            case .couldNotDetermine:
                return SyncAccountIdentity(state: .couldNotDetermine, fingerprint: nil)
            case .temporarilyUnavailable:
                return SyncAccountIdentity(state: .temporarilyUnavailable, fingerprint: nil)
            @unknown default:
                return SyncAccountIdentity(state: .couldNotDetermine, fingerprint: nil)
            }
        } catch {
            throw Self.mapError(error)
        }
    }

    public func fetchChanges(after tokenData: Data?) async throws -> SyncFetchBatch {
        do {
            try await ensureZone()
            // Persisted tokens are opaque cache cursors, not durable user data. If an archive is
            // corrupt or from an incompatible runtime, nil requests a safe full-zone refetch.
            var token = Self.decodeServerToken(tokenData)
            var decoded: [SavedLibrarySyncRecord] = []
            var moreComing: Bool
            repeat {
                let page = try await withCloudKitRetryAfter { () async throws -> (
                    records: [SavedLibrarySyncRecord],
                    changeToken: CKServerChangeToken,
                    moreComing: Bool
                ) in
                    let response = try await database.recordZoneChanges(
                        inZoneWith: zoneID,
                        since: token,
                        desiredKeys: [
                            Self.payloadKey,
                            Self.stampCounterKey,
                            Self.stampDeviceKey,
                            Self.assetDigestKey,
                            Self.assetByteCountKey,
                        ],
                        resultsLimit: nil
                    )
                    var records: [SavedLibrarySyncRecord] = []
                    for result in response.modificationResultsByID.values {
                        let record = try result.get().record
                        if record.recordType == Self.assetRecordType {
                            try Self.validateAssetChangeIdentity(
                                record,
                                expectedZoneID: zoneID
                            )
                            continue
                        }
                        records.append(try decode(record))
                    }
                    return (records, response.changeToken, response.moreComing)
                }
                decoded.append(contentsOf: page.records)
                // Clipboard Router never deletes CKRecords. A user deletion is a tombstone payload.
                // If the zone is externally modified, advancing the server token is still correct;
                // no unauthenticated payload is synthesized from a bare CK deletion.
                token = page.changeToken
                moreComing = page.moreComing
            } while moreComing
            return SyncFetchBatch(
                records: decoded,
                changeToken: try token.map(Self.encodeServerToken)
            )
        } catch let cloudError as CKError where cloudError.code == .changeTokenExpired && tokenData != nil {
            return try await fetchChanges(after: nil)
        } catch {
            throw Self.mapError(error)
        }
    }

    public func push(_ records: [SavedLibrarySyncRecord]) async throws {
        guard !records.isEmpty else { return }
        do {
            try await ensureZone()
            for record in SavedLibrarySyncRecord.dependencyOrdered(records) {
                try await push(record, remainingAttempts: 3)
            }
        } catch {
            throw Self.mapError(error)
        }
    }

    public func pushAssets(_ uploads: [SavedLibrarySyncAssetUpload]) async throws -> Set<String> {
        guard !uploads.isEmpty else { return [] }
        do {
            try await ensureZone()
            var accepted: Set<String> = []
            let byDigest = Dictionary(grouping: uploads, by: { $0.descriptor.digest })
            for digest in byDigest.keys.sorted() {
                guard let upload = byDigest[digest]?.first else { continue }
                let values = try upload.fileURL.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
                )
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                      values.fileSize == upload.descriptor.byteCount
                else { throw SavedLibrarySyncError.invalidAssetStagingFile }
                let localData = try Data(contentsOf: upload.fileURL, options: [.mappedIfSafe])
                try FileSavedLibrarySyncAssetStager.validate(localData, against: upload.descriptor)
                let recordID = assetRecordID(digest: digest)
                if let existing = try await fetchRecordIfPresent(id: recordID) {
                    try validateAssetRecord(existing, descriptor: upload.descriptor)
                    accepted.insert(digest)
                    continue
                }
                let record = CKRecord(recordType: Self.assetRecordType, recordID: recordID)
                record[Self.assetDigestKey] = digest as CKRecordValue
                record[Self.assetByteCountKey] = NSNumber(value: upload.descriptor.byteCount)
                record[Self.assetBlobKey] = CKAsset(fileURL: upload.fileURL)
                let response = try await withCloudKitRetryAfter {
                    try await database.modifyRecords(
                        saving: [record],
                        deleting: [],
                        savePolicy: .ifServerRecordUnchanged,
                        atomically: true
                    )
                }
                guard let result = response.saveResults[recordID] else {
                    throw SavedLibrarySyncError.transportFailure(
                        "CloudKit returned no asset save result"
                    )
                }
                do {
                    let saved = try result.get()
                    try validateAssetRecord(saved, descriptor: upload.descriptor)
                    accepted.insert(digest)
                } catch let error as CKError where error.code == .serverRecordChanged {
                    guard let existing = try await fetchRecordIfPresent(id: recordID) else {
                        throw error
                    }
                    try validateAssetRecord(existing, descriptor: upload.descriptor)
                    accepted.insert(digest)
                }
            }
            return accepted
        } catch {
            throw Self.mapError(error)
        }
    }

    public func fetchAssets(
        _ descriptors: [SavedLibrarySyncAssetDescriptor]
    ) async throws -> [SavedLibrarySyncAssetDownload] {
        guard !descriptors.isEmpty else { return [] }
        do {
            try await ensureZone()
            let byDigest = Dictionary(grouping: descriptors, by: \.digest)
            var dataByDigest: [String: Data] = [:]
            let ids = byDigest.keys.sorted().map { assetRecordID(digest: $0) }
            let response = try await withCloudKitRetryAfter {
                try await database.records(for: ids, desiredKeys: [
                    Self.assetDigestKey,
                    Self.assetByteCountKey,
                    Self.assetBlobKey,
                ])
            }
            for id in ids {
                guard let result = response[id] else {
                    throw SavedLibrarySyncError.assetMissing(id.recordName)
                }
                let record: CKRecord
                do { record = try result.get() }
                catch let error as CKError where error.code == .unknownItem {
                    throw SavedLibrarySyncError.assetMissing(id.recordName)
                }
                guard let descriptor = byDigest[id.recordName]?.first else {
                    throw SavedLibrarySyncError.invalidAssetManifest
                }
                try validateAssetRecord(record, descriptor: descriptor)
                guard let asset = record[Self.assetBlobKey] as? CKAsset,
                      let fileURL = asset.fileURL
                else { throw SavedLibrarySyncError.assetMissing(descriptor.digest) }
                let values = try fileURL.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
                )
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                      values.fileSize == descriptor.byteCount,
                      descriptor.byteCount <= SavedLibrarySyncAssetPolicy.maximumAssetBytes
                else { throw SavedLibrarySyncError.assetSizeMismatch(descriptor.digest) }
                let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
                try FileSavedLibrarySyncAssetStager.validate(data, against: descriptor)
                dataByDigest[descriptor.digest] = data
            }
            return try descriptors.map { descriptor in
                guard let data = dataByDigest[descriptor.digest] else {
                    throw SavedLibrarySyncError.assetMissing(descriptor.digest)
                }
                return SavedLibrarySyncAssetDownload(descriptor: descriptor, data: data)
            }
        } catch {
            throw Self.mapError(error)
        }
    }

    public func garbageCollectAssets(digests: Set<String>) async throws {
        guard digests.isEmpty else { throw SavedLibrarySyncError.assetTransportUnavailable }
    }

    private func push(
        _ candidate: SavedLibrarySyncRecord,
        remainingAttempts: Int
    ) async throws {
        try SavedLibrarySyncRecord.validateSize(candidate)
        let recordID = CKRecord.ID(
            recordName: candidate.id.uuidString.lowercased(),
            zoneID: zoneID
        )
        let existing = try await fetchRecordIfPresent(id: recordID)
        if let existing {
            let remote = try decode(existing)
            try SavedLibrarySyncRecord.rejectStampCollision(between: remote, and: candidate)
            guard candidate.stamp > remote.stamp else { return }
        }

        let cloudRecord = existing ?? CKRecord(recordType: Self.recordType, recordID: recordID)
        cloudRecord[Self.payloadKey] = try encoder.encode(candidate) as CKRecordValue
        cloudRecord[Self.stampCounterKey] = NSNumber(value: candidate.stamp.counter)
        cloudRecord[Self.stampDeviceKey] = candidate.stamp.deviceID as CKRecordValue

        do {
            try await withCloudKitRetryAfter {
                let response = try await database.modifyRecords(
                    saving: [cloudRecord],
                    deleting: [],
                    savePolicy: .ifServerRecordUnchanged,
                    atomically: true
                )
                guard let result = response.saveResults[recordID] else {
                    throw SavedLibrarySyncError.transportFailure("CloudKit returned no save result")
                }
                _ = try result.get()
            }
        } catch let cloudError as CKError
            where cloudError.code == .serverRecordChanged && remainingAttempts > 1
        {
            try await push(candidate, remainingAttempts: remainingAttempts - 1)
        }
    }

    private func fetchRecordIfPresent(id: CKRecord.ID) async throws -> CKRecord? {
        do {
            return try await withCloudKitRetryAfter {
                let response = try await database.records(for: [id], desiredKeys: nil)
                guard let result = response[id] else { return nil }
                return try result.get()
            }
        } catch let cloudError as CKError where cloudError.code == .unknownItem {
            return nil
        }
    }

    private func assetRecordID(digest: String) -> CKRecord.ID {
        CKRecord.ID(recordName: digest, zoneID: zoneID)
    }

    private func validateAssetRecord(
        _ record: CKRecord,
        descriptor: SavedLibrarySyncAssetDescriptor
    ) throws {
        guard record.recordType == Self.assetRecordType,
              record.recordID.zoneID == zoneID,
              record.recordID.recordName == descriptor.digest,
              record[Self.assetDigestKey] as? String == descriptor.digest,
              (record[Self.assetByteCountKey] as? NSNumber)?.intValue == descriptor.byteCount
        else { throw SavedLibrarySyncError.invalidAssetManifest }
        guard let asset = record[Self.assetBlobKey] as? CKAsset,
              let fileURL = asset.fileURL
        else { throw SavedLibrarySyncError.assetMissing(descriptor.digest) }
        let values = try fileURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              values.fileSize == descriptor.byteCount
        else { throw SavedLibrarySyncError.assetSizeMismatch(descriptor.digest) }
        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        try FileSavedLibrarySyncAssetStager.validate(data, against: descriptor)
    }

    static func validateAssetChangeIdentity(
        _ record: CKRecord,
        expectedZoneID: CKRecordZone.ID
    ) throws {
        let digest = record.recordID.recordName.lowercased()
        guard record.recordID.zoneID == expectedZoneID,
              digest.count == 64,
              digest.allSatisfy(\.isHexDigit),
              record[Self.assetDigestKey] as? String == digest,
              let size = (record[Self.assetByteCountKey] as? NSNumber)?.intValue,
              size > 0,
              size <= SavedLibrarySyncAssetPolicy.maximumAssetBytes
        else { throw SavedLibrarySyncError.invalidAssetManifest }
    }

    private func decode(_ cloudRecord: CKRecord) throws -> SavedLibrarySyncRecord {
        guard let data = cloudRecord[Self.payloadKey] as? Data else {
            throw SavedLibrarySyncError.transportFailure("CloudKit record has no payload")
        }
        let record = try decoder.decode(SavedLibrarySyncRecord.self, from: data)
        try Self.validateCloudIdentity(
            recordType: cloudRecord.recordType,
            recordID: cloudRecord.recordID,
            expectedZoneID: zoneID,
            decodedRecord: record
        )
        try SavedLibrarySyncRecord.validate(record)
        return record
    }

    static func validateCloudIdentity(
        recordType: CKRecord.RecordType,
        recordID: CKRecord.ID,
        expectedZoneID: CKRecordZone.ID,
        decodedRecord: SavedLibrarySyncRecord
    ) throws {
        guard recordType == Self.recordType,
              recordID.zoneID == expectedZoneID,
              recordID.recordName == decodedRecord.id.uuidString.lowercased()
        else { throw SavedLibrarySyncError.invalidRecord(decodedRecord.id) }
    }

    private func ensureZone() async throws {
        guard !zoneIsReady else { return }
        let zone = CKRecordZone(zoneID: zoneID)
        try await withCloudKitRetryAfter {
            let response = try await database.modifyRecordZones(saving: [zone], deleting: [])
            guard let result = response.saveResults[zoneID] else {
                throw SavedLibrarySyncError.transportFailure("CloudKit returned no zone result")
            }
            _ = try result.get()
        }
        zoneIsReady = true
    }

    static func mapError(_ error: any Error) -> SavedLibrarySyncError {
        if let syncError = error as? SavedLibrarySyncError { return syncError }
        guard let cloudError = error as? CKError else {
            return .transportFailure(String(describing: error))
        }
        switch cloudError.code {
        case .networkFailure, .networkUnavailable, .serviceUnavailable, .requestRateLimited:
            return .offline
        case .notAuthenticated:
            return .accountUnavailable(.noAccount)
        case .permissionFailure, .badContainer, .missingEntitlement:
            return .cloudKitConfigurationRequired
        case .quotaExceeded, .limitExceeded:
            return .quotaExceeded
        default:
            return .transportFailure(cloudError.localizedDescription)
        }
    }

    /// Apple supplies CKErrorRetryAfterKey for rate limiting and service unavailability. Retry a
    /// single time after the full requested delay; repeated failures return to the coordinator so
    /// local changes stay queued and the UI remains responsive to a later explicit sync attempt.
    private func withCloudKitRetryAfter<T>(
        remainingAttempts: Int = 1,
        operation: () async throws -> T
    ) async throws -> T {
        do {
            return try await operation()
        } catch {
            guard remainingAttempts > 0, let delay = Self.retryDelay(for: error) else {
                throw error
            }
            try await Task<Never, Never>.sleep(for: .seconds(delay))
            return try await withCloudKitRetryAfter(
                remainingAttempts: remainingAttempts - 1,
                operation: operation
            )
        }
    }

    static func retryDelay(for error: any Error) -> TimeInterval? {
        guard let cloudError = error as? CKError,
              cloudError.code == .serviceUnavailable || cloudError.code == .requestRateLimited,
              let number = cloudError.userInfo[CKErrorRetryAfterKey] as? NSNumber
        else { return nil }
        let delay = number.doubleValue
        return delay.isFinite && delay >= 0 ? delay : nil
    }

    private static func deterministicOrder(
        _ lhs: SavedLibrarySyncRecord,
        _ rhs: SavedLibrarySyncRecord
    ) -> Bool {
        lhs.id.uuidString == rhs.id.uuidString
            ? lhs.stamp < rhs.stamp
            : lhs.id.uuidString < rhs.id.uuidString
    }

    private static func encodeServerToken(_ token: CKServerChangeToken) throws -> Data {
        try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
    }

    static func decodeServerToken(_ data: Data?) -> CKServerChangeToken? {
        guard let data else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(
            ofClass: CKServerChangeToken.self,
            from: data
        )
    }
}
