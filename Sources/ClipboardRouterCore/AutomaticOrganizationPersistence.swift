import CryptoKit
import Foundation

public protocol AutomaticOrganizationPersisting: Sendable {
    func load() async throws -> AutomaticOrganizationSnapshot
    func save(_ snapshot: AutomaticOrganizationSnapshot) async throws
}

public enum AutomaticOrganizationPersistenceError: Error, Equatable, LocalizedError, Sendable {
    case unreadableFile(URL, String)
    case undecodableFile(URL, String)
    case checksumMismatch(URL)
    case fileTooLarge(URL, maximum: Int)
    case unwritableFile(URL, String)

    public var errorDescription: String? {
        switch self {
        case let .unreadableFile(url, reason): "Cannot read Automatic Organization rules at \(url.path): \(reason)"
        case let .undecodableFile(url, reason): "Cannot decode Automatic Organization rules at \(url.path): \(reason)"
        case let .checksumMismatch(url): "Automatic Organization checksum does not match at \(url.path)."
        case let .fileTooLarge(url, maximum): "Automatic Organization data at \(url.path) exceeds \(maximum) bytes."
        case let .unwritableFile(url, reason): "Cannot write Automatic Organization rules at \(url.path): \(reason)"
        }
    }
}

public actor JSONFileAutomaticOrganizationStore: AutomaticOrganizationPersisting {
    public static let maximumFileBytes = 2 * 1_024 * 1_024

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

    public func load() async throws -> AutomaticOrganizationSnapshot {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .empty }
        let data: Data
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            if let size = attributes[.size] as? NSNumber, size.intValue > Self.maximumFileBytes {
                throw AutomaticOrganizationPersistenceError.fileTooLarge(
                    fileURL,
                    maximum: Self.maximumFileBytes
                )
            }
            data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        } catch let error as AutomaticOrganizationPersistenceError {
            throw error
        } catch {
            throw AutomaticOrganizationPersistenceError.unreadableFile(
                fileURL,
                String(describing: error)
            )
        }

        let envelope: Envelope
        do {
            envelope = try decoder.decode(Envelope.self, from: data)
        } catch {
            throw AutomaticOrganizationPersistenceError.undecodableFile(
                fileURL,
                String(describing: error)
            )
        }
        guard envelope.payload.count <= Self.maximumFileBytes else {
            throw AutomaticOrganizationPersistenceError.fileTooLarge(
                fileURL,
                maximum: Self.maximumFileBytes
            )
        }
        guard Self.checksum(envelope.payload) == envelope.checksum else {
            throw AutomaticOrganizationPersistenceError.checksumMismatch(fileURL)
        }
        guard envelope.schemaVersion == AutomaticOrganizationSnapshot.currentSchemaVersion else {
            throw AutomaticOrganizationError.unsupportedSchemaVersion(envelope.schemaVersion)
        }
        do {
            return try decoder.decode(AutomaticOrganizationSnapshot.self, from: envelope.payload)
        } catch let error as AutomaticOrganizationError {
            throw error
        } catch {
            throw AutomaticOrganizationPersistenceError.undecodableFile(
                fileURL,
                String(describing: error)
            )
        }
    }

    public func save(_ snapshot: AutomaticOrganizationSnapshot) async throws {
        do {
            let payload = try encoder.encode(snapshot)
            guard payload.count <= Self.maximumFileBytes else {
                throw AutomaticOrganizationPersistenceError.fileTooLarge(
                    fileURL,
                    maximum: Self.maximumFileBytes
                )
            }
            let data = try encoder.encode(Envelope(
                schemaVersion: AutomaticOrganizationSnapshot.currentSchemaVersion,
                checksum: Self.checksum(payload),
                payload: payload
            ))
            guard data.count <= Self.maximumFileBytes else {
                throw AutomaticOrganizationPersistenceError.fileTooLarge(
                    fileURL,
                    maximum: Self.maximumFileBytes
                )
            }
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
            try data.write(to: fileURL, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        } catch let error as AutomaticOrganizationPersistenceError {
            throw error
        } catch {
            throw AutomaticOrganizationPersistenceError.unwritableFile(
                fileURL,
                String(describing: error)
            )
        }
    }

    private static func checksum(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public actor InMemoryAutomaticOrganizationStore: AutomaticOrganizationPersisting {
    private var snapshot: AutomaticOrganizationSnapshot

    public init(snapshot: AutomaticOrganizationSnapshot = .empty) {
        self.snapshot = snapshot
    }

    public func load() async throws -> AutomaticOrganizationSnapshot { snapshot }
    public func save(_ snapshot: AutomaticOrganizationSnapshot) async throws {
        self.snapshot = snapshot
    }
}
