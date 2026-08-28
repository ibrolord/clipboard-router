import AppKit
import ClipboardRouterCore
import CryptoKit
import Foundation
import XCTest
@testable import ClipboardRouterSecurity

final class VaultTypedPayloadTests: XCTestCase {
    func testRichHTMLImageAndFilePayloadsRoundTripWithoutFlattening() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ordinaryAssets = FileClipAssetStore(rootURL: root.appendingPathComponent("ordinary"))
        let encryptedAssets = InMemoryVaultEncryptedAssetStore()
        let session = makeSession()
        let library = try await VaultLibrary.open(
            store: InMemoryVaultStore(),
            session: session,
            assetStore: encryptedAssets
        )
        try await session.unlock()

        let rtf = Data("{\\rtf1\\ansi Rich secret}".utf8)
        let html = Data("<b>Rich secret</b>".utf8)
        let rtfRef = try await ordinaryAssets.put(
            rtf,
            kind: .richText,
            uniformTypeIdentifier: "public.rtf",
            preferredExtension: "rtf"
        )
        let htmlRef = try await ordinaryAssets.put(
            html,
            kind: .html,
            uniformTypeIdentifier: "public.html",
            preferredExtension: "html"
        )
        let rich = try VaultItem(
            name: "Rich",
            content: ClipContent(
                type: .richText,
                text: "Rich secret",
                representations: ClipRepresentations(richText: rtfRef, html: htmlRef)
            ),
            createdAt: Date(timeIntervalSince1970: 10)
        )
        _ = try await library.add(rich, sourceAssets: ordinaryAssets)
        let richPayload = try await library.restoredPayload(id: rich.id)
        XCTAssertEqual(Set(richPayload.assets.map(\.data)), Set([rtf, html]))
        XCTAssertEqual(richPayload.content.type, .richText)

        let imageBytes = Data((0..<4_096).map { UInt8($0 % 251) })
        let imageRef = try await ordinaryAssets.put(
            imageBytes,
            kind: .image,
            uniformTypeIdentifier: "public.png",
            preferredExtension: "png"
        )
        let image = try VaultItem(
            name: "Image",
            content: ClipContent(
                type: .image,
                text: "OCR fallback only",
                representations: ClipRepresentations(image: imageRef)
            ),
            createdAt: Date(timeIntervalSince1970: 20)
        )
        _ = try await library.add(image, sourceAssets: ordinaryAssets)
        let imagePayload = try await library.restoredPayload(id: image.id)
        XCTAssertEqual(imagePayload.assets.map(\.data), [imageBytes])

        let fileURL = URL(fileURLWithPath: "/tmp/private proposal.pdf")
        let files = try VaultItem(
            name: "Files",
            content: ClipContent(
                type: .fileURLs,
                text: "private proposal.pdf",
                representations: ClipRepresentations(
                    files: [try ClipFileReference(url: fileURL)]
                )
            ),
            createdAt: Date(timeIntervalSince1970: 30)
        )
        _ = try await library.add(files)
        let filePayload = try await library.restoredPayload(id: files.id)
        XCTAssertEqual(filePayload.content.representations.files.map(\.url), [fileURL.standardizedFileURL])
        XCTAssertTrue(filePayload.assets.isEmpty)
    }

    func testChunkTamperingMissingAssetAndManifestMismatchFailClosed() async throws {
        let source = InMemoryClipAssetStore()
        let bytes = Data(repeating: 0x5a, count: VaultAssetPolicy.chunkByteCount + 37)
        let reference = try await source.put(
            bytes,
            kind: .image,
            uniformTypeIdentifier: "public.png",
            preferredExtension: "png"
        )
        let item = try VaultItem(
            name: "Chunked image",
            content: ClipContent(
                type: .image,
                text: "image",
                representations: ClipRepresentations(image: reference)
            ),
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let encryptedAssets = InMemoryVaultEncryptedAssetStore()
        let session = makeSession()
        let library = try await VaultLibrary.open(
            store: InMemoryVaultStore(),
            session: session,
            assetStore: encryptedAssets
        )
        try await session.unlock()
        _ = try await library.add(item, sourceAssets: source)
        let descriptor = try XCTUnwrap(item.assets.first)
        let storedEncrypted = await encryptedAssets.encryptedValue(
            for: descriptor.storageIdentifier
        )
        let original = try XCTUnwrap(storedEncrypted)

        var changed = original
        changed[changed.index(changed.startIndex, offsetBy: changed.count / 2)] ^= 0x01
        await encryptedAssets.replaceForTesting(
            storageIdentifier: descriptor.storageIdentifier,
            with: changed
        )
        await XCTAssertThrowsErrorAsync(try await library.restoredPayload(id: item.id))

        await encryptedAssets.replaceForTesting(
            storageIdentifier: descriptor.storageIdentifier,
            with: nil
        )
        await XCTAssertThrowsErrorAsync(try await library.restoredPayload(id: item.id)) { error in
            XCTAssertEqual(error as? VaultError, .missingAsset(descriptor.storageIdentifier))
        }

        let wrongReference = try ClipAssetReference(
            digest: String(repeating: "b", count: 64),
            kind: .image,
            uniformTypeIdentifier: "public.png",
            byteCount: reference.byteCount,
            relativePath: "wrong.png"
        )
        XCTAssertThrowsError(try VaultItem(
            id: item.id,
            name: item.name,
            content: ClipContent(
                type: .image,
                text: item.content.text,
                representations: ClipRepresentations(image: wrongReference)
            ),
            assets: item.assets,
            createdAt: item.createdAt
        )) { error in
            XCTAssertEqual(error as? VaultError, .invalidAssetManifest)
        }
    }

    func testRelaunchRecoveryIsIdempotentForTypedPayload() async throws {
        let source = InMemoryClipAssetStore()
        let bytes = Data("{\\rtf1 recovery canary}".utf8)
        let reference = try await source.put(
            bytes,
            kind: .richText,
            uniformTypeIdentifier: "public.rtf",
            preferredExtension: "rtf"
        )
        let item = try VaultItem(
            name: "Recovery",
            content: ClipContent(
                type: .richText,
                text: "recovery canary",
                representations: ClipRepresentations(richText: reference)
            ),
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let keyProvider = InMemoryVaultKeyProvider()
        let store = InMemoryVaultStore()
        let assets = InMemoryVaultEncryptedAssetStore()
        let firstSession = VaultSession(
            authenticator: StubVaultAuthenticator(),
            keyProvider: keyProvider
        )
        let first = try await VaultLibrary.open(
            store: store,
            session: firstSession,
            assetStore: assets
        )
        try await firstSession.unlock()
        _ = try await first.add(item, sourceAssets: source)
        await firstSession.lock()

        let secondSession = VaultSession(
            authenticator: StubVaultAuthenticator(),
            keyProvider: keyProvider
        )
        let reopened = try await VaultLibrary.open(
            store: store,
            session: secondSession,
            assetStore: assets
        )
        try await secondSession.unlock()
        let reopenedPayload = try await reopened.restoredPayload(id: item.id)
        XCTAssertEqual(reopenedPayload.assets.map(\.data), [bytes])
        await XCTAssertThrowsErrorAsync(
            try await reopened.add(item, sourceAssets: source)
        ) { error in
            XCTAssertEqual(error as? VaultError, .duplicateItem(item.id))
        }
        let reopenedSnapshot = await reopened.encryptedSnapshot()
        XCTAssertEqual(reopenedSnapshot.envelopes.count, 1)
    }

    @MainActor
    func testSecurePasteRestoresOriginalRepresentationsAndOwnershipMarkers() async throws {
        _ = NSApplication.shared
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let writer = SystemSecurePasteboard(pasteboard: pasteboard)
        let fileURL = URL(fileURLWithPath: "/tmp/vault-file.txt")
        let rtfDescriptor = try descriptor(
            kind: .richText,
            type: "public.rtf",
            bytes: Data("{\\rtf1 original}".utf8)
        )
        let htmlDescriptor = try descriptor(
            kind: .html,
            type: "public.html",
            bytes: Data("<b>original</b>".utf8),
            itemID: rtfDescriptor.itemID
        )
        let content = try ClipContent(
            type: .richText,
            text: "original",
            representations: ClipRepresentations(
                richText: rtfDescriptor.reference,
                html: htmlDescriptor.reference,
                files: [try ClipFileReference(url: fileURL)]
            )
        )
        // Mixed rich text and files is intentionally rejected by VaultItem, but the pasteboard
        // writer must still preserve every representation in an already authenticated payload.
        let payload = VaultRestoredPayload(
            content: content,
            sourceTypeIdentifiers: [NSPasteboard.PasteboardType.string.rawValue],
            assets: [
                VaultRestoredAsset(descriptor: rtfDescriptor.descriptor, data: rtfDescriptor.bytes),
                VaultRestoredAsset(descriptor: htmlDescriptor.descriptor, data: htmlDescriptor.bytes),
            ]
        )
        let marker = UUID().uuidString.lowercased()
        _ = try await writer.writeSecurePayload(payload, marker: marker)

        XCTAssertEqual(pasteboard.string(forType: .string), "original")
        XCTAssertEqual(pasteboard.data(forType: .rtf), rtfDescriptor.bytes)
        XCTAssertEqual(pasteboard.data(forType: .html), htmlDescriptor.bytes)
        XCTAssertTrue(pasteboard.readObjects(forClasses: [NSURL.self])?.contains {
            ($0 as? URL)?.standardizedFileURL == fileURL.standardizedFileURL
        } == true)
        XCTAssertEqual(pasteboard.string(forType: SystemSecurePasteboard.markerType), marker)
        XCTAssertTrue(SystemSecurePasteboard.writingOptions.contains(.currentHostOnly))
    }

    func testDiskCanaryAbsentAfterAuthenticatedVaultMoveAndSensitiveCheckpoint() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let canary = "VAULT-CANARY-\(UUID().uuidString)-DO-NOT-LEAK"
        let canaryData = Data("{\\rtf1 \(canary)}".utf8)
        let ordinaryAssets = FileClipAssetStore(
            rootURL: root.appendingPathComponent("clip-assets", isDirectory: true)
        )
        let reference = try await ordinaryAssets.put(
            canaryData,
            kind: .richText,
            uniformTypeIdentifier: "public.rtf",
            preferredExtension: "rtf"
        )
        let content = try ClipContent(
            type: .richText,
            text: canary,
            representations: ClipRepresentations(richText: reference)
        )
        let ordinaryStore = SQLiteFileClipboardLibraryStore(
            fileURL: root.appendingPathComponent("library.sqlite3")
        )
        let ordinary = try await ClipboardLibrary.open(persistence: ordinaryStore)
        _ = try await ordinary.capture(CaptureCandidate(
            content: content,
            pasteboardTypeIdentifiers: ["public.rtf", "public.utf8-plain-text"],
            capturedAt: Date(timeIntervalSince1970: 50)
        ))
        let ordinarySnapshot = await ordinary.snapshot()
        let history = try XCTUnwrap(ordinarySnapshot.history.first)

        let session = makeSession()
        let vaultStoreURL = root.appendingPathComponent("vault.encrypted.json")
        let vaultAssetRoot = root.appendingPathComponent("vault-assets", isDirectory: true)
        let vault = try await VaultLibrary.open(
            store: JSONFileVaultStore(fileURL: vaultStoreURL),
            session: session,
            assetStore: FileVaultEncryptedAssetStore(rootURL: vaultAssetRoot)
        )
        try await session.unlock()
        let item = try VaultItem(
            id: history.id,
            name: "Protected rich clip",
            content: history.content,
            createdAt: history.createdAt,
            modifiedAt: history.modifiedAt,
            provenance: VaultItemProvenance(
                ordinaryOrigin: .history,
                sourceHistoryItemID: history.id,
                sourceHistoryFingerprint: VaultHistoryItemFingerprint(history),
                pasteboardTypeIdentifiers: history.pasteboardTypeIdentifiers ?? []
            )
        )
        _ = try await vault.add(item, sourceAssets: ordinaryAssets)
        try await vault.verifyAssets(for: item)
        _ = try await ordinary.deleteOrdinaryCopiesForVaultMove(
            expectedHistoryItem: history,
            expectedSavedClips: [],
            forbiddenFolderIDs: []
        )
        _ = try await ordinaryAssets.collectGarbage(keeping: [], olderThan: .distantFuture)

        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        var inspectedFiles: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }
            inspectedFiles.append(url)
            let data = try Data(contentsOf: url)
            XCTAssertNil(data.range(of: Data(canary.utf8)), "Plaintext canary leaked in \(url.path)")
            XCTAssertNil(data.range(of: canaryData), "Original typed bytes leaked in \(url.path)")
        }
        XCTAssertTrue(inspectedFiles.contains { $0.lastPathComponent == "library.sqlite3" })
        XCTAssertTrue(inspectedFiles.contains { $0.lastPathComponent == "vault.encrypted.json" })
        XCTAssertTrue(inspectedFiles.contains { $0.pathExtension == "vaultasset" })
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("library.sqlite3-wal").path)
            && ((try? Data(contentsOf: root.appendingPathComponent("library.sqlite3-wal")).count) ?? 0) > 0)

        let directoryMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: vaultAssetRoot.path)[.posixPermissions]
                as? NSNumber
        ).intValue & 0o777
        XCTAssertEqual(directoryMode, 0o700)
        let vaultAsset = try XCTUnwrap(inspectedFiles.first { $0.pathExtension == "vaultasset" })
        let assetMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: vaultAsset.path)[.posixPermissions]
                as? NSNumber
        ).intValue & 0o777
        XCTAssertEqual(assetMode, 0o600)
        let storeMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: vaultStoreURL.path)[.posixPermissions]
                as? NSNumber
        ).intValue & 0o777
        XCTAssertEqual(storeMode, 0o600)
    }

    private func makeSession() -> VaultSession {
        VaultSession(
            authenticator: StubVaultAuthenticator(),
            keyProvider: InMemoryVaultKeyProvider()
        )
    }

    private func descriptor(
        kind: ClipAssetKind,
        type: String,
        bytes: Data,
        itemID: UUID = UUID()
    ) throws -> (itemID: UUID, reference: ClipAssetReference, descriptor: VaultAssetDescriptor, bytes: Data) {
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let reference = try ClipAssetReference(
            digest: digest,
            kind: kind,
            uniformTypeIdentifier: type,
            byteCount: bytes.count,
            relativePath: "\(digest).bin"
        )
        return (itemID, reference, try VaultAssetDescriptor(itemID: itemID, reference: reference), bytes)
    }
}

private actor InMemoryClipAssetStore: ClipAssetStoring {
    private var values: [String: Data] = [:]

    func put(
        _ data: Data,
        kind: ClipAssetKind,
        uniformTypeIdentifier: String,
        preferredExtension: String?
    ) async throws -> ClipAssetReference {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        values[digest] = data
        return try ClipAssetReference(
            digest: digest,
            kind: kind,
            uniformTypeIdentifier: uniformTypeIdentifier,
            byteCount: data.count,
            relativePath: digest
        )
    }

    func read(_ reference: ClipAssetReference) async throws -> Data {
        guard let value = values[reference.digest] else {
            throw ClipAssetStoreError.missingAsset(reference.digest)
        }
        return value
    }

    func collectGarbage(
        keeping references: Set<ClipAssetReference>,
        olderThan cutoff: Date
    ) async throws -> Int { 0 }
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
