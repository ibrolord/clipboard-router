import Foundation

public protocol ClipboardLibraryPersisting: Sendable {
    func load() async throws -> ClipboardLibrarySnapshot
    func save(_ snapshot: ClipboardLibrarySnapshot) async throws
}

public protocol ClipboardLibrarySearchPersisting: ClipboardLibraryPersisting {
    func search(query: String, limit: Int) async -> [ClipSearchResult]
}

/// Optional durability hook used only after an authenticated Vault move deletes sensitive
/// ordinary rows. WAL-backed stores must remove superseded frames before reporting success.
public protocol ClipboardLibrarySensitiveDeletionFlushing: Sendable {
    func flushSensitiveDeletions() async throws
}

public enum ClipboardLibraryPersistenceError: Error, LocalizedError, Sendable {
    case unreadableFile(URL, String)
    case undecodableFile(URL, String)
    case unwritableFile(URL, String)

    public var errorDescription: String? {
        switch self {
        case let .unreadableFile(url, reason):
            "Cannot read clipboard library at \(url.path): \(reason)"
        case let .undecodableFile(url, reason):
            "Cannot decode clipboard library at \(url.path): \(reason)"
        case let .unwritableFile(url, reason):
            "Cannot write clipboard library at \(url.path): \(reason)"
        }
    }
}

/// Dependency-free JSON persistence. `Data.write(.atomic)` writes a sibling temporary file and renames it.
public actor JSONFileClipboardLibraryStore: ClipboardLibraryPersisting {
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

    public func load() async throws -> ClipboardLibrarySnapshot {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .empty
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        } catch {
            throw ClipboardLibraryPersistenceError.unreadableFile(
                fileURL,
                String(describing: error)
            )
        }

        do {
            return try decoder.decode(ClipboardLibrarySnapshot.self, from: data)
        } catch {
            throw ClipboardLibraryPersistenceError.undecodableFile(
                fileURL,
                String(describing: error)
            )
        }
    }

    public func save(_ snapshot: ClipboardLibrarySnapshot) async throws {
        let parentDirectory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: parentDirectory,
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(snapshot)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            throw ClipboardLibraryPersistenceError.unwritableFile(
                fileURL,
                String(describing: error)
            )
        }
    }
}

/// Useful for previews, ephemeral sessions, and deterministic tests.
public actor InMemoryClipboardLibraryStore: ClipboardLibraryPersisting {
    private var storedSnapshot: ClipboardLibrarySnapshot

    public init(snapshot: ClipboardLibrarySnapshot = .empty) {
        self.storedSnapshot = snapshot
    }

    public func load() async throws -> ClipboardLibrarySnapshot {
        storedSnapshot
    }

    public func save(_ snapshot: ClipboardLibrarySnapshot) async throws {
        storedSnapshot = snapshot
    }
}
