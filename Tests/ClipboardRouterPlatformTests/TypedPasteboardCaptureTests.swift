import AppKit
import ClipboardRouterCore
import Foundation
import ImageIO
import XCTest
@testable import ClipboardRouterPlatform

@MainActor
final class TypedPasteboardCaptureTests: XCTestCase {
    func testSensitivityTextIncludesPlainRichHTMLAndOCRRepresentations() {
        let secret = "sk-proj-abcdefghijklmnopqrstuvwxyz123456"
        let draft = PasteboardCaptureDraft(
            changeCount: 1,
            typeIdentifiers: [],
            plainText: "safe preview",
            richTextData: Data("{\\rtf1 rich fallback}".utf8),
            htmlData: Data("<span data-token=\"\(secret)\">visible</span>".utf8)
        )

        let combined = draft.textForSensitivityAnalysis(ocrText: "ocr-only-value")

        XCTAssertTrue(combined.contains("safe preview"))
        XCTAssertTrue(combined.contains("rich fallback"))
        XCTAssertTrue(combined.contains(secret))
        XCTAssertTrue(combined.contains("ocr-only-value"))
    }

    func testSystemReaderPreservesPlainRTFAndHTMLFromOneGeneration() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let item = NSPasteboardItem()
        let rtf = Data("{\\rtf1 rich}".utf8)
        let html = Data("<strong>rich</strong>".utf8)
        XCTAssertTrue(item.setString("rich", forType: .string))
        XCTAssertTrue(item.setData(rtf, forType: .rtf))
        XCTAssertTrue(item.setData(html, forType: .html))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([item]))
        let reader = SystemPasteboardReader(pasteboard: pasteboard)
        let types: Set<String> = [
            NSPasteboard.PasteboardType.string.rawValue,
            NSPasteboard.PasteboardType.rtf.rawValue,
            NSPasteboard.PasteboardType.html.rawValue,
        ]

        let outcome = reader.captureDraft(
            ifChangeCountIs: pasteboard.changeCount,
            declaredTypeIdentifiers: types,
            limits: .default
        )

        guard case let .captured(draft) = outcome else {
            return XCTFail("Expected a typed draft, got \(outcome)")
        }
        XCTAssertEqual(draft.plainText, "rich")
        XCTAssertEqual(draft.richTextData, rtf)
        XCTAssertEqual(draft.htmlData, html)
        XCTAssertEqual(draft.typeIdentifiers, types)
    }

    func testSystemReaderRejectsRepresentationOverHardLimit() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("12345", forType: .string))
        let reader = SystemPasteboardReader(pasteboard: pasteboard)
        let limits = PasteboardCaptureLimits(
            maximumTotalBytes: 100,
            maximumPlainTextBytes: 4,
            maximumURLBytes: 100,
            maximumRichTextBytes: 100,
            maximumHTMLBytes: 100,
            maximumImageBytes: 100,
            maximumFileURLBytes: 100,
            maximumFileURLCount: 2
        )

        XCTAssertEqual(
            reader.captureDraft(
                ifChangeCountIs: pasteboard.changeCount,
                declaredTypeIdentifiers: [NSPasteboard.PasteboardType.string.rawValue],
                limits: limits
            ),
            .limitExceeded(.plainText)
        )
    }

    func testSystemReaderPreservesImageAndMultipleFileURLs() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let imageData = Data([0x89, 0x50, 0x4e, 0x47])
        let imageItem = NSPasteboardItem()
        XCTAssertTrue(imageItem.setData(imageData, forType: .png))
        let firstURL = URL(fileURLWithPath: "/tmp/first.txt")
        let secondURL = URL(fileURLWithPath: "/tmp/second.txt")
        let firstFile = NSPasteboardItem()
        let secondFile = NSPasteboardItem()
        XCTAssertTrue(firstFile.setString(firstURL.absoluteString, forType: .fileURL))
        XCTAssertTrue(secondFile.setString(secondURL.absoluteString, forType: .fileURL))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([imageItem, firstFile, secondFile]))
        let reader = SystemPasteboardReader(pasteboard: pasteboard)

        let outcome = reader.captureDraft(
            ifChangeCountIs: pasteboard.changeCount,
            declaredTypeIdentifiers: [
                NSPasteboard.PasteboardType.png.rawValue,
                NSPasteboard.PasteboardType.fileURL.rawValue,
            ],
            limits: .default
        )

        guard case let .captured(draft) = outcome else {
            return XCTFail("Expected image/file draft, got \(outcome)")
        }
        XCTAssertEqual(draft.image, PasteboardImageDraft(data: imageData, uniformTypeIdentifier: "public.png"))
        XCTAssertEqual(draft.fileURLs, [firstURL.standardizedFileURL, secondURL.standardizedFileURL])
    }

    func testGenerationChangeReturnsNoPartialDraftAndNewConcealedGenerationIsRejected() {
        let reader = FakeTypedPasteboardReader(
            metadata: PasteboardSnapshot(
                changeCount: 0,
                text: nil,
                typeIdentifiers: [NSPasteboard.PasteboardType.string.rawValue]
            )
        )
        var drafts: [PasteboardCaptureDraft] = []
        let monitor = ClipboardMonitor(
            pasteboard: reader,
            applications: FakeTypedFrontmostApplicationProvider(),
            scheduler: FakeTypedRepeatingScheduler(),
            configuration: { ClipboardMonitorConfiguration() },
            onDraft: { drafts.append($0) }
        )
        monitor.start()
        reader.metadata = PasteboardSnapshot(
            changeCount: 1,
            text: nil,
            typeIdentifiers: [NSPasteboard.PasteboardType.string.rawValue]
        )
        reader.nextOutcome = .generationChanged
        reader.metadataAfterRead = PasteboardSnapshot(
            changeCount: 2,
            text: nil,
            typeIdentifiers: [PasteboardSemanticType.concealed]
        )

        monitor.pollNow()
        monitor.pollNow()

        XCTAssertTrue(drafts.isEmpty)
        XCTAssertEqual(reader.draftReadCount, 1)
    }

    func testPrivacyAndExclusionChecksRunBeforeTypedPayloadRead() {
        let reader = FakeTypedPasteboardReader(
            metadata: PasteboardSnapshot(changeCount: 0, text: nil, typeIdentifiers: [])
        )
        let applications = FakeTypedFrontmostApplicationProvider(
            bundleIdentifier: "com.example.private",
            applicationName: "Private"
        )
        let monitor = ClipboardMonitor(
            pasteboard: reader,
            applications: applications,
            scheduler: FakeTypedRepeatingScheduler(),
            configuration: {
                ClipboardMonitorConfiguration(
                    excludedApplicationBundleIdentifiers: ["com.example.private"]
                )
            },
            onDraft: { _ in XCTFail("Excluded content must not be read") }
        )
        monitor.start()
        reader.metadata = PasteboardSnapshot(
            changeCount: 1,
            text: nil,
            typeIdentifiers: [NSPasteboard.PasteboardType.string.rawValue]
        )
        monitor.pollNow()
        applications.bundleIdentifier = "com.example.allowed"
        reader.metadata = PasteboardSnapshot(
            changeCount: 2,
            text: nil,
            typeIdentifiers: [PasteboardSemanticType.transient]
        )
        monitor.pollNow()

        XCTAssertEqual(reader.draftReadCount, 0)
    }

    func testMonitorAddsActualApplicationAndExplicitURLContext() throws {
        let url = try XCTUnwrap(URL(string: "https://docs.example.com/path"))
        let reader = FakeTypedPasteboardReader(
            metadata: PasteboardSnapshot(changeCount: 0, text: nil, typeIdentifiers: [])
        )
        let applications = FakeTypedFrontmostApplicationProvider(
            bundleIdentifier: "com.example.browser",
            applicationName: "Example Browser"
        )
        var drafts: [PasteboardCaptureDraft] = []
        let monitor = ClipboardMonitor(
            pasteboard: reader,
            applications: applications,
            scheduler: FakeTypedRepeatingScheduler(),
            configuration: { ClipboardMonitorConfiguration() },
            onDraft: { drafts.append($0) }
        )
        monitor.start()
        reader.metadata = PasteboardSnapshot(
            changeCount: 1,
            text: nil,
            typeIdentifiers: [NSPasteboard.PasteboardType.URL.rawValue]
        )
        reader.nextOutcome = .captured(
            PasteboardCaptureDraft(
                changeCount: 1,
                typeIdentifiers: [NSPasteboard.PasteboardType.URL.rawValue],
                url: url
            )
        )

        monitor.pollNow()

        let draft = try XCTUnwrap(drafts.first)
        XCTAssertEqual(draft.source.applicationBundleIdentifier, "com.example.browser")
        XCTAssertEqual(draft.source.applicationName, "Example Browser")
        XCTAssertEqual(draft.source.sourceURL, url)
        XCTAssertEqual(draft.source.sourceDomain, "docs.example.com")
    }

    func testDraftIsMemoryOnlyUntilCallerExplicitlyMaterializesIt() async throws {
        let store = FakeClipAssetStore()
        let imageData = try makePNG(width: 32, height: 16)
        let draft = PasteboardCaptureDraft(
            changeCount: 3,
            typeIdentifiers: [
                NSPasteboard.PasteboardType.string.rawValue,
                NSPasteboard.PasteboardType.rtf.rawValue,
                NSPasteboard.PasteboardType.png.rawValue,
            ],
            plainText: "preview",
            richTextData: Data("rtf".utf8),
            image: PasteboardImageDraft(data: imageData, uniformTypeIdentifier: "public.png")
        )

        let initialCounts = await store.counts()
        XCTAssertEqual(initialCounts.puts, 0)
        let candidate = try await PasteboardCaptureMaterializer(assetStore: store)
            .materialize(draft, ocrText: "ocr result")

        let materializedCounts = await store.counts()
        XCTAssertEqual(materializedCounts.puts, 3)
        XCTAssertEqual(candidate.content.type, .image)
        XCTAssertNotNil(candidate.content.representations.richText)
        XCTAssertNotNil(candidate.content.representations.image)
        XCTAssertNotNil(candidate.content.representations.thumbnail)
        XCTAssertEqual(candidate.content.representations.imageMetadata?.pixelWidth, 32)
        XCTAssertEqual(candidate.content.representations.imageMetadata?.pixelHeight, 16)
        XCTAssertEqual(candidate.content.representations.imageMetadata?.byteCount, imageData.count)
        XCTAssertEqual(candidate.content.representations.ocrText, "ocr result")
    }

    func testImageMaterializationCreatesBoundedLocalThumbnailAndMetadata() async throws {
        let store = FakeClipAssetStore()
        let imageData = try makePNG(width: 640, height: 320)
        let limits = PasteboardImageMaterializationLimits(
            maximumSourceBytes: 2 * 1_024 * 1_024,
            maximumPixelCount: 1_000_000,
            maximumThumbnailPixelSize: 64,
            maximumThumbnailBytes: 128 * 1_024
        )
        let draft = PasteboardCaptureDraft(
            changeCount: 1,
            typeIdentifiers: [NSPasteboard.PasteboardType.png.rawValue],
            image: PasteboardImageDraft(data: imageData, uniformTypeIdentifier: "public.png")
        )

        let candidate = try await PasteboardCaptureMaterializer(
            assetStore: store,
            imageLimits: limits
        ).materialize(draft)

        let representations = candidate.content.representations
        let original = try XCTUnwrap(representations.image)
        let thumbnail = try XCTUnwrap(representations.thumbnail)
        let metadata = try XCTUnwrap(representations.imageMetadata)
        XCTAssertEqual(original.kind, .image)
        XCTAssertEqual(original.byteCount, imageData.count)
        XCTAssertEqual(thumbnail.kind, .thumbnail)
        XCTAssertLessThanOrEqual(thumbnail.byteCount, limits.maximumThumbnailBytes)
        XCTAssertEqual(metadata.pixelWidth, 640)
        XCTAssertEqual(metadata.pixelHeight, 320)
        XCTAssertEqual(metadata.format, "public.png")
        XCTAssertEqual(metadata.byteCount, imageData.count)

        let thumbnailData = try await store.read(thumbnail)
        let thumbnailSource = try XCTUnwrap(
            CGImageSourceCreateWithData(thumbnailData as CFData, nil)
        )
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(thumbnailSource, 0, nil) as? [CFString: Any]
        )
        let width = try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? NSNumber).intValue
        let height = try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? NSNumber).intValue
        XCTAssertLessThanOrEqual(width, limits.maximumThumbnailPixelSize)
        XCTAssertLessThanOrEqual(height, limits.maximumThumbnailPixelSize)
        XCTAssertEqual(max(width, height), limits.maximumThumbnailPixelSize)
    }

    func testImageMaterializationRejectsMalformedAndOversizedImagesBeforeStorage() async throws {
        let malformedStore = FakeClipAssetStore()
        let malformed = PasteboardCaptureDraft(
            changeCount: 1,
            typeIdentifiers: [NSPasteboard.PasteboardType.png.rawValue],
            image: PasteboardImageDraft(data: Data([1, 2, 3]), uniformTypeIdentifier: "public.png")
        )
        do {
            _ = try await PasteboardCaptureMaterializer(assetStore: malformedStore)
                .materialize(malformed)
            XCTFail("Expected malformed image rejection")
        } catch {
            XCTAssertEqual(error as? PasteboardCaptureMaterializationError, .invalidImage)
        }
        let malformedCounts = await malformedStore.counts()
        XCTAssertEqual(malformedCounts.puts, 0)

        let oversizedStore = FakeClipAssetStore()
        let oversized = PasteboardCaptureDraft(
            changeCount: 2,
            typeIdentifiers: [NSPasteboard.PasteboardType.png.rawValue],
            image: PasteboardImageDraft(data: Data(repeating: 1, count: 5), uniformTypeIdentifier: "public.png")
        )
        let smallLimits = PasteboardImageMaterializationLimits(maximumSourceBytes: 4)
        do {
            _ = try await PasteboardCaptureMaterializer(
                assetStore: oversizedStore,
                imageLimits: smallLimits
            ).materialize(oversized)
            XCTFail("Expected oversized image rejection")
        } catch {
            XCTAssertEqual(
                error as? PasteboardCaptureMaterializationError,
                .imageTooLarge(actual: 5, maximum: 4)
            )
        }
        let oversizedCounts = await oversizedStore.counts()
        XCTAssertEqual(oversizedCounts.puts, 0)
    }

    func testRepeatedImageMaterializationDeduplicatesOriginalAndThumbnailStorage() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("materialized-image-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileClipAssetStore(
            rootURL: root,
            maximumAssetBytes: 2 * 1_024 * 1_024,
            quotaBytes: 4 * 1_024 * 1_024
        )
        let imageData = try makePNG(width: 128, height: 64)
        let draft = PasteboardCaptureDraft(
            changeCount: 1,
            typeIdentifiers: [NSPasteboard.PasteboardType.png.rawValue],
            image: PasteboardImageDraft(data: imageData, uniformTypeIdentifier: "public.png")
        )
        let materializer = PasteboardCaptureMaterializer(assetStore: store)

        let first = try await materializer.materialize(draft)
        let usedAfterFirst = try await store.usageBytes()
        let second = try await materializer.materialize(draft)
        let usedAfterSecond = try await store.usageBytes()

        XCTAssertEqual(first.content.representations.image, second.content.representations.image)
        XCTAssertEqual(first.content.representations.thumbnail, second.content.representations.thumbnail)
        XCTAssertEqual(usedAfterSecond, usedAfterFirst)
        let original = try XCTUnwrap(first.content.representations.image)
        let thumbnail = try XCTUnwrap(first.content.representations.thumbnail)
        XCTAssertEqual(usedAfterFirst, original.byteCount + thumbnail.byteCount)
        XCTAssertEqual(
            first.content.estimatedStorageByteCount,
            first.content.text.utf8.count + usedAfterFirst
        )
    }

    func testVisionOCRServiceUsesDetachedWorkAndEnforcesLimit() async throws {
        let service = LocalVisionOCRService(maximumImageBytes: 4) { _, _ in
            Thread.isMainThread ? "main" : "background"
        }

        let recognized = try await service.recognizeText(in: Data([1]))
        XCTAssertEqual(recognized, "background")
        do {
            _ = try await service.recognizeText(in: Data(repeating: 1, count: 5))
            XCTFail("Expected imageTooLarge")
        } catch {
            XCTAssertEqual(error as? LocalVisionOCRError, .imageTooLarge(5))
        }
    }

    private func makePNG(width: Int, height: Int) throws -> Data {
        let representation = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: width,
                pixelsHigh: height,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: width * 4,
                bitsPerPixel: 32
            )
        )
        if let pixels = representation.bitmapData {
            pixels[0] = 0x4A
            pixels[1] = 0x91
            pixels[2] = 0xE8
            pixels[3] = 0xFF
        }
        return try XCTUnwrap(representation.representation(using: .png, properties: [:]))
    }
}

@MainActor
final class TypedPasteboardWriterTests: XCTestCase {
    func testOriginalModeRestoresAllRepresentationsAndFileItems() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let richReference = try reference(character: "a", kind: .richText, uti: "public.rtf")
        let htmlReference = try reference(character: "b", kind: .html, uti: "public.html")
        let imageReference = try reference(character: "c", kind: .image, uti: "public.png")
        let richData = Data("rtf".utf8)
        let htmlData = Data("html".utf8)
        let imageData = Data([1, 2, 3])
        let store = FakeClipAssetStore(dataByDigest: [
            richReference.digest: richData,
            htmlReference.digest: htmlData,
            imageReference.digest: imageData,
        ])
        let fileURL = URL(fileURLWithPath: "/tmp/report.pdf")
        let content = try ClipContent(
            type: .image,
            text: "fallback",
            representations: ClipRepresentations(
                richText: richReference,
                html: htmlReference,
                image: imageReference,
                files: [try ClipFileReference(url: fileURL)],
                url: URLClipMetadata(
                    originalURL: "https://example.com",
                    host: "example.com"
                )
            )
        )
        let writer = TypedSystemPasteboardWriter(pasteboard: pasteboard, assetStore: store)

        try await writer.write(
            content,
            mode: .original,
            sourceTypeIdentifiers: [
                NSPasteboard.PasteboardType.string.rawValue,
                NSPasteboard.PasteboardType.URL.rawValue,
                NSPasteboard.PasteboardType.rtf.rawValue,
                NSPasteboard.PasteboardType.html.rawValue,
                NSPasteboard.PasteboardType.png.rawValue,
                NSPasteboard.PasteboardType.fileURL.rawValue,
            ]
        )

        let items = try XCTUnwrap(pasteboard.pasteboardItems)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].string(forType: .string), "fallback")
        XCTAssertEqual(items[0].string(forType: .URL), "https://example.com")
        XCTAssertEqual(items[0].data(forType: .rtf), richData)
        XCTAssertEqual(items[0].data(forType: .html), htmlData)
        XCTAssertEqual(items[0].data(forType: .png), imageData)
        XCTAssertEqual(items[1].string(forType: .fileURL), fileURL.absoluteString)
        let counts = await store.counts()
        XCTAssertEqual(counts.reads, 3)
    }

    func testImageOnlyOriginalModeDoesNotAdvertiseDerivedTextAndProducesReadableImage() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let imageData = try makePNG(width: 18, height: 12)
        let imageReference = try reference(
            character: "e",
            kind: .image,
            uti: "public.png",
            byteCount: imageData.count
        )
        let store = FakeClipAssetStore(dataByDigest: [imageReference.digest: imageData])
        let content = try ClipContent(
            type: .image,
            text: "derived OCR words",
            representations: ClipRepresentations(
                image: imageReference,
                ocrText: "derived OCR words"
            )
        )
        let writer: any TypedPasteboardWriting = TypedSystemPasteboardWriter(
            pasteboard: pasteboard,
            assetStore: store
        )

        try await writer.write(
            content,
            mode: .original,
            sourceTypeIdentifiers: [NSPasteboard.PasteboardType.png.rawValue]
        )

        XCTAssertEqual(pasteboard.pasteboardItems?.count, 1)
        XCTAssertEqual(pasteboard.data(forType: .png), imageData)
        XCTAssertNil(pasteboard.string(forType: .string))
        let pastedImage = try XCTUnwrap(NSImage(pasteboard: pasteboard))
        XCTAssertEqual(Int(pastedImage.size.width), 18)
        XCTAssertEqual(Int(pastedImage.size.height), 12)
    }

    func testImageWithOriginalStringPreservesBothRepresentations() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let imageData = try makePNG(width: 9, height: 7)
        let imageReference = try reference(
            character: "f",
            kind: .image,
            uti: "public.png",
            byteCount: imageData.count
        )
        let store = FakeClipAssetStore(dataByDigest: [imageReference.digest: imageData])
        let content = try ClipContent(
            type: .image,
            text: "original caption",
            representations: ClipRepresentations(image: imageReference)
        )
        let writer = TypedSystemPasteboardWriter(pasteboard: pasteboard, assetStore: store)

        try await writer.write(
            content,
            mode: .original,
            sourceTypeIdentifiers: [
                NSPasteboard.PasteboardType.png.rawValue,
                NSPasteboard.PasteboardType.string.rawValue,
            ]
        )

        XCTAssertEqual(pasteboard.data(forType: .png), imageData)
        XCTAssertEqual(pasteboard.string(forType: .string), "original caption")
        XCTAssertNotNil(NSImage(pasteboard: pasteboard))
    }

    func testFileOnlyOriginalModeDoesNotCreateGhostTextItem() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let fileURL = URL(fileURLWithPath: "/tmp/file-only.pdf")
        let content = try ClipContent(
            type: .fileURLs,
            text: "file-only.pdf",
            representations: ClipRepresentations(
                files: [try ClipFileReference(url: fileURL)]
            )
        )
        let writer = TypedSystemPasteboardWriter(
            pasteboard: pasteboard,
            assetStore: FakeClipAssetStore()
        )

        try await writer.write(
            content,
            mode: .original,
            sourceTypeIdentifiers: [NSPasteboard.PasteboardType.fileURL.rawValue]
        )

        let items = try XCTUnwrap(pasteboard.pasteboardItems)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].string(forType: .fileURL), fileURL.absoluteString)
        XCTAssertNil(items[0].string(forType: .string))
    }

    func testEmptyLegacySourceMetadataFallsBackToSemanticTextType() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let content = try ClipContent(type: .plainText, text: "legacy text")
        let writer = TypedSystemPasteboardWriter(
            pasteboard: pasteboard,
            assetStore: FakeClipAssetStore()
        )

        try await writer.write(content, mode: .original, sourceTypeIdentifiers: [])

        XCTAssertEqual(pasteboard.string(forType: .string), "legacy text")
    }

    func testPlainModeDoesNotReadOrWriteOriginalAssets() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let imageReference = try reference(character: "d", kind: .image, uti: "public.png")
        let store = FakeClipAssetStore(dataByDigest: [imageReference.digest: Data([1])])
        let content = try ClipContent(
            type: .image,
            text: "plain only",
            representations: ClipRepresentations(image: imageReference)
        )
        let writer = TypedSystemPasteboardWriter(pasteboard: pasteboard, assetStore: store)

        try await writer.write(content, mode: .plainText)

        XCTAssertEqual(pasteboard.string(forType: .string), "plain only")
        XCTAssertNil(pasteboard.data(forType: .png))
        let counts = await store.counts()
        XCTAssertEqual(counts.reads, 0)
    }

    private func reference(
        character: Character,
        kind: ClipAssetKind,
        uti: String,
        byteCount: Int = 3
    ) throws -> ClipAssetReference {
        try ClipAssetReference(
            digest: String(repeating: String(character), count: 64),
            kind: kind,
            uniformTypeIdentifier: uti,
            byteCount: byteCount,
            relativePath: String(repeating: String(character), count: 64)
        )
    }

    private func makePNG(width: Int, height: Int) throws -> Data {
        let representation = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: width,
                pixelsHigh: height,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: width * 4,
                bitsPerPixel: 32
            )
        )
        if let pixels = representation.bitmapData {
            pixels[0] = 0x3A
            pixels[1] = 0x88
            pixels[2] = 0xD1
            pixels[3] = 0xFF
        }
        return try XCTUnwrap(representation.representation(using: .png, properties: [:]))
    }
}

@MainActor
private final class FakeTypedPasteboardReader: PasteboardDraftReading {
    var metadata: PasteboardSnapshot
    var nextOutcome: PasteboardDraftReadOutcome = .noSupportedContent
    var metadataAfterRead: PasteboardSnapshot?
    private(set) var draftReadCount = 0

    init(metadata: PasteboardSnapshot) {
        self.metadata = metadata
    }

    func metadataSnapshot() -> PasteboardSnapshot {
        PasteboardSnapshot(
            changeCount: metadata.changeCount,
            text: nil,
            typeIdentifiers: metadata.typeIdentifiers
        )
    }

    func stringValue(ifChangeCountIs expectedChangeCount: Int) -> String? {
        nil
    }

    func captureDraft(
        ifChangeCountIs expectedChangeCount: Int,
        declaredTypeIdentifiers: Set<String>,
        limits: PasteboardCaptureLimits
    ) -> PasteboardDraftReadOutcome {
        draftReadCount += 1
        if let metadataAfterRead {
            metadata = metadataAfterRead
            self.metadataAfterRead = nil
        }
        return nextOutcome
    }
}

@MainActor
private final class FakeTypedFrontmostApplicationProvider: FrontmostApplicationProviding {
    var bundleIdentifier: String?
    var applicationName: String?

    init(bundleIdentifier: String? = nil, applicationName: String? = nil) {
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
    }

    var frontmostBundleIdentifier: String? { bundleIdentifier }
    var frontmostApplicationName: String? { applicationName }
}

@MainActor
private final class FakeTypedRepeatingScheduler: RepeatingScheduling {
    private var action: (@MainActor () -> Void)?

    func schedule(every interval: TimeInterval, _ action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    func cancel() {
        action = nil
    }
}

private actor FakeClipAssetStore: ClipAssetStoring {
    private var storedData: [String: Data]
    private var nextDigestIndex = 0
    private(set) var putCount = 0
    private(set) var readCount = 0

    init(dataByDigest: [String: Data] = [:]) {
        self.storedData = dataByDigest
    }

    func counts() -> (puts: Int, reads: Int) {
        (putCount, readCount)
    }

    func put(
        _ data: Data,
        kind: ClipAssetKind,
        uniformTypeIdentifier: String,
        preferredExtension: String?
    ) async throws -> ClipAssetReference {
        putCount += 1
        let characters = Array("abcdef0123456789")
        let character = characters[nextDigestIndex % characters.count]
        nextDigestIndex += 1
        let digest = String(repeating: String(character), count: 64)
        storedData[digest] = data
        return try ClipAssetReference(
            digest: digest,
            kind: kind,
            uniformTypeIdentifier: uniformTypeIdentifier,
            byteCount: data.count,
            relativePath: digest
        )
    }

    func read(_ reference: ClipAssetReference) async throws -> Data {
        readCount += 1
        guard let data = storedData[reference.digest] else {
            throw ClipAssetStoreError.missingAsset(reference.digest)
        }
        return data
    }

    func collectGarbage(
        keeping references: Set<ClipAssetReference>,
        olderThan cutoff: Date
    ) async throws -> Int {
        0
    }
}
