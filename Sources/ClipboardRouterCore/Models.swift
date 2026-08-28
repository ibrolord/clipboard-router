import CryptoKit
import Foundation

public enum SupportedContentType: String, Codable, CaseIterable, Sendable {
    case plainText
    case url
    case richText
    case image
    case fileURLs
}

/// A representation-preserving clipboard payload. `text` is the safe searchable/preview fallback;
/// original rich and binary representations live in the content-addressed asset store.
public struct ClipContent: Codable, Hashable, Sendable {
    public let type: SupportedContentType
    public let text: String
    public let representations: ClipRepresentations

    public init(
        type: SupportedContentType,
        text: String,
        representations: ClipRepresentations = ClipRepresentations()
    ) throws {
        guard !text.isEmpty else {
            throw ClipboardLibraryError.emptyContent
        }
        self.type = type
        self.text = text
        self.representations = representations
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case representations
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            type: container.decode(SupportedContentType.self, forKey: .type),
            text: container.decode(String.self, forKey: .text),
            representations: container.decodeIfPresent(
                ClipRepresentations.self,
                forKey: .representations
            ) ?? ClipRepresentations()
        )
    }

    public static func detect(text: String) throws -> ClipContent {
        guard !text.isEmpty else {
            throw ClipboardLibraryError.emptyContent
        }

        let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let type: SupportedContentType
        if let components = URLComponents(string: candidate),
           let scheme = components.scheme?.lowercased(),
           ["http", "https"].contains(scheme),
           components.host?.isEmpty == false
        {
            type = .url
        } else {
            type = .plainText
        }
        let representations: ClipRepresentations
        if type == .url {
            representations = ClipRepresentations(
                url: URLClipMetadata(
                    originalURL: text,
                    host: URLComponents(string: candidate)?.host
                )
            )
        } else {
            representations = ClipRepresentations()
        }
        return try ClipContent(type: type, text: text, representations: representations)
    }

    /// Stable across launches and devices; equality is still checked when deduplicating.
    public var deduplicationFingerprint: String {
        let manifest = [type.rawValue, text, representations.identityManifest]
            .joined(separator: "\u{1d}")
        return SHA256.hash(data: Data(manifest.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    public var searchableText: String {
        [text, representations.ocrText].compactMap { $0 }.joined(separator: "\n")
    }

    public var estimatedStorageByteCount: Int {
        let uniqueAssets = Dictionary(
            representations.referencedAssets.map { ($0.relativePath, $0.byteCount) },
            uniquingKeysWith: { first, _ in first }
        )
        return text.utf8.count + uniqueAssets.values.reduce(0, +)
    }

    /// Notes are editable text, not containers for representations that an edit would silently
    /// discard. URL metadata is safe; rich text, image, file, and binary asset payloads are not.
    public var isSafelyConvertibleToNote: Bool {
        guard type == .plainText || type == .url else { return false }
        guard representations.referencedAssets.isEmpty,
              representations.files.isEmpty,
              representations.imageMetadata == nil,
              representations.ocrText == nil
        else { return false }
        if type == .plainText { return representations.url == nil }
        return true
    }

    /// Whether the canonical text can be used to create an explicitly reviewed, editable copy.
    /// Rich-text originals remain immutable because replacing their RTF/HTML representations
    /// in-place would lose formatting. Images, files, and OCR fallbacks are never treated as an
    /// editable source body.
    public var isSafelyEditableAsPlainTextCopy: Bool {
        guard type == .plainText || type == .url || type == .richText else { return false }
        guard representations.files.isEmpty,
              representations.image == nil,
              representations.thumbnail == nil,
              representations.imageMetadata == nil,
              representations.ocrText == nil
        else { return false }
        if type == .plainText { return representations.url == nil }
        if type == .url { return true }
        return representations.url == nil
    }
}

public struct HistoryItem: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let content: ClipContent
    public let createdAt: Date
    public var modifiedAt: Date
    public var lastCapturedAt: Date
    public var captureCount: Int
    public var sourceApplicationBundleIdentifier: String?
    public var originatingDeviceIdentifier: String?
    public var captureContext: ClipCaptureContext?
    public var sensitivity: ClipSensitivityMetadata?
    public var pasteboardTypeIdentifiers: [String]?
    public var pasteCount: Int?
    public var lastPastedAt: Date?
    public var deduplicationFingerprint: String {
        content.deduplicationFingerprint
    }

    public init(
        id: UUID = UUID(),
        content: ClipContent,
        createdAt: Date,
        modifiedAt: Date? = nil,
        lastCapturedAt: Date? = nil,
        captureCount: Int = 1,
        sourceApplicationBundleIdentifier: String? = nil,
        originatingDeviceIdentifier: String? = nil,
        captureContext: ClipCaptureContext? = nil,
        sensitivity: ClipSensitivityMetadata? = nil,
        pasteboardTypeIdentifiers: [String] = [],
        pasteCount: Int = 0,
        lastPastedAt: Date? = nil
    ) {
        self.id = id
        self.content = content
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt ?? createdAt
        self.lastCapturedAt = lastCapturedAt ?? createdAt
        self.captureCount = captureCount
        self.sourceApplicationBundleIdentifier = sourceApplicationBundleIdentifier
        self.originatingDeviceIdentifier = originatingDeviceIdentifier
        self.captureContext = captureContext
        self.sensitivity = sensitivity
        self.pasteboardTypeIdentifiers = normalizedTypeIdentifiers(pasteboardTypeIdentifiers)
        self.pasteCount = pasteCount
        self.lastPastedAt = lastPastedAt
    }
}

public enum SavedItemKind: String, Codable, CaseIterable, Sendable {
    case clip
    case note
}

/// Optimistic-concurrency token captured when an editor opens. Comparing all three fields avoids
/// overwriting a clip that moved or changed while the user was typing, even when timestamps collide.
public struct SavedClipEditExpectation: Equatable, Sendable {
    public let name: String
    public let modifiedAt: Date
    public let folderID: UUID?
    public let contentFingerprint: String

    public init(
        name: String,
        modifiedAt: Date,
        folderID: UUID?,
        contentFingerprint: String
    ) {
        self.name = name
        self.modifiedAt = modifiedAt
        self.folderID = folderID
        self.contentFingerprint = contentFingerprint
    }
}

public struct SavedClip: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var kind: SavedItemKind
    public var name: String
    /// Mutable only through `ClipboardLibrary` note operations so persistence remains atomic.
    public var content: ClipContent
    public var folderID: UUID?
    public let sourceHistoryItemID: UUID?
    /// Records what an edited item was derived from without pretending its current body is still
    /// the exact clipboard row. Missing in legacy snapshots and therefore optional.
    public var derivedFromHistoryItemID: UUID?
    public let createdAt: Date
    public var modifiedAt: Date
    public var pinnedAt: Date?
    public var tags: [String]?
    /// Provenance copied from the source history row so organizing a clip never discards where
    /// and when it originated. All fields remain optional for v1/v2 migration compatibility.
    public var sourceApplicationBundleIdentifier: String?
    public var originatingDeviceIdentifier: String?
    public var captureContext: ClipCaptureContext?
    public var originallyCapturedAt: Date?
    /// Preserved when a user explicitly keeps a detected secret in ordinary storage. This lets
    /// export and synchronization continue to fail closed after the source history row is saved.
    public var sensitivity: ClipSensitivityMetadata?
    public var pasteboardTypeIdentifiers: [String]?

    public init(
        id: UUID = UUID(),
        kind: SavedItemKind = .clip,
        name: String,
        content: ClipContent,
        folderID: UUID? = nil,
        sourceHistoryItemID: UUID? = nil,
        derivedFromHistoryItemID: UUID? = nil,
        createdAt: Date,
        modifiedAt: Date? = nil,
        pinnedAt: Date? = nil,
        tags: [String] = [],
        sourceApplicationBundleIdentifier: String? = nil,
        originatingDeviceIdentifier: String? = nil,
        captureContext: ClipCaptureContext? = nil,
        originallyCapturedAt: Date? = nil,
        sensitivity: ClipSensitivityMetadata? = nil,
        pasteboardTypeIdentifiers: [String] = []
    ) throws {
        self.id = id
        self.kind = kind
        self.name = try validatedName(name)
        self.content = content
        self.folderID = folderID
        self.sourceHistoryItemID = sourceHistoryItemID
        self.derivedFromHistoryItemID = derivedFromHistoryItemID
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt ?? createdAt
        self.pinnedAt = pinnedAt
        self.tags = tags
        self.sourceApplicationBundleIdentifier = sourceApplicationBundleIdentifier
        self.originatingDeviceIdentifier = originatingDeviceIdentifier
        self.captureContext = captureContext
        self.originallyCapturedAt = originallyCapturedAt
        self.sensitivity = sensitivity
        self.pasteboardTypeIdentifiers = normalizedTypeIdentifiers(pasteboardTypeIdentifiers)
    }

    public var isPinned: Bool { pinnedAt != nil }

    private enum CodingKeys: String, CodingKey {
        case id, kind, name, content, folderID, sourceHistoryItemID
        case derivedFromHistoryItemID, createdAt, modifiedAt, pinnedAt, tags
        case sourceApplicationBundleIdentifier, originatingDeviceIdentifier, captureContext
        case originallyCapturedAt, sensitivity, pasteboardTypeIdentifiers
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            kind: container.decodeIfPresent(SavedItemKind.self, forKey: .kind) ?? .clip,
            name: container.decode(String.self, forKey: .name),
            content: container.decode(ClipContent.self, forKey: .content),
            folderID: container.decodeIfPresent(UUID.self, forKey: .folderID),
            sourceHistoryItemID: container.decodeIfPresent(UUID.self, forKey: .sourceHistoryItemID),
            derivedFromHistoryItemID: container.decodeIfPresent(
                UUID.self,
                forKey: .derivedFromHistoryItemID
            ),
            createdAt: container.decode(Date.self, forKey: .createdAt),
            modifiedAt: container.decodeIfPresent(Date.self, forKey: .modifiedAt),
            pinnedAt: container.decodeIfPresent(Date.self, forKey: .pinnedAt),
            tags: container.decodeIfPresent([String].self, forKey: .tags) ?? [],
            sourceApplicationBundleIdentifier: container.decodeIfPresent(
                String.self,
                forKey: .sourceApplicationBundleIdentifier
            ),
            originatingDeviceIdentifier: container.decodeIfPresent(
                String.self,
                forKey: .originatingDeviceIdentifier
            ),
            captureContext: container.decodeIfPresent(ClipCaptureContext.self, forKey: .captureContext),
            originallyCapturedAt: container.decodeIfPresent(Date.self, forKey: .originallyCapturedAt),
            sensitivity: container.decodeIfPresent(ClipSensitivityMetadata.self, forKey: .sensitivity),
            pasteboardTypeIdentifiers: container.decodeIfPresent(
                [String].self,
                forKey: .pasteboardTypeIdentifiers
            ) ?? []
        )
    }
}

private func normalizedTypeIdentifiers(_ values: [String]) -> [String]? {
    let normalized = Set(values.compactMap { value -> String? in
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 255 else { return nil }
        return trimmed
    })
    .sorted()
    .prefix(64)
    return normalized.isEmpty ? nil : Array(normalized)
}

public struct ClipFolder: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var parentFolderID: UUID?
    public var sortOrder: Int
    public let createdAt: Date
    public var modifiedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        parentFolderID: UUID? = nil,
        sortOrder: Int,
        createdAt: Date,
        modifiedAt: Date? = nil
    ) throws {
        self.id = id
        self.name = try validatedName(name)
        self.parentFolderID = parentFolderID
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt ?? createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, parentFolderID, sortOrder, createdAt, modifiedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            name: container.decode(String.self, forKey: .name),
            parentFolderID: container.decodeIfPresent(UUID.self, forKey: .parentFolderID),
            sortOrder: container.decode(Int.self, forKey: .sortOrder),
            createdAt: container.decode(Date.self, forKey: .createdAt),
            modifiedAt: container.decodeIfPresent(Date.self, forKey: .modifiedAt)
        )
    }
}

public struct HistoryRetentionPolicy: Codable, Equatable, Sendable {
    /// `nil` means unlimited retention.
    public let maximumAge: TimeInterval?

    public init(maximumAge: TimeInterval?) throws {
        if let maximumAge, maximumAge <= 0 {
            throw ClipboardLibraryError.invalidRetentionDuration
        }
        self.maximumAge = maximumAge
    }

    private enum CodingKeys: String, CodingKey {
        case maximumAge
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            maximumAge: container.decodeIfPresent(TimeInterval.self, forKey: .maximumAge)
        )
    }

    public static let unlimited = try! HistoryRetentionPolicy(maximumAge: nil)
    public static let oneDay = try! HistoryRetentionPolicy(maximumAge: 24 * 60 * 60)
    public static let sevenDays = try! HistoryRetentionPolicy(maximumAge: 7 * 24 * 60 * 60)
    public static let thirtyDays = try! HistoryRetentionPolicy(maximumAge: 30 * 24 * 60 * 60)

    public func cutoff(relativeTo date: Date) -> Date? {
        maximumAge.map { date.addingTimeInterval(-$0) }
    }
}

public struct ClipboardLibrarySettings: Codable, Equatable, Sendable {
    public var capturePolicy: CapturePolicy
    public var retentionPolicy: HistoryRetentionPolicy
    public var maximumHistoryItemCount: Int?
    public var maximumAssetStorageBytes: Int?
    public var isSecretDetectionEnabled: Bool?
    public var isDeviceContextEnabled: Bool?
    public var isLocationContextEnabled: Bool?

    public init(
        capturePolicy: CapturePolicy = CapturePolicy(),
        retentionPolicy: HistoryRetentionPolicy = .thirtyDays,
        maximumHistoryItemCount: Int = 10_000,
        maximumAssetStorageBytes: Int = 512 * 1_024 * 1_024,
        isSecretDetectionEnabled: Bool = true,
        isDeviceContextEnabled: Bool = false,
        isLocationContextEnabled: Bool = false
    ) {
        self.capturePolicy = capturePolicy
        self.retentionPolicy = retentionPolicy
        self.maximumHistoryItemCount = maximumHistoryItemCount
        self.maximumAssetStorageBytes = maximumAssetStorageBytes
        self.isSecretDetectionEnabled = isSecretDetectionEnabled
        self.isDeviceContextEnabled = isDeviceContextEnabled
        self.isLocationContextEnabled = isLocationContextEnabled
    }

    public var effectiveMaximumHistoryItemCount: Int {
        max(100, maximumHistoryItemCount ?? 10_000)
    }

    public var effectiveMaximumAssetStorageBytes: Int {
        max(10 * 1_024 * 1_024, maximumAssetStorageBytes ?? 512 * 1_024 * 1_024)
    }

    public var effectiveSecretDetectionEnabled: Bool { isSecretDetectionEnabled ?? true }
    public var effectiveDeviceContextEnabled: Bool { isDeviceContextEnabled ?? false }
    public var effectiveLocationContextEnabled: Bool { isLocationContextEnabled ?? false }
}

public struct CaptureContextDeletionResult: Equatable, Sendable {
    public let historyItemCount: Int
    public let savedClipCount: Int

    public init(historyItemCount: Int, savedClipCount: Int) {
        self.historyItemCount = historyItemCount
        self.savedClipCount = savedClipCount
    }

    public var totalItemCount: Int { historyItemCount + savedClipCount }
}

/// A durable, transport-neutral hint written in the same transaction as a saved-library edit.
/// The sync layer acknowledges the exact value only after its own outbox has persisted it.
public struct PendingSavedLibraryMutation: Codable, Equatable, Hashable, Sendable {
    public enum EntityKind: String, Codable, Hashable, Sendable {
        case savedClip
        case folder
    }

    public let id: UUID
    public let kind: EntityKind
    public let isDeletion: Bool
    public let modifiedAt: Date
    /// Opaque acknowledgement identity. Timestamps are metadata, not uniqueness guarantees.
    public let token: UUID

    public init(
        id: UUID,
        kind: EntityKind,
        isDeletion: Bool,
        modifiedAt: Date,
        token: UUID = UUID()
    ) {
        self.id = id
        self.kind = kind
        self.isDeletion = isDeletion
        self.modifiedAt = modifiedAt
        self.token = token
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, isDeletion, modifiedAt, token
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            kind: try container.decode(EntityKind.self, forKey: .kind),
            isDeletion: try container.decode(Bool.self, forKey: .isDeletion),
            modifiedAt: try container.decode(Date.self, forKey: .modifiedAt),
            token: try container.decodeIfPresent(UUID.self, forKey: .token) ?? UUID()
        )
    }
}

public struct ClipboardLibrarySnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 3

    public var schemaVersion: Int
    public var history: [HistoryItem]
    public var savedClips: [SavedClip]
    public var folders: [ClipFolder]
    public var settings: ClipboardLibrarySettings
    public var pendingSavedLibraryMutations: [PendingSavedLibraryMutation]

    public init(
        schemaVersion: Int = currentSchemaVersion,
        history: [HistoryItem] = [],
        savedClips: [SavedClip] = [],
        folders: [ClipFolder] = [],
        settings: ClipboardLibrarySettings = ClipboardLibrarySettings(),
        pendingSavedLibraryMutations: [PendingSavedLibraryMutation] = []
    ) {
        self.schemaVersion = schemaVersion
        self.history = history
        self.savedClips = savedClips
        self.folders = folders
        self.settings = settings
        self.pendingSavedLibraryMutations = pendingSavedLibraryMutations
    }

    public static let empty = ClipboardLibrarySnapshot()

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case history
        case savedClips
        case folders
        case settings
        case pendingSavedLibraryMutations
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedVersion = try container.decode(Int.self, forKey: .schemaVersion)
        schemaVersion = (1...2).contains(decodedVersion) ? Self.currentSchemaVersion : decodedVersion
        history = try container.decode([HistoryItem].self, forKey: .history)
        savedClips = try container.decode([SavedClip].self, forKey: .savedClips)
        folders = try container.decode([ClipFolder].self, forKey: .folders)
        settings = try container.decode(ClipboardLibrarySettings.self, forKey: .settings)
        pendingSavedLibraryMutations = try container.decodeIfPresent(
            [PendingSavedLibraryMutation].self,
            forKey: .pendingSavedLibraryMutations
        ) ?? []
    }
}

public enum ClipboardLibraryError: Error, Equatable, LocalizedError, Sendable {
    case emptyContent
    case emptyName
    case invalidRetentionDuration
    case historyItemNotFound(UUID)
    case savedClipNotFound(UUID)
    case folderNotFound(UUID)
    case duplicateFolderName(String)
    case invalidFolderIndex(Int)
    case invalidFolderParent(UUID)
    case folderCycle(UUID)
    case savedItemIsNotNote(UUID)
    case savedItemIsNotEditableClip(UUID)
    case unsupportedNoteConversion(UUID)
    case unsupportedClipEditing(UUID)
    case savedItemChangedDuringEdit(UUID)
    case combinedClipSourceChanged(UUID)
    case duplicateIdentifier(UUID)
    case duplicatePendingMutation(UUID, PendingSavedLibraryMutation.EntityKind)
    case unsupportedSchemaVersion(Int)
    case invalidCaptureCount(UUID)
    case invalidAssetReference
    case invalidImageMetadata
    case invalidFileReference
    case invalidLocationContext
    case invalidSensitivityMetadata
    case ordinaryVaultMoveSourceChanged(UUID)
    case ordinaryVaultMoveForbiddenFolder(UUID)
    case ordinaryVaultMoveScopeChanged(UUID)

    public var errorDescription: String? {
        switch self {
        case .emptyContent:
            "Clipboard content cannot be empty."
        case .emptyName:
            "Names cannot be empty."
        case .invalidRetentionDuration:
            "Retention duration must be greater than zero."
        case let .historyItemNotFound(id):
            "History item \(id) was not found."
        case let .savedClipNotFound(id):
            "Saved clip \(id) was not found."
        case let .folderNotFound(id):
            "Folder \(id) was not found."
        case let .duplicateFolderName(name):
            "A folder named \"\(name)\" already exists."
        case let .invalidFolderIndex(index):
            "Folder index \(index) is out of range."
        case let .invalidFolderParent(id):
            "Folder \(id) cannot be used as that parent."
        case let .folderCycle(id):
            "Moving folder \(id) would create a folder cycle."
        case let .savedItemIsNotNote(id):
            "Saved item \(id) is not a note."
        case let .savedItemIsNotEditableClip(id):
            "Saved item \(id) is not an editable clip."
        case let .unsupportedNoteConversion(id):
            "Item \(id) contains non-text representations that cannot become an editable note."
        case let .unsupportedClipEditing(id):
            "Item \(id) contains rich media or attached assets that cannot be safely edited as text."
        case let .savedItemChangedDuringEdit(id):
            "Saved item \(id) changed while it was being edited. Review the latest version and try again."
        case let .combinedClipSourceChanged(id):
            "Combined clip \(id) changed after review. Review the collection and try again."
        case let .duplicateIdentifier(id):
            "Identifier \(id) occurs more than once in its collection."
        case let .duplicatePendingMutation(id, kind):
            "Pending \(kind.rawValue) mutation \(id) occurs more than once."
        case let .unsupportedSchemaVersion(version):
            "Library schema version \(version) is unsupported."
        case let .invalidCaptureCount(id):
            "History item \(id) has an invalid capture count."
        case .invalidAssetReference:
            "The clip asset reference is invalid."
        case .invalidImageMetadata:
            "The image dimensions or format are invalid."
        case .invalidFileReference:
            "Only local file references are supported."
        case .invalidLocationContext:
            "The optional clip location must be coarse and have a label."
        case .invalidSensitivityMetadata:
            "The sensitivity metadata is invalid."
        case let .ordinaryVaultMoveSourceChanged(id):
            "Ordinary clip \(id) changed after Vault encryption. Nothing was removed."
        case let .ordinaryVaultMoveForbiddenFolder(id):
            "Ordinary clip \(id) is now in a collaborative folder. Nothing was removed."
        case let .ordinaryVaultMoveScopeChanged(id):
            "The linked Saved copies for \(id) changed after confirmation. Nothing was removed."
        }
    }
}

func validatedName(_ rawName: String) throws -> String {
    let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else {
        throw ClipboardLibraryError.emptyName
    }
    return name
}

func defaultSavedClipName(for content: ClipContent) -> String {
    let firstLine = content.text
        .split(whereSeparator: \Character.isNewline)
        .first
        .map(String.init)?
        .trimmingCharacters(in: .whitespacesAndNewlines)

    let base = firstLine.flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled Clip"
    return String(base.prefix(80))
}
