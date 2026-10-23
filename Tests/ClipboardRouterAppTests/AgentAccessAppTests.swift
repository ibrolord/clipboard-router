import Darwin
import Foundation
import XCTest
@testable import ClipboardRouterAgentAccess
@testable import ClipboardRouterApp
import ClipboardRouterCore
import ClipboardRouterSecurity

final class AgentAccessAsyncGate: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)
    func pass() async {
        entered.signal()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                self.released.wait()
                continuation.resume()
            }
        }
    }
    func waitUntilEntered() -> Bool { entered.wait(timeout: .now() + 5) == .success }
    func release() { released.signal() }
}

final class AuthorityBoxForTest: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: AgentAccessAuthority?
    var authority: AgentAccessAuthority? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

final class AgentAccessResponseBox: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var value: BrokerResponse?
    func set(_ response: BrokerResponse?) { lock.withLock { value = response }; semaphore.signal() }
    func wait() -> BrokerResponse? {
        _ = semaphore.wait(timeout: .now() + 10)
        return lock.withLock { value }
    }
}

/// Synthetic-only app-level tests: real ClipboardLibrary (in-memory), real VaultLibrary with
/// in-memory key/store/assets, the production backend and authority, connected over a
/// socketpair with an injected peer authenticator (no signing, no listener, no Keychain).
@MainActor
final class AgentAccessAppTests: XCTestCase {
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    let folderID = UUID(uuidString: "F0000000-0000-0000-0000-000000000001")!
    let otherFolderID = UUID(uuidString: "F0000000-0000-0000-0000-000000000002")!
    let sharedFolderID = UUID(uuidString: "F0000000-0000-0000-0000-000000000003")!
    let clipA = UUID(uuidString: "C0000000-0000-0000-0000-00000000000A")!
    let clipB = UUID(uuidString: "C0000000-0000-0000-0000-00000000000B")!
    let clipC = UUID(uuidString: "C0000000-0000-0000-0000-00000000000C")!
    let clipSecret = UUID(uuidString: "C0000000-0000-0000-0000-00000000000D")!
    let clipSecretTitle = UUID(uuidString: "C0000000-0000-0000-0000-00000000000E")!
    let clipFile = UUID(uuidString: "C0000000-0000-0000-0000-00000000000F")!
    let clipShared = UUID(uuidString: "C0000000-0000-0000-0000-000000000010")!
    let clipURL = UUID(uuidString: "C0000000-0000-0000-0000-000000000011")!
    let historyID = UUID(uuidString: "D0000000-0000-0000-0000-000000000001")!

    func makeLibrary() throws -> ClipboardLibrary {
        let folders = [
            try ClipFolder(id: folderID, name: "Synthetic scoped", sortOrder: 0, createdAt: date),
            try ClipFolder(id: otherFolderID, name: "Synthetic other", sortOrder: 1, createdAt: date),
            try ClipFolder(id: sharedFolderID, name: "Synthetic collaborative", sortOrder: 2, createdAt: date),
        ]
        func clip(_ id: UUID, _ name: String, _ text: String, folder: UUID? = nil, type: SupportedContentType = .plainText, minutes: Double = 0) throws -> SavedClip {
            try SavedClip(id: id, name: name, content: ClipContent(type: type, text: text), folderID: folder,
                          createdAt: date, modifiedAt: date.addingTimeInterval(minutes * 60))
        }
        let saved = [
            try clip(clipA, "Synthetic A", "CR-SYNTHETIC-A", minutes: 3),
            try clip(clipB, "Synthetic B", "CR-SYNTHETIC-B-NOT-SCOPED"),
            try clip(clipC, "Synthetic C", "CR-SYNTHETIC-C-IN-FOLDER", folder: folderID, minutes: 2),
            try clip(clipSecret, "Synthetic secret", "token ghp_9876543210zyxwvutsrqponmlkjihgfedcbaZY"),
            try clip(clipSecretTitle, "ghp_0123456789abcdefghijklmnopqrstuvwxyzAB", "CR-SYNTHETIC-TITLE-SECRET-BODY"),
            try clip(clipFile, "Synthetic file", "file:///tmp/cr-synthetic", type: .fileURLs),
            try clip(clipShared, "Synthetic collab", "CR-SYNTHETIC-COLLAB", folder: sharedFolderID),
            try clip(clipURL, "Synthetic link", "https://example.com/cr-synthetic", type: .url, minutes: 1),
        ]
        let history = [HistoryItem(id: historyID, content: try ClipContent.detect(text: "CR-SYNTHETIC-HISTORY"), createdAt: date)]
        return try ClipboardLibrary(snapshot: ClipboardLibrarySnapshot(history: history, savedClips: saved, folders: folders))
    }

    struct Rig {
        var controller: AgentAccessController
        var library: ClipboardLibrary
        var vault: VaultLibrary
        var session: VaultSession
        var client: BrokerClient
        var sessionID: String
        var done: DispatchSemaphore
    }

    var activeApp = true

    func makeRig(
        gate: AgentAccessAsyncGate? = nil,
        enable: Bool = true,
        pair: Bool = true,
        insideSnapshot: (@Sendable () -> Void)? = nil
    ) async throws -> Rig {
        let library = try makeLibrary()
        let session = VaultSession(authenticator: StubVaultAuthenticator(), keyProvider: InMemoryVaultKeyProvider())
        let vault = try await VaultLibrary.open(store: InMemoryVaultStore(), session: session)
        let defaults = UserDefaults(suiteName: "AgentAccessAppTests.\(UUID())")!
        let controller = AgentAccessController(
            defaults: defaults,
            isMacAppStore: false,
            resolveIdentity: { throw AgentAccessIdentityError.unsignedOrAdHoc },
            isAppActive: { [unowned self] in self.activeApp },
            requestAttention: {},
            vaultLibrary: { vault }
        )
        controller.attach(library: library)
        XCTAssertFalse(controller.authority.isEnabled, "unsigned test build never enables the listener")
        if enable { controller.authority.setEnabled(true) }
        controller.setClip(clipA, included: true)
        controller.setClip(clipSecret, included: true)
        controller.setClip(clipSecretTitle, included: true)
        controller.setClip(clipFile, included: true)
        controller.setClip(clipShared, included: true)
        controller.setClip(clipURL, included: true)
        controller.setFolder(folderID, included: true)
        controller.addExclusions(folderIDs: [sharedFolderID], savedClipIDs: [])

        let backend = AgentAccessLibraryBackend(
            state: controller.shared,
            projection: controller.projection,
            notify: { _ in Task { @MainActor in controller.refresh() } },
            beforeHandoff: Self.hook(gate),
            insideSnapshot: insideSnapshot
        )
        let handler = BrokerConnectionHandler(
            authority: controller.authority,
            backend: backend,
            authenticate: { _ in VerifiedPeer(identifier: "com.clipboardrouter.cr", teamIdentifier: "TEAMTEST01", processIdentifier: 1) },
            log: { event in XCTAssertFalse(event.line.contains("CR-SYNTHETIC")) }
        )
        var fds: [Int32] = [0, 0]
        precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        for fd in fds { LocalSocket.configure(fd); LocalSocket.setNonBlocking(fd) }
        let done = DispatchSemaphore(value: 0)
        if let connectionID = controller.authority.registerConnection(fd: fds[0]) {
            let serverFD = fds[0]
            Thread { handler.serve(serverFD, connectionID: connectionID); done.signal() }.start()
        } else {
            close(fds[0])
        }
        let client = BrokerClient(fd: fds[1], server: VerifiedPeer(identifier: "app", teamIdentifier: nil, processIdentifier: 0),
                                  timing: BrokerConnectTiming(connectMilliseconds: 0, verifyMilliseconds: 0), limits: .standard)
        var sessionID = ""
        if enable {
            let hello = try client.hello(displayName: "Synthetic agent")
            sessionID = hello.sessionID
            if pair {
                controller.approvePairing(hello.sessionID)
                let paired = try await call(client, sessionID, 1, .awaitPairing)
                XCTAssertEqual(paired, .sessionState(.approved))
            }
        }
        return Rig(controller: controller, library: library, vault: vault, session: session, client: client, sessionID: sessionID, done: done)
    }

    func call(_ client: BrokerClient, _ session: String, _ id: UInt32, _ operation: BrokerOperation) async throws -> BrokerResult {
        try await Task.detached { try client.call(sessionID: session, requestID: id, operation).result }.value
    }

    nonisolated static func hook(_ gate: AgentAccessAsyncGate?) -> (@Sendable () async -> Void)? {
        guard let gate else { return nil }
        return { await gate.pass() }
    }

    func id(_ uuid: UUID) -> String { uuid.uuidString.lowercased() }

    func waitFor(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
        for _ in 0..<250 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    // MARK: Scope and data rules

    func testFreshInstallIsDisabledAndServesNothing() async throws {
        let defaults = UserDefaults(suiteName: "AgentAccessAppTests.fresh.\(UUID())")!
        let controller = AgentAccessController(defaults: defaults, isMacAppStore: false,
                                               resolveIdentity: { throw AgentAccessIdentityError.unsignedOrAdHoc },
                                               vaultLibrary: { nil })
        XCTAssertFalse(controller.isEnabled)
        XCTAssertEqual(controller.scope, .empty)
        let rig = try await makeRig(enable: false)
        var buffer = [UInt8](repeating: 0, count: 16)
        try? LocalSocket.wait(rig.client.fd, events: Int16(POLLIN), deadline: .after(2))
        XCTAssertEqual(recv(rig.client.fd, &buffer, buffer.count, 0), 0, "disabled access sends zero bytes")
    }

    func testMacAppStoreBuildIsAlwaysUnavailable() throws {
        let controller = AgentAccessController(
            defaults: UserDefaults(suiteName: "AgentAccessAppTests.mas.\(UUID())")!,
            isMacAppStore: true,
            resolveIdentity: { XCTFail("MAS must not even resolve identity"); throw AgentAccessIdentityError.unsignedOrAdHoc },
            vaultLibrary: { nil }
        )
        controller.attach(library: try makeLibrary())
        controller.setEnabled(true)
        XCTAssertEqual(controller.availability, .unavailable("Agent Access is available in the direct-download version of Clipboard Router."))
        XCTAssertFalse(controller.authority.isEnabled)
    }

    func testListAndReadOnlyExactEligibleScope() async throws {
        let rig = try await makeRig()
        let listed = try await call(rig.client, rig.sessionID, 2, .listSharedClips(limit: 50))
        guard case let .sharedClips(list) = listed else {
            return XCTFail("expected list")
        }
        XCTAssertEqual(list.map(\.id), [id(clipA), id(clipC), id(clipURL)], "newest first; only eligible scoped clips")
        XCTAssertEqual(list.map(\.kind), [.text, .text, .url])
        XCTAssertEqual(list.first?.title, "Synthetic A")
        let read = try await call(rig.client, rig.sessionID, 3, .getSharedClip(id: id(clipC)))
        XCTAssertEqual(read, .sharedClip(SharedClipContent(id: id(clipC), kind: .text, text: "CR-SYNTHETIC-C-IN-FOLDER")))
        let notFound = BrokerResult.failure(.notFound)
        for (index, excluded) in [clipB, clipSecret, clipSecretTitle, clipFile, clipShared, historyID, UUID()].enumerated() {
            let result = try await call(rig.client, rig.sessionID, UInt32(10 + index), .getSharedClip(id: id(excluded)))
            XCTAssertEqual(result, notFound, "excluded/withheld/history/nonexistent IDs are indistinguishable")
        }
        let malformed = try await call(rig.client, rig.sessionID, 30, .getSharedClip(id: "not-a-uuid"))
        XCTAssertEqual(malformed, notFound)
        let snapshot = await rig.library.snapshot()
        let secret = try XCTUnwrap(snapshot.savedClips.first { $0.id == clipSecretTitle })
        XCTAssertEqual(rig.controller.eligibility(of: secret, in: snapshot), .sensitive)
        let shared = try XCTUnwrap(snapshot.savedClips.first { $0.id == clipShared })
        XCTAssertEqual(rig.controller.eligibility(of: shared, in: snapshot), .collaborativeFolder)
    }

    func testPendingLocalEditSurvivesRemoteProjectionAndServesOffline() async throws {
        let rig = try await makeRig()
        try await rig.library.renameSavedClip(id: clipA, to: "Synthetic A local edit", at: date.addingTimeInterval(600))
        // A stale remote copy of the same clip must not replace the pending local edit.
        let remote = try SavedClip(id: clipA, name: "Synthetic A remote", content: ClipContent(type: .plainText, text: "CR-SYNTHETIC-A-REMOTE"),
                                   createdAt: date, modifiedAt: date.addingTimeInterval(300))
        try await rig.library.applySyncedSavedLibrary(savedClips: [remote], folders: [], managedSavedClipIDs: [clipA], managedFolderIDs: [])
        let listed = try await call(rig.client, rig.sessionID, 2, .listSharedClips(limit: 50))
        guard case let .sharedClips(list) = listed else {
            return XCTFail("expected list")
        }
        XCTAssertEqual(list.first { $0.id == id(clipA) }?.title, "Synthetic A local edit")
        let read = try await call(rig.client, rig.sessionID, 3, .getSharedClip(id: id(clipA)))
        XCTAssertEqual(read, .sharedClip(SharedClipContent(id: id(clipA), kind: .text, text: "CR-SYNTHETIC-A")),
                       "already-local clip served with no network or sync involvement")
    }

    func testRevokeScopeRemoveOrMoveDuringSuspendedReadReleasesNothing() async throws {
        for change in ["scope", "delete", "move", "session"] {
            let gate = AgentAccessAsyncGate()
            let rig = try await makeRig(gate: gate)
            let target = change == "move" ? clipC : clipA
            let box = AgentAccessResponseBox()
            let client = rig.client
            let sessionID = rig.sessionID
            Thread { box.set(try? client.call(sessionID: sessionID, requestID: 9, .getSharedClip(id: target.uuidString.lowercased()))) }.start()
            XCTAssertTrue(gate.waitUntilEntered(), change)
            switch change {
            case "scope": rig.controller.clearScope()
            case "delete": try await rig.library.deleteSavedClip(id: target)
            case "move": try await rig.library.moveSavedClip(id: target, to: otherFolderID)
            default: rig.controller.revoke(sessionID)
            }
            gate.release()
            let result = box.wait()?.result
            // A revoked session's connection is shut down, so no reply at all is also correct.
            if change != "session" { XCTAssertNotNil(result, change) }
            XCTAssertFalse(result?.carriesContent ?? false, "\(change) before handoff must release zero content")
        }
    }

    func testSelectedLocalFolderTurningCollaborativeDuringSuspendedReadLeaksNothing() async throws {
        // Formal review 1 / F1: an exclusion widened after the committed snapshot was taken but
        // before the handoff (the window where exclusions used to be copied) must still apply.
        for operation in ["list", "get"] {
            let box = AuthorityBoxForTest()
            let folder = folderID
            let rig = try await makeRig(insideSnapshot: {
                box.authority?.widenExclusions(folderIDs: [folder], savedClipIDs: [])
            })
            box.authority = rig.controller.authority
            let request: BrokerOperation = operation == "list" ? .listSharedClips(limit: 50) : .getSharedClip(id: id(clipC))
            let result = try await call(rig.client, rig.sessionID, 9, request)
            let encoded = String(decoding: try BrokerProtocol.encode(result), as: UTF8.self)
            XCTAssertFalse(encoded.contains(id(clipC)), "\(operation): exclusion evaluated at handoff: \(encoded)")
            XCTAssertFalse(encoded.contains("CR-SYNTHETIC-C-IN-FOLDER"))
        }
        for operation in ["list", "get"] {
            let gate = AgentAccessAsyncGate()
            let rig = try await makeRig(gate: gate)
            let collaboratorClip = UUID()
            let box = AgentAccessResponseBox()
            let client = rig.client
            let sessionID = rig.sessionID
            let request: BrokerOperation = operation == "list"
                ? .listSharedClips(limit: 50)
                : .getSharedClip(id: collaboratorClip.uuidString.lowercased())
            Thread { box.set(try? client.call(sessionID: sessionID, requestID: 9, request)) }.start()
            XCTAssertTrue(gate.waitUntilEntered())
            // The scoped local folder becomes collaborative (exclusion widened synchronously, as
            // AppModel's shared-folder didSet does) and a collaborator's clip lands in it.
            rig.controller.addExclusions(folderIDs: [folderID], savedClipIDs: [collaboratorClip])
            let incoming = try SavedClip(id: collaboratorClip, name: "CR-SYNTHETIC-COLLABORATOR-TITLE",
                                         content: ClipContent(type: .plainText, text: "CR-SYNTHETIC-COLLABORATOR-BODY"),
                                         folderID: folderID, createdAt: date)
            try await rig.library.applySyncedSavedLibrary(savedClips: [incoming], folders: [], managedSavedClipIDs: [collaboratorClip], managedFolderIDs: [])
            gate.release()
            let response = try XCTUnwrap(box.wait(), operation)
            let encoded = String(decoding: try BrokerProtocol.encode(response), as: UTF8.self)
            XCTAssertFalse(encoded.contains("COLLABORATOR"), "\(operation): no collaborator title/body: \(encoded)")
            XCTAssertFalse(encoded.contains(id(clipC)), "\(operation): the now-collaborative folder is withheld entirely")
        }
    }

    func testSyncStatusIsAuthScopedAndDistinctFromLastSuccess() async throws {
        let rig = try await makeRig(pair: false)
        let unpaired = try await call(rig.client, rig.sessionID, 2, .syncStatus)
        XCTAssertEqual(unpaired, .failure(.notApproved))
        rig.controller.updateStatus(SyncStatusReport(snapshotReady: true, sync: .offline, lastProjection: .failed, lastProjectionAtEpochSeconds: 5))
        rig.controller.approvePairing(rig.sessionID)
        _ = try await call(rig.client, rig.sessionID, 3, .awaitPairing)
        let status = try await call(rig.client, rig.sessionID, 4, .syncStatus)
        XCTAssertEqual(status, .syncStatus(SyncStatusReport(snapshotReady: true, sync: .offline, lastProjection: .failed, lastProjectionAtEpochSeconds: 5)))
    }

    // MARK: Vault handoff

    func addVaultItem(_ rig: Rig, _ text: String, type: SupportedContentType = .plainText) async throws -> UUID {
        try await rig.session.unlock()
        let item = try await rig.vault.add(VaultItem(name: "Synthetic vault item", content: ClipContent(type: type, text: text)))
        return item.id
    }

    func openVaultRequest(_ rig: Rig, requestID: UInt32 = 20) async throws -> (AgentAccessResponseBox, VaultRequestInfo) {
        let box = AgentAccessResponseBox()
        let client = rig.client
        let sessionID = rig.sessionID
        Thread { box.set(try? client.call(sessionID: sessionID, requestID: requestID, .requestVaultItem(purpose: "Synthetic deploy"))) }.start()
        let opened = await waitFor { !rig.controller.pendingVaultRequests.isEmpty }
        XCTAssertTrue(opened)
        return (box, try XCTUnwrap(rig.controller.pendingVaultRequests.first))
    }

    func testSelectedVaultTextApprovedOnceIsHandedOffExactly() async throws {
        let rig = try await makeRig()
        let itemID = try await addVaultItem(rig, "CR-SYNTHETIC-VAULT-TEXT")
        let (box, request) = try await openVaultRequest(rig)
        XCTAssertEqual(request.purpose, "Synthetic deploy")
        await rig.controller.previewVaultItem(requestKey: request.key, itemID: itemID)
        XCTAssertEqual(rig.controller.vaultPreview?.text, "CR-SYNTHETIC-VAULT-TEXT")
        let outcome = await rig.controller.approveVaultPreview()
        XCTAssertEqual(outcome, .handedOff)
        XCTAssertNil(rig.controller.vaultPreview, "plaintext cleared from UI state")
        XCTAssertEqual(box.wait()?.result, .vaultItem(VaultHandoff(kind: .text, text: "CR-SYNTHETIC-VAULT-TEXT")))
        let second = await rig.controller.approveVaultPreview()
        XCTAssertNil(second, "one-shot")
    }

    func testSelectedVaultLinkIsHandedOffAsURL() async throws {
        let rig = try await makeRig()
        let itemID = try await addVaultItem(rig, "https://example.com/cr-synthetic-vault-link", type: .url)
        let (box, request) = try await openVaultRequest(rig)
        await rig.controller.previewVaultItem(requestKey: request.key, itemID: itemID)
        XCTAssertEqual(rig.controller.vaultPreview?.kind, .url)
        let outcome = await rig.controller.approveVaultPreview()
        XCTAssertEqual(outcome, .handedOff)
        XCTAssertEqual(box.wait()?.result, .vaultItem(VaultHandoff(kind: .url, text: "https://example.com/cr-synthetic-vault-link")))
    }

    func testDisabledAccessCreatesNoSessionOrRequestAndNeverReachesData() async throws {
        let rig = try await makeRig(enable: false)
        try? LocalSocket.wait(rig.client.fd, events: Int16(POLLIN), deadline: .after(2))
        XCTAssertEqual(rig.done.wait(timeout: .now() + 3), .success)
        XCTAssertTrue(rig.controller.authority.sessionList.isEmpty)
        XCTAssertTrue(rig.controller.authority.pendingVaultRequests.isEmpty)
        XCTAssertNil(rig.controller.vaultPreview)
        XCTAssertEqual(rig.controller.authority.connectionCount, 0)
        let unlocked = await rig.session.isUnlocked
        XCTAssertFalse(unlocked, "disabled access never unlocks or decrypts the Vault")
    }

    func testVaultDenyBackgroundUnsupportedAndInactiveReleaseNothing() async throws {
        do { // deny
            let rig = try await makeRig()
            _ = try await addVaultItem(rig, "CR-SYNTHETIC-VAULT-DENY")
            let (box, request) = try await openVaultRequest(rig)
            rig.controller.denyVaultRequest(request.key)
            XCTAssertEqual(box.wait()?.result, .failure(.vaultRequestDenied))
        }
        do { // unsupported payload (over the 128 KB text limit) is never previewed or released
            let rig = try await makeRig()
            let itemID = try await addVaultItem(rig, String(repeating: "R", count: BrokerProtocol.maxContentBytes + 1))
            let (box, request) = try await openVaultRequest(rig)
            await rig.controller.previewVaultItem(requestKey: request.key, itemID: itemID)
            XCTAssertNil(rig.controller.vaultPreview)
            let outcome = await rig.controller.approveVaultPreview()
            XCTAssertNil(outcome)
            rig.controller.denyVaultRequest(request.key)
            XCTAssertFalse(box.wait()?.result.carriesContent ?? true)
        }
        do { // app not in the foreground: no release
            let rig = try await makeRig()
            let itemID = try await addVaultItem(rig, "CR-SYNTHETIC-VAULT-BG")
            let (box, request) = try await openVaultRequest(rig)
            await rig.controller.previewVaultItem(requestKey: request.key, itemID: itemID)
            activeApp = false
            let outcome = await rig.controller.approveVaultPreview()
            activeApp = true
            XCTAssertNil(outcome)
            rig.controller.handleLifecycle(.appDidEnterBackground)
            XCTAssertEqual(box.wait()?.result, .failure(.vaultRequestCancelled))
            XCTAssertNil(rig.controller.vaultPreview)
        }
    }

    func testLockThenReunlockInvalidatesApprovalAndLateApprovalCannotRecreate() async throws {
        let rig = try await makeRig()
        let itemID = try await addVaultItem(rig, "CR-SYNTHETIC-VAULT-RELOCK")
        let (box, request) = try await openVaultRequest(rig)
        await rig.controller.previewVaultItem(requestKey: request.key, itemID: itemID)
        XCTAssertNotNil(rig.controller.vaultPreview)
        // Lock and re-unlock without the controller noticing (simulates a race): the old
        // approval is bound to the old epoch and must be refused even though isUnlocked.
        await rig.session.lock()
        try await rig.session.unlock()
        let outcome = await rig.controller.approveVaultPreview()
        XCTAssertNil(outcome)
        XCTAssertTrue(rig.controller.authority.isVaultRequestPending(request.key), "nothing was released")
        // The Vault lock hook cancels the request; a late approval cannot recreate it.
        rig.controller.vaultDidLock()
        XCTAssertEqual(box.wait()?.result, .failure(.vaultRequestCancelled))
        await rig.controller.previewVaultItem(requestKey: request.key, itemID: itemID)
        XCTAssertNil(rig.controller.vaultPreview)
    }

    func testScreenLockRevokesSessions() async throws {
        let rig = try await makeRig()
        rig.controller.handleLifecycle(.screenDidLock)
        XCTAssertEqual(rig.done.wait(timeout: .now() + 3), .success, "revoked connection is shut down")
        XCTAssertTrue(rig.controller.authority.sessionList.allSatisfy { $0.state != .approved })
    }
}
