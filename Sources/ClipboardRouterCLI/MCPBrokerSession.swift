import ClipboardRouterAgentAccess
import Dispatch
import Foundation

/// What the bridge needs from the broker hello. Kept separate from `BrokerHelloReply` so the
/// MCP layer can be driven by a scripted fake.
struct AgentBrokerHello: Sendable, Equatable {
    var sessionID: String
    var pairingCode: String
    var state: SessionState
}

/// One authenticated connection. `hello` and `call` block and are only ever called from the
/// connection's own serial queue, one at a time.
///
/// Descriptor-lifetime contract: `interrupt()` is the only method that may be called from
/// any thread while a `call` is in flight; it must wake the blocked call without releasing
/// the descriptor. `close()` releases the descriptor, so the number can be reused by the next
/// connection: it must only be called from the owning serial queue (after any in-flight
/// `hello`/`call` has returned) or when no call is in flight. Never close from another
/// thread to cancel a call; interrupt first and queue the close behind the call.
protocol AgentBrokerConnection: AnyObject, Sendable {
    func hello(displayName: String?) throws -> AgentBrokerHello
    func call(sessionID: String, requestID: UInt32, _ operation: BrokerOperation) throws -> BrokerResponse
    /// Releases the descriptor. See the contract above: owning queue or no call in flight only.
    func close()
    /// Thread-safe: makes an in-progress `call` fail promptly without closing the descriptor.
    /// Idempotent. There is deliberately no default implementation (a default of `close()`
    /// would reintroduce the descriptor-reuse race).
    func interrupt()
}

protocol AgentBrokerConnector: Sendable {
    func connect() throws -> any AgentBrokerConnection
}

/// Production adapter. The endpoint and server policy come only from the resolved context.
struct BrokerClientConnector: AgentBrokerConnector {
    let context: BridgeIdentityContext

    func connect() throws -> any AgentBrokerConnection {
        BrokerClientConnection(
            client: try BrokerClient.connect(endpoint: context.endpoint, serverPolicy: context.serverPolicy)
        )
    }
}

final class BrokerClientConnection: AgentBrokerConnection, @unchecked Sendable {
    private let client: BrokerClient

    init(client: BrokerClient) { self.client = client }

    func hello(displayName: String?) throws -> AgentBrokerHello {
        let reply = try client.hello(displayName: displayName)
        return AgentBrokerHello(sessionID: reply.sessionID, pairingCode: reply.pairingCode, state: reply.state)
    }

    func call(sessionID: String, requestID: UInt32, _ operation: BrokerOperation) throws -> BrokerResponse {
        try client.call(sessionID: sessionID, requestID: requestID, operation)
    }

    /// Closes the descriptor. Not safe against a concurrent `call`/`hello` on the same client:
    /// call it only from the owning serial queue or when no call is in flight. To abort an
    /// in-flight call use `interrupt()` and queue the close behind the call.
    func close() { client.close() }

    /// Thread-safe `shutdown(2)` of the socket; the descriptor stays open.
    func interrupt() { client.interrupt() }
}

enum BrokerReason {
    /// Stable, content-free code for stderr.
    static func code(for error: Error) -> String {
        if let error = error as? LocalIPCError { return error.reasonCode }
        if let error = error as? AgentAccessIdentityError { return error.reasonCode }
        return "unexpected_error"
    }
}

/// Outcome of one tool operation as seen by the MCP layer.
enum BrokerCallOutcome: Sendable, Equatable {
    case result(BrokerResult)
    /// Pairing is still pending in the app.
    case waiting(code: String)
    /// Denied, expired or revoked. The next call starts a fresh connection.
    case notGranted
    /// Agent Access was turned off in the app. The next call reconnects.
    case accessDisabled
    /// The connection was lost or misbehaved. The next call reconnects.
    case disconnected
    /// The app is not running or could not be verified.
    case unavailable
    /// The MCP client cancelled the call. No response is sent and nothing is retried.
    case cancelled
}

/// How a cancelled broker call ended.
enum BrokerCallCancellation: Error, Equatable {
    /// Cancelled while queued: removed from the queue, never sent; the connection stays usable.
    case beforeSend
    /// Cancelled while in flight: the whole link is interrupted and dropped (fail closed).
    case inFlight
    /// The link died (another call was cancelled in flight, or the session shut down) before
    /// this call was answered. It is never sent on a dead link and never retried.
    case linkDropped
}

/// One queued/running broker call. Its continuation is resumed exactly once, from whichever
/// of completion, cancellation or link death happens first; later results are discarded.
private final class CallTicket: @unchecked Sendable {
    let operation: BrokerOperation
    private let lock = NSLock()
    private var continuation: CheckedContinuation<BrokerResponse, Error>?
    private var early: Result<BrokerResponse, Error>?
    private var finished = false
    private var cancelled = false

    init(_ operation: BrokerOperation) { self.operation = operation }

    var isCancelled: Bool { lock.withLock { cancelled } }
    func markCancelled() { lock.withLock { cancelled = true } }

    func install(_ continuation: CheckedContinuation<BrokerResponse, Error>) {
        let ready: Result<BrokerResponse, Error>? = lock.withLock {
            if let early { return early }
            self.continuation = continuation
            return nil
        }
        if let ready { continuation.resume(with: ready) }
    }

    func finish(_ result: Result<BrokerResponse, Error>) {
        let waiting: CheckedContinuation<BrokerResponse, Error>? = lock.withLock {
            guard !finished else { return nil }
            finished = true
            if let continuation {
                self.continuation = nil
                return continuation
            }
            early = result
            return nil
        }
        waiting?.resume(with: result)
    }
}

/// One authenticated connection with its own call queue. At most one call runs at a time (in
/// wire order). Queued calls live in `pending`, so a cancelled one is removed immediately
/// instead of lingering in a dispatch queue: queued work is bounded by what callers admit.
private final class Link: @unchecked Sendable {
    let id: Int
    let connection: any AgentBrokerConnection
    let sessionID: String
    let pairingCode: String
    private let queue: DispatchQueue
    // Touched only on `queue`.
    private var nextRequestID: UInt32 = 1
    // Protected by `lock`.
    private let lock = NSLock()
    private var pending: [CallTicket] = []
    private var running: CallTicket?
    private var draining = false
    private var dead = false
    // Touched only by the owning actor.
    var outcome: BrokerSession.PairingOutcome?
    var waiters: [Int: CheckedContinuation<BrokerSession.PairingOutcome?, Never>] = [:]
    var closed = false

    init(id: Int, connection: any AgentBrokerConnection, hello: AgentBrokerHello, queue: DispatchQueue) {
        self.id = id
        self.connection = connection
        sessionID = hello.sessionID
        pairingCode = hello.pairingCode
        self.queue = queue
    }

    func submit(_ ticket: CallTicket) {
        enum Action { case rejected, start, queued }
        let action: Action = lock.withLock {
            if dead { return .rejected }
            pending.append(ticket)
            if draining { return .queued }
            draining = true
            return .start
        }
        switch action {
        case .rejected: ticket.finish(.failure(BrokerCallCancellation.linkDropped))
        case .start: queue.async { self.drain() }
        case .queued: break
        }
        // Cancelled between the caller's check and the append: remove it now.
        if ticket.isCancelled { cancel(ticket) }
    }

    /// Ends the connection without ever freeing the descriptor under a running call: the
    /// connection is interrupted at once (thread-safe, descriptor stays open) and the final
    /// `close()` is queued on this link's own serial I/O queue, so it runs only after any
    /// blocking `hello`/`call` has returned. Callers guard against calling it twice.
    func retireConnection() {
        let connection = connection
        connection.interrupt()
        queue.async { connection.close() }
    }

    private func drain() {
        while true {
            let next: CallTicket? = lock.withLock {
                if dead || pending.isEmpty {
                    draining = false
                    return nil
                }
                let ticket = pending.removeFirst()
                running = ticket
                return ticket
            }
            guard let ticket = next else { return }
            let result: Result<BrokerResponse, Error>
            if ticket.isCancelled {
                // Cancelled after the pop: never sent.
                result = .failure(BrokerCallCancellation.beforeSend)
            } else {
                // IDs are assigned on the serial queue so they match wire order.
                let requestID = nextRequestID
                nextRequestID += 1
                do {
                    result = .success(try connection.call(sessionID: sessionID, requestID: requestID, ticket.operation))
                } catch {
                    result = .failure(error)
                }
            }
            lock.withLock { running = nil }
            ticket.finish(result)
        }
    }

    /// MCP cancellation of one call; safe from any thread. A queued call is removed and
    /// resumed at once and the connection is kept. A running call fails the whole link closed:
    /// the connection is interrupted (the app sees EOF) and every other pending call on it is
    /// resumed with `linkDropped`. Nothing is retried; the next tool call reconnects and re-pairs.
    func cancel(_ ticket: CallTicket) {
        ticket.markCancelled()
        enum Kind { case queued, running, none }
        let kind: Kind = lock.withLock {
            if let index = pending.firstIndex(where: { $0 === ticket }) {
                pending.remove(at: index)
                return .queued
            }
            return running === ticket ? .running : .none
        }
        switch kind {
        case .queued, .none:
            ticket.finish(.failure(BrokerCallCancellation.beforeSend))
        case .running:
            ticket.finish(.failure(BrokerCallCancellation.inFlight))
            kill()
            connection.interrupt()
        }
    }

    /// Marks the link dead and resumes every queued or running call with `linkDropped`.
    func kill() {
        let victims: [CallTicket] = lock.withLock {
            dead = true
            let all = pending + (running.map { [$0] } ?? [])
            pending = []
            return all
        }
        for ticket in victims { ticket.finish(.failure(BrokerCallCancellation.linkDropped)) }
    }
}

/// A connection being opened. `abandon()` (shutdown) closes it and resumes the opener at
/// once, so shutdown never waits for a hello; a connection or hello completing after that
/// is closed here and never published.
private final class Opening: @unchecked Sendable {
    private let lock = NSLock()
    private var connection: (any AgentBrokerConnection)?
    private var continuation: CheckedContinuation<Link, Error>?
    private var abandoned = false
    private var finished = false

    func attach(_ continuation: CheckedContinuation<Link, Error>) {
        let rejected: Bool = lock.withLock {
            if abandoned { return true }
            self.continuation = continuation
            return false
        }
        if rejected { continuation.resume(throwing: CancellationError()) }
    }

    /// False when abandoned: the caller must close the connection and stop.
    func adopt(_ connection: any AgentBrokerConnection) -> Bool {
        lock.withLock {
            if abandoned { return false }
            self.connection = connection
            return true
        }
    }

    /// Returns false when the opener was already resumed (abandoned): the caller must close.
    @discardableResult
    func complete(_ result: Result<Link, Error>) -> Bool {
        let waiting: CheckedContinuation<Link, Error>? = lock.withLock {
            guard !finished, !abandoned else { return nil }
            finished = true
            let waiting = continuation
            continuation = nil
            return waiting
        }
        guard let waiting else { return false }
        waiting.resume(with: result)
        return true
    }

    func abandon() {
        let (waiting, held): (CheckedContinuation<Link, Error>?, (any AgentBrokerConnection)?) = lock.withLock {
            abandoned = true
            let pair = (finished ? nil : continuation, connection)
            finished = true
            continuation = nil
            return pair
        }
        // Interrupt, not close: hello may be blocked reading on this descriptor. The opening
        // thread closes the connection once hello returns.
        held?.interrupt()
        waiting?.resume(throwing: CancellationError())
    }
}

/// Owns at most one broker connection. Connects lazily, serializes broker calls, and never
/// holds a connection past the end of its pairing/approval.
actor BrokerSession {
    enum PairingOutcome { case approved, ended, lost }

    private let connector: any AgentBrokerConnector
    private let displayName: @Sendable () -> String?
    private let stderr: @Sendable (String) -> Void
    private let pairingWait: Duration
    private var link: Link?
    private var connecting: Task<Link, Error>?
    private var opening: Opening?
    /// Once set the session never connects again; a late hello is closed, never published.
    private var isShutDown = false
    private var nextLinkID = 0
    private var nextWaiterID = 0

    init(
        connector: any AgentBrokerConnector,
        displayName: @escaping @Sendable () -> String?,
        stderr: @escaping @Sendable (String) -> Void,
        pairingWait: Duration = .seconds(45)
    ) {
        self.connector = connector
        self.displayName = displayName
        self.stderr = stderr
        self.pairingWait = pairingWait
    }

    func perform(_ operation: BrokerOperation) async -> BrokerCallOutcome {
        if Task.isCancelled || isShutDown { return .cancelled }
        let current: Link
        do {
            current = try await ensureLink()
        } catch {
            if isShutDown { return .cancelled }
            stderr("cr mcp: connection failed (\(BrokerReason.code(for: error)))")
            return .unavailable
        }

        switch current.outcome {
        case .approved:
            break
        case .ended:
            drop(current)
            return .notGranted
        case .lost:
            drop(current)
            return .disconnected
        case nil:
            switch await waitForPairing(current) {
            case nil:
                return Task.isCancelled ? .cancelled : .waiting(code: current.pairingCode)
            case .ended:
                drop(current)
                return .notGranted
            case .lost:
                drop(current)
                return .disconnected
            case .approved:
                break
            }
        }

        let response: BrokerResponse
        do {
            response = try await run(current, operation)
        } catch BrokerCallCancellation.beforeSend {
            return .cancelled
        } catch BrokerCallCancellation.inFlight {
            drop(current)
            return .cancelled
        } catch BrokerCallCancellation.linkDropped {
            drop(current)
            return isShutDown ? .cancelled : .disconnected
        } catch {
            stderr("cr mcp: connection lost (\(BrokerReason.code(for: error)))")
            drop(current)
            return .disconnected
        }
        switch response.result {
        case let .sessionState(state):
            if state.isTerminal {
                drop(current)
                return .notGranted
            }
            return .waiting(code: current.pairingCode)
        case .failure(.accessDisabled):
            drop(current)
            return .accessDisabled
        case .failure(.notApproved):
            return .waiting(code: current.pairingCode)
        case .failure(.sessionMismatch), .failure(.requestLimitExceeded), .failure(.malformedRequest):
            stderr("cr mcp: connection reset (\(Self.failureCode(response.result)))")
            drop(current)
            return .disconnected
        default:
            return .result(response.result)
        }
    }

    func shutdown() {
        isShutDown = true
        if let current = link { drop(current) }
        connecting?.cancel()
        connecting = nil
        opening?.abandon()
        opening = nil
    }

    // MARK: - Connection lifecycle

    private func ensureLink() async throws -> Link {
        if isShutDown { throw CancellationError() }
        if let link { return link }
        if let connecting { return try await connecting.value }
        nextLinkID += 1
        let id = nextLinkID
        let connector = connector
        let name = BrokerProtocol.sanitizedDisplayName(displayName())
        let attempt = Opening()
        opening = attempt
        let task = Task<Link, Error> {
            do {
                let opened = try await Self.open(attempt, connector: connector, id: id, displayName: name)
                return try self.install(opened)
            } catch {
                self.connectFailed()
                throw error
            }
        }
        connecting = task
        return try await task.value
    }

    private func connectFailed() {
        connecting = nil
        opening = nil
    }

    private static func open(
        _ attempt: Opening,
        connector: any AgentBrokerConnector,
        id: Int,
        displayName: String
    ) async throws -> Link {
        let queue = DispatchQueue(label: "cr.mcp.broker.\(id)")
        return try await withCheckedThrowingContinuation { continuation in
            attempt.attach(continuation)
            queue.async {
                do {
                    let connection = try connector.connect()
                    guard attempt.adopt(connection) else {
                        connection.close()
                        return
                    }
                    do {
                        let hello = try connection.hello(displayName: displayName)
                        let link = Link(id: id, connection: connection, hello: hello, queue: queue)
                        // Abandoned during hello: nothing may be sent on it; close it.
                        if !attempt.complete(.success(link)) { connection.close() }
                    } catch {
                        connection.close()
                        attempt.complete(.failure(error))
                    }
                } catch {
                    attempt.complete(.failure(error))
                }
            }
        }
    }

    private func install(_ opened: Link) throws -> Link {
        connecting = nil
        opening = nil
        // Checked on the actor, so a shutdown can never interleave with the publish below.
        guard !isShutDown else {
            opened.closed = true
            opened.retireConnection()
            throw CancellationError()
        }
        let digits = opened.pairingCode.utf8
        guard digits.count == 6, digits.allSatisfy({ (0x30...0x39).contains($0) }) else {
            opened.closed = true
            opened.retireConnection()
            throw LocalIPCError.peerSignatureInvalid
        }
        link = opened
        stderr("cr mcp: approve pairing code \(opened.pairingCode) in Clipboard Router")
        startPairing(opened)
        return opened
    }

    private func drop(_ target: Link) {
        if link === target { link = nil }
        target.kill()
        if !target.closed {
            target.closed = true
            target.retireConnection()
        }
        resolve(target, .ended)
    }

    // MARK: - Pairing

    private func startPairing(_ target: Link) {
        Task {
            let outcome: PairingOutcome
            do {
                let response = try await self.run(target, .awaitPairing)
                if case .sessionState(.approved) = response.result {
                    outcome = .approved
                } else {
                    outcome = .ended
                }
            } catch {
                self.stderr("cr mcp: pairing failed (\(BrokerReason.code(for: error)))")
                outcome = .lost
            }
            self.resolve(target, outcome)
        }
    }

    private func resolve(_ target: Link, _ outcome: PairingOutcome) {
        if target.outcome == nil { target.outcome = outcome }
        let pending = target.waiters
        target.waiters = [:]
        for waiter in pending.values { waiter.resume(returning: target.outcome) }
    }

    /// Returns the pairing outcome, or nil if it is still pending after `pairingWait`.
    private func waitForPairing(_ target: Link) async -> PairingOutcome? {
        if let outcome = target.outcome { return outcome }
        nextWaiterID += 1
        let waiterID = nextWaiterID
        let wait = pairingWait
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                target.waiters[waiterID] = continuation
                Task {
                    try? await Task.sleep(for: wait)
                    self.expireWaiter(target, waiterID)
                }
                if Task.isCancelled { expireWaiter(target, waiterID) }
            }
        } onCancel: {
            Task { await self.expireWaiter(target, waiterID) }
        }
    }

    private func expireWaiter(_ target: Link, _ waiterID: Int) {
        target.waiters.removeValue(forKey: waiterID)?.resume(returning: nil)
    }

    // MARK: - Serialized blocking calls

    /// Cancellation policy (see `Link.cancel`): a queued call is removed and resumed at once
    /// and the link is kept; a call already on the wire fails the whole link closed. A
    /// cancelled call is never retried, and a late result is discarded, never surfaced.
    private func run(_ target: Link, _ operation: BrokerOperation) async throws -> BrokerResponse {
        let ticket = CallTicket(operation)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<BrokerResponse, Error>) in
                ticket.install(continuation)
                if ticket.isCancelled {
                    ticket.finish(.failure(BrokerCallCancellation.beforeSend))
                } else {
                    target.submit(ticket)
                }
            }
        } onCancel: {
            target.cancel(ticket)
        }
    }

    private static func failureCode(_ result: BrokerResult) -> String {
        if case let .failure(code) = result { return code.rawValue }
        return "unexpected"
    }
}
