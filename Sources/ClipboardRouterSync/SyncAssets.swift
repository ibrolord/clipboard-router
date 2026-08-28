import ClipboardRouterCore
import CryptoKit
import Darwin
import Foundation

public enum SavedLibrarySyncAssetPolicy {
    public static let maximumAssetBytes = 10 * 1_024 * 1_024
    public static let maximumAssetsPerClip = 4
    public static let maximumBytesPerClip = 32 * 1_024 * 1_024
    public static let maximumTransferBatchBytes = 32 * 1_024 * 1_024
    public static let maximumStagingBytes = 256 * 1_024 * 1_024
    public static let garbageCollectionGrace: TimeInterval = 30 * 24 * 60 * 60
}

/// Content-blind metadata authenticated by the saved-clip record. The path on either Mac is
/// deliberately absent; CloudKit stores bytes by digest and each receiver materializes its own
/// local `ClipAssetReference`.
public struct SavedLibrarySyncAssetDescriptor: Codable, Hashable, Sendable {
    public let digest: String
    public let kind: ClipAssetKind
    public let uniformTypeIdentifier: String
    public let byteCount: Int
    public let preferredExtension: String?
    public let pixelWidth: Int?
    public let pixelHeight: Int?

    public init(
        reference: ClipAssetReference,
        imageMetadata: ClipImageMetadata? = nil
    ) throws {
        try self.init(
            digest: reference.digest,
            kind: reference.kind,
            uniformTypeIdentifier: reference.uniformTypeIdentifier,
            byteCount: reference.byteCount,
            preferredExtension: Self.extensionFrom(reference.relativePath, digest: reference.digest),
            pixelWidth: imageMetadata?.pixelWidth,
            pixelHeight: imageMetadata?.pixelHeight
        )
    }

    public init(
        digest: String,
        kind: ClipAssetKind,
        uniformTypeIdentifier: String,
        byteCount: Int,
        preferredExtension: String? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil
    ) throws {
        let normalizedDigest = digest.lowercased()
        let normalizedExtension = preferredExtension?.lowercased()
        guard normalizedDigest.count == 64,
              normalizedDigest.allSatisfy(\.isHexDigit),
              !uniformTypeIdentifier.isEmpty,
              uniformTypeIdentifier.utf8.count <= 256,
              byteCount > 0,
              byteCount <= SavedLibrarySyncAssetPolicy.maximumAssetBytes,
              normalizedExtension.map(Self.isSafeExtension) ?? true,
              (pixelWidth == nil) == (pixelHeight == nil),
              pixelWidth.map({ $0 > 0 && $0 <= 100_000 }) ?? true,
              pixelHeight.map({ $0 > 0 && $0 <= 100_000 }) ?? true,
              kind == .image || (pixelWidth == nil && pixelHeight == nil)
        else { throw SavedLibrarySyncError.invalidAssetManifest }
        self.digest = normalizedDigest
        self.kind = kind
        self.uniformTypeIdentifier = uniformTypeIdentifier
        self.byteCount = byteCount
        self.preferredExtension = normalizedExtension
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    public func localReference() throws -> ClipAssetReference {
        try ClipAssetReference(
            digest: digest,
            kind: kind,
            uniformTypeIdentifier: uniformTypeIdentifier,
            byteCount: byteCount,
            relativePath: preferredExtension.map { "\(digest).\($0)" } ?? digest
        )
    }

    private static func extensionFrom(_ path: String, digest: String) -> String? {
        let prefix = digest + "."
        guard path.hasPrefix(prefix) else { return nil }
        let value = String(path.dropFirst(prefix.count)).lowercased()
        return isSafeExtension(value) ? value : nil
    }

    private static func isSafeExtension(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 8 && value.allSatisfy { $0.isLetter || $0.isNumber }
    }
}

public extension SavedLibrarySyncAssetDescriptor {
    static func manifest(for clip: SavedClip) throws -> [Self] {
        let representations = clip.content.representations
        let pairs: [(ClipAssetReference, ClipImageMetadata?)] = [
            representations.richText.map { ($0, nil) },
            representations.html.map { ($0, nil) },
            representations.image.map { ($0, representations.imageMetadata) },
            representations.thumbnail.map { ($0, nil) },
        ].compactMap { $0 }
        guard pairs.count <= SavedLibrarySyncAssetPolicy.maximumAssetsPerClip,
              pairs.reduce(0, { $0 + $1.0.byteCount }) <= SavedLibrarySyncAssetPolicy.maximumBytesPerClip
        else { throw SavedLibrarySyncError.assetQuotaExceeded }
        let descriptors = try pairs.map { try Self(reference: $0.0, imageMetadata: $0.1) }
        guard Set(descriptors).count == descriptors.count else {
            throw SavedLibrarySyncError.invalidAssetManifest
        }
        return descriptors.sorted(by: Self.deterministicOrder)
    }

    static func deterministicOrder(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.digest != rhs.digest { return lhs.digest < rhs.digest }
        if lhs.kind.rawValue != rhs.kind.rawValue { return lhs.kind.rawValue < rhs.kind.rawValue }
        return lhs.uniformTypeIdentifier < rhs.uniformTypeIdentifier
    }

    static func boundedBatches(_ descriptors: [Self]) -> [[Self]] {
        var batches: [[Self]] = []
        var current: [Self] = []
        var bytes = 0
        for descriptor in descriptors.sorted(by: deterministicOrder) {
            if !current.isEmpty,
               bytes > SavedLibrarySyncAssetPolicy.maximumTransferBatchBytes
                    - descriptor.byteCount
            {
                batches.append(current)
                current = []
                bytes = 0
            }
            current.append(descriptor)
            bytes += descriptor.byteCount
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }

    static func canonicalizedClip(_ clip: SavedClip) throws -> SavedClip {
        let manifest = try manifest(for: clip)
        var representations = clip.content.representations
        representations.richText = try manifest.first { $0.kind == .richText }?.localReference()
        representations.html = try manifest.first { $0.kind == .html }?.localReference()
        representations.image = try manifest.first { $0.kind == .image }?.localReference()
        representations.thumbnail = try manifest.first { $0.kind == .thumbnail }?.localReference()
        let content = try ClipContent(
            type: clip.content.type,
            text: clip.content.text,
            representations: representations
        )
        return try SavedClip(
            id: clip.id,
            kind: clip.kind,
            name: clip.name,
            content: content,
            folderID: clip.folderID,
            sourceHistoryItemID: clip.sourceHistoryItemID,
            derivedFromHistoryItemID: clip.derivedFromHistoryItemID,
            createdAt: clip.createdAt,
            modifiedAt: clip.modifiedAt,
            pinnedAt: clip.pinnedAt,
            tags: clip.tags ?? [],
            sourceApplicationBundleIdentifier: clip.sourceApplicationBundleIdentifier,
            originatingDeviceIdentifier: clip.originatingDeviceIdentifier,
            captureContext: clip.captureContext,
            originallyCapturedAt: clip.originallyCapturedAt,
            sensitivity: clip.sensitivity,
            pasteboardTypeIdentifiers: clip.pasteboardTypeIdentifiers ?? []
        )
    }
}

public struct SavedLibrarySyncAssetUpload: Sendable {
    public let descriptor: SavedLibrarySyncAssetDescriptor
    public let fileURL: URL

    public init(descriptor: SavedLibrarySyncAssetDescriptor, fileURL: URL) {
        self.descriptor = descriptor
        self.fileURL = fileURL
    }
}

public struct SavedLibrarySyncAssetDownload: Sendable {
    public let descriptor: SavedLibrarySyncAssetDescriptor
    public let data: Data

    public init(descriptor: SavedLibrarySyncAssetDescriptor, data: Data) {
        self.descriptor = descriptor
        self.data = data
    }
}

public protocol SavedLibrarySyncAssetStaging: Sendable {
    func stage(
        _ descriptor: SavedLibrarySyncAssetDescriptor,
        from source: any ClipAssetStoring
    ) async throws -> SavedLibrarySyncAssetUpload
    func materialize(
        _ download: SavedLibrarySyncAssetDownload,
        into destination: any ClipAssetStoring
    ) async throws -> ClipAssetReference
    func removeStagedAsset(digest: String) async throws
    func removeUnneededStaging(keeping digests: Set<String>) async throws
}

/// Private, content-addressed CKAsset staging. Files survive relaunch and are removed only after
/// the transport confirms remote acceptance. No clip text or source metadata is written here.
public actor FileSavedLibrarySyncAssetStager: SavedLibrarySyncAssetStaging {
    public let rootURL: URL
    public let quotaBytes: Int

    public init(
        rootURL: URL,
        quotaBytes: Int = SavedLibrarySyncAssetPolicy.maximumStagingBytes
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.quotaBytes = max(SavedLibrarySyncAssetPolicy.maximumAssetBytes, quotaBytes)
    }

    public func stage(
        _ descriptor: SavedLibrarySyncAssetDescriptor,
        from source: any ClipAssetStoring
    ) async throws -> SavedLibrarySyncAssetUpload {
        let reference = try descriptor.localReference()
        let data = try await source.read(reference)
        try Self.validate(data, against: descriptor)
        try createPrivateDirectory()
        let destination = try resolve(descriptor.digest + ".upload")
        if FileManager.default.fileExists(atPath: destination.path) {
            let existing = try boundedData(at: destination)
            try Self.validate(existing, against: descriptor)
        } else {
            guard try usedBytes() <= quotaBytes - data.count else {
                throw SavedLibrarySyncError.assetQuotaExceeded
            }
            try Self.atomicPrivateWrite(data, to: destination)
        }
        return SavedLibrarySyncAssetUpload(descriptor: descriptor, fileURL: destination)
    }

    public func materialize(
        _ download: SavedLibrarySyncAssetDownload,
        into destination: any ClipAssetStoring
    ) async throws -> ClipAssetReference {
        try Self.validate(download.data, against: download.descriptor)
        let reference = try await destination.put(
            download.data,
            kind: download.descriptor.kind,
            uniformTypeIdentifier: download.descriptor.uniformTypeIdentifier,
            preferredExtension: download.descriptor.preferredExtension
        )
        guard reference.digest == download.descriptor.digest,
              reference.byteCount == download.descriptor.byteCount,
              reference.kind == download.descriptor.kind,
              reference.uniformTypeIdentifier == download.descriptor.uniformTypeIdentifier
        else { throw SavedLibrarySyncError.assetDigestMismatch(download.descriptor.digest) }
        return reference
    }

    public func removeStagedAsset(digest: String) async throws {
        let url = try resolve(digest.lowercased() + ".upload")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    public func removeUnneededStaging(keeping digests: Set<String>) async throws {
        guard FileManager.default.fileExists(atPath: rootURL.path) else { return }
        for url in try FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  url.pathExtension == "upload"
            else { continue }
            if !digests.contains(url.deletingPathExtension().lastPathComponent) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    static func validate(
        _ data: Data,
        against descriptor: SavedLibrarySyncAssetDescriptor
    ) throws {
        guard !data.isEmpty, data.count == descriptor.byteCount,
              data.count <= SavedLibrarySyncAssetPolicy.maximumAssetBytes
        else { throw SavedLibrarySyncError.assetSizeMismatch(descriptor.digest) }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == descriptor.digest else {
            throw SavedLibrarySyncError.assetDigestMismatch(descriptor.digest)
        }
    }

    private func createPrivateDirectory() throws {
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rootURL.path)
    }

    private func boundedData(at url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize,
              size > 0,
              size <= SavedLibrarySyncAssetPolicy.maximumAssetBytes
        else { throw SavedLibrarySyncError.invalidAssetStagingFile }
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }

    private func usedBytes() throws -> Int {
        guard FileManager.default.fileExists(atPath: rootURL.path) else { return 0 }
        return try FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ).reduce(0) { $0 + (try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
    }

    private func resolve(_ name: String) throws -> URL {
        guard !name.contains("/"), !name.contains("..") else {
            throw SavedLibrarySyncError.invalidAssetStagingFile
        }
        let url = rootURL.appendingPathComponent(name).standardizedFileURL
        guard url.deletingLastPathComponent().path == rootURL.path else {
            throw SavedLibrarySyncError.invalidAssetStagingFile
        }
        return url
    }

    private static func atomicPrivateWrite(_ data: Data, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(UUID().uuidString).tmp"
        )
        FileManager.default.createFile(
            atPath: temporary.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        )
        do {
            let handle = try FileHandle(forWritingTo: temporary)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            guard rename(temporary.path, destination.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
}
