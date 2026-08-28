import CryptoKit
import Foundation

public enum ClipAssetKind: String, Codable, CaseIterable, Sendable {
    case richText
    case html
    case image
    case thumbnail
    case pdf
}

public struct ClipAssetReference: Codable, Hashable, Sendable {
    public let digest: String
    public let kind: ClipAssetKind
    public let uniformTypeIdentifier: String
    public let byteCount: Int
    public let relativePath: String

    public init(
        digest: String,
        kind: ClipAssetKind,
        uniformTypeIdentifier: String,
        byteCount: Int,
        relativePath: String
    ) throws {
        let normalizedDigest = digest.lowercased()
        guard normalizedDigest.count == 64,
              normalizedDigest.allSatisfy({ $0.isHexDigit }),
              byteCount > 0,
              !relativePath.isEmpty,
              !relativePath.contains(".."),
              !relativePath.hasPrefix("/")
        else {
            throw ClipboardLibraryError.invalidAssetReference
        }
        self.digest = normalizedDigest
        self.kind = kind
        self.uniformTypeIdentifier = uniformTypeIdentifier
        self.byteCount = byteCount
        self.relativePath = relativePath
    }
}

public struct URLClipMetadata: Codable, Hashable, Sendable {
    public let originalURL: String
    public let host: String?
    public let title: String?

    public init(originalURL: String, host: String? = nil, title: String? = nil) {
        self.originalURL = originalURL
        self.host = host
        self.title = title
    }
}

public struct ClipImageMetadata: Codable, Hashable, Sendable {
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let format: String
    /// Encoded byte count of the original image representation, excluding the local thumbnail.
    public let byteCount: Int?

    public init(
        pixelWidth: Int,
        pixelHeight: Int,
        format: String,
        byteCount: Int? = nil
    ) throws {
        guard pixelWidth > 0,
              pixelHeight > 0,
              !format.isEmpty,
              byteCount.map({ $0 > 0 }) ?? true
        else {
            throw ClipboardLibraryError.invalidImageMetadata
        }
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.format = format
        self.byteCount = byteCount
    }
}

public struct ClipFileReference: Codable, Hashable, Sendable {
    public let url: URL
    public let displayName: String

    public init(url: URL, displayName: String? = nil) throws {
        guard url.isFileURL else { throw ClipboardLibraryError.invalidFileReference }
        self.url = url.standardizedFileURL
        self.displayName = displayName ?? url.lastPathComponent
    }
}

/// A clipboard event can carry several representations at the same time. Binary values are
/// content-addressed assets; OCR is derived metadata and deliberately does not affect identity.
public struct ClipRepresentations: Codable, Hashable, Sendable {
    public var richText: ClipAssetReference?
    public var html: ClipAssetReference?
    public var image: ClipAssetReference?
    public var thumbnail: ClipAssetReference?
    public var imageMetadata: ClipImageMetadata?
    public var files: [ClipFileReference]
    public var url: URLClipMetadata?
    public var ocrText: String?

    public init(
        richText: ClipAssetReference? = nil,
        html: ClipAssetReference? = nil,
        image: ClipAssetReference? = nil,
        thumbnail: ClipAssetReference? = nil,
        imageMetadata: ClipImageMetadata? = nil,
        files: [ClipFileReference] = [],
        url: URLClipMetadata? = nil,
        ocrText: String? = nil
    ) {
        self.richText = richText
        self.html = html
        self.image = image
        self.thumbnail = thumbnail
        self.imageMetadata = imageMetadata
        self.files = files
        self.url = url
        self.ocrText = ocrText
    }

    var identityManifest: String {
        [
            richText.map { "rtf:\($0.digest)" },
            html.map { "html:\($0.digest)" },
            image.map { "image:\($0.digest)" },
            files.isEmpty ? nil : "files:" + files.map(\.url.absoluteString).joined(separator: "\u{1f}"),
            url.map { "url:\($0.originalURL)" },
        ]
        .compactMap { $0 }
        .joined(separator: "\u{1e}")
    }

    public var referencedAssets: Set<ClipAssetReference> {
        Set([richText, html, image, thumbnail].compactMap { $0 })
    }
}

public struct CoarseLocationContext: Codable, Hashable, Sendable {
    public let label: String
    /// Deliberately coarse geohash. Precise coordinates are never stored in a clip.
    public let geohash: String?

    public init(label: String, geohash: String? = nil) throws {
        let cleanLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanLabel.isEmpty, geohash.map({ $0.count <= 5 }) ?? true else {
            throw ClipboardLibraryError.invalidLocationContext
        }
        self.label = cleanLabel
        self.geohash = geohash
    }
}

public struct ClipCaptureContext: Codable, Hashable, Sendable {
    public var sourceApplicationName: String?
    public var sourceURL: String?
    public var sourceDomain: String?
    public var deviceLabel: String?
    public var operatingSystem: String?
    public var coarseLocation: CoarseLocationContext?

    public init(
        sourceApplicationName: String? = nil,
        sourceURL: String? = nil,
        sourceDomain: String? = nil,
        deviceLabel: String? = nil,
        operatingSystem: String? = nil,
        coarseLocation: CoarseLocationContext? = nil
    ) {
        self.sourceApplicationName = sourceApplicationName
        self.sourceURL = sourceURL
        self.sourceDomain = sourceDomain
        self.deviceLabel = deviceLabel
        self.operatingSystem = operatingSystem
        self.coarseLocation = coarseLocation
    }
}

public struct ClipSensitivityMetadata: Codable, Hashable, Sendable {
    public let category: String
    public let confidence: Int
    public let detectorVersion: Int

    public init(category: String, confidence: Int, detectorVersion: Int) throws {
        guard !category.isEmpty, (0...100).contains(confidence), detectorVersion > 0 else {
            throw ClipboardLibraryError.invalidSensitivityMetadata
        }
        self.category = category
        self.confidence = confidence
        self.detectorVersion = detectorVersion
    }
}
