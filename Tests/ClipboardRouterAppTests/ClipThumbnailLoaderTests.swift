import AppKit
import ClipboardRouterCore
import Foundation
import XCTest
@testable import ClipboardRouterApp

@MainActor
final class ClipThumbnailLoaderTests: XCTestCase {
    func testLoaderDownsamplesAndCachesCompletedThumbnail() async throws {
        let data = try makePNG(width: 96, height: 48)
        let reference = try makeReference(data: data)
        let store = FakeThumbnailAssetStore(dataByReference: [reference: data])
        let loader = ClipThumbnailLoader(
            assetStore: store,
            limits: ClipThumbnailLoadLimits(
                maximumEncodedBytes: 1_024 * 1_024,
                maximumSourcePixelDimension: 256,
                maximumSourcePixelCount: 65_536,
                maximumOutputPixelDimension: 24,
                maximumOutputBytes: 1_024 * 1_024,
                cacheByteLimit: 1_024 * 1_024
            )
        )

        let first = try await loader.load(reference)
        let second = try await loader.load(reference)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.pixelWidth, 24)
        XCTAssertEqual(first.pixelHeight, 12)
        XCTAssertNotNil(NSImage(data: first.pngData))
        var readCount = await store.readCount
        XCTAssertEqual(readCount, 1)

        await loader.clearCache()
        _ = try await loader.load(reference)
        readCount = await store.readCount
        XCTAssertEqual(readCount, 2)
    }

    func testLoaderRejectsNonThumbnailAndDeclaredOversizeBeforeReading() async throws {
        let data = try makePNG(width: 8, height: 8)
        let imageReference = try makeReference(data: data, kind: .image)
        let oversizedReference = try ClipAssetReference(
            digest: String(repeating: "b", count: 64),
            kind: .thumbnail,
            uniformTypeIdentifier: "public.png",
            byteCount: 2_048,
            relativePath: "oversized.png"
        )
        let store = FakeThumbnailAssetStore(
            dataByReference: [imageReference: data, oversizedReference: data]
        )
        let loader = ClipThumbnailLoader(
            assetStore: store,
            limits: ClipThumbnailLoadLimits(maximumEncodedBytes: 1_024)
        )

        do {
            _ = try await loader.load(imageReference)
            XCTFail("Expected the loader to reject an original image reference")
        } catch let error as ClipThumbnailLoadError {
            XCTAssertEqual(error, .unexpectedAssetKind(.image))
        }

        do {
            _ = try await loader.load(oversizedReference)
            XCTFail("Expected the loader to reject a declared oversized thumbnail")
        } catch let error as ClipThumbnailLoadError {
            XCTAssertEqual(
                error,
                .encodedDataTooLarge(actual: 2_048, maximum: 1_024)
            )
        }

        let readCount = await store.readCount
        XCTAssertEqual(readCount, 0)
    }

    func testLoaderRejectsSizeMismatchAndMalformedImageSafely() async throws {
        let validData = try makePNG(width: 8, height: 8)
        let mismatchedReference = try ClipAssetReference(
            digest: String(repeating: "c", count: 64),
            kind: .thumbnail,
            uniformTypeIdentifier: "public.png",
            byteCount: validData.count + 1,
            relativePath: "mismatch.png"
        )
        let malformedData = Data([0x89, 0x50, 0x4e, 0x47])
        let malformedReference = try makeReference(
            data: malformedData,
            digestCharacter: "d",
            relativePath: "malformed.png"
        )
        let store = FakeThumbnailAssetStore(
            dataByReference: [
                mismatchedReference: validData,
                malformedReference: malformedData,
            ]
        )
        let loader = ClipThumbnailLoader(assetStore: store)

        do {
            _ = try await loader.load(mismatchedReference)
            XCTFail("Expected the loader to reject a size mismatch")
        } catch let error as ClipThumbnailLoadError {
            XCTAssertEqual(
                error,
                .assetSizeMismatch(
                    expected: validData.count + 1,
                    actual: validData.count
                )
            )
        }

        do {
            _ = try await loader.load(malformedReference)
            XCTFail("Expected the loader to reject malformed image bytes")
        } catch let error as ClipThumbnailLoadError {
            XCTAssertEqual(error, .invalidImage)
        }
    }

    func testCancellationPreventsAReleasedReadFromDecodingOrCaching() async throws {
        let data = try makePNG(width: 16, height: 16)
        let reference = try makeReference(
            data: data,
            digestCharacter: "e",
            relativePath: "cancelled.png"
        )
        let store = FakeThumbnailAssetStore(
            dataByReference: [reference: data],
            startsBlocked: true
        )
        let loader = ClipThumbnailLoader(assetStore: store)
        let task = Task { try await loader.load(reference) }

        await store.waitForReadToStart()
        task.cancel()
        await store.releaseReads()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }

        _ = try await loader.load(reference)
        let readCount = await store.readCount
        XCTAssertEqual(readCount, 2, "A cancelled result must not enter the cache")
    }

    private func makeReference(
        data: Data,
        kind: ClipAssetKind = .thumbnail,
        digestCharacter: Character = "a",
        relativePath: String = "thumbnail.png"
    ) throws -> ClipAssetReference {
        try ClipAssetReference(
            digest: String(repeating: String(digestCharacter), count: 64),
            kind: kind,
            uniformTypeIdentifier: "public.png",
            byteCount: data.count,
            relativePath: relativePath
        )
    }

    private func makePNG(width: Int, height: Int) throws -> Data {
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [],
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw ThumbnailTestError.imageCreationFailed
        }
        representation.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: representation) else {
            throw ThumbnailTestError.imageCreationFailed
        }
        NSGraphicsContext.current = context
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        guard let data = representation.representation(using: .png, properties: [:]) else {
            throw ThumbnailTestError.imageCreationFailed
        }
        return data
    }
}

private actor FakeThumbnailAssetStore: ClipAssetStoring {
    private let dataByReference: [ClipAssetReference: Data]
    private var blocked: Bool
    private var readStarted = false
    private var readStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var readReleaseWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var readCount = 0

    init(
        dataByReference: [ClipAssetReference: Data],
        startsBlocked: Bool = false
    ) {
        self.dataByReference = dataByReference
        blocked = startsBlocked
    }

    func put(
        _: Data,
        kind _: ClipAssetKind,
        uniformTypeIdentifier _: String,
        preferredExtension _: String?
    ) async throws -> ClipAssetReference {
        throw ThumbnailTestError.unsupportedOperation
    }

    func read(_ reference: ClipAssetReference) async throws -> Data {
        readCount += 1
        readStarted = true
        readStartWaiters.forEach { $0.resume() }
        readStartWaiters.removeAll()
        if blocked {
            await withCheckedContinuation { continuation in
                readReleaseWaiters.append(continuation)
            }
        }
        guard let data = dataByReference[reference] else {
            throw ClipAssetStoreError.missingAsset(reference.digest)
        }
        return data
    }

    func collectGarbage(
        keeping _: Set<ClipAssetReference>,
        olderThan _: Date
    ) async throws -> Int {
        0
    }

    func waitForReadToStart() async {
        if readStarted { return }
        await withCheckedContinuation { continuation in
            readStartWaiters.append(continuation)
        }
    }

    func releaseReads() {
        blocked = false
        readReleaseWaiters.forEach { $0.resume() }
        readReleaseWaiters.removeAll()
    }
}

private enum ThumbnailTestError: Error {
    case imageCreationFailed
    case unsupportedOperation
}
