import Foundation
import XCTest
@testable import ClipboardRouterCore

final class TypedContentAssetAndFTSTests: XCTestCase {
    func testRepresentationManifestParticipatesInIdentityButOCRDoesNot() throws {
        let rtfA = try asset(digestCharacter: "a", kind: .richText)
        let rtfB = try asset(digestCharacter: "b", kind: .richText)
        let first = try ClipContent(
            type: .richText,
            text: "same fallback",
            representations: ClipRepresentations(richText: rtfA, ocrText: "first OCR")
        )
        let second = try ClipContent(
            type: .richText,
            text: "same fallback",
            representations: ClipRepresentations(richText: rtfB, ocrText: "first OCR")
        )
        let sameCaptureNewOCR = try ClipContent(
            type: .richText,
            text: "same fallback",
            representations: ClipRepresentations(richText: rtfA, ocrText: "updated OCR")
        )

        XCTAssertNotEqual(first.deduplicationFingerprint, second.deduplicationFingerprint)
        XCTAssertEqual(first.deduplicationFingerprint, sameCaptureNewOCR.deduplicationFingerprint)
    }

    func testImageMetadataDecodesLegacyValuesAndRejectsInvalidEncodedSize() throws {
        let legacy = Data(#"{"pixelWidth":640,"pixelHeight":480,"format":"public.png"}"#.utf8)
        let decoded = try JSONDecoder().decode(ClipImageMetadata.self, from: legacy)

        XCTAssertEqual(decoded.pixelWidth, 640)
        XCTAssertEqual(decoded.pixelHeight, 480)
        XCTAssertEqual(decoded.format, "public.png")
        XCTAssertNil(decoded.byteCount)
        XCTAssertThrowsError(
            try ClipImageMetadata(
                pixelWidth: 640,
                pixelHeight: 480,
                format: "public.png",
                byteCount: 0
            )
        )
    }

    func testEstimatedStorageDoesNotDoubleCountOneContentAddressUsedByImageAndThumbnail() throws {
        let digest = String(repeating: "c", count: 64)
        let image = try ClipAssetReference(
            digest: digest,
            kind: .image,
            uniformTypeIdentifier: "public.png",
            byteCount: 10,
            relativePath: "\(digest).png"
        )
        let thumbnail = try ClipAssetReference(
            digest: digest,
            kind: .thumbnail,
            uniformTypeIdentifier: "public.png",
            byteCount: 10,
            relativePath: "\(digest).png"
        )
        let content = try ClipContent(
            type: .image,
            text: "x",
            representations: ClipRepresentations(image: image, thumbnail: thumbnail)
        )

        XCTAssertEqual(content.estimatedStorageByteCount, 11)
    }

    func testAssetStoreRoundTripDeduplicatesAndGarbageCollectsOnlyUnreferenced() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("asset-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileClipAssetStore(rootURL: root, maximumAssetBytes: 1_024, quotaBytes: 2_048)
        let data = Data("representation".utf8)

        let first = try await store.put(
            data,
            kind: .html,
            uniformTypeIdentifier: "public.html",
            preferredExtension: "html"
        )
        let second = try await store.put(
            data,
            kind: .html,
            uniformTypeIdentifier: "public.html",
            preferredExtension: "html"
        )
        XCTAssertEqual(first, second)
        let loaded = try await store.read(first)
        XCTAssertEqual(loaded, data)

        let kept = try await store.collectGarbage(
            keeping: [first],
            olderThan: .distantFuture
        )
        XCTAssertEqual(kept, 0)
        let removed = try await store.collectGarbage(
            keeping: [],
            olderThan: .distantFuture
        )
        XCTAssertEqual(removed, 1)
    }

    func testAssetStoreQuotaSetterClampsSafelyAndAppliesImmediately() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("asset-quota-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileClipAssetStore(rootURL: root, maximumAssetBytes: 10, quotaBytes: 20)

        await store.setQuotaBytes(-1)
        let clampedQuota = await store.quotaBytes
        XCTAssertEqual(clampedQuota, 10)
        _ = try await store.put(
            Data(repeating: 1, count: 10),
            kind: .image,
            uniformTypeIdentifier: "public.data"
        )
        await XCTAssertThrowsErrorAsync(
            try await store.put(
                Data([2]),
                kind: .image,
                uniformTypeIdentifier: "public.data"
            )
        ) { error in
            guard let assetError = error as? ClipAssetStoreError,
                  case .quotaExceeded = assetError
            else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testSnapshotAwareAssetMaintenanceKeepsReferencesAndReportsEffectiveQuota() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("asset-maintenance-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileClipAssetStore(
            rootURL: root,
            maximumAssetBytes: 1_024,
            quotaBytes: 20 * 1_024 * 1_024
        )
        let kept = try await store.put(
            Data("kept".utf8),
            kind: .html,
            uniformTypeIdentifier: "public.html",
            preferredExtension: "html"
        )
        let orphan = try await store.put(
            Data("orphan".utf8),
            kind: .image,
            uniformTypeIdentifier: "public.png",
            preferredExtension: "png"
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date.distantPast],
            ofItemAtPath: root.appendingPathComponent(orphan.relativePath).path
        )
        let content = try ClipContent(
            type: .richText,
            text: "kept fallback",
            representations: ClipRepresentations(html: kept)
        )
        let configuredQuota = 12 * 1_024 * 1_024
        let snapshot = ClipboardLibrarySnapshot(
            history: [HistoryItem(content: content, createdAt: .distantPast)],
            settings: ClipboardLibrarySettings(maximumAssetStorageBytes: configuredQuota)
        )

        let report = try await store.performMaintenance(
            referencedBy: snapshot,
            olderThan: Date()
        )

        XCTAssertEqual(report.referencedAssetCount, 1)
        XCTAssertEqual(report.removedFileCount, 1)
        XCTAssertEqual(report.usedBytes, Data("kept".utf8).count)
        XCTAssertEqual(report.effectiveQuotaBytes, configuredQuota)
        let keptData = try await store.read(kept)
        XCTAssertEqual(keptData, Data("kept".utf8))
        await XCTAssertThrowsErrorAsync(try await store.read(orphan)) { error in
            guard let assetError = error as? ClipAssetStoreError,
                  case let .missingAsset(digest) = assetError
            else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(digest, orphan.digest)
        }
    }

    func testLegacySchemaOneDecodesAsCurrentSchemaWithSafeDefaults() throws {
        let json = """
        {
          "schemaVersion": 1,
          "history": [],
          "savedClips": [],
          "folders": [],
          "settings": {
            "capturePolicy": {
              "isCaptureEnabled": true,
              "excludedApplicationBundleIdentifiers": [],
              "ignoredPasteboardTypeIdentifiers": []
            },
            "retentionPolicy": { "maximumAge": 2592000 }
          }
        }
        """
        let decoded = try JSONDecoder().decode(
            ClipboardLibrarySnapshot.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(decoded.schemaVersion, 3)
        XCTAssertTrue(decoded.settings.effectiveSecretDetectionEnabled)
        XCTAssertFalse(decoded.settings.effectiveLocationContextEnabled)
        XCTAssertEqual(decoded.settings.effectiveMaximumHistoryItemCount, 10_000)
    }

    func testFTSMetadataFiltersAndTenThousandRowBudget() async throws {
        let base = Date(timeIntervalSince1970: 1_000)
        var history = (0..<10_000).map { index in
            HistoryItem(
                content: try! ClipContent.detect(text: "ordinary record \(index)"),
                createdAt: base.addingTimeInterval(TimeInterval(index))
            )
        }
        let needle = HistoryItem(
            content: try ClipContent(
                type: .image,
                text: "Revenue dashboard",
                representations: ClipRepresentations(ocrText: "Acme pipeline")
            ),
            createdAt: base.addingTimeInterval(20_000),
            sourceApplicationBundleIdentifier: "com.figma.Desktop",
            captureContext: ClipCaptureContext(
                sourceApplicationName: "Figma",
                sourceDomain: "figma.com",
                deviceLabel: "Work Mac",
                coarseLocation: try CoarseLocationContext(label: "Toronto")
            )
        )
        history.append(needle)
        let library = try ClipboardLibrary(snapshot: ClipboardLibrarySnapshot(history: history))

        let clock = ContinuousClock()
        let start = clock.now
        let results = await library.search(
            query: "type:image source:figma device:work pipeline",
            limit: 10
        )
        let elapsed = start.duration(to: clock.now)

        XCTAssertEqual(results.map(\.id), [needle.id])
        XCTAssertLessThan(elapsed, .milliseconds(100), "Warm 10k FTS query took \(elapsed)")
    }

    private func asset(digestCharacter: Character, kind: ClipAssetKind) throws -> ClipAssetReference {
        try ClipAssetReference(
            digest: String(repeating: String(digestCharacter), count: 64),
            kind: kind,
            uniformTypeIdentifier: "public.data",
            byteCount: 10,
            relativePath: String(repeating: String(digestCharacter), count: 64)
        )
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (any Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw")
    } catch {
        errorHandler(error)
    }
}
