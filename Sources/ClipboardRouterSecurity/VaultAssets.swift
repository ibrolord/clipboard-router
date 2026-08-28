import ClipboardRouterCore
import CryptoKit
import Darwin
import Foundation

public enum VaultAssetPolicy {
    public static let maximumAssetCount = 4
    public static let maximumAssetBytes = 10 * 1_024 * 1_024
    public static let maximumItemAssetBytes = 32 * 1_024 * 1_024
    public static let chunkByteCount = 256 * 1_024
    /// JSON base64 expands ciphertext by roughly one third; leave bounded room for chunk
    /// nonces/tags and structural metadata while still rejecting unbounded input before decode.
    public static let maximumEncryptedFileBytes = (maximumAssetBytes * 4 / 3) + 1 * 1_024 * 1_024
}

/// Authenticated inside `VaultItem` ciphertext. The opaque storage identifier is deterministic so
/// an interrupted move can rebuild the same manifest without persisting plaintext staging state.
public struct VaultAssetDescriptor: Codable, Equatable, Hashable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let storageIdentifier: String
    public let kind: ClipAssetKind
    public let uniformTypeIdentifier: String
    public let plaintextDigest: String
    public let plaintextByteCount: Int

    public init(itemID: UUID, reference: ClipAssetReference) throws {
        guard reference.byteCount <= VaultAssetPolicy.maximumAssetBytes else {
            throw VaultError.assetTooLarge(reference.byteCount)
        }
        let type = reference.uniformTypeIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !type.isEmpty, type.utf8.count <= 255 else {
            throw VaultError.invalidAssetManifest
        }
        let material = [
            "clipboard-router:vault-asset:1",
            itemID.uuidString.lowercased(),
            reference.kind.rawValue,
            type,
            reference.digest,
            String(reference.byteCount),
        ].joined(separator: "\u{1f}")
        self.version = Self.currentVersion
        self.storageIdentifier = SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        self.kind = reference.kind
        self.uniformTypeIdentifier = type
        self.plaintextDigest = reference.digest
        self.plaintextByteCount = reference.byteCount
    }

    public var encryptedFileName: String { "\(storageIdentifier).vaultasset" }

    func validate() throws {
        guard version == Self.currentVersion,
              storageIdentifier.count == 64,
              storageIdentifier.allSatisfy(\.isHexDigit),
              plaintextDigest.count == 64,
              plaintextDigest.allSatisfy(\.isHexDigit),
              plaintextByteCount > 0,
              plaintextByteCount <= VaultAssetPolicy.maximumAssetBytes,
              !uniformTypeIdentifier.isEmpty,
              uniformTypeIdentifier.utf8.count <= 255
        else { throw VaultError.invalidAssetManifest }
    }
}

public struct VaultRestoredAsset: Equatable, Sendable {
    public let descriptor: VaultAssetDescriptor
    public let data: Data

    public init(descriptor: VaultAssetDescriptor, data: Data) {
        self.descriptor = descriptor
        self.data = data
    }
}

/// Decrypted only for an explicitly authorized copy/route operation. It is never Codable and is
/// never written to an index, log, sync record, thumbnail cache, or preferences store.
public struct VaultRestoredPayload: Equatable, Sendable {
    public let content: ClipContent
    public let sourceTypeIdentifiers: [String]
    public let assets: [VaultRestoredAsset]

    public init(
        content: ClipContent,
        sourceTypeIdentifiers: [String],
        assets: [VaultRestoredAsset]
    ) {
        self.content = content
        self.sourceTypeIdentifiers = sourceTypeIdentifiers
        self.assets = assets
    }
}

private struct VaultAssetCipherChunk: Codable, Equatable, Sendable {
    let index: Int
    let nonce: Data
    let ciphertext: Data
    let tag: Data
}

private struct VaultAssetCipherFile: Codable, Equatable, Sendable {
    static let currentVersion = 1
    let version: Int
    let storageIdentifier: String
    let plaintextByteCount: Int
    let chunkByteCount: Int
    let chunks: [VaultAssetCipherChunk]
}

public enum VaultAssetCrypto {
    public static func seal(
        _ plaintext: Data,
        descriptor: VaultAssetDescriptor,
        itemID: UUID,
        using keyData: Data
    ) throws -> Data {
        try descriptor.validate()
        guard keyData.count == VaultCrypto.keyByteCount else { throw VaultError.invalidKeyLength }
        guard plaintext.count == descriptor.plaintextByteCount,
              digest(plaintext) == descriptor.plaintextDigest
        else { throw VaultError.assetDigestMismatch(descriptor.storageIdentifier) }

        let key = SymmetricKey(data: keyData)
        let expectedChunks = (plaintext.count + VaultAssetPolicy.chunkByteCount - 1)
            / VaultAssetPolicy.chunkByteCount
        var chunks: [VaultAssetCipherChunk] = []
        chunks.reserveCapacity(expectedChunks)
        for index in 0..<expectedChunks {
            let lower = index * VaultAssetPolicy.chunkByteCount
            let upper = min(plaintext.count, lower + VaultAssetPolicy.chunkByteCount)
            let chunk = plaintext.subdata(in: lower..<upper)
            let nonce = AES.GCM.Nonce()
            let sealed = try AES.GCM.seal(
                chunk,
                using: key,
                nonce: nonce,
                authenticating: authenticatedData(
                    descriptor: descriptor,
                    itemID: itemID,
                    chunkIndex: index,
                    chunkCount: expectedChunks
                )
            )
            chunks.append(VaultAssetCipherChunk(
                index: index,
                nonce: Data(nonce),
                ciphertext: sealed.ciphertext,
                tag: sealed.tag
            ))
        }
        let file = VaultAssetCipherFile(
            version: VaultAssetCipherFile.currentVersion,
            storageIdentifier: descriptor.storageIdentifier,
            plaintextByteCount: plaintext.count,
            chunkByteCount: VaultAssetPolicy.chunkByteCount,
            chunks: chunks
        )
        let encoded = try encoder.encode(file)
        guard encoded.count <= VaultAssetPolicy.maximumEncryptedFileBytes else {
            throw VaultError.assetTooLarge(encoded.count)
        }
        return encoded
    }

    public static func open(
        _ encrypted: Data,
        descriptor: VaultAssetDescriptor,
        itemID: UUID,
        using keyData: Data
    ) throws -> Data {
        try descriptor.validate()
        guard keyData.count == VaultCrypto.keyByteCount else { throw VaultError.invalidKeyLength }
        guard !encrypted.isEmpty,
              encrypted.count <= VaultAssetPolicy.maximumEncryptedFileBytes
        else { throw VaultError.invalidAssetEnvelope }
        let file: VaultAssetCipherFile
        do {
            file = try decoder.decode(VaultAssetCipherFile.self, from: encrypted)
        } catch {
            throw VaultError.invalidAssetEnvelope
        }
        let expectedChunks = (descriptor.plaintextByteCount + VaultAssetPolicy.chunkByteCount - 1)
            / VaultAssetPolicy.chunkByteCount
        guard file.version == VaultAssetCipherFile.currentVersion,
              file.storageIdentifier == descriptor.storageIdentifier,
              file.plaintextByteCount == descriptor.plaintextByteCount,
              file.chunkByteCount == VaultAssetPolicy.chunkByteCount,
              file.chunks.count == expectedChunks,
              file.chunks.indices.allSatisfy({ file.chunks[$0].index == $0 })
        else { throw VaultError.invalidAssetEnvelope }

        let key = SymmetricKey(data: keyData)
        var plaintext = Data()
        plaintext.reserveCapacity(descriptor.plaintextByteCount)
        do {
            for chunk in file.chunks {
                guard chunk.ciphertext.count > 0,
                      chunk.ciphertext.count <= VaultAssetPolicy.chunkByteCount,
                      chunk.nonce.count == 12,
                      chunk.tag.count == 16,
                      plaintext.count <= descriptor.plaintextByteCount - chunk.ciphertext.count
                else { throw VaultError.invalidAssetEnvelope }
                let box = try AES.GCM.SealedBox(
                    nonce: AES.GCM.Nonce(data: chunk.nonce),
                    ciphertext: chunk.ciphertext,
                    tag: chunk.tag
                )
                let opened = try AES.GCM.open(
                    box,
                    using: key,
                    authenticating: authenticatedData(
                        descriptor: descriptor,
                        itemID: itemID,
                        chunkIndex: chunk.index,
                        chunkCount: expectedChunks
                    )
                )
                guard opened.count == chunk.ciphertext.count else {
                    throw VaultError.invalidAssetEnvelope
                }
                plaintext.append(opened)
            }
        } catch let error as VaultError {
            throw error
        } catch {
            throw VaultError.invalidAssetEnvelope
        }
        guard plaintext.count == descriptor.plaintextByteCount,
              digest(plaintext) == descriptor.plaintextDigest
        else { throw VaultError.assetDigestMismatch(descriptor.storageIdentifier) }
        return plaintext
    }

    private static func authenticatedData(
        descriptor: VaultAssetDescriptor,
        itemID: UUID,
        chunkIndex: Int,
        chunkCount: Int
    ) -> Data {
        Data([
            "clipboard-router:vault-asset:\(VaultAssetCipherFile.currentVersion)",
            itemID.uuidString.lowercased(),
            descriptor.storageIdentifier,
            descriptor.kind.rawValue,
            descriptor.uniformTypeIdentifier,
            descriptor.plaintextDigest,
            String(descriptor.plaintextByteCount),
            String(chunkIndex),
            String(chunkCount),
        ].joined(separator: "\u{1f}").utf8)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static let decoder = JSONDecoder()
}

public protocol VaultEncryptedAssetStoring: Sendable {
    func write(_ encrypted: Data, descriptor: VaultAssetDescriptor) async throws
    func read(descriptor: VaultAssetDescriptor) async throws -> Data
    func remove(descriptor: VaultAssetDescriptor) async throws
}

public actor FileVaultEncryptedAssetStore: VaultEncryptedAssetStoring {
    public let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    public func write(_ encrypted: Data, descriptor: VaultAssetDescriptor) async throws {
        try descriptor.validate()
        guard !encrypted.isEmpty,
              encrypted.count <= VaultAssetPolicy.maximumEncryptedFileBytes
        else { throw VaultError.invalidAssetEnvelope }
        let url = try resolve(descriptor.encryptedFileName)
        try VaultPrivateFileIO.writeAtomically(encrypted, to: url)
    }

    public func read(descriptor: VaultAssetDescriptor) async throws -> Data {
        try descriptor.validate()
        let url = try resolve(descriptor.encryptedFileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw VaultError.missingAsset(descriptor.storageIdentifier)
        }
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let size = values.fileSize,
                  size > 0,
                  size <= VaultAssetPolicy.maximumEncryptedFileBytes
            else { throw VaultError.invalidAssetEnvelope }
            return try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch let error as VaultError {
            throw error
        } catch {
            throw VaultError.unreadableStore(String(describing: error))
        }
    }

    public func remove(descriptor: VaultAssetDescriptor) async throws {
        let url = try resolve(descriptor.encryptedFileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw VaultError.unwritableStore(String(describing: error))
        }
    }

    private func resolve(_ fileName: String) throws -> URL {
        guard fileName.count == 75,
              fileName.hasSuffix(".vaultasset"),
              fileName.dropLast(11).allSatisfy(\.isHexDigit)
        else { throw VaultError.invalidAssetManifest }
        let url = rootURL.appendingPathComponent(fileName).standardizedFileURL
        guard url.deletingLastPathComponent().path == rootURL.path else {
            throw VaultError.invalidAssetManifest
        }
        return url
    }
}

public actor InMemoryVaultEncryptedAssetStore: VaultEncryptedAssetStoring {
    private var values: [String: Data]

    public init(values: [String: Data] = [:]) { self.values = values }

    public func write(_ encrypted: Data, descriptor: VaultAssetDescriptor) async throws {
        values[descriptor.storageIdentifier] = encrypted
    }

    public func read(descriptor: VaultAssetDescriptor) async throws -> Data {
        guard let value = values[descriptor.storageIdentifier] else {
            throw VaultError.missingAsset(descriptor.storageIdentifier)
        }
        return value
    }

    public func remove(descriptor: VaultAssetDescriptor) async throws {
        values.removeValue(forKey: descriptor.storageIdentifier)
    }

    public func replaceForTesting(storageIdentifier: String, with value: Data?) {
        values[storageIdentifier] = value
    }

    public func encryptedValue(for storageIdentifier: String) -> Data? {
        values[storageIdentifier]
    }
}

enum VaultPrivateFileIO {
    static func writeAtomically(_ data: Data, to destination: URL) throws {
        let manager = FileManager.default
        let directory = destination.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        guard manager.createFile(
            atPath: temporary.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else { throw VaultError.unwritableStore("Could not create private temporary file") }
        do {
            let handle = try FileHandle(forWritingTo: temporary)
            do {
                try handle.write(contentsOf: data)
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            guard rename(temporary.path, destination.path) == 0 else {
                throw VaultError.unwritableStore(String(cString: strerror(errno)))
            }
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        } catch {
            try? manager.removeItem(at: temporary)
            throw error
        }
    }
}
