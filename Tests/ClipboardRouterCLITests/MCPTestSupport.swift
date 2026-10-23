import ClipboardRouterAgentAccess
import Foundation
import MCP
import XCTest
@testable import ClipboardRouterCLI

let syntheticCanary = "CR-SYNTHETIC-CANARY-7f3a"
let syntheticTitle = "CR-SYNTHETIC-TITLE-91bc"
let syntheticPurpose = "CR-SYNTHETIC-PURPOSE-5d2e"
let syntheticClientName = "CR-SYNTHETIC-CLIENT-22aa"

final class LineSink: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ line: String) { lock.withLock { storage.append(line) } }
    var lines: [String] { lock.withLock { storage } }
}

final class DataSink: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Data] = []
    private var failOnWrite: Int?

    init(failOnWrite: Int? = nil) { self.failOnWrite = failOnWrite }

    func write(_ data: Data) throws {
        try lock.withLock {
            storage.append(data)
            if let failOnWrite, storage.count >= failOnWrite { throw BoundedTransportError.writeFailed }
        }
    }

    var writes: [Data] { lock.withLock { storage } }
}

final class ChunkSource: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [Data]

    init(_ chunks: [Data]) { self.chunks = chunks }

    func next() -> Data? {
        lock.withLock { chunks.isEmpty ? nil : chunks.removeFirst() }
    }
}

final class ScriptedConnection: AgentBrokerConnection, @unchecked Sendable {
    struct Call: Equatable {
        var requestID: UInt32
        var operation: BrokerOperation
    }

    typealias Handler = @Sendable (BrokerOperation) -> Result<BrokerResult, Error>

    let code: String
    private let handler: Handler
    private let pairingError: Error?
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var decision: SessionState?
    private var recordedCalls: [Call] = []
    private var recordedNames: [String?] = []
    private var closes = 0

    init(code: String, pairingError: Error? = nil, handler: @escaping Handler) {
        self.code = code
        self.pairingError = pairingError
        self.handler = handler
    }

    var calls: [Call] { lock.withLock { recordedCalls } }
    var helloNames: [String?] { lock.withLock { recordedNames } }
    var closeCount: Int { lock.withLock { closes } }

    func decide(_ state: SessionState) {
        lock.withLock { if decision == nil { decision = state } }
        gate.signal()
    }

    func hello(displayName: String?) throws -> AgentBrokerHello {
        lock.withLock { recordedNames.append(displayName) }
        return AgentBrokerHello(sessionID: "session-\(code)", pairingCode: code, state: .pendingApproval)
    }

    func call(sessionID: String, requestID: UInt32, _ operation: BrokerOperation) throws -> BrokerResponse {
        lock.withLock { recordedCalls.append(Call(requestID: requestID, operation: operation)) }
        if case .awaitPairing = operation {
            if let pairingError { throw pairingError }
            gate.wait()
            let state = lock.withLock { decision ?? .revoked }
            return BrokerResponse(requestID: requestID, result: .sessionState(state))
        }
        switch handler(operation) {
        case let .success(result): return BrokerResponse(requestID: requestID, result: result)
        case let .failure(error): throw error
        }
    }

    /// Wakes a blocked `awaitPairing` without counting as a close (close is queued behind it).
    func interrupt() { decide(.revoked) }

    func close() {
        lock.withLock { closes += 1 }
        decide(.revoked)
    }
}

final class FakeConnector: AgentBrokerConnector, @unchecked Sendable {
    private let lock = NSLock()
    private let codes: [String]
    private let autoApprove: Bool
    private let pairingError: Error?
    private let handler: ScriptedConnection.Handler
    private var connections: [ScriptedConnection] = []
    var connectError: Error?

    init(
        codes: [String] = ["123456", "654321", "246810"],
        autoApprove: Bool = false,
        pairingError: Error? = nil,
        handler: @escaping ScriptedConnection.Handler = FakeConnector.defaultHandler
    ) {
        self.codes = codes
        self.autoApprove = autoApprove
        self.pairingError = pairingError
        self.handler = handler
    }

    static let defaultHandler: ScriptedConnection.Handler = { operation in
        switch operation {
        case let .listSharedClips(limit):
            return .success(.sharedClips(
                [SharedClipSummary(
                    id: "clip-1",
                    title: syntheticTitle,
                    kind: .text,
                    byteCount: syntheticCanary.utf8.count,
                    modifiedAtEpochSeconds: 1_700_000_000
                )].prefix(limit).map { $0 }
            ))
        case let .getSharedClip(id):
            return id == "clip-1"
                ? .success(.sharedClip(SharedClipContent(id: id, kind: .text, text: syntheticCanary)))
                : .success(.failure(.notFound))
        case .requestVaultItem:
            return .success(.vaultItem(VaultHandoff(kind: .text, text: syntheticCanary)))
        case .syncStatus:
            return .success(.syncStatus(SyncStatusReport(
                snapshotReady: true, sync: .idle, lastProjection: .applied, lastProjectionAtEpochSeconds: 1_700_000_000
            )))
        case .awaitPairing:
            return .success(.sessionState(.approved))
        }
    }

    var made: [ScriptedConnection] { lock.withLock { connections } }

    func connect() throws -> any AgentBrokerConnection {
        try lock.withLock {
            if let connectError { throw connectError }
            let code = codes[min(connections.count, codes.count - 1)]
            let connection = ScriptedConnection(code: code, pairingError: pairingError, handler: handler)
            if autoApprove { connection.decide(.approved) }
            connections.append(connection)
            return connection
        }
    }
}

struct MCPHarness {
    let client: Client
    let server: Server
    let session: BrokerSession
    let connector: FakeConnector
    let stderr: LineSink

    func finish() async {
        await client.disconnect()
        await server.stop()
        await session.shutdown()
        for connection in connector.made { connection.decide(.revoked) }
    }

    func call(_ name: String, _ arguments: [String: Value]? = nil) async throws -> (texts: [String], isError: Bool) {
        let result = try await client.callTool(name: name, arguments: arguments)
        return (result.content.compactMap(textOf), result.isError ?? false)
    }
}

func textOf(_ content: Tool.Content) -> String? {
    if case let .text(text, _, _) = content { return text }
    return nil
}

func makeHarness(
    connector: FakeConnector,
    pairingWait: Duration = .milliseconds(200)
) async throws -> MCPHarness {
    let names = MCPClientNameBox()
    let stderr = LineSink()
    let session = BrokerSession(
        connector: connector,
        displayName: { names.current },
        stderr: { stderr.append($0) },
        pairingWait: pairingWait
    )
    let server = await MCPServerFactory.make(session: session)
    let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
    try await server.start(transport: serverTransport) { info, _ in names.set(info.name) }
    let client = Client(name: syntheticClientName, version: "1")
    _ = try await client.connect(transport: clientTransport)
    return MCPHarness(client: client, server: server, session: session, connector: connector, stderr: stderr)
}
