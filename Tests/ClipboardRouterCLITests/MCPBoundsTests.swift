import ClipboardRouterAgentAccess
import Foundation
import MCP
import XCTest
@testable import ClipboardRouterCLI

/// Line source the test feeds explicitly; `next()` blocks like stdin.
final class PushSource: @unchecked Sendable {
    private let condition = NSCondition()
    private var queue: [Data] = []
    private var closed = false
    private var _reads = 0

    func push(_ line: String) {
        condition.lock()
        queue.append(Data((line + "\n").utf8))
        condition.signal()
        condition.unlock()
    }

    func close() {
        condition.lock()
        closed = true
        condition.broadcast()
        condition.unlock()
    }

    var reads: Int { condition.lock(); defer { condition.unlock() }; return _reads }

    func next() -> Data? {
        condition.lock()
        defer { condition.unlock() }
        while queue.isEmpty, !closed { condition.wait() }
        guard !queue.isEmpty else { return nil }
        _reads += 1
        return queue.removeFirst()
    }
}

/// Collects outbound JSON-RPC messages; optionally blocks writes to simulate a client that
/// stopped reading stdout.
final class MessageSink: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [[String: Any]] = []
    private let blocker: DispatchSemaphore?

    init(blockWrites: Bool = false) { blocker = blockWrites ? DispatchSemaphore(value: 0) : nil }

    func write(_ data: Data) throws {
        blocker?.wait()
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        lock.withLock { messages.append(object) }
    }

    func unblock(_ count: Int) { for _ in 0..<count { blocker?.signal() } }
    var all: [[String: Any]] { lock.withLock { messages } }
    func response(id: Int) -> [String: Any]? { all.first { ($0["id"] as? Int) == id } }
    var busyCount: Int { all.filter { (($0["error"] as? [String: Any])?["code"] as? Int) == -32000 }.count }
}

func waitUntil(_ timeout: TimeInterval = 5, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

func toolCall(_ id: Int, _ name: String, _ arguments: String = "{}") -> String {
    "{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":\"tools/call\",\"params\":{\"name\":\"\(name)\",\"arguments\":\(arguments)}}"
}

/// Tracks the highest number of simultaneously executing broker calls across connections.
final class ConcurrencyProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private var _peak = 0

    func enter() { lock.withLock { current += 1; _peak = max(_peak, current) } }
    func exit() { lock.withLock { current -= 1 } }
    var peak: Int { lock.withLock { _peak } }
}

/// Broker connection whose Vault request blocks until released or interrupted.
final class BlockingConnection: AgentBrokerConnection, @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private let probe: ConcurrencyProbe?
    private var interrupted = false
    private var _operations: [BrokerOperation] = []
    private var _interrupts = 0

    init(probe: ConcurrencyProbe? = nil) { self.probe = probe }

    var operations: [BrokerOperation] { lock.withLock { _operations } }
    var interrupts: Int { lock.withLock { _interrupts } }

    func hello(displayName: String?) throws -> AgentBrokerHello {
        AgentBrokerHello(sessionID: "blocking-session", pairingCode: "135790", state: .pendingApproval)
    }

    func call(sessionID: String, requestID: UInt32, _ operation: BrokerOperation) throws -> BrokerResponse {
        probe?.enter()
        defer { probe?.exit() }
        lock.withLock { _operations.append(operation) }
        switch operation {
        case .awaitPairing:
            return BrokerResponse(requestID: requestID, result: .sessionState(.approved))
        case .requestVaultItem:
            release.wait()
            if lock.withLock({ interrupted }) { throw LocalIPCError.peerClosed }
            return BrokerResponse(requestID: requestID, result: .vaultItem(VaultHandoff(kind: .text, text: syntheticCanary)))
        default:
            return BrokerResponse(requestID: requestID, result: .sharedClip(SharedClipContent(id: "clip-1", kind: .text, text: syntheticCanary)))
        }
    }

    func releaseVault() { release.signal() }

    func interrupt() {
        lock.withLock {
            interrupted = true
            _interrupts += 1
        }
        release.signal()
    }

    func close() { interrupt() }
}

final class BlockingConnector: AgentBrokerConnector, @unchecked Sendable {
    private let lock = NSLock()
    private var _made: [BlockingConnection] = []
    let probe = ConcurrencyProbe()
    var made: [BlockingConnection] { lock.withLock { _made } }
    var vaultOperationCount: Int {
        made.reduce(0) { total, connection in
            total + connection.operations.filter { if case .requestVaultItem = $0 { true } else { false } }.count
        }
    }

    func connect() throws -> any AgentBrokerConnection {
        let connection = BlockingConnection(probe: probe)
        lock.withLock { _made.append(connection) }
        return connection
    }
}

/// Connection whose hello blocks until the test releases it.
final class GatedHelloConnection: AgentBrokerConnection, @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var _helloEntered = false
    private var _helloReturned = false
    private var _operations: [BrokerOperation] = []
    private var _closes = 0
    private var _interrupts = 0

    var helloEntered: Bool { lock.withLock { _helloEntered } }
    var helloReturned: Bool { lock.withLock { _helloReturned } }
    var operations: [BrokerOperation] { lock.withLock { _operations } }
    var closes: Int { lock.withLock { _closes } }
    var interrupts: Int { lock.withLock { _interrupts } }
    func releaseHello() { gate.signal() }

    func hello(displayName: String?) throws -> AgentBrokerHello {
        lock.withLock { _helloEntered = true }
        gate.wait()
        lock.withLock { _helloReturned = true }
        return AgentBrokerHello(sessionID: "gated-session", pairingCode: "112233", state: .pendingApproval)
    }

    func call(sessionID: String, requestID: UInt32, _ operation: BrokerOperation) throws -> BrokerResponse {
        lock.withLock { _operations.append(operation) }
        return BrokerResponse(requestID: requestID, result: .sessionState(.approved))
    }

    func close() { lock.withLock { _closes += 1 } }
    func interrupt() { lock.withLock { _interrupts += 1 } }
}

final class GatedHelloConnector: AgentBrokerConnector, @unchecked Sendable {
    private let lock = NSLock()
    private var _made: [GatedHelloConnection] = []
    var made: [GatedHelloConnection] { lock.withLock { _made } }

    func connect() throws -> any AgentBrokerConnection {
        let connection = GatedHelloConnection()
        lock.withLock { _made.append(connection) }
        return connection
    }
}

final class MCPTransportBoundsTests: XCTestCase {
    private func drainCount(_ transport: BoundedStdioTransport, counter: LineSink) {
        Task {
            try await transport.connect()
            for try await data in await transport.receive() {
                counter.append(String(decoding: data, as: UTF8.self))
            }
        }
    }

    func testRequestFloodIsAdmittedOnlyUpToTheCapAndRestRefusedImmediately() async throws {
        let source = PushSource()
        let sink = MessageSink()
        let transport = BoundedStdioTransport(
            maxInFlightRequests: 4,
            maxPendingRefusals: 2_000,
            readChunk: { source.next() },
            writeSink: { try sink.write($0) }
        )
        let forwarded = LineSink()
        drainCount(transport, counter: forwarded)
        for id in 1...500 { source.push(toolCall(id, "get_shared_clip", "{\"id\":\"clip-1\"}")) }
        let refused = await waitUntil { sink.busyCount == 496 }
        XCTAssertTrue(refused, "busy refusals: \(sink.busyCount)")
        XCTAssertEqual(forwarded.lines.count, 4, "only admitted requests reach the SDK")
        let inFlight = await transport.inFlightRequestCount
        XCTAssertEqual(inFlight, 4)

        // A cancellation alone does not free the slot of work whose handler is running.
        XCTAssertTrue(transport.admission.handlerStarted("n:2"))
        source.push("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":2}}")
        source.push(toolCall(899, "sync_status"))
        let refusedWhileUnretired = await waitUntil { sink.busyCount == 497 }
        XCTAssertTrue(refusedWhileUnretired, "a cancelled request keeps its slot until its handler retires")
        let stillHeld = await transport.inFlightRequestCount
        XCTAssertEqual(stillHeld, 4)
        // Once the cancelled handler task has ended, the slot is free and the next request is admitted.
        transport.admission.retire("n:2")
        source.push(toolCall(900, "sync_status"))
        let admitted = await waitUntil { forwarded.lines.contains { $0.contains("\"id\":900") } }
        XCTAssertTrue(admitted)
        XCTAssertEqual(forwarded.lines.count, 6, "four requests, the cancellation notification and request 900")
        // An answered request frees its slot once its response has been written.
        try await transport.send(Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}".utf8))
        let freed = await transport.inFlightRequestCount
        XCTAssertEqual(freed, 3)
        source.close()
    }

    func testSlotIsHeldUntilTheResponseWriteCompletes() async throws {
        let source = PushSource()
        let sink = MessageSink(blockWrites: true)
        let transport = BoundedStdioTransport(
            maxInFlightRequests: 1,
            readChunk: { source.next() },
            writeSink: { try sink.write($0) }
        )
        let forwarded = LineSink()
        drainCount(transport, counter: forwarded)
        source.push(toolCall(1, "sync_status"))
        let first = await waitUntil { forwarded.lines.count == 1 }
        XCTAssertTrue(first)
        // The response for request 1 is blocked inside the sink.
        let writing = Task { try await transport.send(Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}".utf8)) }
        try await Task.sleep(for: .milliseconds(100))
        source.push(toolCall(2, "sync_status"))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(forwarded.lines.count, 1, "request 2 must not reach the SDK while write 1 is blocked")
        let held = await transport.inFlightRequestCount
        XCTAssertEqual(held, 1, "the slot is kept until the response write completes")
        sink.unblock(10)
        try await writing.value
        let released = await waitUntil { await transport.inFlightRequestCount == 0 }
        XCTAssertTrue(released)
        source.push(toolCall(3, "sync_status"))
        let admitted = await waitUntil { forwarded.lines.contains { $0.contains("\"id\":3") } }
        XCTAssertTrue(admitted, "a request is admitted once the previous response was written")
        XCTAssertNotNil(sink.response(id: 1))
        source.close()
    }

    func testQueuedOutboundWorkIsCappedAndFailsClosedWithoutRetry() async throws {
        let source = PushSource()
        let sink = MessageSink(blockWrites: true)
        let transport = BoundedStdioTransport(
            maxInFlightRequests: 8,
            maxPendingRefusals: 2,
            readChunk: { source.next() },
            writeSink: { try sink.write($0) }
        )
        let notification = Data("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/x\"}".utf8)
        let first = Task { try? await transport.send(notification) }
        let second = Task { try? await transport.send(notification) }
        try await Task.sleep(for: .milliseconds(100))
        do {
            try await transport.send(notification)
            XCTFail("the third queued write exceeds the outbound cap")
        } catch {
            XCTAssertEqual(error as? BoundedTransportError, .overloaded)
        }
        let failure = await transport.terminationFailure
        XCTAssertEqual(failure, .overloaded)
        sink.unblock(10)
        _ = await (first.value, second.value)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertLessThanOrEqual(sink.all.count, 2, "nothing is duplicated or retried")
        source.close()
    }

    func testBatchAndDuplicateIDsAreRefused() async throws {
        let source = PushSource()
        let sink = MessageSink()
        let transport = BoundedStdioTransport(readChunk: { source.next() }, writeSink: { try sink.write($0) })
        let forwarded = LineSink()
        drainCount(transport, counter: forwarded)
        source.push("[\(toolCall(1, "sync_status")),\(toolCall(2, "sync_status"))]")
        source.push(toolCall(3, "sync_status"))
        source.push(toolCall(3, "sync_status"))
        let done = await waitUntil { sink.all.count == 2 }
        XCTAssertTrue(done)
        XCTAssertEqual(forwarded.lines.count, 1)
        XCTAssertEqual(sink.all.compactMap { ($0["error"] as? [String: Any])?["code"] as? Int }, [-32600, -32600])
        source.close()
    }

    func testClientThatStopsReadingFailsClosedWithFiniteBuffers() async throws {
        let source = PushSource()
        let sink = MessageSink(blockWrites: true)
        let transport = BoundedStdioTransport(
            maxInFlightRequests: 1,
            maxPendingRefusals: 3,
            readChunk: { source.next() },
            writeSink: { try sink.write($0) }
        )
        let forwarded = LineSink()
        drainCount(transport, counter: forwarded)
        for id in 1...100 { source.push(toolCall(id, "sync_status")) }
        let failed = await waitUntil { await transport.terminationFailure == .overloaded }
        XCTAssertTrue(failed)
        XCTAssertLessThan(source.reads, 100, "the reader stops consuming once the transport failed")
        XCTAssertEqual(forwarded.lines.count, 1)
        sink.unblock(10)
        source.close()
    }

    func testReaderDoesNotRunAheadOfTheConsumer() async throws {
        let source = PushSource()
        for id in 1...50 { source.push("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/x\",\"params\":{\"n\":\(id)}}") }
        let transport = BoundedStdioTransport(readChunk: { source.next() }, writeSink: { _ in })
        try await transport.connect()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertLessThanOrEqual(source.reads, 2, "at most one line is buffered ahead")
        source.close()
        await transport.disconnect()
    }
}

final class MCPCancellationTests: XCTestCase {
    func approvedSession(_ connector: BlockingConnector) async -> BrokerSession {
        let session = BrokerSession(connector: connector, displayName: { nil }, stderr: { _ in }, pairingWait: .seconds(2))
        _ = await session.perform(.syncStatus)
        return session
    }

    func testCancellingInFlightVaultRequestInterruptsConnectionWithoutRetry() async throws {
        let connector = BlockingConnector()
        let session = await approvedSession(connector)
        let task = Task { await session.perform(.requestVaultItem(purpose: syntheticPurpose)) }
        let started = await waitUntil { connector.made.first?.operations.contains(.requestVaultItem(purpose: syntheticPurpose)) == true }
        XCTAssertTrue(started)
        task.cancel()
        let outcome = await task.value
        XCTAssertEqual(outcome, .cancelled)
        let connection = try XCTUnwrap(connector.made.first)
        XCTAssertGreaterThanOrEqual(connection.interrupts, 1, "the app sees EOF and cancels the pending Vault request")
        XCTAssertEqual(connection.operations.filter { if case .requestVaultItem = $0 { true } else { false } }.count, 1, "never retried")
        // The next call starts a fresh connection (new pairing).
        _ = await session.perform(.syncStatus)
        XCTAssertEqual(connector.made.count, 2)
        await session.shutdown()
    }

    func testCallCancelledWhileQueuedIsNeverSent() async throws {
        let connector = BlockingConnector()
        let session = await approvedSession(connector)
        let vault = Task { await session.perform(.requestVaultItem(purpose: syntheticPurpose)) }
        let connection = try XCTUnwrap(connector.made.first)
        let started = await waitUntil { connection.operations.contains(.requestVaultItem(purpose: syntheticPurpose)) }
        XCTAssertTrue(started)
        let queued = Task { await session.perform(.getSharedClip(id: "clip-1")) }
        try await Task.sleep(for: .milliseconds(100))
        queued.cancel()
        let queuedOutcome = await queued.value
        XCTAssertEqual(queuedOutcome, .cancelled)
        connection.releaseVault()
        let vaultOutcome = await vault.value
        XCTAssertEqual(vaultOutcome, .result(.vaultItem(VaultHandoff(kind: .text, text: syntheticCanary))))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(connection.operations.contains(.getSharedClip(id: "clip-1")), "a cancelled queued call is never sent")
        XCTAssertEqual(connection.interrupts, 0, "queued cancellation keeps the connection")
        await session.shutdown()
    }

    func testMCPCancelledNotificationReachesPendingVaultRequest() async throws {
        let connector = BlockingConnector()
        let session = BrokerSession(connector: connector, displayName: { nil }, stderr: { _ in }, pairingWait: .seconds(2))
        let source = PushSource()
        let sink = MessageSink()
        let transport = BoundedStdioTransport(readChunk: { source.next() }, writeSink: { try sink.write($0) })
        let server = await MCPServerFactory.make(session: session, admission: transport.admission)
        try await server.start(transport: transport)
        source.push("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"clientInfo\":{\"name\":\"\(syntheticClientName)\",\"version\":\"1\"}}}")
        let initialized = await waitUntil { sink.response(id: 1) != nil }
        XCTAssertTrue(initialized)
        source.push("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}")
        source.push(toolCall(7, "request_vault_item", "{\"purpose\":\"\(syntheticPurpose)\"}"))
        let pending = await waitUntil { connector.made.first?.operations.contains(.requestVaultItem(purpose: syntheticPurpose)) == true }
        XCTAssertTrue(pending)
        source.push("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":7,\"reason\":\"user\"}}")
        let interrupted = await waitUntil { (connector.made.first?.interrupts ?? 0) >= 1 }
        XCTAssertTrue(interrupted, "cancellation must reach the blocked broker call, not just a task flag")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(sink.response(id: 7), "no response (and no Vault text) after cancellation")
        XCTAssertFalse(sink.all.contains { String(describing: $0).contains(syntheticCanary) })
        let inFlight = await transport.inFlightRequestCount
        XCTAssertEqual(inFlight, 0)
        source.close()
        await server.stop()
        await session.shutdown()
    }

    func testRequestCancelFloodNeverExceedsTheWorkCap() async throws {
        let cap = 3
        let rounds = 5
        let connector = BlockingConnector()
        let session = BrokerSession(connector: connector, displayName: { nil }, stderr: { _ in }, pairingWait: .seconds(2))
        let source = PushSource()
        let sink = MessageSink()
        let transport = BoundedStdioTransport(
            maxInFlightRequests: cap,
            maxPendingRefusals: 2_000,
            readChunk: { source.next() },
            writeSink: { try sink.write($0) }
        )
        let server = await MCPServerFactory.make(session: session, admission: transport.admission)
        try await server.start(transport: transport)
        source.push("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"clientInfo\":{\"name\":\"\(syntheticClientName)\",\"version\":\"1\"}}}")
        let initialized = await waitUntil { sink.response(id: 1) != nil }
        XCTAssertTrue(initialized)
        source.push("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}")

        var nextID = 100
        for round in 1...rounds {
            let ids = (0..<(cap + 4)).map { _ in
                nextID += 1
                return nextID
            }
            let before = connector.vaultOperationCount
            for id in ids { source.push(toolCall(id, "request_vault_item", "{\"purpose\":\"\(syntheticPurpose)\"}")) }
            let admitted = await waitUntil { await transport.inFlightRequestCount == cap }
            XCTAssertTrue(admitted, "round \(round): \(transport.admission.inFlightCount) admitted")
            let onWire = await waitUntil { connector.vaultOperationCount > before }
            XCTAssertTrue(onWire, "round \(round): a Vault request reaches the broker")
            for id in ids.prefix(cap) {
                source.push("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":\(id)}}")
            }
            let retired = await waitUntil(10) { await transport.inFlightRequestCount == 0 }
            XCTAssertTrue(retired, "round \(round): cancelled work must retire; held \(transport.admission.inFlightCount)")
        }
        XCTAssertLessThanOrEqual(transport.admission.peakInFlight, cap, "handler tasks never exceed the cap")
        XCTAssertLessThanOrEqual(transport.admission.peakConcurrentHandlers, cap)
        XCTAssertLessThanOrEqual(connector.probe.peak, cap, "broker calls never exceed the cap")
        XCTAssertLessThanOrEqual(connector.vaultOperationCount, rounds * cap, "at most one broker send per admitted request")
        XCTAssertEqual(sink.busyCount, rounds * 4)
        XCTAssertFalse(sink.all.contains { String(describing: $0).contains(syntheticCanary) })
        source.close()
        await server.stop()
        await session.shutdown()
    }
}

final class MCPAdmissionAccountingTests: XCTestCase {
    func testUnknownResponseKeysNeverFreeAHeldCancelledSlot() {
        let admission = RequestAdmission(maxInFlight: 1, maxPendingOutbound: 10)
        XCTAssertEqual(admission.admit("s:held", isToolCall: true), .admit)
        XCTAssertTrue(admission.handlerStarted("s:held"))
        admission.markCancelled("s:held")
        admission.finish("s:parse-error")
        XCTAssertEqual(admission.inFlightCount, 1, "an unmatched response frees nothing")
        XCTAssertEqual(admission.admit("s:other", isToolCall: true), .busy)
        admission.retire("s:held")
        XCTAssertEqual(admission.inFlightCount, 0)
        XCTAssertEqual(admission.admit("s:other", isToolCall: true), .admit)
    }

    func testCancellationBeforeHandlerStartFreesTheSlotAndTheLateHandlerRefuses() {
        let admission = RequestAdmission(maxInFlight: 1, maxPendingOutbound: 10)
        XCTAssertEqual(admission.admit("n:1", isToolCall: true), .admit)
        let ticket = admission.ticket(for: "n:1")
        admission.markCancelled("n:1")
        XCTAssertEqual(admission.inFlightCount, 0)
        XCTAssertFalse(admission.handlerStarted("n:1"), "no broker work for a request cancelled before it started")
        // The cancelled id is never reused in this session; the stale ticket stays dead.
        XCTAssertEqual(admission.admit("n:1", isToolCall: true), .duplicate)
        let stale = RequestAdmission.parse(ticket: ticket ?? "")
        XCTAssertFalse(admission.handlerStarted("n:1", generation: stale?.generation))
        XCTAssertEqual(admission.admit("n:2", isToolCall: true), .admit, "a fresh id takes the freed slot")
    }

    func testResponseHoldsTheSlotUntilItsOwnResponseIsWritten() {
        let admission = RequestAdmission(maxInFlight: 2, maxPendingOutbound: 10)
        XCTAssertEqual(admission.admit("n:1", isToolCall: true), .admit)
        XCTAssertEqual(admission.admit("n:2"), .admit)
        XCTAssertTrue(admission.handlerStarted("n:1"))
        admission.handlerReturned("n:1")
        XCTAssertEqual(admission.inFlightCount, 2, "a returned handler keeps its slot until the response write")
        admission.finish("n:2")
        XCTAssertEqual(admission.inFlightCount, 1)
        admission.finish("n:1")
        XCTAssertEqual(admission.inFlightCount, 0)
        // Non-tool work is freed immediately when cancelled first.
        XCTAssertEqual(admission.admit("n:3"), .admit)
        admission.markCancelled("n:3")
        XCTAssertEqual(admission.inFlightCount, 0)
    }

    func testClientSuppliedTicketIsReplaced() throws {
        let line = Data(toolCall(5, "sync_status").replacingOccurrences(of: "\"params\":{", with: "\"params\":{\"_meta\":{\"\(RequestTicketInjection.metaKey)\":\"1/n:99\",\"progressToken\":3},").utf8)
        let injected = try XCTUnwrap(RequestTicketInjection.inject(into: line, ticket: "7/n:5"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: injected) as? [String: Any])
        let meta = try XCTUnwrap((object["params"] as? [String: Any])?["_meta"] as? [String: Any])
        XCTAssertEqual(meta[RequestTicketInjection.metaKey] as? String, "7/n:5")
        XCTAssertEqual(meta["progressToken"] as? Int, 3)
        XCTAssertEqual((object["params"] as? [String: Any])?["name"] as? String, "sync_status")
    }
}

final class MCPAdmissionIntegrationTests: XCTestCase {
    private func start(
        connector: any AgentBrokerConnector,
        cap: Int
    ) async throws -> (PushSource, MessageSink, BoundedStdioTransport, Server, BrokerSession) {
        let session = BrokerSession(connector: connector, displayName: { nil }, stderr: { _ in }, pairingWait: .seconds(2))
        let source = PushSource()
        let sink = MessageSink()
        let transport = BoundedStdioTransport(
            maxInFlightRequests: cap,
            maxPendingRefusals: 2_000,
            readChunk: { source.next() },
            writeSink: { try sink.write($0) }
        )
        let server = await MCPServerFactory.make(session: session, admission: transport.admission)
        try await server.start(transport: transport)
        source.push("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"clientInfo\":{\"name\":\"\(syntheticClientName)\",\"version\":\"1\"}}}")
        let initialized = await waitUntil { sink.response(id: 1) != nil }
        XCTAssertTrue(initialized)
        source.push("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}")
        return (source, sink, transport, server, session)
    }

    private func cancel(_ id: Int) -> String {
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":\(id)}}"
    }

    func testParseErrorResponseDoesNotFreeCancelledWorkThatIsStillHeld() async throws {
        let connector = GatedHelloConnector()
        let (source, sink, transport, server, session) = try await start(connector: connector, cap: 1)
        source.push(toolCall(10, "sync_status"))
        let entered = await waitUntil { connector.made.first?.helloEntered == true }
        XCTAssertTrue(entered, "handler A is blocked inside the broker hello")
        source.push(cancel(10))
        // Malformed input makes the SDK write a parse-error response with an unrelated id.
        source.push("{\"jsonrpc\":\"2.0\",\"method\":17}")
        let parseError = await waitUntil { sink.all.contains { (($0["error"] as? [String: Any])?["code"] as? Int) == -32700 } }
        XCTAssertTrue(parseError)
        // The parse-error write has completed; A's handler still exists, so B must be refused.
        let written = await waitUntil { transport.admission.inFlightCount == 1 }
        XCTAssertTrue(written)
        source.push(toolCall(11, "sync_status"))
        let refused = await waitUntil { sink.busyCount == 1 }
        XCTAssertTrue(refused, "B is not admitted while A's handler is alive")
        XCTAssertEqual(transport.admission.inFlightCount, 1)
        connector.made.first?.releaseHello()
        let retired = await waitUntil { transport.admission.inFlightCount == 0 }
        XCTAssertTrue(retired, "A retires when its own handler exits")
        source.push(toolCall(12, "sync_status"))
        let answered = await waitUntil { sink.response(id: 12) != nil }
        XCTAssertTrue(answered)
        XCTAssertNil(sink.response(id: 10))
        source.close()
        await server.stop()
        await session.shutdown()
    }

    func testImmediateCancellationsRacingHandlerStartNeverExhaustTheCap() async throws {
        let cap = 3
        let connector = BlockingConnector()
        let (source, sink, transport, server, session) = try await start(connector: connector, cap: cap)
        for id in 100..<120 {
            source.push(toolCall(id, "request_vault_item", "{\"purpose\":\"\(syntheticPurpose)\"}"))
            source.push(cancel(id))
        }
        let drained = await waitUntil(10) { transport.admission.inFlightCount == 0 }
        XCTAssertTrue(drained, "held \(transport.admission.inFlightCount)")
        source.push(toolCall(9000, "get_shared_clip", "{\"id\":\"clip-1\"}"))
        let answered = await waitUntil(10) { sink.response(id: 9000) != nil }
        XCTAssertTrue(answered, "a fresh call is admitted and answered")
        XCTAssertEqual(sink.busyCount, 0)
        XCTAssertLessThanOrEqual(transport.admission.peakConcurrentHandlers, cap)
        XCTAssertLessThanOrEqual(connector.probe.peak, cap)
        XCTAssertFalse(sink.all.contains { String(describing: $0).contains(syntheticCanary) && ($0["id"] as? Int ?? 0) < 9000 })
        source.close()
        await server.stop()
        await session.shutdown()
    }
}

final class MCPShutdownTests: XCTestCase {
    func testShutdownDuringHelloNeverPublishesOrUsesTheLateConnection() async throws {
        let connector = GatedHelloConnector()
        let session = BrokerSession(connector: connector, displayName: { nil }, stderr: { _ in }, pairingWait: .seconds(2))
        let pending = Task { await session.perform(.syncStatus) }
        let entered = await waitUntil { connector.made.first?.helloEntered == true }
        XCTAssertTrue(entered)
        let connection = try XCTUnwrap(connector.made.first)

        await session.shutdown()  // must not wait for the blocked hello
        let outcome = await pending.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertGreaterThanOrEqual(connection.interrupts, 1, "the provisional connection is interrupted")

        connection.releaseHello()
        let returned = await waitUntil { connection.helloReturned }
        XCTAssertTrue(returned)
        let closed = await waitUntil { connection.closes >= 1 }
        XCTAssertTrue(closed, "a hello completing after shutdown is closed")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(connection.operations, [], "nothing is ever sent on it after shutdown")

        let after = await session.perform(.syncStatus)
        XCTAssertEqual(after, .cancelled)
        XCTAssertEqual(connector.made.count, 1, "perform after shutdown does not connect")
    }
}
