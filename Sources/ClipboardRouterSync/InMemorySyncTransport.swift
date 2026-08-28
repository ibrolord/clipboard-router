import Foundation

/// A deterministic transport used by tests and offline previews.
public actor InMemorySavedLibrarySyncTransport: SavedLibrarySyncTransport {
    private var records: [UUID: SavedLibrarySyncRecord]
    private var changeLog: [(sequence: Int64, record: SavedLibrarySyncRecord)]
    private var sequence: Int64
    private var configuredAccountState: SyncAccountState
    private var accountFingerprint: String
    private var online: Bool
    private var assets: [String: Data]
    public private(set) var identityCallCount = 0
    public private(set) var fetchCallCount = 0
    public private(set) var pushCallCount = 0

    public init(
        records: [SavedLibrarySyncRecord] = [],
        accountState: SyncAccountState = .available,
        accountFingerprint: String = "test-account-a",
        online: Bool = true,
        assets: [String: Data] = [:]
    ) {
        var newestByID: [UUID: SavedLibrarySyncRecord] = [:]
        for record in records {
            if let existing = newestByID[record.id] {
                if record.stamp > existing.stamp { newestByID[record.id] = record }
            } else {
                newestByID[record.id] = record
            }
        }
        self.records = newestByID
        self.changeLog = records.enumerated().map {
            (sequence: Int64($0.offset + 1), record: $0.element)
        }
        self.sequence = Int64(records.count)
        self.configuredAccountState = accountState
        self.accountFingerprint = accountFingerprint
        self.online = online
        self.assets = assets
    }

    public func accountIdentity() async throws -> SyncAccountIdentity {
        identityCallCount += 1
        guard online else { throw SavedLibrarySyncError.offline }
        return SyncAccountIdentity(
            state: configuredAccountState,
            fingerprint: configuredAccountState == .available ? accountFingerprint : nil
        )
    }

    public func fetchChanges(after token: Data?) async throws -> SyncFetchBatch {
        fetchCallCount += 1
        guard online else { throw SavedLibrarySyncError.offline }
        let cursor = Self.decodeToken(token)
        let changes = changeLog
            .filter { $0.sequence > cursor }
            .map(\.record)
        return SyncFetchBatch(records: changes, changeToken: Self.encodeToken(sequence))
    }

    public func push(_ incoming: [SavedLibrarySyncRecord]) async throws {
        pushCallCount += 1
        guard online else { throw SavedLibrarySyncError.offline }
        for candidate in SavedLibrarySyncRecord.dependencyOrdered(incoming) {
            try SavedLibrarySyncRecord.validateSize(candidate)
            if let existing = records[candidate.id] {
                try SavedLibrarySyncRecord.rejectStampCollision(between: existing, and: candidate)
                if existing.stamp >= candidate.stamp { continue }
            }
            records[candidate.id] = candidate
            sequence += 1
            changeLog.append((sequence, candidate))
        }
    }

    public func pushAssets(_ uploads: [SavedLibrarySyncAssetUpload]) async throws -> Set<String> {
        guard online else { throw SavedLibrarySyncError.offline }
        var accepted: Set<String> = []
        for upload in uploads {
            let values = try upload.fileURL.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            )
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  values.fileSize == upload.descriptor.byteCount
            else { throw SavedLibrarySyncError.invalidAssetStagingFile }
            let data = try Data(contentsOf: upload.fileURL, options: [.mappedIfSafe])
            try FileSavedLibrarySyncAssetStager.validate(data, against: upload.descriptor)
            if let existing = assets[upload.descriptor.digest] {
                guard existing == data else {
                    throw SavedLibrarySyncError.assetDigestMismatch(upload.descriptor.digest)
                }
            } else {
                assets[upload.descriptor.digest] = data
            }
            accepted.insert(upload.descriptor.digest)
        }
        return accepted
    }

    public func fetchAssets(
        _ descriptors: [SavedLibrarySyncAssetDescriptor]
    ) async throws -> [SavedLibrarySyncAssetDownload] {
        guard online else { throw SavedLibrarySyncError.offline }
        return try descriptors.map { descriptor in
            guard let data = assets[descriptor.digest] else {
                throw SavedLibrarySyncError.assetMissing(descriptor.digest)
            }
            try FileSavedLibrarySyncAssetStager.validate(data, against: descriptor)
            return SavedLibrarySyncAssetDownload(descriptor: descriptor, data: data)
        }
    }

    public func garbageCollectAssets(digests: Set<String>) async throws {
        guard online else { throw SavedLibrarySyncError.offline }
        for digest in digests { assets.removeValue(forKey: digest) }
    }

    public func setOnline(_ value: Bool) { online = value }
    public func setAccountState(_ value: SyncAccountState) { configuredAccountState = value }
    public func setAccountFingerprint(_ value: String) { accountFingerprint = value }
    public func resetRemoteRecordsForTesting() {
        records.removeAll()
        changeLog.removeAll()
        sequence = 0
    }
    public func allRecords() -> [SavedLibrarySyncRecord] {
        records.values.sorted(by: Self.deterministicOrder)
    }
    public func allAssetDigests() -> Set<String> { Set(assets.keys) }
    public func replaceAssetForTesting(digest: String, data: Data?) {
        assets[digest] = data
    }

    private static func deterministicOrder(
        _ lhs: SavedLibrarySyncRecord,
        _ rhs: SavedLibrarySyncRecord
    ) -> Bool {
        lhs.id.uuidString == rhs.id.uuidString
            ? lhs.stamp < rhs.stamp
            : lhs.id.uuidString < rhs.id.uuidString
    }

    private static func encodeToken(_ value: Int64) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    private static func decodeToken(_ data: Data?) -> Int64 {
        guard let data, data.count == MemoryLayout<Int64>.size else { return 0 }
        return data.withUnsafeBytes { rawBuffer in
            let value = rawBuffer.loadUnaligned(as: Int64.self)
            return Int64(bigEndian: value)
        }
    }
}
