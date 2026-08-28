import ClipboardRouterCore
import Foundation
import XCTest
@testable import ClipboardRouterSync

final class SavedLibraryAssetSyncTests: XCTestCase {
    func testRichAndImageAssetsRoundTripWithOriginalBytesAndDimensions() async throws {
        let fixture = try AssetSyncFixture()
        defer { fixture.cleanup() }
        let rtf = Data("{\\rtf1\\ansi Exact rich bytes}".utf8)
        let html = Data("<p><b>Exact rich bytes</b></p>".utf8)
        let image = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 4, 5])
        let rtfRef = try await fixture.senderAssets.put(
            rtf, kind: .richText, uniformTypeIdentifier: "public.rtf", preferredExtension: "rtf"
        )
        let htmlRef = try await fixture.senderAssets.put(
            html, kind: .html, uniformTypeIdentifier: "public.html", preferredExtension: "html"
        )
        let imageRef = try await fixture.senderAssets.put(
            image, kind: .image, uniformTypeIdentifier: "public.png", preferredExtension: "png"
        )
        let rich = try SavedClip(
            name: "Rich",
            content: ClipContent(
                type: .richText,
                text: "Exact rich bytes",
                representations: ClipRepresentations(richText: rtfRef, html: htmlRef)
            ),
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        let dimensions = try ClipImageMetadata(
            pixelWidth: 1_920,
            pixelHeight: 1_080,
            format: "png",
            byteCount: image.count
        )
        let picture = try SavedClip(
            name: "Picture",
            content: ClipContent(
                type: .image,
                text: "Picture",
                representations: ClipRepresentations(
                    image: imageRef,
                    imageMetadata: dimensions
                )
            ),
            createdAt: Date(timeIntervalSince1970: 1_001)
        )

        let sender = try await fixture.sender()
        try await sender.setEnabled(true)
        try await sender.recordSavedClip(rich)
        try await sender.recordSavedClip(picture)
        await sender.synchronize()
        let senderSnapshot = await sender.snapshot()
        let uploadedDigests = await fixture.transport.allAssetDigests()
        XCTAssertTrue(senderSnapshot.outbox.isEmpty)
        XCTAssertEqual(uploadedDigests.count, 3)

        let receiver = try await fixture.receiver()
        try await receiver.setEnabled(true)
        await receiver.synchronize()
        let received = await receiver.materializedLibrary().savedClips
        let receivedRich = try XCTUnwrap(received.first { $0.id == rich.id })
        let receivedImage = try XCTUnwrap(received.first { $0.id == picture.id })
        XCTAssertEqual(receivedRich.content.representations.richText?.digest, rtfRef.digest)
        XCTAssertEqual(receivedRich.content.representations.html?.digest, htmlRef.digest)
        XCTAssertEqual(receivedImage.content.representations.imageMetadata, dimensions)
        let receivedRTF = try await fixture.receiverAssets.read(
            try XCTUnwrap(receivedRich.content.representations.richText)
        )
        let receivedHTML = try await fixture.receiverAssets.read(
            try XCTUnwrap(receivedRich.content.representations.html)
        )
        let receivedImageBytes = try await fixture.receiverAssets.read(
            try XCTUnwrap(receivedImage.content.representations.image)
        )
        XCTAssertEqual(receivedRTF, rtf)
        XCTAssertEqual(receivedHTML, html)
        XCTAssertEqual(receivedImageBytes, image)
    }

    func testTwoClipsDeduplicateOneRemoteContentAddressedAsset() async throws {
        let fixture = try AssetSyncFixture()
        defer { fixture.cleanup() }
        let bytes = Data("same exact rtf".utf8)
        let reference = try await fixture.senderAssets.put(
            bytes, kind: .richText, uniformTypeIdentifier: "public.rtf", preferredExtension: "rtf"
        )
        let sender = try await fixture.sender()
        try await sender.setEnabled(true)
        for index in 0..<2 {
            let clip = try SavedClip(
                name: "Rich \(index)",
                content: ClipContent(
                    type: .richText,
                    text: "same exact rtf",
                    representations: ClipRepresentations(richText: reference)
                ),
                createdAt: Date(timeIntervalSince1970: TimeInterval(1_000 + index))
            )
            try await sender.recordSavedClip(clip)
        }
        await sender.synchronize()
        let digests = await fixture.transport.allAssetDigests()
        XCTAssertEqual(digests, [reference.digest])
    }

    func testCorruptRemoteAssetFailsBeforeTokenAdvanceThenRecovers() async throws {
        let fixture = try AssetSyncFixture()
        defer { fixture.cleanup() }
        let original = Data("verified original".utf8)
        let reference = try await fixture.senderAssets.put(
            original, kind: .richText, uniformTypeIdentifier: "public.rtf", preferredExtension: "rtf"
        )
        let clip = try SavedClip(
            name: "Recoverable",
            content: ClipContent(
                type: .richText,
                text: "verified original",
                representations: ClipRepresentations(richText: reference)
            ),
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        let sender = try await fixture.sender()
        try await sender.setEnabled(true)
        try await sender.recordSavedClip(clip)
        await sender.synchronize()
        await fixture.transport.replaceAssetForTesting(
            digest: reference.digest,
            data: Data("tampered".utf8)
        )

        let receiver = try await fixture.receiver()
        try await receiver.setEnabled(true)
        await receiver.synchronize()
        let failed = await receiver.snapshot()
        let failedLibrary = await receiver.materializedLibrary()
        XCTAssertNil(failed.changeToken)
        XCTAssertTrue(failedLibrary.savedClips.isEmpty)
        if case .failed = failed.status {} else { XCTFail("Expected fail-closed status") }
        if case .failed = failed.entityStates[clip.id] {} else {
            XCTFail("Expected item-level asset failure state")
        }

        await fixture.transport.replaceAssetForTesting(digest: reference.digest, data: original)
        await receiver.synchronize()
        let recovered = await receiver.materializedLibrary()
        XCTAssertEqual(recovered.savedClips.map(\.id), [clip.id])
    }

    func testAcceptedAssetAndRecordOutboxResumeAcrossRelaunch() async throws {
        let fixture = try AssetSyncFixture()
        defer { fixture.cleanup() }
        let transport = FailRecordOnceAssetTransport()
        let bytes = Data("relaunch bytes".utf8)
        let reference = try await fixture.senderAssets.put(
            bytes, kind: .richText, uniformTypeIdentifier: "public.rtf", preferredExtension: "rtf"
        )
        let clip = try SavedClip(
            name: "Relaunch",
            content: ClipContent(
                type: .richText,
                text: "relaunch bytes",
                representations: ClipRepresentations(richText: reference)
            ),
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        let first = try await SavedLibrarySyncCoordinator.open(
            deviceID: "sender",
            transport: transport,
            store: fixture.senderState,
            assetStore: fixture.senderAssets,
            assetStager: fixture.senderStager
        )
        try await first.setEnabled(true)
        try await first.recordSavedClip(clip)
        await first.synchronize()
        let failedSnapshot = await first.snapshot()
        let acceptedDigests = await transport.assetDigests()
        XCTAssertNotNil(failedSnapshot.outbox[clip.id])
        XCTAssertEqual(acceptedDigests, [reference.digest])

        let reopened = try await SavedLibrarySyncCoordinator.open(
            deviceID: "sender",
            transport: transport,
            store: fixture.senderState,
            assetStore: fixture.senderAssets,
            assetStager: fixture.senderStager
        )
        await reopened.synchronize()
        let recoveredSnapshot = await reopened.snapshot()
        let remoteRecords = await transport.records()
        XCTAssertTrue(recoveredSnapshot.outbox.isEmpty)
        XCTAssertEqual(remoteRecords.map(\.id), [clip.id])
    }

    func testStagingUsesPrivateAtomicFilesAndBoundsRejectOversizeManifest() async throws {
        let fixture = try AssetSyncFixture()
        defer { fixture.cleanup() }
        let bytes = Data("private staging".utf8)
        let reference = try await fixture.senderAssets.put(
            bytes, kind: .richText, uniformTypeIdentifier: "public.rtf", preferredExtension: "rtf"
        )
        let descriptor = try SavedLibrarySyncAssetDescriptor(reference: reference)
        let upload = try await fixture.senderStager.stage(descriptor, from: fixture.senderAssets)
        let directoryPermissions = try FileManager.default.attributesOfItem(
            atPath: fixture.senderStageRoot.path
        )[.posixPermissions] as? NSNumber
        let filePermissions = try FileManager.default.attributesOfItem(
            atPath: upload.fileURL.path
        )[.posixPermissions] as? NSNumber
        XCTAssertEqual(directoryPermissions?.intValue, 0o700)
        XCTAssertEqual(filePermissions?.intValue, 0o600)
        XCTAssertThrowsError(
            try SavedLibrarySyncAssetDescriptor(
                digest: String(repeating: "a", count: 64),
                kind: .image,
                uniformTypeIdentifier: "public.png",
                byteCount: SavedLibrarySyncAssetPolicy.maximumAssetBytes + 1
            )
        )
    }

    func testAssetGarbageWaitsForGraceAndDeletesAfterConfirmedTombstone() async throws {
        let fixture = try AssetSyncFixture()
        defer { fixture.cleanup() }
        let retiredAt = Date(timeIntervalSince1970: 1_000)
        let bytes = Data("retire me".utf8)
        let reference = try await fixture.senderAssets.put(
            bytes, kind: .richText, uniformTypeIdentifier: "public.rtf", preferredExtension: "rtf"
        )
        let clip = try SavedClip(
            name: "Retire",
            content: ClipContent(
                type: .richText,
                text: "retire me",
                representations: ClipRepresentations(richText: reference)
            ),
            createdAt: retiredAt
        )
        let first = try await SavedLibrarySyncCoordinator.open(
            deviceID: "sender",
            transport: fixture.transport,
            store: fixture.senderState,
            assetStore: fixture.senderAssets,
            assetStager: fixture.senderStager,
            now: { retiredAt }
        )
        try await first.setEnabled(true)
        try await first.recordSavedClip(clip)
        await first.synchronize()
        try await first.recordDeletion(id: clip.id, kind: .savedClip)
        await first.synchronize()
        let retainedDigests = await fixture.transport.allAssetDigests()
        XCTAssertEqual(retainedDigests, [reference.digest])

        let later = retiredAt.addingTimeInterval(
            SavedLibrarySyncAssetPolicy.garbageCollectionGrace + 1
        )
        let reopened = try await SavedLibrarySyncCoordinator.open(
            deviceID: "sender",
            transport: fixture.transport,
            store: fixture.senderState,
            assetStore: fixture.senderAssets,
            assetStager: fixture.senderStager,
            now: { later }
        )
        await reopened.synchronize()
        let finalDigests = await fixture.transport.allAssetDigests()
        let finalSnapshot = await reopened.snapshot()
        // Client-side remote deletion is deliberately disabled. A second Mac may have
        // re-referenced this digest after our last fetch; only a server-coordinated GC can
        // prove it is globally unreferenced without racing that writer.
        XCTAssertEqual(finalDigests, [reference.digest])
        XCTAssertTrue(finalSnapshot.assetGarbage.isEmpty)
    }
}

private final class AssetSyncFixture: @unchecked Sendable {
    let root: URL
    let senderAssets: FileClipAssetStore
    let receiverAssets: FileClipAssetStore
    let senderStager: FileSavedLibrarySyncAssetStager
    let receiverStager: FileSavedLibrarySyncAssetStager
    let senderState = InMemorySavedLibrarySyncStateStore()
    let receiverState = InMemorySavedLibrarySyncStateStore()
    let transport = InMemorySavedLibrarySyncTransport()
    let senderStageRoot: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SavedLibraryAssetSyncTests-\(UUID())",
            isDirectory: true
        )
        senderStageRoot = root.appendingPathComponent("sender-stage", isDirectory: true)
        senderAssets = FileClipAssetStore(
            rootURL: root.appendingPathComponent("sender-assets", isDirectory: true)
        )
        receiverAssets = FileClipAssetStore(
            rootURL: root.appendingPathComponent("receiver-assets", isDirectory: true)
        )
        senderStager = FileSavedLibrarySyncAssetStager(rootURL: senderStageRoot)
        receiverStager = FileSavedLibrarySyncAssetStager(
            rootURL: root.appendingPathComponent("receiver-stage", isDirectory: true)
        )
    }

    func sender() async throws -> SavedLibrarySyncCoordinator {
        try await SavedLibrarySyncCoordinator.open(
            deviceID: "sender",
            transport: transport,
            store: senderState,
            assetStore: senderAssets,
            assetStager: senderStager
        )
    }

    func receiver() async throws -> SavedLibrarySyncCoordinator {
        try await SavedLibrarySyncCoordinator.open(
            deviceID: "receiver",
            transport: transport,
            store: receiverState,
            assetStore: receiverAssets,
            assetStager: receiverStager
        )
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private actor FailRecordOnceAssetTransport: SavedLibrarySyncTransport {
    private let base = InMemorySavedLibrarySyncTransport()
    private var shouldFailRecord = true

    func accountIdentity() async throws -> SyncAccountIdentity { try await base.accountIdentity() }
    func fetchChanges(after token: Data?) async throws -> SyncFetchBatch {
        try await base.fetchChanges(after: token)
    }
    func push(_ records: [SavedLibrarySyncRecord]) async throws {
        if shouldFailRecord {
            shouldFailRecord = false
            throw SavedLibrarySyncError.offline
        }
        try await base.push(records)
    }
    func pushAssets(_ assets: [SavedLibrarySyncAssetUpload]) async throws -> Set<String> {
        try await base.pushAssets(assets)
    }
    func fetchAssets(
        _ descriptors: [SavedLibrarySyncAssetDescriptor]
    ) async throws -> [SavedLibrarySyncAssetDownload] {
        try await base.fetchAssets(descriptors)
    }
    func garbageCollectAssets(digests: Set<String>) async throws {
        try await base.garbageCollectAssets(digests: digests)
    }
    func assetDigests() async -> Set<String> { await base.allAssetDigests() }
    func records() async -> [SavedLibrarySyncRecord] { await base.allRecords() }
}
