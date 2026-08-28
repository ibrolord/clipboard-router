import ClipboardRouterCore
import AppKit
import Foundation
import ImageIO

public struct PasteboardCaptureLimits: Equatable, Sendable {
    public var maximumTotalBytes: Int
    public var maximumPlainTextBytes: Int
    public var maximumURLBytes: Int
    public var maximumRichTextBytes: Int
    public var maximumHTMLBytes: Int
    public var maximumImageBytes: Int
    public var maximumFileURLBytes: Int
    public var maximumFileURLCount: Int

    public init(
        maximumTotalBytes: Int = 16 * 1_024 * 1_024,
        maximumPlainTextBytes: Int = 2 * 1_024 * 1_024,
        maximumURLBytes: Int = 64 * 1_024,
        maximumRichTextBytes: Int = 4 * 1_024 * 1_024,
        maximumHTMLBytes: Int = 4 * 1_024 * 1_024,
        maximumImageBytes: Int = 12 * 1_024 * 1_024,
        maximumFileURLBytes: Int = 64 * 1_024,
        maximumFileURLCount: Int = 64
    ) {
        precondition(
            [
                maximumTotalBytes,
                maximumPlainTextBytes,
                maximumURLBytes,
                maximumRichTextBytes,
                maximumHTMLBytes,
                maximumImageBytes,
                maximumFileURLBytes,
                maximumFileURLCount,
            ].allSatisfy { $0 > 0 },
            "Pasteboard capture limits must be positive."
        )
        self.maximumTotalBytes = maximumTotalBytes
        self.maximumPlainTextBytes = maximumPlainTextBytes
        self.maximumURLBytes = maximumURLBytes
        self.maximumRichTextBytes = maximumRichTextBytes
        self.maximumHTMLBytes = maximumHTMLBytes
        self.maximumImageBytes = maximumImageBytes
        self.maximumFileURLBytes = maximumFileURLBytes
        self.maximumFileURLCount = maximumFileURLCount
    }

    public static let `default` = PasteboardCaptureLimits()
}

public enum PasteboardCaptureLimitKind: String, Equatable, Sendable {
    case total
    case plainText
    case url
    case richText
    case html
    case image
    case fileURL
    case fileURLCount
}

public struct PasteboardImageDraft: Equatable, Sendable {
    public let data: Data
    public let uniformTypeIdentifier: String

    public init(data: Data, uniformTypeIdentifier: String) {
        self.data = data
        self.uniformTypeIdentifier = uniformTypeIdentifier
    }
}

public struct PasteboardImageMaterializationLimits: Equatable, Sendable {
    public var maximumSourceBytes: Int
    public var maximumPixelCount: Int
    public var maximumThumbnailPixelSize: Int
    public var maximumThumbnailBytes: Int

    public init(
        maximumSourceBytes: Int = 12 * 1_024 * 1_024,
        maximumPixelCount: Int = 100_000_000,
        maximumThumbnailPixelSize: Int = 320,
        maximumThumbnailBytes: Int = 1 * 1_024 * 1_024
    ) {
        precondition(
            maximumSourceBytes > 0
                && maximumPixelCount > 0
                && maximumThumbnailPixelSize > 0
                && maximumThumbnailBytes > 0,
            "Image materialization limits must be positive."
        )
        self.maximumSourceBytes = maximumSourceBytes
        self.maximumPixelCount = maximumPixelCount
        self.maximumThumbnailPixelSize = maximumThumbnailPixelSize
        self.maximumThumbnailBytes = maximumThumbnailBytes
    }

    public static let `default` = PasteboardImageMaterializationLimits()
}

public enum PasteboardCaptureMaterializationError: Error, Equatable, LocalizedError, Sendable {
    case imageTooLarge(actual: Int, maximum: Int)
    case invalidImage
    case imageDimensionsTooLarge(width: Int, height: Int, maximumPixels: Int)
    case thumbnailEncodingFailed
    case thumbnailTooLarge(actual: Int, maximum: Int)

    public var errorDescription: String? {
        switch self {
        case let .imageTooLarge(actual, maximum):
            "The image is \(actual) bytes; the capture limit is \(maximum) bytes."
        case .invalidImage:
            "The clipboard image is malformed or uses an unsupported format."
        case let .imageDimensionsTooLarge(width, height, maximumPixels):
            "The image dimensions \(width) × \(height) exceed the \(maximumPixels)-pixel safety limit."
        case .thumbnailEncodingFailed:
            "Clipboard Router could not create a local image thumbnail."
        case let .thumbnailTooLarge(actual, maximum):
            "The generated thumbnail is \(actual) bytes; the limit is \(maximum) bytes."
        }
    }
}

public struct PasteboardCaptureSource: Equatable, Sendable {
    public let applicationBundleIdentifier: String?
    public let applicationName: String?
    public let sourceURL: URL?
    public let sourceDomain: String?

    public init(
        applicationBundleIdentifier: String? = nil,
        applicationName: String? = nil,
        sourceURL: URL? = nil,
        sourceDomain: String? = nil
    ) {
        self.applicationBundleIdentifier = applicationBundleIdentifier
        self.applicationName = applicationName
        self.sourceURL = sourceURL
        self.sourceDomain = sourceDomain
    }

    public var clipCaptureContext: ClipCaptureContext {
        ClipCaptureContext(
            sourceApplicationName: applicationName,
            sourceURL: sourceURL?.absoluteString,
            sourceDomain: sourceDomain
        )
    }
}

/// A single in-memory snapshot of one pasteboard generation. Raw payload bytes have no asset
/// references and are never persisted by the monitor. Callers must apply sensitivity policy before
/// invoking `PasteboardCaptureMaterializer`.
public struct PasteboardCaptureDraft: Equatable, Sendable {
    public let changeCount: Int
    public let typeIdentifiers: Set<String>
    public let plainText: String?
    public let url: URL?
    public let richTextData: Data?
    public let htmlData: Data?
    public let image: PasteboardImageDraft?
    public let fileURLs: [URL]
    public let source: PasteboardCaptureSource
    public let capturedAt: Date

    public init(
        changeCount: Int,
        typeIdentifiers: Set<String>,
        plainText: String? = nil,
        url: URL? = nil,
        richTextData: Data? = nil,
        htmlData: Data? = nil,
        image: PasteboardImageDraft? = nil,
        fileURLs: [URL] = [],
        source: PasteboardCaptureSource = PasteboardCaptureSource(),
        capturedAt: Date = Date()
    ) {
        self.changeCount = changeCount
        self.typeIdentifiers = typeIdentifiers
        self.plainText = plainText
        self.url = url
        self.richTextData = richTextData
        self.htmlData = htmlData
        self.image = image
        self.fileURLs = fileURLs.map(\.standardizedFileURL)
        self.source = source
        self.capturedAt = capturedAt
    }

    public var isEmpty: Bool {
        plainText == nil
            && url == nil
            && richTextData == nil
            && htmlData == nil
            && image == nil
            && fileURLs.isEmpty
    }

    /// Returns every textual representation that must be inspected before the draft may reach
    /// an asset store, search index, sync outbox, export, or ordinary history. The monitor keeps
    /// the draft in memory until the caller has classified this combined value.
    public func textForSensitivityAnalysis(ocrText: String? = nil) -> String {
        var values: [String] = []
        func append(_ value: String?) {
            guard let value else { return }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !values.contains(trimmed) else { return }
            values.append(trimmed)
        }

        append(plainText)
        if let richTextData {
            append(NSAttributedString(rtf: richTextData, documentAttributes: nil)?.string)
            append(String(data: richTextData, encoding: .utf8))
        }
        if let htmlData {
            // Scan the raw markup as well as visible text. Tokens in attributes or source must
            // not evade classification merely because they are not rendered.
            append(String(data: htmlData, encoding: .utf8))
            append(
                try? NSAttributedString(
                    data: htmlData,
                    options: [.documentType: NSAttributedString.DocumentType.html],
                    documentAttributes: nil
                ).string
            )
        }
        append(url?.absoluteString)
        for fileURL in fileURLs { append(fileURL.absoluteString) }
        append(ocrText)
        if values.isEmpty, image != nil { append("[Image]") }
        return values.joined(separator: "\n")
    }

    func replacingSource(_ source: PasteboardCaptureSource) -> PasteboardCaptureDraft {
        PasteboardCaptureDraft(
            changeCount: changeCount,
            typeIdentifiers: typeIdentifiers,
            plainText: plainText,
            url: url,
            richTextData: richTextData,
            htmlData: htmlData,
            image: image,
            fileURLs: fileURLs,
            source: source,
            capturedAt: capturedAt
        )
    }

    func legacyCaptureCandidate() -> CaptureCandidate? {
        let fallback = Self.nonempty(plainText) ?? url?.absoluteString
        guard let fallback, let content = try? ClipContent.detect(text: fallback) else { return nil }
        return CaptureCandidate(
            content: content,
            sourceApplicationBundleIdentifier: source.applicationBundleIdentifier,
            captureContext: source.clipCaptureContext,
            pasteboardTypeIdentifiers: typeIdentifiers,
            capturedAt: capturedAt
        )
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

public enum PasteboardDraftReadOutcome: Equatable, Sendable {
    case captured(PasteboardCaptureDraft)
    case noSupportedContent
    case generationChanged
    case limitExceeded(PasteboardCaptureLimitKind)
    case invalidPayload
}

@MainActor
public protocol PasteboardSourceContextProviding: AnyObject {
    func sourceContext(
        applicationBundleIdentifier: String?,
        applicationName: String?,
        explicitPayloadURL: URL?
    ) -> PasteboardCaptureSource
}

@MainActor
public final class DefaultPasteboardSourceContextProvider: PasteboardSourceContextProviding {
    public init() {}

    public func sourceContext(
        applicationBundleIdentifier: String?,
        applicationName: String?,
        explicitPayloadURL: URL?
    ) -> PasteboardCaptureSource {
        let sourceURL: URL?
        if let explicitPayloadURL,
           let scheme = explicitPayloadURL.scheme?.lowercased(),
           ["http", "https"].contains(scheme)
        {
            sourceURL = explicitPayloadURL
        } else {
            sourceURL = nil
        }
        return PasteboardCaptureSource(
            applicationBundleIdentifier: applicationBundleIdentifier,
            applicationName: applicationName,
            sourceURL: sourceURL,
            sourceDomain: sourceURL?.host
        )
    }
}

public struct PasteboardCaptureMaterializer: Sendable {
    private let assetStore: any ClipAssetStoring
    private let imageLimits: PasteboardImageMaterializationLimits

    public init(
        assetStore: any ClipAssetStoring,
        imageLimits: PasteboardImageMaterializationLimits = .default
    ) {
        self.assetStore = assetStore
        self.imageLimits = imageLimits
    }

    /// Persists binary representations only when the caller explicitly invokes this method after
    /// sensitivity classification. A failure may leave content-addressed orphans for normal GC.
    public func materialize(
        _ draft: PasteboardCaptureDraft,
        ocrText: String? = nil
    ) async throws -> CaptureCandidate {
        // Decode and bound the image before persisting any representation. Invalid or oversized
        // image drafts therefore fail without creating an original, thumbnail, RTF, or HTML orphan.
        let preparedImage = try await Self.prepareImage(draft.image, limits: imageLimits)
        let richTextReference = try await put(
            draft.richTextData,
            kind: .richText,
            uniformTypeIdentifier: "public.rtf",
            preferredExtension: "rtf"
        )
        let htmlReference = try await put(
            draft.htmlData,
            kind: .html,
            uniformTypeIdentifier: "public.html",
            preferredExtension: "html"
        )
        let imageReference = try await put(
            preparedImage?.originalData,
            kind: .image,
            uniformTypeIdentifier: preparedImage?.format ?? "public.image",
            preferredExtension: Self.preferredExtension(
                for: preparedImage?.format
            )
        )
        let thumbnailReference = try await put(
            preparedImage?.thumbnailData,
            kind: .thumbnail,
            uniformTypeIdentifier: "public.png",
            preferredExtension: "png"
        )
        let files = try draft.fileURLs.map { try ClipFileReference(url: $0) }
        let cleanOCR = ocrText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let searchableOCR = cleanOCR.flatMap { $0.isEmpty ? nil : $0 }
        let representations = ClipRepresentations(
            richText: richTextReference,
            html: htmlReference,
            image: imageReference,
            thumbnail: thumbnailReference,
            imageMetadata: preparedImage?.metadata,
            files: files,
            url: draft.url.map {
                URLClipMetadata(originalURL: $0.absoluteString, host: $0.host)
            },
            ocrText: searchableOCR
        )
        let type: SupportedContentType
        if draft.image != nil {
            type = .image
        } else if !draft.fileURLs.isEmpty {
            type = .fileURLs
        } else if draft.richTextData != nil || draft.htmlData != nil {
            type = .richText
        } else if draft.url != nil {
            type = .url
        } else {
            type = .plainText
        }
        let text = Self.previewText(for: draft, ocrText: searchableOCR)
        let content = try ClipContent(type: type, text: text, representations: representations)
        return CaptureCandidate(
            content: content,
            sourceApplicationBundleIdentifier: draft.source.applicationBundleIdentifier,
            captureContext: draft.source.clipCaptureContext,
            pasteboardTypeIdentifiers: draft.typeIdentifiers,
            capturedAt: draft.capturedAt
        )
    }

    private func put(
        _ data: Data?,
        kind: ClipAssetKind,
        uniformTypeIdentifier: String,
        preferredExtension: String?
    ) async throws -> ClipAssetReference? {
        guard let data, !data.isEmpty else { return nil }
        return try await assetStore.put(
            data,
            kind: kind,
            uniformTypeIdentifier: uniformTypeIdentifier,
            preferredExtension: preferredExtension
        )
    }

    private static func previewText(
        for draft: PasteboardCaptureDraft,
        ocrText: String?
    ) -> String {
        if let plainText = draft.plainText, !plainText.isEmpty { return plainText }
        if let ocrText, !ocrText.isEmpty { return ocrText }
        if let url = draft.url { return url.absoluteString }
        if !draft.fileURLs.isEmpty {
            return draft.fileURLs.map(\.lastPathComponent).joined(separator: "\n")
        }
        if draft.image != nil { return "[Image]" }
        return "[Rich Text]"
    }

    private struct PreparedImage: Sendable {
        let originalData: Data
        let thumbnailData: Data
        let format: String
        let metadata: ClipImageMetadata
    }

    private static func prepareImage(
        _ image: PasteboardImageDraft?,
        limits: PasteboardImageMaterializationLimits
    ) async throws -> PreparedImage? {
        guard let image else { return nil }
        return try await Task.detached(priority: .utility) {
            try prepareImageSynchronously(image, limits: limits)
        }.value
    }

    private static func prepareImageSynchronously(
        _ image: PasteboardImageDraft,
        limits: PasteboardImageMaterializationLimits
    ) throws -> PreparedImage {
        guard !image.data.isEmpty else {
            throw PasteboardCaptureMaterializationError.invalidImage
        }
        guard image.data.count <= limits.maximumSourceBytes else {
            throw PasteboardCaptureMaterializationError.imageTooLarge(
                actual: image.data.count,
                maximum: limits.maximumSourceBytes
            )
        }

        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(image.data as CFData, sourceOptions),
              CGImageSourceGetCount(source) > 0,
              let detectedType = CGImageSourceGetType(source),
              Self.supportedImageTypes.contains(detectedType as String),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, sourceOptions)
                as? [CFString: Any],
              let widthValue = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let heightValue = properties[kCGImagePropertyPixelHeight] as? NSNumber
        else {
            throw PasteboardCaptureMaterializationError.invalidImage
        }
        let rawWidth = widthValue.intValue
        let rawHeight = heightValue.intValue
        guard rawWidth > 0, rawHeight > 0 else {
            throw PasteboardCaptureMaterializationError.invalidImage
        }
        let (pixelCount, overflow) = rawWidth.multipliedReportingOverflow(by: rawHeight)
        guard !overflow, pixelCount <= limits.maximumPixelCount else {
            throw PasteboardCaptureMaterializationError.imageDimensionsTooLarge(
                width: rawWidth,
                height: rawHeight,
                maximumPixels: limits.maximumPixelCount
            )
        }

        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let swapsDimensions = (5...8).contains(orientation)
        let displayWidth = swapsDimensions ? rawHeight : rawWidth
        let displayHeight = swapsDimensions ? rawWidth : rawHeight
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: limits.maximumThumbnailPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            thumbnailOptions as CFDictionary
        ),
        thumbnail.width <= limits.maximumThumbnailPixelSize,
        thumbnail.height <= limits.maximumThumbnailPixelSize
        else {
            throw PasteboardCaptureMaterializationError.thumbnailEncodingFailed
        }

        let thumbnailBuffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            thumbnailBuffer,
            "public.png" as CFString,
            1,
            nil
        ) else {
            throw PasteboardCaptureMaterializationError.thumbnailEncodingFailed
        }
        CGImageDestinationAddImage(destination, thumbnail, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw PasteboardCaptureMaterializationError.thumbnailEncodingFailed
        }
        let thumbnailData = thumbnailBuffer as Data
        guard !thumbnailData.isEmpty else {
            throw PasteboardCaptureMaterializationError.thumbnailEncodingFailed
        }
        guard thumbnailData.count <= limits.maximumThumbnailBytes else {
            throw PasteboardCaptureMaterializationError.thumbnailTooLarge(
                actual: thumbnailData.count,
                maximum: limits.maximumThumbnailBytes
            )
        }

        let format = detectedType as String
        return try PreparedImage(
            originalData: image.data,
            thumbnailData: thumbnailData,
            format: format,
            metadata: ClipImageMetadata(
                pixelWidth: displayWidth,
                pixelHeight: displayHeight,
                format: format,
                byteCount: image.data.count
            )
        )
    }

    private static let supportedImageTypes: Set<String> = [
        "public.png",
        "public.jpeg",
        "public.heic",
        "public.heif",
        "public.tiff",
    ]

    private static func preferredExtension(for uniformTypeIdentifier: String?) -> String? {
        switch uniformTypeIdentifier {
        case "public.png": "png"
        case "public.jpeg": "jpg"
        case "public.heic": "heic"
        case "public.tiff": "tiff"
        default: nil
        }
    }
}
