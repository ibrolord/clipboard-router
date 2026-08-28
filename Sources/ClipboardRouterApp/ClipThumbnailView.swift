import AppKit
import ClipboardRouterCore
import Foundation
import ImageIO
import SwiftUI

struct ClipThumbnailLoadLimits: Equatable, Sendable {
    var maximumEncodedBytes: Int
    var maximumSourcePixelDimension: Int
    var maximumSourcePixelCount: Int
    var maximumOutputPixelDimension: Int
    var maximumOutputBytes: Int
    var cacheByteLimit: Int

    init(
        maximumEncodedBytes: Int = 1 * 1_024 * 1_024,
        maximumSourcePixelDimension: Int = 4_096,
        maximumSourcePixelCount: Int = 4_000_000,
        maximumOutputPixelDimension: Int = 320,
        maximumOutputBytes: Int = 1 * 1_024 * 1_024,
        cacheByteLimit: Int = 16 * 1_024 * 1_024
    ) {
        precondition(
            maximumEncodedBytes > 0
                && maximumSourcePixelDimension > 0
                && maximumSourcePixelCount > 0
                && maximumOutputPixelDimension > 0
                && maximumOutputBytes > 0
                && cacheByteLimit >= 0,
            "Thumbnail loading limits must be positive; the cache limit may be zero."
        )
        self.maximumEncodedBytes = maximumEncodedBytes
        self.maximumSourcePixelDimension = maximumSourcePixelDimension
        self.maximumSourcePixelCount = maximumSourcePixelCount
        self.maximumOutputPixelDimension = maximumOutputPixelDimension
        self.maximumOutputBytes = maximumOutputBytes
        self.cacheByteLimit = cacheByteLimit
    }

    static let `default` = ClipThumbnailLoadLimits()
}

enum ClipThumbnailLoadError: Error, Equatable, LocalizedError, Sendable {
    case unexpectedAssetKind(ClipAssetKind)
    case encodedDataTooLarge(actual: Int, maximum: Int)
    case assetSizeMismatch(expected: Int, actual: Int)
    case invalidImage
    case sourceDimensionsTooLarge(
        width: Int,
        height: Int,
        maximumDimension: Int,
        maximumPixels: Int
    )
    case outputTooLarge(actual: Int, maximum: Int)

    var errorDescription: String? {
        switch self {
        case let .unexpectedAssetKind(kind):
            "Expected a thumbnail asset, but received \(kind.rawValue)."
        case let .encodedDataTooLarge(actual, maximum):
            "The thumbnail is \(actual) bytes; the display limit is \(maximum) bytes."
        case let .assetSizeMismatch(expected, actual):
            "The thumbnail size does not match its reference (expected \(expected), got \(actual))."
        case .invalidImage:
            "The thumbnail is malformed or uses an unsupported image format."
        case let .sourceDimensionsTooLarge(width, height, maximumDimension, maximumPixels):
            "The thumbnail dimensions \(width) x \(height) exceed the \(maximumDimension)-pixel or \(maximumPixels)-pixel safety limit."
        case let .outputTooLarge(actual, maximum):
            "The decoded thumbnail is \(actual) bytes; the display limit is \(maximum) bytes."
        }
    }
}

struct ClipThumbnailPayload: Equatable, Sendable {
    let pngData: Data
    let pixelWidth: Int
    let pixelHeight: Int
}

/// Reads only local thumbnail references and returns a bounded, display-ready PNG.
/// The actor owns a small completed-result LRU cache so scrolling never shares mutable UI state.
actor ClipThumbnailLoader {
    private struct CacheEntry: Sendable {
        let payload: ClipThumbnailPayload
        var lastAccess: UInt64
    }

    private let assetStore: any ClipAssetStoring
    private let limits: ClipThumbnailLoadLimits
    private var cache: [ClipAssetReference: CacheEntry] = [:]
    private var cachedByteCount = 0
    private var accessCounter: UInt64 = 0

    init(
        assetStore: any ClipAssetStoring,
        limits: ClipThumbnailLoadLimits = .default
    ) {
        self.assetStore = assetStore
        self.limits = limits
    }

    func load(_ reference: ClipAssetReference) async throws -> ClipThumbnailPayload {
        try Task.checkCancellation()
        guard reference.kind == .thumbnail else {
            throw ClipThumbnailLoadError.unexpectedAssetKind(reference.kind)
        }
        guard reference.byteCount <= limits.maximumEncodedBytes else {
            throw ClipThumbnailLoadError.encodedDataTooLarge(
                actual: reference.byteCount,
                maximum: limits.maximumEncodedBytes
            )
        }

        if var entry = cache[reference] {
            accessCounter &+= 1
            entry.lastAccess = accessCounter
            cache[reference] = entry
            return entry.payload
        }

        let data = try await assetStore.read(reference)
        try Task.checkCancellation()
        guard data.count == reference.byteCount else {
            throw ClipThumbnailLoadError.assetSizeMismatch(
                expected: reference.byteCount,
                actual: data.count
            )
        }
        guard data.count <= limits.maximumEncodedBytes else {
            throw ClipThumbnailLoadError.encodedDataTooLarge(
                actual: data.count,
                maximum: limits.maximumEncodedBytes
            )
        }

        let decodeTask = Task.detached(priority: .utility) { [limits] in
            try Self.makeBoundedPayload(from: data, limits: limits)
        }
        let payload = try await withTaskCancellationHandler {
            try await decodeTask.value
        } onCancel: {
            decodeTask.cancel()
        }
        try Task.checkCancellation()
        insertIntoCache(payload, for: reference)
        return payload
    }

    func clearCache() {
        cache.removeAll(keepingCapacity: false)
        cachedByteCount = 0
        accessCounter = 0
    }

    private func insertIntoCache(
        _ payload: ClipThumbnailPayload,
        for reference: ClipAssetReference
    ) {
        guard limits.cacheByteLimit > 0,
              payload.pngData.count <= limits.cacheByteLimit
        else { return }

        if let existing = cache.removeValue(forKey: reference) {
            cachedByteCount -= existing.payload.pngData.count
        }
        accessCounter &+= 1
        cache[reference] = CacheEntry(payload: payload, lastAccess: accessCounter)
        cachedByteCount += payload.pngData.count

        while cachedByteCount > limits.cacheByteLimit,
              let leastRecentlyUsed = cache.min(by: {
                  $0.value.lastAccess < $1.value.lastAccess
              })
        {
            cache.removeValue(forKey: leastRecentlyUsed.key)
            cachedByteCount -= leastRecentlyUsed.value.payload.pngData.count
        }
    }

    nonisolated private static func makeBoundedPayload(
        from data: Data,
        limits: ClipThumbnailLoadLimits
    ) throws -> ClipThumbnailPayload {
        try Task.checkCancellation()
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              CGImageSourceGetCount(source) == 1,
              let detectedType = CGImageSourceGetType(source),
              supportedImageTypes.contains(detectedType as String),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, sourceOptions)
                as? [CFString: Any],
              let widthValue = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let heightValue = properties[kCGImagePropertyPixelHeight] as? NSNumber
        else {
            throw ClipThumbnailLoadError.invalidImage
        }

        let width = widthValue.intValue
        let height = heightValue.intValue
        let (pixelCount, overflow) = width.multipliedReportingOverflow(by: height)
        guard width > 0,
              height > 0,
              !overflow,
              width <= limits.maximumSourcePixelDimension,
              height <= limits.maximumSourcePixelDimension,
              pixelCount <= limits.maximumSourcePixelCount
        else {
            throw ClipThumbnailLoadError.sourceDimensionsTooLarge(
                width: width,
                height: height,
                maximumDimension: limits.maximumSourcePixelDimension,
                maximumPixels: limits.maximumSourcePixelCount
            )
        }

        try Task.checkCancellation()
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: limits.maximumOutputPixelDimension,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            thumbnailOptions as CFDictionary
        ),
        image.width > 0,
        image.height > 0,
        image.width <= limits.maximumOutputPixelDimension,
        image.height <= limits.maximumOutputPixelDimension
        else {
            throw ClipThumbnailLoadError.invalidImage
        }

        try Task.checkCancellation()
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            buffer,
            "public.png" as CFString,
            1,
            nil
        ) else {
            throw ClipThumbnailLoadError.invalidImage
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ClipThumbnailLoadError.invalidImage
        }
        let pngData = buffer as Data
        guard !pngData.isEmpty else { throw ClipThumbnailLoadError.invalidImage }
        guard pngData.count <= limits.maximumOutputBytes else {
            throw ClipThumbnailLoadError.outputTooLarge(
                actual: pngData.count,
                maximum: limits.maximumOutputBytes
            )
        }
        try Task.checkCancellation()
        return ClipThumbnailPayload(
            pngData: pngData,
            pixelWidth: image.width,
            pixelHeight: image.height
        )
    }

    nonisolated private static let supportedImageTypes: Set<String> = [
        "public.png",
        "public.jpeg",
        "public.heic",
        "public.heif",
        "public.tiff",
    ]
}

@MainActor
struct ClipThumbnailView: View {
    private enum Phase {
        case placeholder
        case loading
        case loaded(NSImage)
        case failed
    }

    let reference: ClipAssetReference?
    let loader: ClipThumbnailLoader
    var contentMode: ContentMode = .fit
    var cornerRadius: CGFloat = 8
    var accessibilityLabel: String = "Image clip thumbnail"

    @State private var phase: Phase = .placeholder

    var body: some View {
        ZStack {
            Color.secondary.opacity(0.08)

            switch phase {
            case .placeholder:
                Image(systemName: "photo")
                    .foregroundStyle(.tertiary)
            case .loading:
                ProgressView()
                    .controlSize(.small)
            case let .loaded(image):
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            case .failed:
                Image(systemName: "photo.badge.exclamationmark")
                    .foregroundStyle(.secondary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .task(id: reference) {
            await updateThumbnail()
        }
    }

    private func updateThumbnail() async {
        guard let reference else {
            phase = .placeholder
            return
        }

        phase = .loading
        do {
            let payload = try await loader.load(reference)
            try Task.checkCancellation()
            guard let image = NSImage(data: payload.pngData) else {
                throw ClipThumbnailLoadError.invalidImage
            }
            try Task.checkCancellation()
            phase = .loaded(image)
        } catch is CancellationError {
            // A recycled row gets a new task; leave its replacement task in control of the phase.
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed
        }
    }
}
