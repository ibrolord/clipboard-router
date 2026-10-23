import Darwin
import Foundation
import XCTest
@testable import ClipboardRouterAgentAccess

/// Thread-safe manual monotonic clock.
final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var nanos: UInt64 = 1_000_000_000
    var now: UInt64 { lock.withLock { nanos } }
    func advance(_ seconds: TimeInterval) { lock.withLock { nanos &+= UInt64(seconds * 1_000_000_000) } }
}

final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AgentAccessEvent] = []
    func record(_ event: AgentAccessEvent) { lock.withLock { events.append(event) } }
    var lines: [String] { lock.withLock { events.map(\.line) } }
}

/// Barrier a backend read suspends on before reaching the handoff.
final class Gate: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)
    func pass() { entered.signal(); released.wait() }
    func waitUntilEntered() { XCTAssertEqual(entered.wait(timeout: .now() + 5), .success) }
    func release() { released.signal() }
}

struct SyntheticClip: Sendable {
    var id: String
    var title: String
    var text: String
}

final class SyntheticBackend: AgentAccessBackend, @unchecked Sendable {
    let authority: AgentAccessAuthority
    let clips: [SyntheticClip]
    let gate: Gate?
    /// Runs inside the handoff's build closure (under the authority lock).
    let duringBuild: (@Sendable () -> Void)?
    private let lock = NSLock()
    private var _pairings: [AgentAccessSessionInfo] = []
    private var _dataCalls = 0

    init(authority: AgentAccessAuthority, clips: [SyntheticClip], gate: Gate? = nil, duringBuild: (@Sendable () -> Void)? = nil) {
        self.authority = authority
        self.clips = clips
        self.gate = gate
        self.duringBuild = duringBuild
    }

    var pairings: [AgentAccessSessionInfo] { lock.withLock { _pairings } }
    var dataCalls: Int { lock.withLock { _dataCalls } }

    func listSharedClips(_ channel: ReleaseChannel, limit: Int) async -> ReleaseOutcome {
        lock.withLock { _dataCalls += 1 }
        gate?.pass()
        return channel.release { _ in
            .sharedClips(clips.prefix(limit).map {
                SharedClipSummary(id: $0.id, title: $0.title, kind: .text, byteCount: $0.text.utf8.count, modifiedAtEpochSeconds: 0)
            })
        }
    }

    func getSharedClip(_ channel: ReleaseChannel, id: String) async -> ReleaseOutcome {
        lock.withLock { _dataCalls += 1 }
        gate?.pass()
        return channel.release { scope in
            duringBuild?()
            guard let clip = clips.first(where: { $0.id == id }),
                  let uuid = UUID(uuidString: id), scope.savedClipIDs.contains(uuid)
            else { return .failure(.notFound) }
            return .sharedClip(SharedClipContent(id: clip.id, kind: .text, text: clip.text))
        }
    }

    func syncStatus(_ channel: ReleaseChannel) async -> ReleaseOutcome {
        channel.release { _ in
            .syncStatus(SyncStatusReport(snapshotReady: true, sync: .offline, lastProjection: .notAppliedThisLaunch, lastProjectionAtEpochSeconds: nil))
        }
    }

    func vaultRequestOpened(_ info: VaultRequestInfo) async {}
    func pairingRequested(_ info: AgentAccessSessionInfo) async { lock.withLock { _pairings.append(info) } }
}

final class ResultBox: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var value: Result<BrokerResponse, Error>?
    func set(_ body: () throws -> BrokerResponse) {
        let result = Result { try body() }
        lock.withLock { value = result }
        semaphore.signal()
    }
    func wait() -> Result<BrokerResponse, Error>? {
        _ = semaphore.wait(timeout: .now() + 10)
        return lock.withLock { value }
    }
    func response() -> BrokerResponse? { try? wait()?.get() }
}

final class ConcurrentOutcomes: @unchecked Sendable {
    private let lock = NSLock()
    private var outcomes: [VaultReleaseOutcome] = []
    func add(_ outcome: VaultReleaseOutcome) { lock.withLock { outcomes.append(outcome) } }
    func count(_ outcome: VaultReleaseOutcome) -> Int { lock.withLock { outcomes.filter { $0 == outcome }.count } }
}

let syntheticClipA = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
let syntheticClipB = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!

func syntheticClips(bigText: Bool = false) -> [SyntheticClip] {
    [
        SyntheticClip(id: syntheticClipA.uuidString, title: "Synthetic A",
                      text: bigText ? String(repeating: "S", count: 120 * 1024) : "SYNTHETIC-TEXT-A"),
        SyntheticClip(id: syntheticClipB.uuidString, title: "Synthetic B", text: "SYNTHETIC-TEXT-B"),
    ]
}

func socketPair() -> (Int32, Int32) {
    var fds: [Int32] = [0, 0]
    precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
    for fd in fds {
        LocalSocket.configure(fd)
        precondition(LocalSocket.setNonBlocking(fd))
    }
    return (fds[0], fds[1])
}

/// Reads until EOF or until no byte arrives for `timeout` seconds.
func receivedBytesUntilEOF(_ fd: Int32, timeout: TimeInterval = 3) -> Int {
    var total = 0
    var buffer = [UInt8](repeating: 0, count: 65536)
    while true {
        do {
            try LocalSocket.wait(fd, events: Int16(POLLIN), deadline: .after(timeout))
        } catch {
            return total
        }
        let count = recv(fd, &buffer, buffer.count, 0)
        if count < 0, errno == EINTR || errno == EAGAIN { continue }
        if count <= 0 { return total }
        total += count
    }
}

/// Runs `body` on a separate thread and fails (instead of hanging the suite) if it does
/// not finish within `seconds`.
func withWatchdog(_ seconds: TimeInterval, _ name: String, file: StaticString = #filePath, line: UInt = #line, _ body: @escaping @Sendable () -> Void) {
    let finished = DispatchSemaphore(value: 0)
    Thread {
        body()
        finished.signal()
    }.start()
    XCTAssertEqual(finished.wait(timeout: .now() + seconds), .success, "\(name) blocked past its watchdog", file: file, line: line)
}

func syntheticPeer(_: Int32) throws -> VerifiedPeer {
    VerifiedPeer(identifier: "com.clipboardrouter.cr", teamIdentifier: "TEAMTEST01", processIdentifier: 1)
}

final class AgentAccessTransportTests: XCTestCase {
    struct Harness {
        var client: BrokerClient
        var authority: AgentAccessAuthority
        var backend: SyntheticBackend
        var events: EventRecorder
        var done: DispatchSemaphore
    }

    func makeHarness(
        enabled: Bool = true,
        clock: ManualClock = ManualClock(),
        limits: TransportLimits = .standard,
        gate: Gate? = nil,
        bigText: Bool = false,
        serverSendBuffer: Int32? = nil,
        duringBuild: (@Sendable () -> Void)? = nil,
        authenticate: @escaping @Sendable (Int32) throws -> VerifiedPeer = syntheticPeer
    ) -> Harness {
        let authority = AgentAccessAuthority(limits: limits, clock: { clock.now })
        authority.setEnabled(enabled)
        authority.setScope(AgentAccessScope(savedClipIDs: [syntheticClipA]))
        let backend = SyntheticBackend(authority: authority, clips: syntheticClips(bigText: bigText), gate: gate, duringBuild: duringBuild)
        let events = EventRecorder()
        let handler = BrokerConnectionHandler(
            limits: limits,
            authority: authority,
            backend: backend,
            authenticate: authenticate,
            log: { events.record($0) }
        )
        let (server, clientFD) = socketPair()
        if var size = serverSendBuffer {
            _ = setsockopt(server, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
            _ = setsockopt(clientFD, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        }
        let connectionID = authority.registerConnection(fd: server)!
        let done = DispatchSemaphore(value: 0)
        Thread {
            handler.serve(server, connectionID: connectionID)
            done.signal()
        }.start()
        let client = BrokerClient(
            fd: clientFD,
            server: VerifiedPeer(identifier: "app", teamIdentifier: nil, processIdentifier: 0),
            timing: BrokerConnectTiming(connectMilliseconds: 0, verifyMilliseconds: 0),
            limits: limits
        )
        return Harness(client: client, authority: authority, backend: backend, events: events, done: done)
    }

    func paired(
        clock: ManualClock = ManualClock(),
        limits: TransportLimits = .standard,
        gate: Gate? = nil,
        bigText: Bool = false,
        serverSendBuffer: Int32? = nil,
        duringBuild: (@Sendable () -> Void)? = nil
    ) throws -> (Harness, String) {
        let harness = makeHarness(clock: clock, limits: limits, gate: gate, bigText: bigText, serverSendBuffer: serverSendBuffer, duringBuild: duringBuild)
        let reply = try harness.client.hello(displayName: "Synthetic Agent")
        XCTAssertTrue(harness.authority.decidePairing(reply.sessionID, approve: true))
        XCTAssertEqual(try harness.client.call(sessionID: reply.sessionID, requestID: 1, .awaitPairing).result, .sessionState(.approved))
        return (harness, reply.sessionID)
    }

    func waitForVaultRequest(_ authority: AgentAccessAuthority) throws -> VaultRequestInfo {
        for _ in 0..<250 {
            if let info = authority.pendingVaultRequests.first { return info }
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTFail("vault request never opened")
        throw CancellationError()
    }

    // MARK: Framing and endpoint

    func testFramingCapsAndDeadlines() throws {
        let (a, b) = socketPair()
        defer { close(a); close(b) }
        try FrameIO.writeFrame(a, Data("hello".utf8), maxBytes: 16, timeout: 1)
        XCTAssertEqual(try FrameIO.readFrame(b, maxBytes: 16, headerDeadline: .after(1), bodyTimeout: 1), Data("hello".utf8))
        try FrameIO.writeAll(a, [0, 0, 0, 17], deadline: .after(1))
        XCTAssertThrowsError(try FrameIO.readFrame(b, maxBytes: 16, headerDeadline: .after(1), bodyTimeout: 1)) {
            XCTAssertEqual($0 as? LocalIPCError, .frameTooLarge(17))
        }
        try FrameIO.writeAll(a, [0, 0, 0, 0], deadline: .after(1))
        XCTAssertThrowsError(try FrameIO.readFrame(b, maxBytes: 16, headerDeadline: .after(1), bodyTimeout: 1)) {
            XCTAssertEqual($0 as? LocalIPCError, .frameEmpty)
        }
        try FrameIO.writeAll(a, [0, 0, 0, 8, 1, 2], deadline: .after(1))
        let start = Date()
        XCTAssertThrowsError(try FrameIO.readFrame(b, maxBytes: 16, headerDeadline: .after(1), bodyTimeout: 0.3)) {
            XCTAssertEqual($0 as? LocalIPCError, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
        XCTAssertThrowsError(try FrameIO.writeFrame(a, Data(count: 17), maxBytes: 16, timeout: 1))
    }

    func testMaximumFrameFitsOneNonBlockingSend() throws {
        let (a, b) = socketPair()
        defer { close(a); close(b) }
        let frame = try FrameIO.encodeFrame(Data(repeating: 0x41, count: TransportLimits.standard.maxResponseFrameBytes), maxBytes: TransportLimits.standard.maxResponseFrameBytes)
        XCTAssertTrue(FrameIO.sendWithoutBlocking(a, frame))
    }

    func testEndpointUsesShortNameAndFailsClosedWhenTooLong() throws {
        let endpoint = try AgentAccessEndpoint.forBridge(appBundleIdentifier: "com.clipboardrouter.ClipboardRouter", userHome: "/Users/synthetic")
        XCTAssertEqual(endpoint.socketPath, "/Users/synthetic/Library/Containers/com.clipboardrouter.ClipboardRouter/Data/m/s")
        // /Users/<32-character short name> is the documented supported maximum.
        XCTAssertEqual(AgentAccessEndpoint.maxHomePathBytes(appBundleIdentifier: "com.clipboardrouter.ClipboardRouter"), 39)
        XCTAssertNoThrow(try AgentAccessEndpoint.forBridge(appBundleIdentifier: "com.clipboardrouter.ClipboardRouter", userHome: "/Users/" + String(repeating: "u", count: 32)))
        XCTAssertThrowsError(try AgentAccessEndpoint.forBridge(appBundleIdentifier: "com.clipboardrouter.ClipboardRouter", userHome: "/Users/" + String(repeating: "u", count: 33))) {
            XCTAssertEqual($0 as? AgentAccessIdentityError, .endpointPathTooLong)
        }
        XCTAssertThrowsError(try AgentAccessEndpoint.forBridge(appBundleIdentifier: "../evil", userHome: "/Users/x"))
    }

    // MARK: Session lifecycle

    func testDisabledAccessSendsZeroBytesAndNeverReachesBackend() {
        let harness = makeHarness(enabled: false)
        XCTAssertEqual(receivedBytesUntilEOF(harness.client.fd), 0)
        XCTAssertEqual(harness.done.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(harness.backend.dataCalls, 0)
        XCTAssertTrue(harness.backend.pairings.isEmpty)
        XCTAssertEqual(harness.authority.connectionCount, 0)
    }

    func testRejectedPeerGetsZeroBytes() {
        let harness = makeHarness(authenticate: { _ in throw LocalIPCError.peerEntitlementMissing("com.apple.security.app-sandbox") })
        XCTAssertEqual(receivedBytesUntilEOF(harness.client.fd), 0)
        XCTAssertEqual(harness.done.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(harness.events.lines.contains { $0.contains("reason=peer_entitlement_missing") })
    }

    func testDataRefusedUntilPairedThenExactScope() throws {
        let harness = makeHarness()
        let reply = try harness.client.hello(displayName: "Synthetic\u{202E} Agent")
        XCTAssertEqual(reply.pairingCode.count, 6)
        XCTAssertEqual(try harness.client.call(sessionID: reply.sessionID, requestID: 1, .listSharedClips(limit: 5)).result, .failure(.notApproved))
        XCTAssertEqual(harness.backend.dataCalls, 0)
        XCTAssertEqual(harness.backend.pairings.first?.displayName, "Synthetic Agent")

        harness.authority.decidePairing(reply.sessionID, approve: true)
        XCTAssertEqual(try harness.client.call(sessionID: reply.sessionID, requestID: 2, .awaitPairing).result, .sessionState(.approved))
        let inScope = try harness.client.call(sessionID: reply.sessionID, requestID: 3, .getSharedClip(id: syntheticClipA.uuidString))
        XCTAssertEqual(inScope.result, .sharedClip(SharedClipContent(id: syntheticClipA.uuidString, kind: .text, text: "SYNTHETIC-TEXT-A")))
        let outOfScope = try harness.client.call(sessionID: reply.sessionID, requestID: 4, .getSharedClip(id: syntheticClipB.uuidString))
        let missing = try harness.client.call(sessionID: reply.sessionID, requestID: 5, .getSharedClip(id: UUID().uuidString))
        XCTAssertEqual(outOfScope.result, .failure(.notFound))
        XCTAssertEqual(missing.result, outOfScope.result, "excluded and nonexistent IDs must be indistinguishable")
        let lines = harness.events.lines.joined(separator: "\n")
        XCTAssertFalse(lines.contains("SYNTHETIC"))
        XCTAssertFalse(lines.contains("Agent"))
    }

    func testDeniedPairingClosesConnection() throws {
        let harness = makeHarness()
        let reply = try harness.client.hello(displayName: nil)
        harness.authority.decidePairing(reply.sessionID, approve: false)
        XCTAssertEqual(try harness.client.call(sessionID: reply.sessionID, requestID: 1, .awaitPairing).result, .sessionState(.denied))
        XCTAssertEqual(harness.done.wait(timeout: .now() + 5), .success)
        XCTAssertFalse(harness.authority.decidePairing(reply.sessionID, approve: true), "late approval cannot resurrect")
    }

    func testPairingExpiresOnManualClock() throws {
        let clock = ManualClock()
        let harness = makeHarness(clock: clock)
        let reply = try harness.client.hello(displayName: nil)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            clock.advance(TransportLimits.standard.pairingTimeout + 1)
            harness.authority.wakeWaiters()
        }
        XCTAssertEqual(try harness.client.call(sessionID: reply.sessionID, requestID: 1, .awaitPairing).result, .sessionState(.expired))
        XCTAssertFalse(harness.authority.decidePairing(reply.sessionID, approve: true))
    }

    func testSessionReplayAcrossConnectionsFails() throws {
        let (first, firstSession) = try paired()
        first.client.close()
        XCTAssertEqual(first.done.wait(timeout: .now() + 5), .success)
        let second = makeHarness()
        let reply = try second.client.hello(displayName: nil)
        XCTAssertNotEqual(reply.sessionID, firstSession)
        XCTAssertEqual(try second.client.call(sessionID: firstSession, requestID: 9, .listSharedClips(limit: 1)).result, .failure(.sessionMismatch))
        XCTAssertEqual(second.done.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(second.backend.dataCalls, 0)
    }

    func testMalformedAndOversizeRequestsCloseSafely() throws {
        let (harness, _) = try paired()
        try FrameIO.writeFrame(harness.client.fd, Data("{not json".utf8), maxBytes: 64, timeout: 1)
        XCTAssertEqual(try harness.client.receive(BrokerResponse.self, timeout: 3).result, .failure(.malformedRequest))
        XCTAssertEqual(harness.done.wait(timeout: .now() + 5), .success)

        let (other, _) = try paired()
        let declared = UInt32(TransportLimits.standard.maxRequestFrameBytes + 1)
        try FrameIO.writeAll(other.client.fd, [UInt8(declared >> 24), UInt8((declared >> 16) & 0xFF), UInt8((declared >> 8) & 0xFF), UInt8(declared & 0xFF)], deadline: .after(1))
        XCTAssertEqual(receivedBytesUntilEOF(other.client.fd), 0)
        XCTAssertTrue(other.events.lines.contains { $0.contains("reason=frame_too_large") })
    }

    func testDisconnectWhilePairingPendingRemovesSession() throws {
        let harness = makeHarness()
        let reply = try harness.client.hello(displayName: nil)
        try harness.client.sendFrame(BrokerRequest(sessionID: reply.sessionID, requestID: 1, operation: .awaitPairing))
        harness.client.close()
        XCTAssertEqual(harness.done.wait(timeout: .now() + 5), .success)
        XCTAssertNil(harness.authority.sessionState(reply.sessionID))
        XCTAssertEqual(harness.authority.connectionCount, 0)
    }

    func testRevokingIdleSessionShutsItsConnectionPromptly() throws {
        let (harness, session) = try paired()
        harness.authority.revokeSession(session)
        XCTAssertEqual(harness.done.wait(timeout: .now() + 2), .success, "revoked idle connection must not linger in readFrame")
        XCTAssertEqual(harness.authority.connectionCount, 0)
    }

    // MARK: Handoff boundary

    func testRevokeBeforeHandoffReleasesZeroContent() throws {
        for revoke in ["session", "scope", "disable", "lifetime"] {
            let gate = Gate()
            let clock = ManualClock()
            let (harness, session) = try paired(clock: clock, gate: gate)
            let result = ResultBox()
            Thread { result.set { try harness.client.call(sessionID: session, requestID: 7, .getSharedClip(id: syntheticClipA.uuidString)) } }.start()
            gate.waitUntilEntered()
            switch revoke {
            case "session": harness.authority.revokeSession(session)
            case "scope": harness.authority.setScope(.empty)
            case "disable": harness.authority.setEnabled(false)
            default: clock.advance(TransportLimits.standard.maxSessionLifetime + 1)
            }
            gate.release()
            let response = result.response()
            XCTAssertFalse(response?.result.carriesContent ?? false, revoke)
            if revoke == "lifetime" { XCTAssertEqual(response?.result, .sessionState(.expired)) }
            XCTAssertEqual(harness.authority.sessionList.first?.disclosures ?? 0, 0, revoke)
        }
    }

    func testRevokeRacingTheHandoffWaitsAndContentIsDeliveredOnce() throws {
        let box = AuthorityBox()
        let revoked = DispatchSemaphore(value: 0)
        let (harness, session) = try paired(duringBuild: {
            // Attempt a revoke while the handoff holds the lock: it must wait for the lock,
            // so the content (already being handed off) arrives exactly once.
            Thread {
                box.authority?.revokeAllSessions(.userRevoked)
                revoked.signal()
            }.start()
            Thread.sleep(forTimeInterval: 0.05)
        })
        box.authority = harness.authority
        let response = try harness.client.call(sessionID: session, requestID: 7, .getSharedClip(id: syntheticClipA.uuidString))
        XCTAssertEqual(response.result, .sharedClip(SharedClipContent(id: syntheticClipA.uuidString, kind: .text, text: "SYNTHETIC-TEXT-A")))
        XCTAssertEqual(revoked.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(harness.done.wait(timeout: .now() + 5), .success, "revocation shuts the connection after the handoff")
        XCTAssertEqual(harness.backend.dataCalls, 1)
    }

    /// Names of recorded events (`event=<name>`), in order; reasons are not included.
    private func eventNames(_ events: EventRecorder) -> [String] {
        events.lines.compactMap { line in
            line.split(separator: " ").first { $0.hasPrefix("event=") }.map { String($0.dropFirst("event=".count)) }
        }
    }

    /// Handoff-boundary finding (R): the session lifetime is re-checked after build and encode,
    /// immediately before the send. A lifetime that passes while the payload is built must
    /// yield the content-free `.sessionState(.expired)` refusal (not a transport failure), zero
    /// content bytes, and a closed connection with no "handoff" event.
    func testSessionLifetimePassingDuringOrdinaryBuildSendsNothingAndClosesExpired() throws {
        var limits = TransportLimits.standard
        limits.maxSessionLifetime = 60
        let clock = ManualClock()
        let (harness, session) = try paired(clock: clock, limits: limits, duringBuild: { clock.advance(61) })
        defer { harness.authority.revokeAllSessions(.userRevoked) }
        let response = try harness.client.call(sessionID: session, requestID: 7, .getSharedClip(id: syntheticClipA.uuidString))
        XCTAssertEqual(response.result, .sessionState(.expired))
        XCTAssertFalse(response.result.carriesContent)
        let encoded = String(decoding: try BrokerProtocol.encode(response), as: UTF8.self)
        XCTAssertFalse(encoded.contains("SYNTHETIC-TEXT-A"), "no clip content in the response")
        XCTAssertEqual(receivedBytesUntilEOF(harness.client.fd, timeout: 1), 0, "no further bytes, then EOF")
        XCTAssertEqual(harness.done.wait(timeout: .now() + 5), .success, "an expired session closes its connection")
        XCTAssertFalse(eventNames(harness.events).contains("handoff"), "no handoff event: \(harness.events.lines)")
        XCTAssertFalse(harness.events.lines.contains { $0.contains("handoff_transport_failed") }, "not a transport failure: \(harness.events.lines)")
        XCTAssertTrue(harness.events.lines.contains { $0.contains("event=close") && $0.contains("reason=session_expired") },
                      "closed because the session expired: \(harness.events.lines)")
        let state = harness.authority.sessionState(session)
        XCTAssertTrue(state == nil || state == .expired, "session is gone or expired, got \(String(describing: state))")
    }

    /// Handoff-boundary control (C): a lifetime that has not yet passed at the send still
    /// delivers the content exactly once.
    func testSessionLifetimeJustUnderLimitDuringBuildStillDeliversOnce() throws {
        var limits = TransportLimits.standard
        limits.maxSessionLifetime = 60
        let clock = ManualClock()
        let (harness, session) = try paired(clock: clock, limits: limits, duringBuild: { clock.advance(59) })
        defer { harness.authority.revokeAllSessions(.userRevoked) }
        let response = try harness.client.call(sessionID: session, requestID: 7, .getSharedClip(id: syntheticClipA.uuidString))
        XCTAssertEqual(response.result, .sharedClip(SharedClipContent(id: syntheticClipA.uuidString, kind: .text, text: "SYNTHETIC-TEXT-A")))
        // A later request on the same connection proves the clip was not sent a second time.
        let next = try harness.client.call(sessionID: session, requestID: 8, .syncStatus)
        XCTAssertEqual(next.result.carriesContent, false)
        XCTAssertEqual(harness.backend.dataCalls, 1)
        XCTAssertEqual(harness.authority.sessionList.first?.disclosures, 1)
        XCTAssertEqual(harness.events.lines.filter { $0.contains("event=handoff") && $0.contains("reason=get_shared_clip") }.count, 1,
                       "exactly one clip handoff: \(harness.events.lines)")
    }

    func testNonBlockingSendRefusesFullSocket() throws {
        let (a, b) = socketPair()
        let result = Box<(Int, Bool)>()
        withWatchdog(2, "saturated handoff") {
            let chunk = [UInt8](repeating: 0x42, count: 65536)
            var accepted = 0
            while accepted < 4096, FrameIO.sendWithoutBlocking(a, chunk) { accepted += 1 }
            var tail = 0
            while tail < 1_000_000, FrameIO.sendWithoutBlocking(a, [0x42]) { tail += 1 }
            result.value = (accepted, FrameIO.sendWithoutBlocking(a, [1, 2, 3, 4]))
        }
        XCTAssertLessThan(result.value?.0 ?? 4096, 4096, "socket never saturated")
        XCTAssertEqual(result.value?.1, false, "a backpressured handoff never waits")
        close(a)
        close(b)
    }

    func testHandoffRefusesBlockingDescriptorAndIOFailsClosed() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { close(fds[0]); close(fds[1]) }
        XCTAssertFalse(LocalSocket.isNonBlocking(fds[0]))
        XCTAssertFalse(FrameIO.sendWithoutBlocking(fds[0], [1]), "never send on a descriptor that could block")
        XCTAssertThrowsError(try FrameIO.readExactly(fds[1], count: 1, deadline: .after(0.1)))
    }

    func testWriteDeadlineIsBoundedOnSaturatedSocket() throws {
        let (a, b) = socketPair()
        let outcome = Box<LocalIPCError>()
        withWatchdog(3, "bounded write") {
            let chunk = [UInt8](repeating: 0x43, count: 65536)
            while FrameIO.sendWithoutBlocking(a, chunk) {}
            do {
                try FrameIO.writeAll(a, chunk, deadline: .after(0.3))
            } catch {
                outcome.value = error as? LocalIPCError
            }
        }
        XCTAssertEqual(outcome.value, .timedOut)
        close(a)
        close(b)
    }

    func testPeerBytesDuringSuspendedReadBreakConnectionWithoutContentOrRetry() throws {
        let gate = Gate()
        let (harness, session) = try paired(gate: gate)
        try harness.client.sendFrame(BrokerRequest(sessionID: session, requestID: 7, operation: .getSharedClip(id: syntheticClipA.uuidString)))
        gate.waitUntilEntered()
        // Pipelined bytes violate the strict request/response protocol: no handoff happens.
        try FrameIO.writeAll(harness.client.fd, [0, 0, 0, 1, 0x7B], deadline: .after(1))
        gate.release()
        XCTAssertEqual(harness.done.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(harness.events.lines.filter { $0.contains("handoff_transport_failed") }.count, 1)
        XCTAssertEqual(harness.backend.dataCalls, 1)
        XCTAssertEqual(receivedBytesUntilEOF(harness.client.fd), 0)
        XCTAssertEqual(harness.authority.sessionList.first?.disclosures ?? 0, 0)
    }

    // MARK: Vault requests

    func testVaultRequestSingleHandoffAndNoIdentifiers() throws {
        let (harness, session) = try paired()
        let result = ResultBox()
        Thread { result.set { try harness.client.call(sessionID: session, requestID: 11, .requestVaultItem(purpose: "Deploy\u{0007} synthetic")) } }.start()
        let info = try waitForVaultRequest(harness.authority)
        XCTAssertEqual(info.purpose, "Deploy synthetic")
        let handoff = VaultHandoff(kind: .text, text: "SYNTHETIC-VAULT-TEXT")
        let outcomes = ConcurrentOutcomes()
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            outcomes.add(harness.authority.releaseVault(info.key) { handoff })
        }
        XCTAssertEqual(outcomes.count(.handedOff), 1, "exactly one concurrent redemption")
        XCTAssertEqual(result.response()?.result, .vaultItem(handoff))
        XCTAssertNotEqual(harness.authority.releaseVault(info.key) { handoff }, .handedOff, "one-shot")
        // The connection keeps serving afterwards and never re-sends the item.
        XCTAssertEqual(try harness.client.call(sessionID: session, requestID: 12, .syncStatus).result.carriesContent, false)
        let encoded = String(decoding: try BrokerProtocol.encode(BrokerResult.vaultItem(handoff)), as: UTF8.self)
        XCTAssertFalse(encoded.contains("\"id\""), "handoff carries no Vault identifier: \(encoded)")
    }

    func testVaultDenyCancelExpireLifetimeAndHalfClose() throws {
        let late = VaultHandoff(kind: .text, text: "SYNTHETIC-LATE")
        do { // deny
            let (harness, session) = try paired()
            let result = ResultBox()
            Thread { result.set { try harness.client.call(sessionID: session, requestID: 11, .requestVaultItem(purpose: "x")) } }.start()
            let info = try waitForVaultRequest(harness.authority)
            XCTAssertTrue(harness.authority.denyVaultRequest(info.key))
            XCTAssertEqual(result.response()?.result, .failure(.vaultRequestDenied))
            XCTAssertNotEqual(harness.authority.releaseVault(info.key) { late }, .handedOff)
        }
        do { // lock/background cancels; a late approval cannot recreate the grant
            let (harness, session) = try paired()
            let result = ResultBox()
            Thread { result.set { try harness.client.call(sessionID: session, requestID: 12, .requestVaultItem(purpose: "x")) } }.start()
            let info = try waitForVaultRequest(harness.authority)
            harness.authority.cancelPendingVaultRequests(.vaultLocked)
            XCTAssertNotEqual(harness.authority.releaseVault(info.key) { late }, .handedOff)
            XCTAssertEqual(result.response()?.result, .failure(.vaultRequestCancelled))
        }
        do { // exact deadline, not extended by activity
            let clock = ManualClock()
            let (harness, session) = try paired(clock: clock)
            let result = ResultBox()
            Thread { result.set { try harness.client.call(sessionID: session, requestID: 13, .requestVaultItem(purpose: "x")) } }.start()
            let info = try waitForVaultRequest(harness.authority)
            clock.advance(TransportLimits.standard.vaultRequestTimeout - 0.001)
            XCTAssertEqual(try ReleaseChannel(authority: harness.authority, connectionID: 0, sessionID: session, requestID: 99).release { _ in .failure(.notFound) }, .refused(.failure(.notApproved)))
            XCTAssertTrue(harness.authority.isVaultRequestPending(info.key))
            clock.advance(0.002)
            XCTAssertEqual(harness.authority.releaseVault(info.key) { late }, .expired)
            harness.authority.wakeWaiters()
            XCTAssertEqual(result.response()?.result, .failure(.vaultRequestExpired))
        }
        do { // absolute session lifetime is authoritative at release
            var limits = TransportLimits.standard
            limits.maxSessionLifetime = 60
            limits.vaultRequestTimeout = 600
            let clock = ManualClock()
            let (harness, session) = try paired(clock: clock, limits: limits)
            let result = ResultBox()
            Thread { result.set { try harness.client.call(sessionID: session, requestID: 14, .requestVaultItem(purpose: "x")) } }.start()
            let info = try waitForVaultRequest(harness.authority)
            clock.advance(61)
            XCTAssertNotEqual(harness.authority.releaseVault(info.key) { late }, .handedOff)
            harness.authority.wakeWaiters()
            XCTAssertFalse(result.response()?.result.carriesContent ?? false)
        }
        do { // client half-closes (SHUT_WR) while approval is pending: zero content
            let (harness, session) = try paired()
            try harness.client.sendFrame(BrokerRequest(sessionID: session, requestID: 15, operation: .requestVaultItem(purpose: "x")))
            let info = try waitForVaultRequest(harness.authority)
            XCTAssertEqual(shutdown(harness.client.fd, SHUT_WR), 0)
            let outcome = harness.authority.releaseVault(info.key) { late }
            XCTAssertNotEqual(outcome, .handedOff)
            // Only a content-free refusal may follow.
            if let response = try? harness.client.receive(BrokerResponse.self, timeout: 2) {
                XCTAssertFalse(response.result.carriesContent)
                XCTAssertEqual(response.result, .failure(.vaultRequestCancelled))
            }
            XCTAssertEqual(receivedBytesUntilEOF(harness.client.fd), 0)
            XCTAssertEqual(harness.done.wait(timeout: .now() + 5), .success)
        }
    }

    func testOnlyOnePendingVaultRequestPerSession() throws {
        try onlyOnePendingVaultRequestPerSession()
    }

    /// Formal review 1 / F3: the Vault unlock precondition is evaluated under the authority
    /// lock immediately before the send; a deadline that passed while waiting yields no content.
    func testVaultHandoffRefusedWhenUnlockCheckFailsAtSend() throws {
        let (harness, session) = try paired()
        let result = ResultBox()
        Thread { result.set { try harness.client.call(sessionID: session, requestID: 21, .requestVaultItem(purpose: "x")) } }.start()
        let info = try waitForVaultRequest(harness.authority)
        let outcome = harness.authority.releaseVault(info.key, stillUnlocked: { false }) {
            VaultHandoff(kind: .text, text: "CR-SYNTHETIC-SHOULD-NOT-SEND")
        }
        XCTAssertEqual(outcome, .vaultLocked)
        XCTAssertEqual(result.response()?.result, .failure(.vaultRequestCancelled))
        XCTAssertNotEqual(harness.authority.releaseVault(info.key) { VaultHandoff(kind: .text, text: "late") }, .handedOff)
    }

    /// 17:35 follow-up: the unlock check is re-evaluated after the payload is built and encoded,
    /// immediately before the send. Expiry during build/encode sends zero content bytes.
    func testVaultDeadlinePassingDuringBuildSendsNothing() throws {
        let (harness, session) = try paired()
        let result = ResultBox()
        Thread { result.set { try harness.client.call(sessionID: session, requestID: 22, .requestVaultItem(purpose: "x")) } }.start()
        let info = try waitForVaultRequest(harness.authority)
        let unlocked = Box<Bool>()
        unlocked.value = true
        let outcome = harness.authority.releaseVault(info.key, stillUnlocked: { unlocked.value == true }) {
            unlocked.value = false // the Vault deadline passes while the payload is being built
            return VaultHandoff(kind: .text, text: "CR-SYNTHETIC-SHOULD-NOT-SEND")
        }
        XCTAssertEqual(outcome, .vaultLocked)
        let response = result.response()
        XCTAssertEqual(response?.result, .failure(.vaultRequestCancelled))
        XCTAssertFalse(response?.result.carriesContent ?? true)
    }

    private func openVaultWaiter(_ harness: Harness, session: String, requestID: UInt32) throws -> (ResultBox, VaultRequestInfo) {
        let result = ResultBox()
        Thread { result.set { try harness.client.call(sessionID: session, requestID: requestID, .requestVaultItem(purpose: "x")) } }.start()
        return (result, try waitForVaultRequest(harness.authority))
    }

    /// Vault handoff boundary (R): the request deadline is re-checked after build and encode,
    /// before the send. A deadline that passes during build yields `.expired`, the waiter gets
    /// `vaultRequestExpired`, and no content is sent or counted.
    func testVaultRequestDeadlinePassingDuringBuildExpiresWithoutSending() throws {
        let canary = "CR-SYNTHETIC-SHOULD-NOT-SEND"
        var limits = TransportLimits.standard
        limits.maxSessionLifetime = 600
        limits.vaultRequestTimeout = 60
        let clock = ManualClock()
        let (harness, session) = try paired(clock: clock, limits: limits)
        defer { harness.authority.revokeAllSessions(.userRevoked) }
        let (result, info) = try openVaultWaiter(harness, session: session, requestID: 31)
        let outcome = harness.authority.releaseVault(info.key, stillUnlocked: { true }) {
            clock.advance(61) // the request deadline passes while the payload is being built
            return VaultHandoff(kind: .text, text: canary)
        }
        XCTAssertEqual(outcome, .expired)
        harness.authority.wakeWaiters()
        let response = result.response()
        XCTAssertEqual(response?.result, .failure(.vaultRequestExpired))
        XCTAssertFalse(response?.result.carriesContent ?? true)
        if let response {
            XCTAssertFalse(String(decoding: try BrokerProtocol.encode(response), as: UTF8.self).contains(canary))
        }
        XCTAssertEqual(harness.authority.sessionList.first?.disclosures, 0, "nothing was disclosed")
        XCTAssertNotEqual(harness.authority.releaseVault(info.key) { VaultHandoff(kind: .text, text: canary) }, .handedOff)
        XCTAssertEqual(receivedBytesUntilEOF(harness.client.fd, timeout: 0.5), 0, "no further bytes reach the client")
    }

    /// Vault handoff boundary (R): the absolute session lifetime passing during build, while the
    /// Vault is still unlocked, prevents the handoff and expires the session.
    func testVaultSessionExpiryDuringBuildWhileUnlockedSendsNothing() throws {
        let canary = "CR-SYNTHETIC-SHOULD-NOT-SEND"
        var limits = TransportLimits.standard
        limits.maxSessionLifetime = 60
        limits.vaultRequestTimeout = 600
        let clock = ManualClock()
        let (harness, session) = try paired(clock: clock, limits: limits)
        defer { harness.authority.revokeAllSessions(.userRevoked) }
        let (result, info) = try openVaultWaiter(harness, session: session, requestID: 32)
        let outcome = harness.authority.releaseVault(info.key, stillUnlocked: { true }) {
            clock.advance(61) // the session lifetime passes while the payload is being built
            return VaultHandoff(kind: .text, text: canary)
        }
        XCTAssertEqual(outcome, .sessionNotApproved)
        harness.authority.wakeWaiters()
        let response = result.response()
        XCTAssertEqual(response?.result, .failure(.vaultRequestCancelled))
        XCTAssertFalse(response?.result.carriesContent ?? true)
        if let response {
            XCTAssertFalse(String(decoding: try BrokerProtocol.encode(response), as: UTF8.self).contains(canary))
        }
        XCTAssertEqual(harness.authority.sessionList.first?.disclosures, 0, "nothing was disclosed")
        XCTAssertEqual(harness.authority.sessionState(session), .expired)
        let next = try harness.client.call(sessionID: session, requestID: 33, .syncStatus)
        XCTAssertEqual(next.result, .sessionState(.expired))
        XCTAssertEqual(harness.done.wait(timeout: .now() + 5), .success, "the expired session closes its connection")
    }

    /// Vault handoff boundary (R): when both the request deadline and the session lifetime pass
    /// during build, session expiry wins, so the waiter sees a cancellation, and nothing is sent.
    func testVaultSessionExpiryWinsWhenRequestDeadlineAlsoPassesDuringBuild() throws {
        let canary = "CR-SYNTHETIC-SHOULD-NOT-SEND"
        var limits = TransportLimits.standard
        limits.maxSessionLifetime = 60
        limits.vaultRequestTimeout = 60
        let clock = ManualClock()
        let (harness, session) = try paired(clock: clock, limits: limits)
        defer { harness.authority.revokeAllSessions(.userRevoked) }
        let (result, info) = try openVaultWaiter(harness, session: session, requestID: 34)
        let outcome = harness.authority.releaseVault(info.key, stillUnlocked: { true }) {
            clock.advance(61)
            return VaultHandoff(kind: .text, text: canary)
        }
        XCTAssertNotEqual(outcome, .handedOff)
        XCTAssertEqual(outcome, .sessionNotApproved)
        harness.authority.wakeWaiters()
        let response = result.response()
        XCTAssertEqual(response?.result, .failure(.vaultRequestCancelled))
        XCTAssertFalse(response?.result.carriesContent ?? true)
        if let response {
            XCTAssertFalse(String(decoding: try BrokerProtocol.encode(response), as: UTF8.self).contains(canary))
        }
        XCTAssertEqual(harness.authority.sessionList.first?.disclosures, 0, "nothing was disclosed")
    }

    /// Vault handoff boundary control (C): deadlines that have not passed at the send still
    /// deliver the approved item exactly once.
    func testVaultHandoffStillSucceedsWhenDeadlinesAreNotReachedDuringBuild() throws {
        var limits = TransportLimits.standard
        limits.maxSessionLifetime = 600
        limits.vaultRequestTimeout = 60
        let clock = ManualClock()
        let (harness, session) = try paired(clock: clock, limits: limits)
        defer { harness.authority.revokeAllSessions(.userRevoked) }
        let (result, info) = try openVaultWaiter(harness, session: session, requestID: 35)
        let handoff = VaultHandoff(kind: .text, text: "CR-SYNTHETIC-VAULT-OK")
        let outcome = harness.authority.releaseVault(info.key, stillUnlocked: { true }) {
            clock.advance(59)
            return handoff
        }
        XCTAssertEqual(outcome, .handedOff)
        XCTAssertEqual(result.response()?.result, .vaultItem(handoff))
        XCTAssertEqual(harness.authority.sessionList.first?.disclosures, 1)
        XCTAssertNotEqual(harness.authority.releaseVault(info.key) { handoff }, .handedOff, "one-shot")
    }

    func testExclusionsWidenOnlyAndReachTheHandoff() throws {
        let authority = AgentAccessAuthority()
        let folder = UUID()
        authority.widenExclusions(folderIDs: [folder], savedClipIDs: [])
        authority.widenExclusions(folderIDs: [], savedClipIDs: [syntheticClipA])
        XCTAssertEqual(authority.currentExclusions, AgentAccessExclusions(folderIDs: [folder], savedClipIDs: [syntheticClipA]))
    }

    private func onlyOnePendingVaultRequestPerSession() throws {
        let authority = AgentAccessAuthority()
        authority.setEnabled(true)
        let (a, b) = socketPair()
        defer { close(a); close(b) }
        let connection = try XCTUnwrap(authority.registerConnection(fd: a))
        let session = try XCTUnwrap(authority.openSession(connectionID: connection, displayName: "x", pairingTimeout: 60, lifetime: 600))
        XCTAssertEqual(authority.openVaultRequest(connectionID: connection, sessionID: session.id, requestID: 1, purpose: "p", timeout: 60), .failure(.notApproved))
        authority.decidePairing(session.id, approve: true)
        guard case .success = authority.openVaultRequest(connectionID: connection, sessionID: session.id, requestID: 1, purpose: "p", timeout: 60) else {
            return XCTFail("expected open")
        }
        XCTAssertEqual(authority.openVaultRequest(connectionID: connection, sessionID: session.id, requestID: 2, purpose: "p", timeout: 60), .failure(.vaultRequestBusy))
        XCTAssertEqual(authority.openVaultRequest(connectionID: connection + 1, sessionID: session.id, requestID: 3, purpose: "p", timeout: 60), .failure(.notApproved), "a session is bound to its connection")
    }
}

final class AuthorityBox: @unchecked Sendable {
    var authority: AgentAccessAuthority?
}

final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?
    var value: T? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// Real listening sockets under a unique short temporary directory per test.
final class AgentAccessListenerTests: XCTestCase {
    var directory = ""

    override func setUpWithError() throws {
        directory = "/tmp/cr-aa-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: directory)
    }

    func makeListener(authenticate: @escaping @Sendable (Int32) throws -> VerifiedPeer = syntheticPeer) -> (AgentAccessListener, AgentAccessAuthority, EventRecorder) {
        let authority = AgentAccessAuthority()
        authority.setEnabled(true)
        let events = EventRecorder()
        let listener = AgentAccessListener(handler: BrokerConnectionHandler(
            authority: authority,
            backend: SyntheticBackend(authority: authority, clips: syntheticClips()),
            authenticate: authenticate,
            log: { events.record($0) }
        ))
        return (listener, authority, events)
    }

    func connectClient(_ endpoint: AgentAccessEndpoint) throws -> BrokerClient {
        let fd = try LocalSocket.connect(to: endpoint.socketPath)
        return BrokerClient(fd: fd, server: VerifiedPeer(identifier: "app", teamIdentifier: nil, processIdentifier: 0),
                            timing: BrokerConnectTiming(connectMilliseconds: 0, verifyMilliseconds: 0), limits: .standard)
    }

    func waitFor(_ condition: () -> Bool, timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return condition()
    }

    func testPrivateSocketRejectedPeerGetsZeroBytesAndStopUnlinks() throws {
        let endpoint = try AgentAccessEndpoint(containerDataPath: directory)
        let (listener, _, events) = makeListener(authenticate: { _ in throw LocalIPCError.peerRequirementFailed(-67050) })
        try listener.start(endpoint: endpoint)
        var info = stat()
        XCTAssertEqual(lstat(endpoint.socketPath, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
        XCTAssertEqual(lstat(endpoint.directoryPath, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o700)
        let fd = try LocalSocket.connect(to: endpoint.socketPath)
        XCTAssertEqual(receivedBytesUntilEOF(fd), 0, "rejected peer must receive zero bytes")
        close(fd)
        listener.stop()
        XCTAssertNotEqual(lstat(endpoint.socketPath, &info), 0, "stop is synchronous and unlinks")
        XCTAssertTrue(events.lines.contains { $0.contains("event=reject reason=peer_requirement_failed") })
        XCTAssertThrowsError(try LocalSocket.connect(to: endpoint.socketPath))
    }

    func testStopThenImmediateStartKeepsReplacementSocket() throws {
        let endpoint = try AgentAccessEndpoint(containerDataPath: directory)
        let (listener, _, _) = makeListener()
        for _ in 0..<20 {
            try listener.start(endpoint: endpoint)
            listener.stop()
            try listener.start(endpoint: endpoint)
            let client = try connectClient(endpoint)
            XCTAssertEqual(try client.hello(displayName: nil).state, .pendingApproval, "replacement socket must be live")
            client.close()
            listener.stop()
        }
    }

    func testFourIdleClientsFreedByDisableAndRestart() throws {
        let endpoint = try AgentAccessEndpoint(containerDataPath: directory)
        let (listener, authority, events) = makeListener()
        try listener.start(endpoint: endpoint)
        var clients: [BrokerClient] = []
        for _ in 0..<4 {
            let client = try connectClient(endpoint)
            let reply = try client.hello(displayName: nil)
            authority.decidePairing(reply.sessionID, approve: true)
            XCTAssertEqual(try client.call(sessionID: reply.sessionID, requestID: 1, .awaitPairing).result, .sessionState(.approved))
            clients.append(client)
        }
        let extra = try connectClient(endpoint)
        XCTAssertEqual(receivedBytesUntilEOF(extra.fd), 0)
        XCTAssertTrue(waitFor { events.lines.contains { $0.contains("reason=connection_cap") } })

        authority.setEnabled(false)
        for client in clients { XCTAssertEqual(receivedBytesUntilEOF(client.fd, timeout: 2), 0, "idle client is shut down") }
        XCTAssertTrue(waitFor { authority.connectionCount == 0 }, "all four slots free promptly")
        listener.stop()

        authority.setEnabled(true)
        try listener.start(endpoint: endpoint)
        let fresh = try connectClient(endpoint)
        XCTAssertEqual(try fresh.hello(displayName: nil).state, .pendingApproval)
        listener.stop()
        XCTAssertEqual(receivedBytesUntilEOF(fresh.fd, timeout: 2), 0, "stop shuts down live connections")
        XCTAssertTrue(waitFor { authority.connectionCount == 0 })
    }

    func testRevokingOneSessionFreesItsSlot() throws {
        let endpoint = try AgentAccessEndpoint(containerDataPath: directory)
        let (listener, authority, _) = makeListener()
        try listener.start(endpoint: endpoint)
        defer { listener.stop() }
        var sessions: [String] = []
        var clients: [BrokerClient] = []
        for _ in 0..<4 {
            let client = try connectClient(endpoint)
            sessions.append(try client.hello(displayName: nil).sessionID)
            clients.append(client)
        }
        authority.revokeSession(sessions[0])
        XCTAssertEqual(receivedBytesUntilEOF(clients[0].fd, timeout: 2), 0)
        XCTAssertTrue(waitFor { authority.connectionCount == 3 })
        let replacement = try connectClient(endpoint)
        XCTAssertEqual(try replacement.hello(displayName: nil).state, .pendingApproval)
    }
}
