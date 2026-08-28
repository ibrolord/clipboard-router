import ClipboardRouterCore
import ClipboardRouterPlatform
import ClipboardRouterSecurity
import CryptoKit
import Foundation
import XCTest
@testable import ClipboardRouterApp

@MainActor
final class VaultTypedPayloadAppTests: XCTestCase {
    func testRichClipMovesThroughAppAndRestoresOriginalBytesAfterRelaunch() async throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultTypedPayloadAppTests-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: support) }
        let rtf = Data("{\\rtf1\\ansi Reviewed rich content}".utf8)
        let html = Data("<p><b>Reviewed rich content</b></p>".utf8)
        let vaultStore = InMemoryVaultStore()
        let vaultAssets = InMemoryVaultEncryptedAssetStore()
        let keyProvider = InMemoryVaultKeyProvider()
        let firstSession = VaultSession(
            authenticator: StubVaultAuthenticator(),
            keyProvider: keyProvider
        )
        let model = AppModel(
            defaults: UserDefaults(suiteName: "VaultTypedPayloadAppTests.\(UUID())")!,
            typedPasteboardWriter: AppVaultTypedWriter(),
            hotKey: AppVaultNoopHotKey(),
            supportDirectory: support,
            vaultSession: firstSession,
            vaultStore: vaultStore,
            vaultAssetStore: vaultAssets,
            libraryPersistence: InMemoryClipboardLibraryStore()
        )
        await model.start()
        model.capture(PasteboardCaptureDraft(
            changeCount: 1,
            typeIdentifiers: ["public.rtf", "public.html", "public.utf8-plain-text"],
            plainText: "Reviewed rich content",
            richTextData: rtf,
            htmlData: html,
            capturedAt: Date(timeIntervalSince1970: 1_000)
        ))
        // Capture materialization is intentionally asynchronous and can include secure asset
        // writes. Allow normal co-execution load without weakening the observable assertion.
        let captured = await waitUntil(timeout: .seconds(3)) { model.menuBarRecentClips.count == 1 }
        XCTAssertTrue(captured)
        let clip = try XCTUnwrap(model.menuBarRecentClips.first)
        XCTAssertEqual(clip.content.type, .richText)
        XCTAssertTrue(model.canMoveClipToVault(clip))

        model.moveClipToVault(clip)
        let moved = await waitUntil(timeout: .seconds(2)) {
            model.snapshot.history.isEmpty && model.vaultEncryptedItemCount == 1
        }
        XCTAssertTrue(moved)
        await firstSession.lock()

        let secondSession = VaultSession(
            authenticator: StubVaultAuthenticator(),
            keyProvider: keyProvider
        )
        let reopened = try await VaultLibrary.open(
            store: vaultStore,
            session: secondSession,
            assetStore: vaultAssets
        )
        try await secondSession.unlock()
        let payload = try await reopened.restoredPayload(id: clip.id)
        XCTAssertEqual(payload.content.type, .richText)
        XCTAssertEqual(Set(payload.assets.map(\.data)), Set([rtf, html]))
        XCTAssertEqual(
            Set(payload.sourceTypeIdentifiers),
            ["public.rtf", "public.html", "public.utf8-plain-text"]
        )
    }

    func testMissingVaultAssetPreventsRelaunchRecoveryFromDeletingOrdinarySource() async throws {
        let rtf = Data("{\\rtf1\\ansi Keep ordinary source}".utf8)
        let ordinaryAssets = AppVaultMemoryAssetStore()
        let reference = try await ordinaryAssets.put(
            rtf,
            kind: .richText,
            uniformTypeIdentifier: "public.rtf",
            preferredExtension: "rtf"
        )
        let content = try ClipContent(
            type: .richText,
            text: "Keep ordinary source",
            representations: ClipRepresentations(richText: reference)
        )
        let history = HistoryItem(content: content, createdAt: Date())
        let vaultStore = InMemoryVaultStore()
        let vaultAssets = InMemoryVaultEncryptedAssetStore()
        let keyProvider = InMemoryVaultKeyProvider()
        let session = VaultSession(
            authenticator: StubVaultAuthenticator(),
            keyProvider: keyProvider
        )
        let vault = try await VaultLibrary.open(
            store: vaultStore,
            session: session,
            assetStore: vaultAssets
        )
        try await session.unlock()
        let item = try VaultItem(
            id: history.id,
            name: history.content.text,
            content: history.content,
            createdAt: history.createdAt,
            provenance: VaultItemProvenance(
                ordinaryOrigin: .history,
                sourceHistoryItemID: history.id,
                sourceHistoryFingerprint: VaultHistoryItemFingerprint(history)
            )
        )
        _ = try await vault.add(item, sourceAssets: ordinaryAssets)
        let descriptor = try XCTUnwrap(item.assets.first)
        await vaultAssets.replaceForTesting(storageIdentifier: descriptor.storageIdentifier, with: nil)
        await session.lock()

        let model = AppModel(
            defaults: UserDefaults(suiteName: "VaultTypedPayloadAppTests.\(UUID())")!,
            typedPasteboardWriter: AppVaultTypedWriter(),
            hotKey: AppVaultNoopHotKey(),
            supportDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("VaultTypedPayloadAppTests-\(UUID())"),
            vaultSession: session,
            vaultStore: vaultStore,
            vaultAssetStore: vaultAssets,
            libraryPersistence: InMemoryClipboardLibraryStore(
                snapshot: ClipboardLibrarySnapshot(history: [history])
            )
        )
        await model.start()
        model.unlockVault()

        let completedUnlockAttempt = await waitUntil {
            model.errorMessage != nil || model.statusMessage != nil
        }
        XCTAssertTrue(completedUnlockAttempt)
        XCTAssertEqual(model.snapshot.history.map(\.id), [history.id])
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

@MainActor
private final class AppVaultTypedWriter: TypedPasteboardWriting {
    func write(_ content: ClipContent, mode: ClipPasteboardWriteMode) async throws {}
}

@MainActor
private final class AppVaultNoopHotKey: GlobalHotKeyRegistering {
    func register(
        _ descriptor: GlobalHotKeyDescriptor,
        handler: @escaping @MainActor @Sendable () -> Void
    ) throws {}
    func unregister() {}
}

private actor AppVaultMemoryAssetStore: ClipAssetStoring {
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
