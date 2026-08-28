import Foundation

public actor JSONFileVaultStore: VaultStore {
    public static let maximumStoreBytes = 32 * 1_024 * 1_024
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

    public func load() async throws -> VaultStoreSnapshot {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .empty }
        do {
            let values = try fileURL.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            )
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let size = values.fileSize,
                  size > 0,
                  size <= Self.maximumStoreBytes
            else { throw VaultError.unreadableStore("Invalid or oversized private store") }
            let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
            let snapshot = try decoder.decode(VaultStoreSnapshot.self, from: data)
            return try Self.validate(snapshot)
        } catch let error as VaultError {
            throw error
        } catch let error as DecodingError {
            throw VaultError.undecodableStore(String(describing: error))
        } catch {
            throw VaultError.unreadableStore(String(describing: error))
        }
    }

    public func save(_ snapshot: VaultStoreSnapshot) async throws {
        let validated = try Self.validate(snapshot)
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(validated)
            guard data.count <= Self.maximumStoreBytes else {
                throw VaultError.unwritableStore("Encrypted Vault store exceeds its size limit")
            }
            try VaultPrivateFileIO.writeAtomically(data, to: fileURL)
        } catch let error as VaultError {
            throw error
        } catch {
            throw VaultError.unwritableStore(String(describing: error))
        }
    }

    private static func validate(_ snapshot: VaultStoreSnapshot) throws -> VaultStoreSnapshot {
        guard snapshot.schemaVersion == VaultStoreSnapshot.currentSchemaVersion else {
            throw VaultError.unsupportedStoreVersion(snapshot.schemaVersion)
        }
        var seen = Set<UUID>()
        for envelope in snapshot.envelopes {
            guard envelope.version == 1 || envelope.version == VaultCiphertextEnvelope.currentVersion,
                  envelope.nonce.count == 12,
                  envelope.tag.count == 16,
                  !envelope.ciphertext.isEmpty,
                  envelope.ciphertext.count <= VaultCrypto.maximumItemCiphertextBytes
            else { throw VaultError.invalidEnvelope }
            guard seen.insert(envelope.id).inserted else {
                throw VaultError.duplicateItem(envelope.id)
            }
        }
        return snapshot
    }
}

public actor InMemoryVaultStore: VaultStore {
    private var snapshot: VaultStoreSnapshot

    public init(snapshot: VaultStoreSnapshot = .empty) {
        self.snapshot = snapshot
    }

    public func load() async throws -> VaultStoreSnapshot { snapshot }
    public func save(_ snapshot: VaultStoreSnapshot) async throws { self.snapshot = snapshot }
}
