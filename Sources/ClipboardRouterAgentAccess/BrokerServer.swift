// App-side listener and per-connection request loop. Events carry only names, reason codes
// and monotonic millisecond offsets, never payloads, titles, purposes or client names.

import Darwin
import Foundation

public struct AgentAccessEvent: Sendable, Equatable {
    public var name: String
    public var reason: String?
    /// Milliseconds since the connection was accepted (0 for listener events).
    public var elapsedMilliseconds: Int

    public init(name: String, reason: String? = nil, elapsedMilliseconds: Int) {
        self.name = name
        self.reason = reason
        self.elapsedMilliseconds = elapsedMilliseconds
    }

    public var line: String {
        "t_ms=\(elapsedMilliseconds) event=\(name)" + (reason.map { " reason=\($0)" } ?? "")
    }
}

/// Data the app serves. Content may only leave through `ReleaseChannel.release` (saved
/// clips, status) or `AgentAccessAuthority.releaseVault` (the user-approved Vault item).
public protocol AgentAccessBackend: Sendable {
    func listSharedClips(_ channel: ReleaseChannel, limit: Int) async -> ReleaseOutcome
    func getSharedClip(_ channel: ReleaseChannel, id: String) async -> ReleaseOutcome
    func syncStatus(_ channel: ReleaseChannel) async -> ReleaseOutcome
    /// A Vault request was registered; surface it in the foreground UI. The user's decision
    /// reaches the waiting connection through the authority.
    func vaultRequestOpened(_ info: VaultRequestInfo) async
    func pairingRequested(_ info: AgentAccessSessionInfo) async
}

/// Runs an async call to completion from a dedicated (non-cooperative) connection thread.
func runBlocking<T: Sendable>(_ body: @escaping @Sendable () async -> T) -> T {
    let box = BlockingBox<T>()
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
        box.value = await body()
        semaphore.signal()
    }
    semaphore.wait()
    return box.value!
}

private final class BlockingBox<T>: @unchecked Sendable {
    var value: T?
}

public struct BrokerConnectionHandler: Sendable {
    public var limits: TransportLimits
    public var authority: AgentAccessAuthority
    public var backend: any AgentAccessBackend
    /// Peer authentication; runs before any byte is read from or written to the socket.
    public var authenticate: @Sendable (Int32) throws -> VerifiedPeer
    public var log: @Sendable (AgentAccessEvent) -> Void

    public init(
        limits: TransportLimits = .standard,
        authority: AgentAccessAuthority,
        backend: any AgentAccessBackend,
        authenticate: @escaping @Sendable (Int32) throws -> VerifiedPeer,
        log: @escaping @Sendable (AgentAccessEvent) -> Void
    ) {
        self.limits = limits
        self.authority = authority
        self.backend = backend
        self.authenticate = authenticate
        self.log = log
    }

    /// Serves one registered connection. This thread owns `fd`: it is the only code that
    /// closes it, and only after unregistering it from the authority.
    public func serve(_ fd: Int32, connectionID: UInt64) {
        let accepted = MonotonicDeadline.now
        let log = log
        let emit: (String, String?) -> Void = { name, reason in
            let elapsed = Int((MonotonicDeadline.now.uptimeNanoseconds &- accepted.uptimeNanoseconds) / 1_000_000)
            log(AgentAccessEvent(name: name, reason: reason, elapsedMilliseconds: elapsed))
        }
        defer {
            authority.unregisterConnection(connectionID)
            close(fd)
            emit("connection_closed", nil)
        }
        let handshakeDeadline = MonotonicDeadline.after(limits.handshakeTimeout)
        do {
            _ = try authenticate(fd)
        } catch {
            emit("reject", Self.reason(error))
            return
        }
        emit("peer_verified", nil)
        guard authority.isEnabled else {
            emit("reject", "access_disabled")
            return
        }

        let hello: BridgeHello
        do {
            let frame = try FrameIO.readFrame(
                fd,
                maxBytes: limits.maxRequestFrameBytes,
                headerDeadline: handshakeDeadline,
                bodyTimeout: limits.frameBodyTimeout
            )
            hello = try BrokerProtocol.decode(BridgeHello.self, from: frame)
        } catch {
            emit("close", "handshake_" + Self.reason(error))
            return
        }
        guard hello.protocolVersion == BrokerProtocol.version else {
            emit("close", "handshake_unsupported_version")
            return
        }
        guard let session = authority.openSession(
            connectionID: connectionID,
            displayName: hello.clientDisplayName ?? "",
            pairingTimeout: limits.pairingTimeout,
            lifetime: limits.maxSessionLifetime
        ) else {
            emit("close", "access_disabled")
            return
        }
        let reply = BrokerHelloReply(
            protocolVersion: BrokerProtocol.version,
            sessionID: session.id,
            pairingCode: session.pairingCode,
            state: .pendingApproval,
            limits: limits
        )
        guard write(reply, fd, emit) else { return }
        emit("session_opened", nil)
        let backend = backend
        runBlocking { await backend.pairingRequested(session) }

        var requestCount = 0
        while true {
            let request: BrokerRequest
            do {
                let frame = try FrameIO.readFrame(
                    fd,
                    maxBytes: limits.maxRequestFrameBytes,
                    headerDeadline: .after(limits.idleTimeout),
                    bodyTimeout: limits.frameBodyTimeout
                )
                requestCount += 1
                guard requestCount <= limits.maxRequestsPerSession else {
                    _ = write(BrokerResponse(requestID: 0, result: .failure(.requestLimitExceeded)), fd, emit)
                    emit("close", "request_limit")
                    return
                }
                guard let decoded = try? BrokerProtocol.decode(BrokerRequest.self, from: frame) else {
                    _ = write(BrokerResponse(requestID: 0, result: .failure(.malformedRequest)), fd, emit)
                    emit("close", "malformed_request")
                    return
                }
                request = decoded
            } catch {
                emit("close", Self.reason(error))
                return
            }

            guard BrokerProtocol.constantTimeEquals(request.sessionID, session.id) else {
                _ = write(BrokerResponse(requestID: request.requestID, result: .failure(.sessionMismatch)), fd, emit)
                emit("close", "session_mismatch")
                return
            }

            let channel = ReleaseChannel(
                authority: authority,
                connectionID: connectionID,
                sessionID: session.id,
                requestID: request.requestID
            )
            switch handle(request, channel: channel, emit: emit) {
            case .handedOff:
                emit("handoff", Self.operationCode(request.operation))
            case let .refused(result):
                // Defensive: a refusal must never carry content.
                let safe = result.carriesContent ? BrokerResult.failure(.unavailable) : result
                guard write(BrokerResponse(requestID: request.requestID, result: safe), fd, emit) else { return }
                emit("response", Self.resultCode(safe))
                if case let .sessionState(state) = safe, state.isTerminal {
                    emit("close", "session_\(state.rawValue)")
                    return
                }
                if case .failure(.accessDisabled) = safe {
                    emit("close", "access_disabled")
                    return
                }
            case .transportFailed:
                emit("close", "handoff_transport_failed")
                return
            }
        }
    }

    private func handle(
        _ request: BrokerRequest,
        channel: ReleaseChannel,
        emit: (String, String?) -> Void
    ) -> ReleaseOutcome {
        let backend = backend
        let sessionID = channel.sessionID
        switch request.operation {
        case .awaitPairing:
            let state = authority.awaitPairing(sessionID)
            emit("pairing_decided", state.rawValue)
            return .refused(.sessionState(state))
        case let .listSharedClips(limit):
            guard (1...BrokerProtocol.maxListLimit).contains(limit) else { return .refused(.failure(.invalidArgument)) }
            return gated(sessionID) { runBlocking { await backend.listSharedClips(channel, limit: limit) } }
        case let .getSharedClip(id):
            guard !id.isEmpty, id.utf8.count <= BrokerProtocol.maxClipIDBytes else {
                return .refused(.failure(.invalidArgument))
            }
            return gated(sessionID) { runBlocking { await backend.getSharedClip(channel, id: id) } }
        case .syncStatus:
            return gated(sessionID) { runBlocking { await backend.syncStatus(channel) } }
        case let .requestVaultItem(purpose):
            switch authority.openVaultRequest(
                connectionID: channel.connectionID,
                sessionID: sessionID,
                requestID: request.requestID,
                purpose: purpose,
                timeout: limits.vaultRequestTimeout
            ) {
            case let .failure(code):
                return code == .notApproved ? .refused(stateResult(sessionID)) : .refused(.failure(code))
            case let .success(key):
                emit("vault_request_opened", nil)
                if let info = authority.pendingVaultRequests.first(where: { $0.key == key }) {
                    runBlocking { await backend.vaultRequestOpened(info) }
                }
                switch authority.awaitVaultRequest(key) {
                case .handedOff:
                    return .handedOff
                case let .failed(code):
                    emit("vault_request_finished", code.rawValue)
                    return .refused(.failure(code))
                case .connectionGone:
                    return .transportFailed
                }
            }
        }
    }

    /// Unpaired sessions never reach the backend; the handoff re-checks everything.
    private func gated(_ sessionID: String, _ body: () -> ReleaseOutcome) -> ReleaseOutcome {
        if let code = authority.authorizeMetadata(sessionID: sessionID) {
            return .refused(code == .notApproved ? stateResult(sessionID) : .failure(code))
        }
        return body()
    }

    private func stateResult(_ sessionID: String) -> BrokerResult {
        let state = authority.sessionState(sessionID) ?? .revoked
        return state.isTerminal ? .sessionState(state) : .failure(.notApproved)
    }

    /// Content-free frames only (hello, refusals). Content goes through the authority.
    private func write(_ value: some Encodable, _ fd: Int32, _ emit: (String, String?) -> Void) -> Bool {
        do {
            try FrameIO.writeFrame(fd, try BrokerProtocol.encode(value), maxBytes: limits.maxResponseFrameBytes, timeout: limits.writeTimeout)
            return true
        } catch {
            emit("close", "write_" + Self.reason(error))
            return false
        }
    }

    public static func reason(_ error: any Error) -> String {
        if let ipc = error as? LocalIPCError { return ipc.reasonCode }
        if error is DecodingError { return "decode_failed" }
        return "unexpected"
    }

    static func operationCode(_ operation: BrokerOperation) -> String {
        switch operation {
        case .awaitPairing: "await_pairing"
        case .listSharedClips: "list_shared_clips"
        case .getSharedClip: "get_shared_clip"
        case .requestVaultItem: "request_vault_item"
        case .syncStatus: "sync_status"
        }
    }

    public static func resultCode(_ result: BrokerResult) -> String {
        switch result {
        case let .sessionState(state): "state_\(state.rawValue)"
        case .sharedClips: "shared_clips"
        case .sharedClip: "shared_clip"
        case .vaultItem: "vault_item"
        case .syncStatus: "sync_status"
        case let .failure(code): "failure_\(code.rawValue)"
        }
    }
}

public enum AgentAccessListenerError: Error, Equatable, Sendable {
    case stopInProgress
}

/// Accept loop on a private serial queue. No socket exists while stopped. `stop()` is
/// synchronous: when it returns, the listening descriptor is closed, the socket path is
/// unlinked (only if it is still ours), no further accept can run, and every live
/// connection has been shut down so its thread exits and frees its slot.
public final class AgentAccessListener: @unchecked Sendable {
    private enum State {
        case idle
        case listening(source: DispatchSourceRead, generation: UInt64)
        case stopping
    }

    private let queue = DispatchQueue(label: "com.clipboardrouter.agent-access.listener")
    private let lock = NSLock()
    private var state = State.idle
    private var generation: UInt64 = 0
    public let handler: BrokerConnectionHandler
    static let acceptBatchLimit = 8

    public init(handler: BrokerConnectionHandler) {
        self.handler = handler
    }

    public var isListening: Bool {
        lock.withLock { if case .listening = state { true } else { false } }
    }

    public func start(endpoint: AgentAccessEndpoint) throws {
        try lock.withLock {
            switch state {
            case .listening: return
            case .stopping: throw AgentAccessListenerError.stopInProgress
            case .idle: break
            }
            try LocalSocket.preparePrivateDirectory(endpoint.directoryPath)
            let fd = try LocalSocket.listen(at: endpoint.socketPath)
            var info = stat()
            _ = lstat(endpoint.socketPath, &info)
            let boundDevice = info.st_dev
            let boundInode = info.st_ino
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            generation &+= 1
            let current = generation
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            let path = endpoint.socketPath
            source.setEventHandler { [weak self] in self?.acceptBatch(fd, generation: current) }
            source.setCancelHandler {
                close(fd)
                // Unlink only the socket this generation bound; never a replacement.
                var now = stat()
                if lstat(path, &now) == 0, now.st_dev == boundDevice, now.st_ino == boundInode {
                    unlink(path)
                }
            }
            state = .listening(source: source, generation: current)
            source.resume()
        }
        handler.log(AgentAccessEvent(name: "listener_started", elapsedMilliseconds: 0))
    }

    public func stop() {
        let source: DispatchSourceRead? = lock.withLock {
            guard case let .listening(source, _) = state else { return nil }
            state = .stopping
            return source
        }
        guard let source else { return }
        // The cancel handler runs on the serial queue after any in-flight accept batch, so
        // when this barrier completes no accept can follow and cleanup has finished.
        source.cancel()
        queue.sync {}
        handler.authority.shutdownAllConnections(.listenerStopped)
        lock.withLock { state = .idle }
        handler.log(AgentAccessEvent(name: "listener_stopped", elapsedMilliseconds: 0))
    }

    private func isCurrent(_ candidate: UInt64) -> Bool {
        lock.withLock {
            if case let .listening(_, current) = state { current == candidate } else { false }
        }
    }

    /// Bounded batch so a flood of arrivals cannot starve cancellation; each accept re-checks
    /// that this generation is still listening.
    private func acceptBatch(_ listenFD: Int32, generation candidate: UInt64) {
        for _ in 0..<Self.acceptBatchLimit {
            guard isCurrent(candidate) else { return }
            let client = accept(listenFD, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            LocalSocket.configure(client)
            guard LocalSocket.setNonBlocking(client) else {
                close(client)
                continue
            }
            guard isCurrent(candidate) else {
                close(client)
                return
            }
            guard let connectionID = handler.authority.registerConnection(fd: client) else {
                handler.log(AgentAccessEvent(name: "reject", reason: "connection_cap", elapsedMilliseconds: 0))
                close(client)
                continue
            }
            let handler = handler
            let thread = Thread { handler.serve(client, connectionID: connectionID) }
            thread.name = "agent-access-connection"
            thread.start()
        }
    }
}
