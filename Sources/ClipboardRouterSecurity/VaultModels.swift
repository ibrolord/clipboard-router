import ClipboardRouterCore
import Foundation
import Security

/// An encrypted exact snapshot used as deletion proof during Vault move recovery. Equality is
/// deliberately stronger than an ID/content hash: organizing, renaming, pinning, or changing any
/// captured provenance after encryption invalidates cleanup for that row.
public struct VaultSavedClipFingerprint: Codable, Equatable, Sendable {
    public let clip: SavedClip

    public init(_ clip: SavedClip) { self.clip = clip }
    public func exactlyMatches(_ candidate: SavedClip) -> Bool {
        vaultFingerprintCanonicalized(candidate) == clip
    }
}

public struct VaultHistoryItemFingerprint: Codable, Equatable, Sendable {
    public let item: HistoryItem

    public init(_ item: HistoryItem) { self.item = item }
    public func exactlyMatches(_ candidate: HistoryItem) -> Bool {
        vaultFingerprintCanonicalized(candidate) == item
    }
}

/// Vault's authenticated JSON uses millisecond dates. Canonicalizing the current ordinary row
/// before comparison avoids treating sub-millisecond process-local precision as a content change,
/// while every persisted field still has to match exactly.
private func vaultFingerprintCanonicalized<Value: Codable>(_ value: Value) -> Value? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .millisecondsSince1970
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    guard let data = try? encoder.encode(value) else { return nil }
    return try? decoder.decode(Value.self, from: data)
}

/// Encrypted, authenticated provenance for an ordinary item moved into Vault. It is part of the
/// `VaultItem` ciphertext, never the cleartext envelope, and gives crash reconciliation enough
/// evidence to remove only the exact History/Saved sources that produced the encrypted item.
public struct VaultItemProvenance: Codable, Equatable, Sendable {
    public enum OrdinaryOrigin: String, Codable, Equatable, Sendable {
        case history
        case saved
    }

    public let ordinaryOrigin: OrdinaryOrigin
    public let sourceHistoryItemID: UUID?
    public let sourceSavedClipID: UUID?
    /// Legacy IDs remain for decoding already-encrypted items. New recovery code never deletes a
    /// SavedClip from these IDs alone; it requires the exact fingerprints below.
    public let linkedSavedClipIDs: [UUID]
    public let sourceHistoryFingerprint: VaultHistoryItemFingerprint?
    public let linkedSavedClipFingerprints: [VaultSavedClipFingerprint]?
    public let sourceFolderID: UUID?
    public let sourcePinnedAt: Date?
    public let sourceApplicationBundleIdentifier: String?
    public let originatingDeviceIdentifier: String?
    public let captureContext: ClipCaptureContext?
    public let originallyCapturedAt: Date?
    public let sensitivity: ClipSensitivityMetadata?
    public let pasteboardTypeIdentifiers: [String]

    public init(
        ordinaryOrigin: OrdinaryOrigin,
        sourceHistoryItemID: UUID? = nil,
        sourceSavedClipID: UUID? = nil,
        linkedSavedClipIDs: [UUID] = [],
        sourceHistoryFingerprint: VaultHistoryItemFingerprint? = nil,
        linkedSavedClipFingerprints: [VaultSavedClipFingerprint]? = nil,
        sourceFolderID: UUID? = nil,
        sourcePinnedAt: Date? = nil,
        sourceApplicationBundleIdentifier: String? = nil,
        originatingDeviceIdentifier: String? = nil,
        captureContext: ClipCaptureContext? = nil,
        originallyCapturedAt: Date? = nil,
        sensitivity: ClipSensitivityMetadata? = nil,
        pasteboardTypeIdentifiers: [String] = []
    ) {
        self.ordinaryOrigin = ordinaryOrigin
        self.sourceHistoryItemID = sourceHistoryItemID
        self.sourceSavedClipID = sourceSavedClipID
        self.linkedSavedClipIDs = Array(Set(linkedSavedClipIDs)).sorted {
            $0.uuidString < $1.uuidString
        }
        self.sourceHistoryFingerprint = sourceHistoryFingerprint
        self.linkedSavedClipFingerprints = linkedSavedClipFingerprints.map { fingerprints in
            var unique: [UUID: VaultSavedClipFingerprint] = [:]
            for fingerprint in fingerprints { unique[fingerprint.clip.id] = fingerprint }
            return unique.values.sorted { $0.clip.id.uuidString < $1.clip.id.uuidString }
        }
        self.sourceFolderID = sourceFolderID
        self.sourcePinnedAt = sourcePinnedAt
        self.sourceApplicationBundleIdentifier = sourceApplicationBundleIdentifier
        self.originatingDeviceIdentifier = originatingDeviceIdentifier
        self.captureContext = captureContext
        self.originallyCapturedAt = originallyCapturedAt
        self.sensitivity = sensitivity
        self.pasteboardTypeIdentifiers = Array(Set(pasteboardTypeIdentifiers)).sorted()
    }
}

public struct VaultItem: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    /// Authenticated inside the ciphertext. This is intentionally absent from the clear envelope.
    public let kind: SavedItemKind
    public var name: String
    public let content: ClipContent
    /// Manifest for every original binary representation. It is encrypted with the item and maps
    /// the ordinary content-addressed references to opaque Vault ciphertext files.
    public let assets: [VaultAssetDescriptor]
    public let createdAt: Date
    public var modifiedAt: Date
    public let provenance: VaultItemProvenance?

    public init(
        id: UUID = UUID(),
        kind: SavedItemKind = .clip,
        name: String,
        content: ClipContent,
        assets: [VaultAssetDescriptor]? = nil,
        createdAt: Date = Date(),
        modifiedAt: Date? = nil,
        provenance: VaultItemProvenance? = nil
    ) throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw VaultError.emptyName }
        let structuredURL: URL?
        if let originalURL = content.representations.url?.originalURL {
            structuredURL = URL(string: originalURL)
        } else {
            structuredURL = nil
        }
        let displayedURL = content.type == .url
            ? URL(string: content.text.trimmingCharacters(in: .whitespacesAndNewlines))
            : nil
        guard structuredURL?.isFileURL != true,
              displayedURL?.isFileURL != true
        else { throw VaultError.unsupportedExternalRepresentations }

        let references = content.representations.referencedAssets.sorted {
            if $0.kind.rawValue != $1.kind.rawValue {
                return $0.kind.rawValue < $1.kind.rawValue
            }
            return $0.digest < $1.digest
        }
        guard references.count <= VaultAssetPolicy.maximumAssetCount else {
            throw VaultError.tooManyAssets(references.count)
        }
        let totalBytes = references.reduce(into: 0) { total, reference in
            let (next, overflow) = total.addingReportingOverflow(reference.byteCount)
            total = overflow ? Int.max : next
        }
        guard totalBytes <= VaultAssetPolicy.maximumItemAssetBytes else {
            throw VaultError.assetTooLarge(totalBytes)
        }
        let expectedAssets = try references.map {
            try VaultAssetDescriptor(itemID: id, reference: $0)
        }
        let resolvedAssets = assets ?? expectedAssets
        guard resolvedAssets == expectedAssets else { throw VaultError.invalidAssetManifest }

        switch content.type {
        case .plainText:
            guard references.isEmpty,
                  content.representations.files.isEmpty,
                  content.representations.url == nil
            else { throw VaultError.unsupportedExternalRepresentations }
        case .url:
            guard references.isEmpty, content.representations.files.isEmpty else {
                throw VaultError.unsupportedExternalRepresentations
            }
        case .richText:
            guard content.representations.richText != nil
                    || content.representations.html != nil,
                  content.representations.image == nil,
                  content.representations.files.isEmpty
            else { throw VaultError.unsupportedExternalRepresentations }
        case .image:
            guard content.representations.image != nil,
                  content.representations.richText == nil,
                  content.representations.html == nil,
                  content.representations.files.isEmpty
            else { throw VaultError.unsupportedExternalRepresentations }
        case .fileURLs:
            guard references.isEmpty,
                  !content.representations.files.isEmpty,
                  content.representations.files.count <= 64,
                  content.representations.files.allSatisfy({
                      $0.url.isFileURL && $0.url.absoluteString.utf8.count <= 4_096
                  })
            else { throw VaultError.unsupportedExternalRepresentations }
        }
        self.id = id
        self.kind = kind
        self.name = trimmedName
        self.content = content
        self.assets = resolvedAssets
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt ?? createdAt
        self.provenance = provenance
    }

    public static func supports(_ content: ClipContent) -> Bool {
        (try? VaultItem(name: "Supported content", content: content)) != nil
    }

    /// Compares the complete authenticated representation that Vault persists. This is used only
    /// to resume an interrupted move after decrypting an existing envelope.
    public func exactlyMatchesMoveManifest(_ candidate: VaultItem) -> Bool {
        vaultFingerprintCanonicalized(self) == vaultFingerprintCanonicalized(candidate)
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, name, content, assets, createdAt, modifiedAt, provenance
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            kind: container.decodeIfPresent(SavedItemKind.self, forKey: .kind) ?? .clip,
            name: container.decode(String.self, forKey: .name),
            content: container.decode(ClipContent.self, forKey: .content),
            assets: container.decodeIfPresent([VaultAssetDescriptor].self, forKey: .assets),
            createdAt: container.decode(Date.self, forKey: .createdAt),
            modifiedAt: container.decode(Date.self, forKey: .modifiedAt),
            provenance: container.decodeIfPresent(VaultItemProvenance.self, forKey: .provenance)
        )
    }
}

/// Only ciphertext and non-sensitive routing metadata are persisted.
/// `id` and `version` are authenticated as AES-GCM additional authenticated data.
public struct VaultCiphertextEnvelope: Codable, Equatable, Identifiable, Sendable {
    public static let currentVersion = 2

    public let id: UUID
    public let version: Int
    public let nonce: Data
    public let ciphertext: Data
    public let tag: Data

    public init(id: UUID, version: Int, nonce: Data, ciphertext: Data, tag: Data) {
        self.id = id
        self.version = version
        self.nonce = nonce
        self.ciphertext = ciphertext
        self.tag = tag
    }
}

public struct VaultStoreSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var envelopes: [VaultCiphertextEnvelope]

    public init(
        schemaVersion: Int = currentSchemaVersion,
        envelopes: [VaultCiphertextEnvelope] = []
    ) {
        self.schemaVersion = schemaVersion
        self.envelopes = envelopes
    }

    public static let empty = VaultStoreSnapshot()
}

public enum VaultLifecycleEvent: Sendable {
    case appDidEnterBackground
    case screenDidLock
    case systemWillSleep
    case appWillTerminate
}

public enum VaultError: Error, Equatable, LocalizedError, Sendable {
    case emptyName
    case locked
    case authenticationFailed
    case keyStateUnprepared
    case missingKeyForExistingVault
    case invalidKeyLength
    case invalidEnvelope
    case unsupportedEnvelopeVersion(Int)
    case itemIdentityMismatch
    case duplicateItem(UUID)
    case itemNotFound(UUID)
    case unsupportedExternalRepresentations
    case invalidAssetManifest
    case tooManyAssets(Int)
    case assetTooLarge(Int)
    case missingAsset(String)
    case assetDigestMismatch(String)
    case invalidAssetEnvelope
    case unsupportedStoreVersion(Int)
    case keychainFailure(Int32)
    case unreadableStore(String)
    case undecodableStore(String)
    case unwritableStore(String)
    case migrationConflict

    public var errorDescription: String? {
        switch self {
        case .emptyName: "Vault item names cannot be empty."
        case .locked: "The vault is locked."
        case .authenticationFailed: "Vault authentication failed."
        case .keyStateUnprepared: "The vault key state was not prepared from its encrypted store."
        case .missingKeyForExistingVault:
            "The vault encryption key is missing. Existing ciphertext cannot be recovered without it."
        case .invalidKeyLength: "The vault encryption key is invalid."
        case .invalidEnvelope: "The vault item is damaged or was modified."
        case let .unsupportedEnvelopeVersion(version):
            "Vault envelope version \(version) is unsupported."
        case .itemIdentityMismatch: "The decrypted vault item does not match its envelope."
        case let .duplicateItem(id): "Vault item \(id) appears more than once."
        case let .itemNotFound(id): "Vault item \(id) was not found."
        case .unsupportedExternalRepresentations:
            "This clip's typed representations are invalid or unsafe for Vault. Its ordinary copy was not changed."
        case .invalidAssetManifest:
            "The encrypted Vault asset manifest is invalid."
        case let .tooManyAssets(count):
            "This clip has too many binary representations for Vault (\(count))."
        case let .assetTooLarge(size):
            "This clip's encrypted asset payload is too large (\(size) bytes)."
        case let .missingAsset(identifier):
            "Encrypted Vault asset \(identifier) is missing."
        case let .assetDigestMismatch(identifier):
            "Encrypted Vault asset \(identifier) failed integrity verification."
        case .invalidAssetEnvelope:
            "An encrypted Vault asset is damaged or was modified."
        case let .unsupportedStoreVersion(version):
            "Vault store schema version \(version) is unsupported."
        case let .keychainFailure(status) where status == errSecMissingEntitlement:
            "Vault is unavailable in this build. Install an Apple Developer-signed build authorized for secure Keychain access."
        case let .keychainFailure(status): "Keychain operation failed (OSStatus \(status))."
        case let .unreadableStore(reason): "The encrypted vault store cannot be read: \(reason)"
        case let .undecodableStore(reason): "The encrypted vault store cannot be decoded: \(reason)"
        case let .unwritableStore(reason): "The encrypted vault store cannot be written: \(reason)"
        case .migrationConflict: "The vault migration journal conflicts with this migration."
        }
    }
}
