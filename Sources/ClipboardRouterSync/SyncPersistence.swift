import Foundation

public actor JSONFileSavedLibrarySyncStateStore: SavedLibrarySyncStateStore {
    public let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL) {
        self.fileURL = fileURL.standardizedFileURL
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        self.decoder = decoder
    }

    public func load() async throws -> SavedLibrarySyncSnapshot {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .disabled }
        do {
            let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
            return try validate(decoder.decode(SavedLibrarySyncSnapshot.self, from: data))
        } catch let error as SavedLibrarySyncError {
            throw error
        } catch {
            throw SavedLibrarySyncError.persistenceFailure(String(describing: error))
        }
    }

    public func save(_ snapshot: SavedLibrarySyncSnapshot) async throws {
        do {
            let checked = try validate(snapshot)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try encoder.encode(checked).write(to: fileURL, options: [.atomic])
        } catch let error as SavedLibrarySyncError {
            throw error
        } catch {
            throw SavedLibrarySyncError.persistenceFailure(String(describing: error))
        }
    }

    private func validate(_ snapshot: SavedLibrarySyncSnapshot) throws -> SavedLibrarySyncSnapshot {
        guard snapshot.schemaVersion == SavedLibrarySyncSnapshot.currentSchemaVersion else {
            throw SavedLibrarySyncError.unsupportedSnapshotVersion(snapshot.schemaVersion)
        }
        for (id, record) in snapshot.records where id != record.id {
            throw SavedLibrarySyncError.invalidRecord(record.id)
        }
        for (id, record) in snapshot.outbox where id != record.id {
            throw SavedLibrarySyncError.invalidRecord(record.id)
        }
        guard snapshot.localLamportCounter >= 0,
              snapshot.localLamportCounter < Int64.max
        else { throw SavedLibrarySyncError.lamportOverflow }
        guard snapshot.assetGarbage.allSatisfy({ digest, date in
            digest.count == 64
                && digest.allSatisfy(\.isHexDigit)
                && date.timeIntervalSinceReferenceDate.isFinite
        }) else { throw SavedLibrarySyncError.invalidAssetManifest }
        try snapshot.records.values.forEach(SavedLibrarySyncRecord.validate)
        try snapshot.outbox.values.forEach(SavedLibrarySyncRecord.validate)
        return snapshot
    }
}

public actor InMemorySavedLibrarySyncStateStore: SavedLibrarySyncStateStore {
    private var snapshot: SavedLibrarySyncSnapshot
    public init(snapshot: SavedLibrarySyncSnapshot = .disabled) { self.snapshot = snapshot }
    public func load() async throws -> SavedLibrarySyncSnapshot { snapshot }
    public func save(_ snapshot: SavedLibrarySyncSnapshot) async throws { self.snapshot = snapshot }
}
