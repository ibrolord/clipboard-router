import Foundation

public struct ClipArchiveEntry: Codable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let folderName: String?
    public let content: ClipContent
    public let createdAt: Date
    public let modifiedAt: Date

    public init(
        id: UUID,
        name: String,
        folderName: String?,
        content: ClipContent,
        createdAt: Date,
        modifiedAt: Date
    ) {
        self.id = id
        self.name = name
        self.folderName = folderName
        self.content = content
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }
}

public struct ClipArchiveOmission: Codable, Equatable, Sendable {
    public let id: UUID
    public let reason: String

    public init(id: UUID, reason: String) {
        self.id = id
        self.reason = reason
    }
}

public struct ClipArchiveManifest: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let exportedAt: Date
    public let entries: [ClipArchiveEntry]
    public let omissions: [ClipArchiveOmission]

    public init(
        version: Int = currentVersion,
        exportedAt: Date,
        entries: [ClipArchiveEntry],
        omissions: [ClipArchiveOmission]
    ) {
        self.version = version
        self.exportedAt = exportedAt
        self.entries = entries
        self.omissions = omissions
    }
}

public enum ClipExportError: Error, LocalizedError, Sendable {
    case destinationExists(URL)
    case emptySelection
    case unsafeAssetPath
    case unsupportedManifestVersion(Int)
    case operationFailed(String, String)

    public var errorDescription: String? {
        switch self {
        case let .destinationExists(url): "Export destination already exists: \(url.path)"
        case .emptySelection: "There are no eligible clips to export."
        case .unsafeAssetPath: "The export contained an unsafe asset path."
        case let .unsupportedManifestVersion(version): "Archive version \(version) is not supported."
        case let .operationFailed(step, reason): "Export failed while \(step): \(reason)"
        }
    }
}

public actor ClipArchiveService {
    private let assets: any ClipAssetStoring
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(assets: any ClipAssetStoring) {
        self.assets = assets
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    /// Exports ordinary saved clips. Vault, quarantine and private-session values are separate
    /// types and cannot be passed to this API. Flagged sensitive clips are omitted by default.
    public func export(
        savedClips: [SavedClip],
        folders: [ClipFolder],
        to destination: URL,
        at date: Date = Date(),
        includeFlaggedSensitiveClipIDs: Set<UUID> = []
    ) async throws -> ClipArchiveManifest {
        let destination = destination.standardizedFileURL
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw ClipExportError.destinationExists(destination)
        }
        let foldersByID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0.name) })
        var entries: [ClipArchiveEntry] = []
        var omissions: [ClipArchiveOmission] = []
        for clip in savedClips {
            if clip.sensitivity != nil, !includeFlaggedSensitiveClipIDs.contains(clip.id) {
                omissions.append(
                    ClipArchiveOmission(
                        id: clip.id,
                        reason: "Flagged sensitive content requires explicit export selection."
                    )
                )
                continue
            }
            let structuredURL: URL?
            if let originalURL = clip.content.representations.url?.originalURL {
                structuredURL = URL(string: originalURL)
            } else {
                structuredURL = nil
            }
            let containsLocalReference = clip.content.type == .fileURLs
                || !clip.content.representations.files.isEmpty
                || structuredURL?.isFileURL == true
            if containsLocalReference {
                omissions.append(ClipArchiveOmission(id: clip.id, reason: "Local file references are not portable."))
                continue
            }
            entries.append(
                ClipArchiveEntry(
                    id: clip.id,
                    name: clip.name,
                    folderName: clip.folderID.flatMap { foldersByID[$0] },
                    content: clip.content,
                    createdAt: clip.createdAt,
                    modifiedAt: clip.modifiedAt
                )
            )
        }
        guard !entries.isEmpty else { throw ClipExportError.emptySelection }

        let manifest = ClipArchiveManifest(
            exportedAt: date,
            entries: entries,
            omissions: omissions
        )
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(
            ".clipboardrouter-export-\(UUID().uuidString)",
            isDirectory: true
        )
        var step = "creating the staging package"
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            step = "creating the asset directory"
            let assetDirectory = staging.appendingPathComponent("assets", isDirectory: true)
            try FileManager.default.createDirectory(at: assetDirectory, withIntermediateDirectories: true)
            let references = Set(entries.flatMap { $0.content.representations.referencedAssets })
            for reference in references {
                guard !reference.relativePath.contains(".."), !reference.relativePath.hasPrefix("/") else {
                    throw ClipExportError.unsafeAssetPath
                }
                step = "reading asset \(reference.digest)"
                let data = try await assets.read(reference)
                step = "writing asset \(reference.digest)"
                try data.write(
                    to: assetDirectory.appendingPathComponent(reference.relativePath),
                    options: [.atomic]
                )
            }
            step = "writing the manifest"
            try encoder.encode(manifest).write(
                to: staging.appendingPathComponent("manifest.json"),
                options: [.atomic]
            )
            step = "committing the archive"
            try FileManager.default.moveItem(at: staging, to: destination)
            return manifest
        } catch {
            try? FileManager.default.removeItem(at: staging)
            if error is ClipExportError { throw error }
            throw ClipExportError.operationFailed(step, error.localizedDescription)
        }
    }

    public func readManifest(from archive: URL) throws -> ClipArchiveManifest {
        let data = try Data(
            contentsOf: archive.standardizedFileURL.appendingPathComponent("manifest.json"),
            options: [.mappedIfSafe]
        )
        let manifest = try decoder.decode(ClipArchiveManifest.self, from: data)
        guard manifest.version == ClipArchiveManifest.currentVersion else {
            throw ClipExportError.unsupportedManifestVersion(manifest.version)
        }
        return manifest
    }
}
