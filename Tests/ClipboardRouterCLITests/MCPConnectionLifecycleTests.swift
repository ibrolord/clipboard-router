import ClipboardRouterAgentAccess
import Dispatch
import Foundation
import XCTest
@testable import ClipboardRouterCLI

private func currentQueueLabel() -> String {
    String(cString: __dispatch_queue_get_label(nil))
}

/// Records the ordering, queue and overlap of hello/call/interrupt/close. A vault call blocks
/// until interrupted and, when `holdExit`, then stays running until the test lets it exit, so
/// a close arriving before that is provably concurrent with the call.
final class LifecycleConnection: AgentBrokerConnection, @unchecked Sendable {
    struct Event: Equatable {
        var name: String
        var queue: String
    }

    private let lock = NSLock()
    private let wake = DispatchSemaphore(value: 0)
    private let exitGate = DispatchSemaphore(value: 0)
    private let holdExit: Bool
    private var interrupted = false
    private var inCall = false
    private var _events: [Event] = []
    private var _closedWhileCallRunning = false

    init(holdExit: Bool) { self.holdExit = holdExit }

    var events: [Event] { lock.withLock { _events } }
    var names: [String] { events.map(\.name) }
    var closedWhileCallRunning: Bool { lock.withLock { _closedWhileCallRunning } }
    func count(_ name: String) -> Int { names.filter { $0 == name }.count }
    func letCallExit() { exitGate.signal() }

    private func record(_ name: String) { lock.withLock { _events.append(Event(name: name, queue: currentQueueLabel())) } }

    func hello(displayName: String?) throws -> AgentBrokerHello {
        AgentBrokerHello(sessionID: "lifecycle-session", pairingCode: "424242", state: .pendingApproval)
    }

    func call(sessionID: String, requestID: UInt32, _ operation: BrokerOperation) throws -> BrokerResponse {
        guard case .requestVaultItem = operation else {
            return BrokerResponse(requestID: requestID, result: .sessionState(.approved))
        }
        lock.withLock {
            inCall = true
            _events.append(Event(name: "call-enter", queue: currentQueueLabel()))
        }
        wake.wait()
        record("call-woken")
        if holdExit { exitGate.wait() }
        lock.withLock {
            inCall = false
            _events.append(Event(name: "call-exit", queue: currentQueueLabel()))
        }
        throw LocalIPCError.peerClosed
    }

    func interrupt() {
        lock.withLock {
            _events.append(Event(name: "interrupt", queue: currentQueueLabel()))
            interrupted = true
        }
        wake.signal()
    }

    func close() {
        lock.withLock {
            if inCall { _closedWhileCallRunning = true }
            _events.append(Event(name: "close", queue: currentQueueLabel()))
        }
    }
}

final class LifecycleConnector: AgentBrokerConnector, @unchecked Sendable {
    private let lock = NSLock()
    private var _made: [LifecycleConnection] = []
    var made: [LifecycleConnection] { lock.withLock { _made } }

    /// Only the first connection holds its blocked call open after the interrupt.
    func connect() throws -> any AgentBrokerConnection {
        lock.withLock {
            let connection = LifecycleConnection(holdExit: _made.isEmpty)
            _made.append(connection)
            return connection
        }
    }
}

final class MCPConnectionLifecycleTests: XCTestCase {
    private func approvedSession(_ connector: LifecycleConnector) async -> BrokerSession {
        let session = BrokerSession(connector: connector, displayName: { nil }, stderr: { _ in }, pairingWait: .seconds(2))
        _ = await session.perform(.syncStatus)
        return session
    }

    private func startBlockedVault(_ session: BrokerSession, _ connection: LifecycleConnection) async -> Task<BrokerCallOutcome, Never> {
        let task = Task { await session.perform(.requestVaultItem(purpose: syntheticPurpose)) }
        let entered = await waitUntil { connection.count("call-enter") == 1 }
        XCTAssertTrue(entered)
        return task
    }

    func testCancelledInFlightCallInterruptsAtOnceAndClosesOnlyAfterTheCallReturned() async throws {
        let connector = LifecycleConnector()
        let session = await approvedSession(connector)
        let old = try XCTUnwrap(connector.made.first)
        let task = await startBlockedVault(session, old)

        task.cancel()
        let outcome = await task.value
        XCTAssertEqual(outcome, .cancelled)

        // Interrupted immediately, from the cancelling context; the blocked call has woken
        // but is still running, so the descriptor must still be open.
        XCTAssertGreaterThanOrEqual(old.count("interrupt"), 1)
        let woken = await waitUntil { old.count("call-woken") == 1 }
        XCTAssertTrue(woken)
        XCTAssertEqual(old.count("close"), 0, "no close while the call is still running")

        // A reconnect issued right after the cancellation must not close anything on the
        // old link (nor the new one), while the old call is still running.
        _ = await session.perform(.syncStatus)
        XCTAssertEqual(connector.made.count, 2)
        let fresh = connector.made[1]
        XCTAssertEqual(old.count("close"), 0, "the old descriptor stays open across the reconnect")
        XCTAssertEqual(fresh.count("close"), 0, "the new connection is never closed by the old link's teardown")
        XCTAssertEqual(old.count("call-exit"), 0)

        old.letCallExit()
        let closed = await waitUntil { old.count("close") == 1 }
        XCTAssertTrue(closed)
        let names = old.names
        let callExit = try XCTUnwrap(names.firstIndex(of: "call-exit"))
        let close = try XCTUnwrap(names.firstIndex(of: "close"))
        let interrupt = try XCTUnwrap(names.firstIndex(of: "interrupt"))
        XCTAssertLessThan(interrupt, callExit, "interrupt precedes the call's exit")
        XCTAssertLessThan(callExit, close, "close is strictly after the blocked call returned")
        XCTAssertFalse(old.closedWhileCallRunning, "close is never concurrent with the call")
        let events = old.events
        XCTAssertEqual(events[close].queue, events[names.firstIndex(of: "call-enter")!].queue, "close runs on the link's own I/O queue")
        XCTAssertTrue(events[close].queue.hasPrefix("cr.mcp.broker."))
        XCTAssertEqual(old.count("close"), 1)
        XCTAssertEqual(fresh.count("close"), 0)
        await session.shutdown()
    }

    func testShutdownDuringInFlightCallInterruptsAtOnceAndClosesAfterTheCallReturned() async throws {
        let connector = LifecycleConnector()
        let session = await approvedSession(connector)
        let connection = try XCTUnwrap(connector.made.first)
        let task = await startBlockedVault(session, connection)

        await session.shutdown()
        let outcome = await task.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertGreaterThanOrEqual(connection.count("interrupt"), 1)
        let woken = await waitUntil { connection.count("call-woken") == 1 }
        XCTAssertTrue(woken)
        XCTAssertEqual(connection.count("close"), 0, "shutdown never frees the descriptor under a running call")

        connection.letCallExit()
        let closed = await waitUntil { connection.count("close") == 1 }
        XCTAssertTrue(closed)
        let names = connection.names
        XCTAssertLessThan(try XCTUnwrap(names.firstIndex(of: "call-exit")), try XCTUnwrap(names.firstIndex(of: "close")))
        XCTAssertFalse(connection.closedWhileCallRunning)
    }
}
