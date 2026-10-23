import Darwin
import Foundation
import XCTest
@testable import ClipboardRouterAgentAccess
@testable import ClipboardRouterApp
import ClipboardRouterCore
import ClipboardRouterPlatform
import ClipboardRouterSecurity

@MainActor
private final class LifecycleNoopWriter: TypedPasteboardWriting {
    func write(_ content: ClipContent, mode: ClipPasteboardWriteMode) async throws {}
}

@MainActor
private final class LifecycleNoopHotKey: GlobalHotKeyRegistering {
    func register(_ descriptor: GlobalHotKeyDescriptor, handler: @escaping @MainActor @Sendable () -> Void) throws {}
    func unregister() {}
}

/// AppModel-level ordering proof: agent authority is revoked synchronously inside the
/// lifecycle notification handler, before the asynchronous Vault cleanup can run.
@MainActor
final class AgentAccessLifecycleAppTests: XCTestCase {
    private func makeModel() throws -> AppModel {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentAccessLifecycleAppTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return AppModel(
            defaults: UserDefaults(suiteName: "AgentAccessLifecycleAppTests.\(UUID())")!,
            typedPasteboardWriter: LifecycleNoopWriter(),
            hotKey: LifecycleNoopHotKey(),
            supportDirectory: support,
            vaultSession: VaultSession(authenticator: StubVaultAuthenticator(), keyProvider: InMemoryVaultKeyProvider()),
            vaultStore: InMemoryVaultStore(),
            vaultAssetStore: InMemoryVaultEncryptedAssetStore(),
            libraryPersistence: InMemoryClipboardLibraryStore()
        )
    }

    /// Opens an approved synthetic session with one pending Vault request directly on the
    /// model's authority (no listener, no signing).
    private func openSession(_ authority: AgentAccessAuthority) throws -> (String, VaultRequestKey, Int32, Int32) {
        authority.setEnabled(true)
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        for fd in fds { LocalSocket.configure(fd); LocalSocket.setNonBlocking(fd) }
        let connection = try XCTUnwrap(authority.registerConnection(fd: fds[0]))
        let session = try XCTUnwrap(authority.openSession(connectionID: connection, displayName: "Synthetic", pairingTimeout: 60, lifetime: 600))
        XCTAssertTrue(authority.decidePairing(session.id, approve: true))
        guard case let .success(key) = authority.openVaultRequest(connectionID: connection, sessionID: session.id, requestID: 1, purpose: "Synthetic", timeout: 60) else {
            XCTFail("vault request not opened")
            throw CancellationError()
        }
        return (session.id, key, fds[0], fds[1])
    }

    func testScreenLockRevokesSessionsSynchronouslyBeforeAsyncCleanup() throws {
        let model = try makeModel()
        let authority = model.agentAccess.authority
        let (sessionID, key, a, b) = try openSession(authority)
        defer { close(a); close(b) }
        model.receiveLifecycleNotification(.screenDidLock)
        // No await between the notification and these checks: the async Vault cleanup task
        // has not run yet, so this proves the synchronous ordering.
        XCTAssertEqual(authority.sessionState(sessionID), .revoked)
        XCTAssertFalse(authority.isVaultRequestPending(key))
        XCTAssertNotEqual(authority.releaseVault(key) { VaultHandoff(kind: .text, text: "CR-SYNTHETIC-LATE") }, .handedOff)
    }

    func testBackgroundCancelsVaultRequestsButKeepsClipSessions() throws {
        let model = try makeModel()
        let authority = model.agentAccess.authority
        let (sessionID, key, a, b) = try openSession(authority)
        defer { close(a); close(b) }
        model.receiveLifecycleNotification(.appDidEnterBackground)
        XCTAssertFalse(authority.isVaultRequestPending(key), "Vault request cancelled before any await")
        XCTAssertEqual(authority.sessionState(sessionID), .approved, "ordinary deactivation keeps clip sessions")
    }
}
