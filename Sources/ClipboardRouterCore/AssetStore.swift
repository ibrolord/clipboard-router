import CryptoKit
import Foundation

public enum ClipAssetStoreError: Error, LocalizedError, Sendable {
    case emptyAsset
    case assetTooLarge(Int)
    case quotaExceeded
    case missingAsset(String)
    case digestMismatch(String)
    case unsafePath

    public var errorDescription: String? {
        switch self {
        case .emptyAsset: "The clipboard asset is empty."
        case let .assetTooLarge(size): "The clipboard asset is too large (\(size) bytes)."
        case .quotaExceeded: "The clipboard asset storage quota has been reached."
        case let .missingAsset(digest): "Clipboard asset \(digest) is missing."
        case let .digestMismatch(digest): "Clipboard asset \(digest) failed integrity verification."
        case .unsafePath: "The clipboard asset path is unsafe."
        }
    }
}

public protocol ClipAssetStoring: Sendable {
    func put(
        _ data: Data,
        kind: ClipAssetKind,
        uniformTypeIdentifier: String,
        preferredExtension: String?
    ) async throws -> ClipAssetReference
    func read(_ reference: ClipAssetReference) async throws -> Data
    func collectGarbage(
        keeping references: Set<ClipAssetReference>,
        olderThan cutoff: Date
    ) async throws -> Int
}

public struct ClipAssetMaintenanceReport: Equatable, Sendable {
    public let referencedAssetCount: Int
    public let removedFileCount: Int
    public let usedBytes: Int
    public let effectiveQuotaBytes: Int

    public init(
        referencedAssetCount: Int,
        removedFileCount: Int,
        usedBytes: Int,
        effectiveQuotaBytes: Int
    ) {
        self.referencedAssetCount = referencedAssetCount
        self.removedFileCount = removedFileCount
        self.usedBytes = usedBytes
        self.effectiveQuotaBytes = effectiveQuotaBytes
    }

    public var remainingBytes: Int { max(0, effectiveQuotaBytes - usedBytes) }
    public var isOverQuota: Bool { usedBytes > effectiveQuotaBytes }
}

/// Content-addressed, atomic binary storage. Callers must run sensitivity policy before `put`.
public actor FileClipAssetStore: ClipAssetStoring {
    public let rootURL: URL
    public let maximumAssetBytes: Int
    public private(set) var quotaBytes: Int

    public init(
        rootURL: URL,
        maximumAssetBytes: Int = 10 * 1_024 * 1_024,
        quotaBytes: Int = 512 * 1_024 * 1_024
    ) {
        self.rootURL = rootURL.standardizedFileURL
        let safeMaximumAssetBytes = max(1, maximumAssetBytes)
        self.maximumAssetBytes = safeMaximumAssetBytes
        self.quotaBytes = max(safeMaximumAssetBytes, quotaBytes)
    }

    /// Updates the live storage quota while preserving room for at least one permitted asset.
    /// A persisted or user-entered zero/negative value cannot disable storage accidentally.
    public func setQuotaBytes(_ quotaBytes: Int) {
        self.quotaBytes = max(maximumAssetBytes, quotaBytes)
    }

    public func put(
        _ data: Data,
        kind: ClipAssetKind,
        uniformTypeIdentifier: String,
        preferredExtension: String? = nil
    ) async throws -> ClipAssetReference {
        guard !data.isEmpty else { throw ClipAssetStoreError.emptyAsset }
        guard data.count <= maximumAssetBytes else {
            throw ClipAssetStoreError.assetTooLarge(data.count)
        }

        let digest = Self.digest(data)
        let fileExtension = Self.safeExtension(preferredExtension)
        let relativePath = fileExtension.map { "\(digest).\($0)" } ?? digest
        let destination = try resolve(relativePath)

        if FileManager.default.fileExists(atPath: destination.path) {
            let existing = try Data(contentsOf: destination, options: [.mappedIfSafe])
            guard Self.digest(existing) == digest else {
                throw ClipAssetStoreError.digestMismatch(digest)
            }
        } else {
            let used = try storageByteCount()
            guard used <= quotaBytes - data.count else { throw ClipAssetStoreError.quotaExceeded }
            try FileManager.default.createDirectory(
                at: rootURL,
                withIntermediateDirectories: true
            )
            try data.write(to: destination, options: [.atomic])
        }

        return try ClipAssetReference(
            digest: digest,
            kind: kind,
            uniformTypeIdentifier: uniformTypeIdentifier,
            byteCount: data.count,
            relativePath: relativePath
        )
    }

    public func read(_ reference: ClipAssetReference) async throws -> Data {
        let url = try resolve(reference.relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ClipAssetStoreError.missingAsset(reference.digest)
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count == reference.byteCount, Self.digest(data) == reference.digest else {
            throw ClipAssetStoreError.digestMismatch(reference.digest)
        }
        return data
    }

    /// Removes one exact content-addressed asset after the caller has proven that no ordinary row
    /// references it. This avoids a global zero-grace garbage collection racing a different
    /// clipboard materialization that has not committed its row yet.
    public func removeUnreferenced(_ reference: ClipAssetReference) throws {
        let url = try resolve(reference.relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count == reference.byteCount, Self.digest(data) == reference.digest else {
            throw ClipAssetStoreError.digestMismatch(reference.digest)
        }
        try FileManager.default.removeItem(at: url)
    }

    public func collectGarbage(
        keeping references: Set<ClipAssetReference>,
        olderThan cutoff: Date
    ) async throws -> Int {
        guard FileManager.default.fileExists(atPath: rootURL.path) else { return 0 }
        let keptPaths = Set(references.map(\.relativePath))
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        let files = try FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )
        var removed = 0
        for file in files {
            guard !keptPaths.contains(file.lastPathComponent) else { continue }
            let values = try file.resourceValues(forKeys: keys)
            guard values.isRegularFile == true,
                  (values.contentModificationDate ?? .distantPast) < cutoff
            else { continue }
            try FileManager.default.removeItem(at: file)
            removed += 1
        }
        return removed
    }

    /// Production integration point: derives the complete keep-set from the ordinary snapshot,
    /// collects only unreferenced old files, and reports the user-configured effective quota.
    public func performMaintenance(
        referencedBy snapshot: ClipboardLibrarySnapshot,
        olderThan cutoff: Date
    ) async throws -> ClipAssetMaintenanceReport {
        let references = Set(
            snapshot.history.flatMap { $0.content.representations.referencedAssets }
                + snapshot.savedClips.flatMap { $0.content.representations.referencedAssets }
        )
        let removed = try await collectGarbage(keeping: references, olderThan: cutoff)
        let used = try storageByteCount()
        return ClipAssetMaintenanceReport(
            referencedAssetCount: references.count,
            removedFileCount: removed,
            usedBytes: used,
            effectiveQuotaBytes: min(
                quotaBytes,
                snapshot.settings.effectiveMaximumAssetStorageBytes
            )
        )
    }

    public func usageBytes() throws -> Int {
        try storageByteCount()
    }

    private func storageByteCount() throws -> Int {
        guard FileManager.default.fileExists(atPath: rootURL.path) else { return 0 }
        return try FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ).reduce(0) { total, url in
            total + (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }
    }

    private func resolve(_ relativePath: String) throws -> URL {
        guard !relativePath.contains(".."), !relativePath.hasPrefix("/") else {
            throw ClipAssetStoreError.unsafePath
        }
        let resolved = rootURL.appendingPathComponent(relativePath).standardizedFileURL
        let expectedPrefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        guard resolved.path.hasPrefix(expectedPrefix),
              resolved.deletingLastPathComponent().path == rootURL.path
        else {
            throw ClipAssetStoreError.unsafePath
        }
        return resolved
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func safeExtension(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !normalized.isEmpty,
              normalized.count <= 8,
              normalized.allSatisfy({ $0.isLetter || $0.isNumber })
        else { return nil }
        return normalized
    }
}
