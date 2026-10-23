import ClipboardRouterAgentAccess
import Foundation
import MCP
import XCTest
@testable import ClipboardRouterCLI

/// Sink that blocks the first write of a response with `gatedID` until released, and says so
/// once that write is inside the sink.
final class EnteredGateSink: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private let gatedID: Int
    private var _entered = false
    private var _messages: [[String: Any]] = []

    init(gatedID: Int) { self.gatedID = gatedID }

    func write(_ data: Data) throws {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let block = lock.withLock { () -> Bool in
            guard !_entered, (object["id"] as? Int) == gatedID else { return false }
            _entered = true
            return true
        }
        if block { gate.wait() }
        lock.withLock { _messages.append(object) }
    }

    var entered: Bool { lock.withLock { _entered } }
    var messages: [[String: Any]] { lock.withLock { _messages } }
    func release() { gate.signal() }
}

private func ticket(in line: String) -> String? {
    guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
          let params = object["params"] as? [String: Any],
          let meta = params["_meta"] as? [String: Any]
    else { return nil }
    return meta[RequestTicketInjection.metaKey] as? String
}

private func errorCode(_ message: [String: Any]) -> Int? {
    (message["error"] as? [String: Any])?["code"] as? Int
}

/// Integer ids of the `tools/call` requests among the forwarded lines.
private func forwardedToolCallIDs(_ lines: [String]) -> [Int] {
    lines.compactMap { line in
        guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              object["method"] as? String == "tools/call"
        else { return nil }
        return object["id"] as? Int
    }
}

final class MCPAdmissionRegressionTests: XCTestCase {
    private func makeTransport(
        cap: Int = 8,
        source: PushSource,
        sink: @escaping @Sendable (Data) throws -> Void
    ) -> (BoundedStdioTransport, LineSink) {
        let transport = BoundedStdioTransport(
            maxInFlightRequests: cap,
            maxPendingRefusals: 2_000,
            readChunk: { source.next() },
            writeSink: sink
        )
        let forwarded = LineSink()
        Task {
            try await transport.connect()
            for try await data in await transport.receive() {
                forwarded.append(String(decoding: data, as: UTF8.self))
            }
        }
        return (transport, forwarded)
    }

    private func cancel(_ rawID: String) -> String {
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":\(rawID)}}"
    }

    // MARK: finding 1 and 2: unusable ids never reach the SDK and never consume a slot

    func testUnusableRequestIDsAreRefusedBeforeAdmissionAndNeverForwarded() async throws {
        let source = PushSource()
        let sink = MessageSink()
        let (transport, forwarded) = makeTransport(cap: 1, source: source) { try sink.write($0) }
        let rawIDs = ["null", "1.5", "1.0", "-0.0", "1e2", "1E0", "true", "false", "9223372036854775808", "[]", "{}", "[1]"]
        var expected = 0
        for rawID in rawIDs {
            for method in ["tools/call", "ping", "tools/list"] {
                source.push("{\"jsonrpc\":\"2.0\",\"id\":\(rawID),\"method\":\"\(method)\",\"params\":{\"name\":\"sync_status\",\"arguments\":{}}}")
                expected += 1
            }
        }
        // A non-string method with an id and an id with no method/result/error would make the SDK
        // echo the raw id in a parse-error response, which could free a held slot.
        source.push("{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":17}")
        source.push("{\"jsonrpc\":\"2.0\",\"id\":7}")
        expected += 2
        let refused = await waitUntil { sink.all.count == expected }
        XCTAssertTrue(refused, "refusals: \(sink.all.count) of \(expected)")
        XCTAssertTrue(sink.all.allSatisfy { errorCode($0) == -32600 && $0["id"] is NSNull })
        XCTAssertEqual(forwarded.lines.count, 0, "nothing with an unusable id reaches the SDK")
        let held = await transport.inFlightRequestCount
        XCTAssertEqual(held, 0, "no slot is consumed")
        XCTAssertEqual(sink.busyCount, 0)
        // The single slot is still free for a valid request.
        source.push(toolCall(5, "sync_status"))
        let admitted = await waitUntil { forwarded.lines.contains { $0.contains("\"id\":5") } }
        XCTAssertTrue(admitted)
        XCTAssertEqual(sink.busyCount, 0)
        source.close()
    }

    func testNullIDToolCallCarryingAnotherRequestsTicketIsNeverForwarded() async throws {
        let source = PushSource()
        let sink = MessageSink()
        let (transport, forwarded) = makeTransport(cap: 4, source: source) { try sink.write($0) }
        // Request 5 is admitted and held before its handler starts (no SDK is attached).
        source.push(toolCall(5, "sync_status"))
        let first = await waitUntil { forwarded.lines.count == 1 }
        XCTAssertTrue(first)
        let heldTicket = try XCTUnwrap(ticket(in: try XCTUnwrap(forwarded.lines.first)))
        let parsed = try XCTUnwrap(RequestAdmission.parse(ticket: heldTicket))
        let before = await transport.inFlightRequestCount

        source.push("{\"jsonrpc\":\"2.0\",\"id\":null,\"method\":\"tools/call\",\"params\":{\"name\":\"sync_status\",\"arguments\":{},\"_meta\":{\"\(RequestTicketInjection.metaKey)\":\"\(heldTicket)\"}}}")
        let refused = await waitUntil { sink.all.count == 1 }
        XCTAssertTrue(refused)
        XCTAssertEqual(sink.all.compactMap(errorCode), [-32600])
        XCTAssertTrue(sink.all.first?["id"] is NSNull)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(forwarded.lines.count, 1, "the null-id call is not forwarded")
        let after = await transport.inFlightRequestCount
        XCTAssertEqual(after, before, "the held request's accounting is unchanged")
        XCTAssertTrue(
            transport.admission.handlerStarted(parsed.key, generation: parsed.generation),
            "the held request's ticket was not consumed by anyone else"
        )
        source.close()
    }

    func testNullIDToolCallNeverReachesTheBroker() async throws {
        let connector = BlockingConnector()
        let session = BrokerSession(connector: connector, displayName: { nil }, stderr: { _ in }, pairingWait: .seconds(2))
        let source = PushSource()
        let sink = MessageSink()
        let transport = BoundedStdioTransport(
            maxInFlightRequests: 4,
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
        source.push("{\"jsonrpc\":\"2.0\",\"id\":null,\"method\":\"tools/call\",\"params\":{\"name\":\"get_shared_clip\",\"arguments\":{\"id\":\"clip-1\"},\"_meta\":{\"\(RequestTicketInjection.metaKey)\":\"1/n:1\"}}}")
        let refused = await waitUntil { sink.all.contains { errorCode($0) == -32600 } }
        XCTAssertTrue(refused)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(connector.made.isEmpty, "no broker connection was even made")
        XCTAssertFalse(sink.all.contains { String(describing: $0).contains(syntheticCanary) })
        source.close()
        await server.stop()
        await session.shutdown()
    }

    func testFractionalIDDoesNotLeakTheOnlySlot() async throws {
        let connector = BlockingConnector()
        let session = BrokerSession(connector: connector, displayName: { nil }, stderr: { _ in }, pairingWait: .seconds(2))
        let source = PushSource()
        let sink = MessageSink()
        let transport = BoundedStdioTransport(
            maxInFlightRequests: 1,
            maxPendingRefusals: 2_000,
            readChunk: { source.next() },
            writeSink: { try sink.write($0) }
        )
        let server = await MCPServerFactory.make(session: session, admission: transport.admission)
        try await server.start(transport: transport)
        source.push("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"clientInfo\":{\"name\":\"\(syntheticClientName)\",\"version\":\"1\"}}}")
        let initialized = await waitUntil { sink.response(id: 1) != nil }
        XCTAssertTrue(initialized)
        let freed = await waitUntil { transport.admission.inFlightCount == 0 }
        XCTAssertTrue(freed)
        source.push("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}")

        source.push("{\"jsonrpc\":\"2.0\",\"id\":1.5,\"method\":\"tools/call\",\"params\":{\"name\":\"get_shared_clip\",\"arguments\":{\"id\":\"clip-1\"}}}")
        let refused = await waitUntil { sink.all.contains { errorCode($0) == -32600 } }
        XCTAssertTrue(refused)
        XCTAssertEqual(transport.admission.inFlightCount, 0, "a refused id never holds a slot")
        source.push(toolCall(2, "get_shared_clip", "{\"id\":\"clip-1\"}"))
        let answered = await waitUntil(10) { sink.response(id: 2) != nil }
        XCTAssertTrue(answered, "the valid call is admitted and answered")
        XCTAssertEqual(sink.busyCount, 0)
        let released = await waitUntil { transport.admission.inFlightCount == 0 }
        XCTAssertTrue(released)
        source.close()
        await server.stop()
        await session.shutdown()
    }

    func testCancellationIDsAreKeyedExactlyAsTheSDKDecodesThem() async throws {
        let source = PushSource()
        let sink = MessageSink()
        let (_, forwarded) = makeTransport(source: source) { try sink.write($0) }
        var expectedForwarded = 0
        for raw in ["1.0", "1e0", "1.5", "true", "null", "9223372036854775808", "1"] {
            let sdkDecodes = (try? JSONDecoder().decode(MCP.ID.self, from: Data(raw.utf8))) != nil
            let exact = (raw == "1")
            source.push(cancel(raw))
            // An id the SDK would honour but admission cannot key exactly is dropped; ids the SDK
            // ignores are harmless and may pass.
            if exact || !sdkDecodes || raw == "null" { expectedForwarded += 1 }
            let settled = await waitUntil { forwarded.lines.count == expectedForwarded }
            XCTAssertTrue(settled, "cancellation of \(raw): forwarded \(forwarded.lines.count), expected \(expectedForwarded)")
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertEqual(forwarded.lines.count, expectedForwarded, "cancellation of \(raw)")
        }
        source.close()
    }

    // MARK: finding 1: client-supplied tickets never survive

    func testUnadmittedToolCallNeverCarriesAClientTicketIntoTheSDK() async throws {
        let source = PushSource()
        let sink = MessageSink()
        let (transport, forwarded) = makeTransport(source: source) { try sink.write($0) }
        let key = RequestTicketInjection.metaKey
        // Notification form (no id): forwarded, but without the forged ticket.
        source.push("{\"jsonrpc\":\"2.0\",\"method\":\"tools/call\",\"params\":{\"name\":\"sync_status\",\"_meta\":{\"\(key)\":\"1/n:1\",\"progressToken\":3}}}")
        let forwardedOnce = await waitUntil { forwarded.lines.count == 1 }
        XCTAssertTrue(forwardedOnce)
        let line = try XCTUnwrap(forwarded.lines.first)
        XCTAssertNil(ticket(in: line))
        XCTAssertFalse(line.contains(key))
        XCTAssertTrue(line.contains("progressToken"), "everything else is preserved")
        // Admitted form whose _meta cannot be rewritten is refused, never forwarded.
        source.push("{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"tools/call\",\"params\":{\"name\":\"sync_status\",\"_meta\":\"\(key)\"}}")
        let refused = await waitUntil { sink.all.count == 1 }
        XCTAssertTrue(refused)
        XCTAssertEqual(sink.all.compactMap(errorCode), [-32600])
        XCTAssertEqual(forwarded.lines.count, 1)
        let held = await transport.inFlightRequestCount
        XCTAssertEqual(held, 0)
        source.close()
    }

    func testStripLeavesLinesWithoutATicketUntouched() throws {
        let line = Data(toolCall(5, "sync_status").utf8)
        XCTAssertEqual(RequestTicketInjection.strip(from: line), line)
        let forged = Data("{\"jsonrpc\":\"2.0\",\"method\":\"tools/call\",\"params\":{\"name\":\"x\",\"_meta\":{\"\(RequestTicketInjection.metaKey)\":\"1/n:1\"}}}".utf8)
        let cleaned = try XCTUnwrap(RequestTicketInjection.strip(from: forged))
        XCTAssertFalse(String(decoding: cleaned, as: UTF8.self).contains(RequestTicketInjection.metaKey))
    }

    // MARK: finding 3: a response write only ever retires its own generation

    /// Fail-closed id-reuse policy: an id cancelled before its response was sent is never
    /// admitted again in this session, so a late response can never be credited to a new
    /// request. A fresh id is admitted normally.
    func testIDCancelledBeforeResponseIsNeverReusedAndOldWriteFreesNothing() async throws {
        let source = PushSource()
        let sink = EnteredGateSink(gatedID: 7)
        let (transport, forwarded) = makeTransport(cap: 2, source: source) { try sink.write($0) }
        source.push("{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"ping\"}")
        let pinged = await waitUntil { forwarded.lines.count == 1 }
        XCTAssertTrue(pinged)
        // The ping response is inside the (blocked) sink.
        let writing = Task { try await transport.send(Data("{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{}}".utf8)) }
        let entered = await waitUntil { sink.entered }
        XCTAssertTrue(entered)

        source.push(cancel("7"))
        let cancelled = await waitUntil { transport.admission.inFlightCount == 0 }
        XCTAssertTrue(cancelled, "the cancelled ping released its slot")
        source.push(toolCall(7, "sync_status"))
        source.push(toolCall(8, "sync_status"))
        let fresh = await waitUntil { forwarded.lines.contains { $0.contains("\"id\":8") } }
        XCTAssertTrue(fresh, "a fresh id is admitted")
        XCTAssertFalse(forwarded.lines.contains { $0.contains("\"method\":\"tools/call\"") && $0.contains("\"id\":7") },
                       "the reused id 7 is refused, never forwarded")
        XCTAssertEqual(transport.admission.inFlightCount, 1)
        let newTicket = try XCTUnwrap(ticket(in: try XCTUnwrap(forwarded.lines.last)))
        let parsed = try XCTUnwrap(RequestAdmission.parse(ticket: newTicket))

        sink.release()
        try await writing.value
        XCTAssertEqual(transport.admission.inFlightCount, 1, "the old response write frees nothing")
        XCTAssertTrue(
            transport.admission.handlerStarted(parsed.key, generation: parsed.generation),
            "the new handler runs normally"
        )
        transport.admission.handlerReturned(parsed.key, generation: parsed.generation)
        try await transport.send(Data("{\"jsonrpc\":\"2.0\",\"id\":8,\"result\":{}}".utf8))
        XCTAssertEqual(transport.admission.inFlightCount, 0, "its own response write frees it")
        source.close()
    }

    func testFinishRetiresOnlyTheGenerationItWasCapturedFor() {
        let admission = RequestAdmission(maxInFlight: 2, maxPendingOutbound: 10)
        XCTAssertEqual(admission.admit("n:7"), .admit)
        let current = try? XCTUnwrap(admission.generation(of: "n:7"))
        admission.finish("n:7", generation: (current ?? 0) &+ 999)
        XCTAssertEqual(admission.inFlightCount, 1, "a stale generation frees nothing")
        admission.finish("n:7", generation: current)
        XCTAssertEqual(admission.inFlightCount, 0)
        // Cancelled before any response: the id is never admitted again (fail closed).
        XCTAssertEqual(admission.admit("n:9"), .admit)
        admission.markCancelled("n:9")
        XCTAssertEqual(admission.admit("n:9", isToolCall: true), .duplicate)
    }

    // MARK: cancelled while the handler runs: quarantine, never re-admit

    private func startedToolCall(_ admission: RequestAdmission, _ key: String, file: StaticString = #filePath, line: UInt = #line) -> UInt64? {
        guard admission.admit(key, isToolCall: true) == .admit,
              let generation = admission.generation(of: key),
              admission.handlerStarted(key, generation: generation)
        else {
            XCTFail("could not admit and start \(key)", file: file, line: line)
            return nil
        }
        return generation
    }

    /// Finding 2 (R): an id cancelled while its handler runs keeps its slot until the handler
    /// exits and is then quarantined, so it can never be admitted again.
    func testIDCancelledWhileHandlerRunsHoldsSlotThenIsQuarantinedOnRetire() throws {
        let admission = RequestAdmission(maxInFlight: 2, maxPendingOutbound: 10)
        let generation = try XCTUnwrap(startedToolCall(admission, "n:5"))
        admission.markCancelled("n:5")
        XCTAssertEqual(admission.inFlightCount, 1, "the running handler keeps its slot")
        XCTAssertEqual(admission.admit("n:6"), .admit)
        XCTAssertEqual(admission.admit("n:7"), .busy, "the cancelled-but-running handler still holds capacity")
        XCTAssertEqual(admission.admit("n:5", isToolCall: true), .duplicate, "not re-admitted while running")

        admission.retire("n:5", generation: generation &+ 999)
        XCTAssertEqual(admission.inFlightCount, 2, "a stale generation frees nothing")
        admission.retire("n:5", generation: generation)
        XCTAssertEqual(admission.inFlightCount, 1, "the handler exit frees the slot")

        XCTAssertEqual(admission.admit("n:5", isToolCall: true), .duplicate, "a cancelled id is never admitted again")
        XCTAssertFalse(admission.handlerStarted("n:5", generation: generation))
        XCTAssertEqual(admission.admit("n:8"), .admit, "a fresh id still uses the freed slot")
    }

    /// Finding 2 (R): the same quarantine applies when the cancelled handler returns a result
    /// and the response write frees the slot.
    func testIDCancelledWhileHandlerRunsIsQuarantinedAfterItsResponseIsWritten() throws {
        let admission = RequestAdmission(maxInFlight: 2, maxPendingOutbound: 10)
        let generation = try XCTUnwrap(startedToolCall(admission, "n:5"))
        admission.markCancelled("n:5")
        admission.handlerReturned("n:5", generation: generation)
        XCTAssertEqual(admission.inFlightCount, 1, "the slot is held until the response is written")
        admission.finish("n:5", generation: generation)
        XCTAssertEqual(admission.inFlightCount, 0)
        XCTAssertEqual(admission.admit("n:5", isToolCall: true), .duplicate, "a cancelled id is never admitted again")
    }

    /// Finding 2 (R): a cancellation that arrives after the handler returned (response pending)
    /// quarantines the id too, and keeps the slot until the response is written.
    func testIDCancelledWhileResponseIsPendingIsQuarantinedAfterItsResponseIsWritten() throws {
        let admission = RequestAdmission(maxInFlight: 2, maxPendingOutbound: 10)
        let generation = try XCTUnwrap(startedToolCall(admission, "n:5"))
        admission.handlerReturned("n:5", generation: generation)
        admission.markCancelled("n:5")
        XCTAssertEqual(admission.inFlightCount, 1, "the pending response still holds its slot")
        admission.finish("n:5", generation: generation)
        XCTAssertEqual(admission.inFlightCount, 0)
        XCTAssertEqual(admission.admit("n:5", isToolCall: true), .duplicate, "a cancelled id is never admitted again")
    }

    /// Finding 2 control (C): without a cancellation an id is reusable after its response, and
    /// the generic `retire` (an unforwarded, refused tools/call) does not quarantine.
    func testUncancelledIDsRemainReusableAfterFinishAndGenericRetire() throws {
        let admission = RequestAdmission(maxInFlight: 2, maxPendingOutbound: 10)
        let generation = try XCTUnwrap(startedToolCall(admission, "n:5"))
        admission.handlerReturned("n:5", generation: generation)
        admission.finish("n:5", generation: generation)
        XCTAssertEqual(admission.inFlightCount, 0)
        XCTAssertEqual(admission.admit("n:5", isToolCall: true), .admit, "ordinary id reuse is retained")
        XCTAssertEqual(admission.admit("n:6", isToolCall: true), .admit)
        admission.retire("n:6")
        XCTAssertEqual(admission.admit("n:6", isToolCall: true), .admit, "generic retire does not quarantine")
    }

    /// Finding 2 control (C, integration): a `tools/call` whose `_meta` cannot carry a ticket is
    /// refused without being forwarded, and the same id is then admitted normally.
    func testRefusedMalformedMetaToolCallDoesNotQuarantineItsID() async throws {
        let source = PushSource()
        let sink = MessageSink()
        let (transport, forwarded) = makeTransport(source: source) { try sink.write($0) }
        source.push("{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"tools/call\",\"params\":{\"name\":\"sync_status\",\"_meta\":5}}")
        let refused = await waitUntil { sink.all.count == 1 }
        XCTAssertTrue(refused)
        XCTAssertEqual(sink.all.compactMap(errorCode), [-32600])
        XCTAssertEqual(forwarded.lines.count, 0, "the malformed call is not forwarded")
        let held = await transport.inFlightRequestCount
        XCTAssertEqual(held, 0)

        source.push(toolCall(9, "sync_status"))
        let admitted = await waitUntil { forwardedToolCallIDs(forwarded.lines) == [9] }
        XCTAssertTrue(admitted, "the same id is admitted and forwarded afterwards")
        XCTAssertNotNil(forwarded.lines.first.flatMap { ticket(in: $0) }, "the forwarded call carries a ticket")
        XCTAssertEqual(sink.all.count, 1, "no second refusal")
        source.close()
    }

    /// Finding 2 (R): every id cancelled while its handler ran is quarantined, and quarantined
    /// ids count toward the bounded capacity, after which admission is exhausted.
    func testQuarantinedHandlerCancellationsCountTowardTheCapacity() {
        let admission = RequestAdmission(maxInFlight: 2, maxPendingOutbound: 10)
        for index in 0..<RequestAdmission.maxCancelledUnanswered {
            let key = "n:\(index)"
            guard let generation = startedToolCall(admission, key) else { return }
            admission.markCancelled(key)
            admission.retire(key, generation: generation)
        }
        XCTAssertEqual(admission.inFlightCount, 0)
        XCTAssertEqual(admission.admit("n:fresh", isToolCall: true), .exhausted)
        XCTAssertEqual(admission.admit("n:0", isToolCall: true), .exhausted)
    }

    /// Finding 2 (R, integration): a request id cancelled while its handler ran and then retired
    /// is refused as a duplicate and never forwarded again; a fresh id is forwarded.
    func testIDCancelledWhileHandlerRunsIsRefusedAsDuplicateThroughTransport() async throws {
        let source = PushSource()
        let sink = MessageSink()
        let (transport, forwarded) = makeTransport(source: source) { try sink.write($0) }
        defer { source.close() }
        source.push(toolCall(10, "sync_status"))
        let first = await waitUntil { forwardedToolCallIDs(forwarded.lines) == [10] }
        XCTAssertTrue(first)
        let heldTicket = try XCTUnwrap(forwarded.lines.first.flatMap { ticket(in: $0) })
        let parsed = try XCTUnwrap(RequestAdmission.parse(ticket: heldTicket))
        XCTAssertTrue(transport.admission.handlerStarted(parsed.key, generation: parsed.generation))

        source.push(cancel("10"))
        // The cancellation is forwarded only after the reader applied markCancelled.
        let cancelForwarded = await waitUntil { forwarded.lines.count == 2 }
        XCTAssertTrue(cancelForwarded, "the cancellation notification is forwarded")
        transport.admission.retire(parsed.key, generation: parsed.generation)

        source.push(toolCall(10, "sync_status"))
        source.push(toolCall(11, "sync_status"))
        let freshForwarded = await waitUntil { forwardedToolCallIDs(forwarded.lines).contains(11) }
        XCTAssertTrue(freshForwarded, "a fresh id is forwarded")
        let refused = await waitUntil { sink.all.contains { ($0["id"] as? Int) == 10 } }
        XCTAssertTrue(refused, "the reused id 10 is refused")
        if let refusal = sink.all.first(where: { ($0["id"] as? Int) == 10 }) {
            XCTAssertEqual(errorCode(refusal), -32600)
            XCTAssertEqual((refusal["error"] as? [String: Any])?["message"] as? String, "Duplicate request id.")
        }
        XCTAssertEqual(forwardedToolCallIDs(forwarded.lines).filter { $0 == 10 }.count, 1, "id 10 is never forwarded a second time")
    }
}
