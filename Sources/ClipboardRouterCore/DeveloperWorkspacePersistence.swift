import CryptoKit
import Foundation

public protocol DeveloperWorkspacePersisting: Sendable {
    func load() async throws -> DeveloperWorkspaceSnapshot
    func save(_ snapshot: DeveloperWorkspaceSnapshot) async throws
}

public enum DeveloperWorkspacePersistenceError: Error, Equatable, LocalizedError, Sendable {
    case unreadableFile(URL, String)
    case undecodableFile(URL, String)
    case checksumMismatch(URL)
    case fileTooLarge(URL, maximum: Int)
    case unwritableFile(URL, String)

    public var errorDescription: String? {
        switch self {
        case let .unreadableFile(url, reason):
            "Cannot read Developer Workspace at \(url.path): \(reason)"
        case let .undecodableFile(url, reason):
            "Cannot decode Developer Workspace at \(url.path): \(reason)"
        case let .checksumMismatch(url):
            "Developer Workspace checksum does not match at \(url.path)."
        case let .fileTooLarge(url, maximum):
            "Developer Workspace at \(url.path) exceeds the \(maximum)-byte limit."
        case let .unwritableFile(url, reason):
            "Cannot write Developer Workspace at \(url.path): \(reason)"
        }
    }
}

/// A checksummed, atomic JSON store for local-only Developer Workspace state.
public actor JSONFileDeveloperWorkspaceStore: DeveloperWorkspacePersisting {
    public static let maximumFileBytes = 64 * 1_024 * 1_024

    private struct Envelope: Codable {
        let schemaVersion: Int
        let checksum: String
        let payload: Data
    }

    public let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL) {
        self.fileURL = fileURL.standardizedFileURL

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .deferredToDate
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        self.decoder = decoder
    }

    public func load() async throws -> DeveloperWorkspaceSnapshot {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .empty
        }

        let data: Data
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            if let fileSize = attributes[.size] as? NSNumber,
               fileSize.intValue > Self.maximumFileBytes
            {
                throw DeveloperWorkspacePersistenceError.fileTooLarge(
                    fileURL,
                    maximum: Self.maximumFileBytes
                )
            }
            data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        } catch let error as DeveloperWorkspacePersistenceError {
            throw error
        } catch {
            throw DeveloperWorkspacePersistenceError.unreadableFile(
                fileURL,
                String(describing: error)
            )
        }

        let envelope: Envelope
        do {
            envelope = try decoder.decode(Envelope.self, from: data)
        } catch {
            throw DeveloperWorkspacePersistenceError.undecodableFile(
                fileURL,
                String(describing: error)
            )
        }
        guard envelope.schemaVersion == DeveloperWorkspaceSnapshot.currentSchemaVersion else {
            throw DeveloperWorkspaceError.unsupportedSchemaVersion(envelope.schemaVersion)
        }
        guard envelope.payload.count <= Self.maximumFileBytes else {
            throw DeveloperWorkspacePersistenceError.fileTooLarge(
                fileURL,
                maximum: Self.maximumFileBytes
            )
        }
        guard Self.checksum(envelope.payload) == envelope.checksum else {
            throw DeveloperWorkspacePersistenceError.checksumMismatch(fileURL)
        }

        do {
            return try decoder.decode(DeveloperWorkspaceSnapshot.self, from: envelope.payload)
        } catch let error as DeveloperWorkspaceError {
            throw error
        } catch {
            throw DeveloperWorkspacePersistenceError.undecodableFile(
                fileURL,
                String(describing: error)
            )
        }
    }

    public func save(_ snapshot: DeveloperWorkspaceSnapshot) async throws {
        do {
            let payload = try encoder.encode(snapshot)
            guard payload.count <= Self.maximumFileBytes else {
                throw DeveloperWorkspacePersistenceError.fileTooLarge(
                    fileURL,
                    maximum: Self.maximumFileBytes
                )
            }
            let envelope = Envelope(
                schemaVersion: DeveloperWorkspaceSnapshot.currentSchemaVersion,
                checksum: Self.checksum(payload),
                payload: payload
            )
            let data = try encoder.encode(envelope)
            guard data.count <= Self.maximumFileBytes else {
                throw DeveloperWorkspacePersistenceError.fileTooLarge(
                    fileURL,
                    maximum: Self.maximumFileBytes
                )
            }
            let directoryURL = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directoryURL.path
            )
            try data.write(to: fileURL, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        } catch let error as DeveloperWorkspacePersistenceError {
            throw error
        } catch {
            throw DeveloperWorkspacePersistenceError.unwritableFile(
                fileURL,
                String(describing: error)
            )
        }
    }

    private static func checksum(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Deterministic storage for tests, previews, and ephemeral sessions.
public actor InMemoryDeveloperWorkspaceStore: DeveloperWorkspacePersisting {
    private var storedSnapshot: DeveloperWorkspaceSnapshot

    public init(snapshot: DeveloperWorkspaceSnapshot = .empty) {
        self.storedSnapshot = snapshot
    }

    public func load() async throws -> DeveloperWorkspaceSnapshot {
        storedSnapshot
    }

    public func save(_ snapshot: DeveloperWorkspaceSnapshot) async throws {
        storedSnapshot = snapshot
    }
}
