import ClipboardRouterCore
import ClipboardRouterSecurity
import Foundation
import XCTest

private final class TestDate: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_000)
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
}

private actor CountingAssetStore: VaultEncryptedAssetStoring {
    private let inner = InMemoryVaultEncryptedAssetStore()
    private(set) var reads = 0
    func write(_ encrypted: Data, descriptor: VaultAssetDescriptor) async throws {
        try await inner.write(encrypted, descriptor: descriptor)
    }
    func read(descriptor: VaultAssetDescriptor) async throws -> Data {
        reads += 1
        return try await inner.read(descriptor: descriptor)
    }
    func remove(descriptor: VaultAssetDescriptor) async throws {
        try await inner.remove(descriptor: descriptor)
    }
}

/// Synthetic-only proofs for the agent handoff path.
final class VaultAgentHandoffTests: XCTestCase {
    private func makeVault(clock: TestDate, timeout: TimeInterval = 10) async throws -> (VaultSession, VaultLibrary, CountingAssetStore, VaultItem) {
        let session = VaultSession(
            authenticator: StubVaultAuthenticator(),
            keyProvider: InMemoryVaultKeyProvider(),
            timeout: timeout,
            now: { clock.now }
        )
        let assets = CountingAssetStore()
        let library = try await VaultLibrary.open(store: InMemoryVaultStore(), session: session, assetStore: assets)
        try await session.unlock()
        let item = try await library.add(VaultItem(
            name: "Synthetic token",
            content: ClipContent(type: .plainText, text: "SYNTHETIC-VAULT-CANARY"),
            createdAt: clock.now,
            modifiedAt: clock.now
        ))
        return (session, library, assets, item)
    }

    private func assertLocked(_ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await body()
            XCTFail("expected denial", file: file, line: line)
        } catch {
            XCTAssertTrue(error as? VaultError == .locked || { if case .itemNotFound = error as? VaultError { return true }; return false }(),
                          "unexpected \(error)", file: file, line: line)
        }
    }

    func testPreviewAndReleaseReturnApprovedItemWithoutAssetReads() async throws {
        let (_, library, assets, item) = try await makeVault(clock: TestDate())
        let preview = try await library.agentHandoffPreview(id: item.id)
        XCTAssertEqual(preview.item.content.text, "SYNTHETIC-VAULT-CANARY")
        let released = try await library.releaseApprovedAgentHandoff(preview.approval) { item, _ in item.content.text }
        XCTAssertEqual(released, "SYNTHETIC-VAULT-CANARY")
        let reads = await assets.reads
        XCTAssertEqual(reads, 0)
    }

    func testReadsAtTMinusOneDoNotExtendOriginalDeadline() async throws {
        let clock = TestDate()
        let (session, library, _, item) = try await makeVault(clock: clock)
        clock.advance(9)
        let preview = try await library.agentHandoffPreview(id: item.id)
        _ = try await library.releaseApprovedAgentHandoff(preview.approval) { _, _ in true }
        _ = await session.currentUnlockEpoch()
        clock.advance(1.01)
        let epoch = await session.currentUnlockEpoch()
        XCTAssertNil(epoch, "agent reads must not keep the Vault unlocked past its original deadline")
        await assertLocked { _ = try await library.releaseApprovedAgentHandoff(preview.approval) { _, _ in true } }
    }

    func testApprovalThenLockThenUnlockIsDenied() async throws {
        let (session, library, _, item) = try await makeVault(clock: TestDate())
        let preview = try await library.agentHandoffPreview(id: item.id)
        await session.lock()
        try await session.unlock()
        let unlocked = await session.isUnlocked
        XCTAssertTrue(unlocked)
        await assertLocked { _ = try await library.releaseApprovedAgentHandoff(preview.approval) { _, _ in true } }
        await session.handleLifecycleEvent(.appDidEnterBackground)
        await assertLocked { _ = try await library.agentHandoffPreview(id: item.id) }
    }

    func testSameTimestampReplacementIsDenied() async throws {
        let clock = TestDate()
        let (_, library, _, item) = try await makeVault(clock: clock)
        let preview = try await library.agentHandoffPreview(id: item.id)
        let replacement = try VaultItem(
            id: item.id,
            kind: item.kind,
            name: item.name,
            content: ClipContent(type: .plainText, text: "SYNTHETIC-REPLACED"),
            assets: item.assets,
            createdAt: item.createdAt,
            modifiedAt: item.modifiedAt,
            provenance: item.provenance
        )
        try await library.replace(replacement)
        await assertLocked { _ = try await library.releaseApprovedAgentHandoff(preview.approval) { _, _ in true } }
    }

    func testDeletionDuringSuspendedApprovalIsDenied() async throws {
        let (_, library, _, item) = try await makeVault(clock: TestDate())
        let preview = try await library.agentHandoffPreview(id: item.id)
        try await library.delete(id: item.id)
        await assertLocked { _ = try await library.releaseApprovedAgentHandoff(preview.approval) { _, _ in true } }
    }

    /// Formal review 1 / F3: the idle deadline can pass while the handoff body waits for another
    /// lock; the check handed to the body must report it (without extending the deadline).
    func testUnlockCheckReportsDeadlinePassedDuringBody() async throws {
        let clock = TestDate()
        let (session, library, _, item) = try await makeVault(clock: clock)
        clock.advance(9)
        let preview = try await library.agentHandoffPreview(id: item.id)
        let observed = try await library.releaseApprovedAgentHandoff(preview.approval) { _, unlock in
            let before = unlock.isStillUnlocked()
            clock.advance(1.5) // simulated wait for the authority lock
            return (before, unlock.isStillUnlocked())
        }
        XCTAssertEqual(observed.0, true)
        XCTAssertEqual(observed.1, false)
        let epoch = await session.currentUnlockEpoch()
        XCTAssertNil(epoch, "the deadline was never extended")
    }

    func testExistingUIReadsStillExtendDeadline() async throws {
        let clock = TestDate()
        let (session, library, _, item) = try await makeVault(clock: clock)
        clock.advance(9)
        _ = try await library.existingItem(id: item.id)
        clock.advance(5)
        let unlocked = await session.isUnlocked
        XCTAssertTrue(unlocked, "foreground UI behavior is unchanged")
    }
}
