import CryptoKit
import Foundation

public enum SharedWorkspacePersistenceError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedSchema(Int)
    case checksumMismatch
    case accountMismatch
    case invalidAccountIdentity

    public var errorDescription: String? {
        switch self {
        case let .unsupportedSchema(version):
            "The shared-workspace cache uses unsupported schema version \(version)."
        case .checksumMismatch:
            "The shared-workspace cache failed its integrity check."
        case .accountMismatch:
            "The iCloud account changed. Cached shared workspaces were hidden until revalidated."
        case .invalidAccountIdentity:
            "The current iCloud account identity could not be validated."
        }
    }
}

public enum SharedAccountFingerprint {
    public static func derive(
        accountIdentifier: String,
        installationSecret: String
    ) throws -> String {
        let account = accountIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = installationSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !account.isEmpty, !secret.isEmpty else {
            throw SharedWorkspacePersistenceError.invalidAccountIdentity
        }
        let key = SymmetricKey(data: Data(secret.utf8))
        let digest = HMAC<SHA256>.authenticationCode(for: Data(account.utf8), using: key)
        return Data(digest).map { String(format: "%02x", $0) }.joined()
    }
}

public struct SharedZoneCursor: Codable, Equatable, Sendable {
    public let accountFingerprint: String
    public let folderID: UUID
    public let ownerParticipantID: String
    public let zoneName: String
    public let databaseScope: SharedFolderDatabaseScope
    public var serverChangeToken: Data?
    public var lastSuccessfulFetchAt: Date?

    public init(
        accountFingerprint: String,
        folderID: UUID,
        ownerParticipantID: String,
        zoneName: String,
        databaseScope: SharedFolderDatabaseScope,
        serverChangeToken: Data? = nil,
        lastSuccessfulFetchAt: Date? = nil
    ) {
        self.accountFingerprint = accountFingerprint
        self.folderID = folderID
        self.ownerParticipantID = ownerParticipantID
        self.zoneName = zoneName
        self.databaseScope = databaseScope
        self.serverChangeToken = serverChangeToken
        self.lastSuccessfulFetchAt = lastSuccessfulFetchAt
    }
}

public struct SharedConflictRecoveryCopy: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let originalItemID: UUID
    public let workspaceID: UUID
    public let losingRecord: SharedFolderRecord
    public let winningStamp: LamportStamp
    public let detectedAt: Date

    public init(
        id: UUID = UUID(),
        originalItemID: UUID,
        workspaceID: UUID,
        losingRecord: SharedFolderRecord,
        winningStamp: LamportStamp,
        detectedAt: Date = Date()
    ) {
        self.id = id
        self.originalItemID = originalItemID
        self.workspaceID = workspaceID
        self.losingRecord = losingRecord
        self.winningStamp = winningStamp
        self.detectedAt = detectedAt
    }
}

public struct SharedWorkspaceRegistration: Codable, Equatable, Sendable {
    public let accountFingerprint: String
    public let location: SharedFolderRemoteLocation
    public var managedFolderIDs: Set<UUID>
    public var managedSavedClipIDs: Set<UUID>
    public var cursor: SharedZoneCursor
    public var recoveryCopies: [SharedConflictRecoveryCopy]

    public init(
        accountFingerprint: String,
        location: SharedFolderRemoteLocation,
        managedFolderIDs: Set<UUID>,
        managedSavedClipIDs: Set<UUID>,
        cursor: SharedZoneCursor,
        recoveryCopies: [SharedConflictRecoveryCopy] = []
    ) {
        self.accountFingerprint = accountFingerprint
        self.location = location
        self.managedFolderIDs = managedFolderIDs
        self.managedSavedClipIDs = managedSavedClipIDs
        self.cursor = cursor
        self.recoveryCopies = Self.pruned(recoveryCopies)
    }

    private static func pruned(_ copies: [SharedConflictRecoveryCopy]) -> [SharedConflictRecoveryCopy] {
        let newestFirst = copies.sorted { $0.detectedAt > $1.detectedAt }
        var countsByItem: [UUID: Int] = [:]
        var accepted: [SharedConflictRecoveryCopy] = []
        for copy in newestFirst {
            guard accepted.count < 100, countsByItem[copy.originalItemID, default: 0] < 3 else {
                continue
            }
            countsByItem[copy.originalItemID, default: 0] += 1
            accepted.append(copy)
        }
        return accepted.sorted { $0.detectedAt < $1.detectedAt }
    }
}

public struct SharedWorkspaceRegistry: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let accountFingerprint: String
    public var workspaces: [SharedWorkspaceRegistration]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        accountFingerprint: String,
        workspaces: [SharedWorkspaceRegistration]
    ) {
        self.schemaVersion = schemaVersion
        self.accountFingerprint = accountFingerprint
        self.workspaces = workspaces.sorted {
            $0.location.folderID.uuidString < $1.location.folderID.uuidString
        }
    }
}

public struct SharedWorkspaceRegistryStore: Sendable {
    private struct Envelope: Codable {
        let schemaVersion: Int
        let checksum: String
        let payload: Data
    }

    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> SharedWorkspaceRegistry? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: fileURL))
        guard envelope.schemaVersion == SharedWorkspaceRegistry.currentSchemaVersion else {
            throw SharedWorkspacePersistenceError.unsupportedSchema(envelope.schemaVersion)
        }
        guard checksum(envelope.payload) == envelope.checksum else {
            throw SharedWorkspacePersistenceError.checksumMismatch
        }
        let registry = try JSONDecoder().decode(SharedWorkspaceRegistry.self, from: envelope.payload)
        guard registry.schemaVersion == SharedWorkspaceRegistry.currentSchemaVersion else {
            throw SharedWorkspacePersistenceError.unsupportedSchema(registry.schemaVersion)
        }
        return registry
    }

    public func save(_ registry: SharedWorkspaceRegistry) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(registry)
        let envelope = Envelope(
            schemaVersion: SharedWorkspaceRegistry.currentSchemaVersion,
            checksum: checksum(payload),
            payload: payload
        )
        let data = try encoder.encode(envelope)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }

    private func checksum(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
