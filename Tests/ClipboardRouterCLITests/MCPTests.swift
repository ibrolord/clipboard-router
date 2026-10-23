import ClipboardRouterAgentAccess
import Foundation
import MCP
import XCTest
@testable import ClipboardRouterCLI

final class MCPParsingTests: XCTestCase {
    func testMCPAcceptsNoArguments() throws {
        XCTAssertEqual(try CLIArgumentParser.parse(["mcp"]), .mcp)
        for extra in [["mcp", "x"], ["mcp", "--socket", "/tmp/s"], ["mcp", "--requirement", "anchor apple"], ["mcp", "--team", "ABCDE12345"]] {
            XCTAssertThrowsError(try CLIArgumentParser.parse(extra)) { error in
                XCTAssertEqual(error as? CLIError, .unexpectedArguments)
            }
        }
    }

    func testHelpDescribesMCPWithoutExtraClaims() {
        let usage = CLIArgumentParser.usage
        XCTAssertTrue(usage.contains("cr mcp"))
        XCTAssertTrue(usage.contains("connects an MCP client to the running Clipboard Router app (direct-download build)"))
        XCTAssertTrue(usage.contains("Agent Access"))
        XCTAssertTrue(usage.contains("approved in the app"))
        XCTAssertFalse(usage.contains("2025"))
        XCTAssertFalse(usage.localizedCaseInsensitiveContains("App Store"))
    }

    func testExistingCommandsStillParse() throws {
        XCTAssertEqual(try CLIArgumentParser.parse(["help"]), .help)
        XCTAssertEqual(try CLIArgumentParser.parse(["version"]), .version)
    }
}

final class MCPCommandTests: XCTestCase {
    func testGateFailureExits69WithReasonCodeOnly() async {
        let stderr = LineSink()
        let stdout = DataSink()
        let read = ReadFlag()
        let environment = MCPEnvironment(
            resolve: { throw AgentAccessIdentityError.unsignedOrAdHoc },
            readChunk: { read.mark(); return nil },
            writeStdout: { try stdout.write($0) },
            writeStderrLine: { stderr.append($0) }
        )
        let code = await MCPCommand.run(environment)
        XCTAssertEqual(code, 69)
        XCTAssertEqual(stderr.lines, ["cr mcp: unavailable (unsigned_or_ad_hoc_build)"])
        XCTAssertTrue(stdout.writes.isEmpty)
        XCTAssertFalse(read.value, "must not read MCP input after a failed gate")
    }

    func testGateFailureWithUnknownErrorStaysContentFree() async {
        struct Boom: Error, CustomStringConvertible { var description: String { syntheticCanary } }
        let stderr = LineSink()
        let environment = MCPEnvironment(
            resolve: { throw Boom() },
            readChunk: { nil },
            writeStdout: { _ in },
            writeStderrLine: { stderr.append($0) }
        )
        let code = await MCPCommand.run(environment)
        XCTAssertEqual(code, 69)
        XCTAssertEqual(stderr.lines, ["cr mcp: unavailable (unexpected_error)"])
    }

    func testFullStdioSessionKeepsStdoutProtocolOnlyAndStderrContentFree() async throws {
        let connector = FakeConnector(autoApprove: true)
        let stderr = LineSink()
        let stdout = DataSink()
        let expectedResponses = 5  // initialize + 4 tool calls
        let done = DispatchSemaphore(value: 0)
        let counter = CountingSink(target: expectedResponses, done: done)
        let requests: [String] = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"\#(syntheticClientName)","version":"1"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_shared_clips","arguments":{}}}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_shared_clip","arguments":{"id":"clip-1"}}}"#,
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"request_vault_item","arguments":{"purpose":"\#(syntheticPurpose)"}}}"#,
            #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"sync_status","arguments":{}}}"#,
        ]
        let source = ChunkSource(requests.map { Data(($0 + "\n").utf8) })
        let environment = MCPEnvironment(
            resolve: { connector },
            readChunk: {
                if let chunk = source.next() { return chunk }
                // Hold EOF until every response was written, like a client waiting for answers.
                _ = done.wait(timeout: .now() + 10)
                return nil
            },
            writeStdout: { data in
                try stdout.write(data)
                counter.hit()
            },
            writeStderrLine: { stderr.append($0) },
            pairingWait: .seconds(5)
        )
        let code = await MCPCommand.run(environment)
        XCTAssertEqual(code, 0)

        let output = stdout.writes
        XCTAssertEqual(output.count, expectedResponses)
        for message in output {
            XCTAssertEqual(message.last, 0x0A)
            XCTAssertEqual(message.filter { $0 == 0x0A }.count, 1, "exactly one newline per message")
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: message.dropLast()))
        }
        let joined = output.compactMap { String(data: $0, encoding: .utf8) }.joined()
        XCTAssertTrue(joined.contains(syntheticCanary), "the clip text is delivered on stdout")

        let errText = stderr.lines.joined(separator: "\n")
        XCTAssertEqual(stderr.lines, ["cr mcp: approve pairing code 123456 in Clipboard Router"])
        for forbidden in [syntheticCanary, syntheticTitle, syntheticPurpose, syntheticClientName, "clip-1"] {
            XCTAssertFalse(errText.contains(forbidden))
        }
        XCTAssertEqual(connector.made.first?.helloNames, [syntheticClientName])
    }
}

private final class ReadFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func mark() { lock.withLock { flag = true } }
    var value: Bool { lock.withLock { flag } }
}

private final class CountingSink: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let target: Int
    private let done: DispatchSemaphore
    init(target: Int, done: DispatchSemaphore) { self.target = target; self.done = done }
    func hit() {
        let reached = lock.withLock { () -> Bool in count += 1; return count == target }
        if reached { done.signal() }
    }
}

final class MCPToolTests: XCTestCase {
    func testCatalogIsStaticExactAndIdenticalBeforeAndAfterPairing() async throws {
        let connector = FakeConnector(autoApprove: true)
        let harness = try await makeHarness(connector: connector, pairingWait: .seconds(5))
        let before = try await harness.client.listTools().tools
        XCTAssertTrue(connector.made.isEmpty, "tools/list must not connect to the app")

        XCTAssertEqual(
            before.map(\.name),
            ["list_shared_clips", "get_shared_clip", "request_vault_item", "sync_status"]
        )
        XCTAssertTrue(before.allSatisfy { $0.annotations.readOnlyHint == true })
        let schemas = Dictionary(uniqueKeysWithValues: before.map { ($0.name, $0.inputSchema) })
        XCTAssertEqual(schemas["get_shared_clip"]?.objectValue?["required"], ["id"])
        XCTAssertEqual(schemas["request_vault_item"]?.objectValue?["required"], ["purpose"])
        XCTAssertEqual(schemas["list_shared_clips"]?.objectValue?["required"], nil)
        XCTAssertEqual(
            schemas["list_shared_clips"]?.objectValue?["properties"]?.objectValue?["limit"]?.objectValue?["maximum"],
            100
        )
        XCTAssertEqual(
            schemas["request_vault_item"]?.objectValue?["properties"]?.objectValue?["purpose"]?.objectValue?["maxLength"],
            280
        )
        let vault = before.first { $0.name == "request_vault_item" }
        XCTAssertTrue(vault?.description?.contains("user picks") == true || vault?.description?.contains("The user picks") == true)
        XCTAssertTrue(vault?.description?.contains("approve") == true)
        let sync = before.first { $0.name == "sync_status" }
        XCTAssertTrue(sync?.description?.contains("not a freshness guarantee") == true)

        _ = try await harness.call("list_shared_clips")
        let after = try await harness.client.listTools().tools
        XCTAssertEqual(before, after)
        let encoded = String(data: try JSONEncoder().encode(after), encoding: .utf8) ?? ""
        for forbidden in [syntheticTitle, syntheticCanary, "clip-1"] {
            XCTAssertFalse(encoded.contains(forbidden))
        }
        await harness.finish()
    }

    func testUnknownToolIsAProtocolError() async throws {
        let harness = try await makeHarness(connector: FakeConnector(autoApprove: true))
        do {
            _ = try await harness.client.callTool(name: "delete_everything")
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error is MCPError)
        }
        await harness.finish()
    }

    func testPrePairingCallReturnsWaitingMessageWithCodeThenSucceedsAfterApproval() async throws {
        let connector = FakeConnector()
        let harness = try await makeHarness(connector: connector)
        XCTAssertTrue(connector.made.isEmpty, "connect lazily")

        let waiting = try await harness.call("list_shared_clips")
        XCTAssertTrue(waiting.isError)
        XCTAssertEqual(waiting.texts, [MCPToolMessages.waiting(code: "123456")])
        XCTAssertEqual(
            waiting.texts.first,
            "Waiting for approval in Clipboard Router (pairing code 123456). Approve it in the app, then try again."
        )
        XCTAssertEqual(harness.stderr.lines, ["cr mcp: approve pairing code 123456 in Clipboard Router"])
        XCTAssertEqual(connector.made.count, 1)
        XCTAssertEqual(connector.made[0].helloNames, [syntheticClientName])

        connector.made[0].decide(.approved)
        let listed = try await harness.call("list_shared_clips", ["limit": 10])
        XCTAssertFalse(listed.isError)
        let rows = try JSONSerialization.jsonObject(with: Data(listed.texts[0].utf8)) as? [[String: Any]]
        XCTAssertEqual(rows?.count, 1)
        XCTAssertEqual(rows?[0]["id"] as? String, "clip-1")
        XCTAssertEqual(rows?[0]["title"] as? String, syntheticTitle)
        XCTAssertEqual(rows?[0]["kind"] as? String, "text")
        XCTAssertEqual(rows?[0]["byteCount"] as? Int, syntheticCanary.utf8.count)
        XCTAssertEqual(rows?[0]["modifiedAt"] as? String, "2023-11-14T22:13:20Z")

        let clip = try await harness.call("get_shared_clip", ["id": "clip-1"])
        XCTAssertFalse(clip.isError)
        XCTAssertEqual(clip.texts.first, syntheticCanary)

        let calls = connector.made[0].calls
        XCTAssertEqual(calls.map(\.requestID), [1, 2, 3])
        XCTAssertEqual(calls[0].operation, .awaitPairing)
        XCTAssertEqual(calls[1].operation, .listSharedClips(limit: 10))
        XCTAssertEqual(calls[2].operation, .getSharedClip(id: "clip-1"))
        XCTAssertEqual(connector.made.count, 1)
        await harness.finish()
    }

    func testNotFoundTextIsIdenticalForEveryID() async throws {
        let harness = try await makeHarness(connector: FakeConnector(autoApprove: true), pairingWait: .seconds(5))
        let first = try await harness.call("get_shared_clip", ["id": "missing-a"])
        let second = try await harness.call("get_shared_clip", ["id": "other-b"])
        XCTAssertTrue(first.isError)
        XCTAssertEqual(first.texts, ["No shared clip with that id is available."])
        XCTAssertEqual(first.texts, second.texts)
        XCTAssertEqual(first.isError, second.isError)
        await harness.finish()
    }

    func testVaultRequestAndSyncStatus() async throws {
        let connector = FakeConnector(autoApprove: true)
        let harness = try await makeHarness(connector: connector, pairingWait: .seconds(5))
        let vault = try await harness.call("request_vault_item", ["purpose": .string(syntheticPurpose)])
        XCTAssertFalse(vault.isError)
        XCTAssertEqual(vault.texts.first, syntheticCanary)
        XCTAssertTrue(connector.made[0].calls.contains { $0.operation == .requestVaultItem(purpose: syntheticPurpose) })

        let status = try await harness.call("sync_status")
        XCTAssertFalse(status.isError)
        let object = try JSONSerialization.jsonObject(with: Data(status.texts[0].utf8)) as? [String: Any]
        XCTAssertEqual(object?["snapshotReady"] as? Bool, true)
        XCTAssertEqual(object?["lastProjection"] as? String, "applied")
        await harness.finish()
    }

    func testInvalidArgumentsAreRejectedWithoutTouchingTheBroker() async throws {
        let connector = FakeConnector(autoApprove: true)
        let harness = try await makeHarness(connector: connector, pairingWait: .seconds(5))
        let tooLong = String(repeating: "x", count: 281)
        for (tool, args) in [
            ("list_shared_clips", ["limit": Value.int(0)]),
            ("list_shared_clips", ["limit": Value.int(101)]),
            ("get_shared_clip", [:]),
            ("get_shared_clip", ["id": Value.string("")]),
            ("request_vault_item", ["purpose": Value.string(tooLong)]),
            ("request_vault_item", [:]),
        ] as [(String, [String: Value])] {
            let result = try await harness.call(tool, args)
            XCTAssertTrue(result.isError)
            XCTAssertEqual(result.texts, [MCPToolMessages.invalidArguments])
        }
        XCTAssertTrue(connector.made.isEmpty)
        await harness.finish()
    }

    func testVaultOutcomesHaveDistinctNeutralMessages() async throws {
        let codes: [BrokerErrorCode] = [.vaultRequestDenied, .vaultRequestExpired, .vaultRequestCancelled, .vaultRequestBusy]
        var seen = Set<String>()
        for code in codes {
            let connector = FakeConnector(autoApprove: true, handler: { _ in .success(.failure(code)) })
            let harness = try await makeHarness(connector: connector, pairingWait: .seconds(5))
            let result = try await harness.call("request_vault_item", ["purpose": "need a token"])
            XCTAssertTrue(result.isError)
            seen.insert(result.texts.joined())
            await harness.finish()
        }
        XCTAssertEqual(seen.count, codes.count)
    }

    func testDeniedPairingReportsNotGrantedThenNextCallReconnectsWithNewCode() async throws {
        let connector = FakeConnector()
        let harness = try await makeHarness(connector: connector)
        _ = try await harness.call("list_shared_clips")
        connector.made[0].decide(.denied)

        let denied = try await harness.call("list_shared_clips")
        XCTAssertTrue(denied.isError)
        XCTAssertEqual(denied.texts, [MCPToolMessages.notGranted])
        XCTAssertEqual(connector.made.count, 1)
        // The close is queued on the link's I/O queue, behind the pairing call.
        let deniedClosed = await waitUntil { connector.made[0].closeCount == 1 }
        XCTAssertTrue(deniedClosed)

        let fresh = try await harness.call("list_shared_clips")
        XCTAssertEqual(fresh.texts, [MCPToolMessages.waiting(code: "654321")])
        XCTAssertEqual(connector.made.count, 2)
        XCTAssertEqual(
            harness.stderr.lines,
            [
                "cr mcp: approve pairing code 123456 in Clipboard Router",
                "cr mcp: approve pairing code 654321 in Clipboard Router",
            ]
        )
        await harness.finish()
    }

    func testAccessDisabledDropsTheConnectionAndNextCallReconnects() async throws {
        let counter = ToggleBox()
        let connector = FakeConnector(autoApprove: true, handler: { _ in
            counter.firstTime() ? .success(.failure(.accessDisabled)) : .success(.sharedClips([]))
        })
        let harness = try await makeHarness(connector: connector, pairingWait: .seconds(5))
        let off = try await harness.call("list_shared_clips")
        XCTAssertTrue(off.isError)
        XCTAssertEqual(off.texts, [MCPToolMessages.accessDisabled])
        let disabledClosed = await waitUntil { connector.made[0].closeCount == 1 }
        XCTAssertTrue(disabledClosed)

        let again = try await harness.call("list_shared_clips")
        XCTAssertFalse(again.isError)
        XCTAssertEqual(connector.made.count, 2)
        await harness.finish()
    }

    func testPeerClosedDropsTheConnectionAndNextCallReconnects() async throws {
        // A pairing call that fails is a lost connection, not a refusal.
        let lostConnector = FakeConnector(pairingError: LocalIPCError.peerClosed)
        let lostHarness = try await makeHarness(connector: lostConnector, pairingWait: .seconds(5))
        let lostPairing = try await lostHarness.call("list_shared_clips")
        XCTAssertTrue(lostPairing.isError)
        XCTAssertEqual(lostPairing.texts, [MCPToolMessages.disconnected])
        XCTAssertTrue(lostHarness.stderr.lines.contains("cr mcp: pairing failed (peer_closed)"))
        _ = try await lostHarness.call("list_shared_clips")
        XCTAssertEqual(lostConnector.made.count, 2)
        await lostHarness.finish()

        let counter = ToggleBox()
        let connector = FakeConnector(autoApprove: true, handler: { _ in
            counter.firstTime() ? .failure(LocalIPCError.peerClosed) : .success(.sharedClips([]))
        })
        let harness = try await makeHarness(connector: connector, pairingWait: .seconds(5))
        let lost = try await harness.call("list_shared_clips")
        XCTAssertEqual(lost.texts, [MCPToolMessages.disconnected])
        XCTAssertTrue(harness.stderr.lines.contains("cr mcp: connection lost (peer_closed)"))
        let again = try await harness.call("list_shared_clips")
        XCTAssertFalse(again.isError)
        XCTAssertEqual(connector.made.count, 2)
        await harness.finish()
    }

    func testUnavailableAppReturnsNeutralMessageAndReasonCodeOnStderr() async throws {
        let connector = FakeConnector()
        connector.connectError = LocalIPCError.peerRequirementFailed(-67050)
        let harness = try await makeHarness(connector: connector)
        let result = try await harness.call("sync_status")
        XCTAssertTrue(result.isError)
        XCTAssertEqual(
            result.texts,
            ["Clipboard Router is not running, Agent Access is off, or the app could not be verified."]
        )
        XCTAssertEqual(harness.stderr.lines, ["cr mcp: connection failed (peer_requirement_failed_-67050)"])
        await harness.finish()
    }

    func testConcurrentCallsShareOneConnectionAndUseIncreasingRequestIDs() async throws {
        let connector = FakeConnector(autoApprove: true)
        let harness = try await makeHarness(connector: connector, pairingWait: .seconds(5))
        try await withThrowingTaskGroup(of: Bool.self) { group in
            for _ in 0..<6 {
                group.addTask { try await harness.call("sync_status").isError }
            }
            for try await failed in group { XCTAssertFalse(failed) }
        }
        XCTAssertEqual(connector.made.count, 1)
        let ids = connector.made[0].calls.map(\.requestID)
        XCTAssertEqual(ids, Array(1...7))
        await harness.finish()
    }
}

private final class ToggleBox: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    func firstTime() -> Bool {
        lock.withLock {
            defer { used = true }
            return !used
        }
    }
}

final class BoundedStdioTransportTests: XCTestCase {
    private func drain(_ transport: BoundedStdioTransport) async -> (messages: [String], error: Error?) {
        var messages: [String] = []
        do {
            try await transport.connect()
            for try await data in await transport.receive() {
                messages.append(String(decoding: data, as: UTF8.self))
            }
            return (messages, nil)
        } catch {
            return (messages, error)
        }
    }

    func testSplitLinesBlankLinesAndCRLFAreHandled() async {
        let source = ChunkSource([
            Data("{\"a\":".utf8), Data("1}\r\n\n".utf8), Data("{\"b\":2}\n{\"c\":3}".utf8),
        ])
        let transport = BoundedStdioTransport(readChunk: { source.next() }, writeSink: { _ in })
        let result = await drain(transport)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.messages, ["{\"a\":1}", "{\"b\":2}", "{\"c\":3}"])
        let failure = await transport.terminationFailure
        XCTAssertNil(failure)
    }

    func testLineAtTheLimitIsAcceptedAndOneByteOverClosesWithoutParsing() async {
        let limit = 64
        let exact = Data(repeating: 0x61, count: limit) + Data("\n".utf8)
        let atLimit = BoundedStdioTransport(
            maxLineBytes: limit,
            readChunk: { [source = ChunkSource([exact])] in source.next() },
            writeSink: { _ in }
        )
        let accepted = await drain(atLimit)
        XCTAssertNil(accepted.error)
        XCTAssertEqual(accepted.messages.count, 1)

        let over = Data(repeating: 0x62, count: limit + 1) + Data("\n".utf8)
        let overSource = ChunkSource([Data("{\"ok\":true}\n".utf8), over, Data("{\"late\":true}\n".utf8)])
        let overTransport = BoundedStdioTransport(
            maxLineBytes: limit,
            readChunk: { overSource.next() },
            writeSink: { _ in }
        )
        let rejected = await drain(overTransport)
        XCTAssertEqual(rejected.messages, ["{\"ok\":true}"], "nothing from the oversize line or after it")
        XCTAssertEqual(rejected.error as? BoundedTransportError, .lineTooLong)
        let failure = await overTransport.terminationFailure
        XCTAssertEqual(failure, .lineTooLong)
    }

    func testOversizeLineSplitAcrossChunksWithoutNewlineIsRejected() async {
        let chunks = (0..<5).map { _ in Data(repeating: 0x63, count: 20) }
        let source = ChunkSource(chunks)
        let transport = BoundedStdioTransport(maxLineBytes: 64, readChunk: { source.next() }, writeSink: { _ in })
        let result = await drain(transport)
        XCTAssertTrue(result.messages.isEmpty)
        XCTAssertEqual(result.error as? BoundedTransportError, .lineTooLong)
    }

    func testEachMessageIsWrittenExactlyOnceWithOneTrailingNewline() async throws {
        let sink = DataSink()
        let transport = BoundedStdioTransport(readChunk: { nil }, writeSink: { try sink.write($0) })
        try await transport.send(Data("{\"x\":1}".utf8))
        try await transport.send(Data("{\"y\":2}".utf8))
        XCTAssertEqual(sink.writes, [Data("{\"x\":1}\n".utf8), Data("{\"y\":2}\n".utf8)])
    }

    func testOutboundDataContainingANewlineIsRefused() async {
        let sink = DataSink()
        let transport = BoundedStdioTransport(readChunk: { nil }, writeSink: { try sink.write($0) })
        do {
            try await transport.send(Data("{\"x\":\n1}".utf8))
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? BoundedTransportError, .invalidOutbound)
        }
        XCTAssertTrue(sink.writes.isEmpty)
    }

    func testWriteFailureEndsTheTransportAndIsNeverRetried() async {
        let sink = DataSink(failOnWrite: 1)
        let transport = BoundedStdioTransport(readChunk: { nil }, writeSink: { try sink.write($0) })
        do {
            try await transport.send(Data("{\"canary\":\"\(syntheticCanary)\"}".utf8))
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? BoundedTransportError, .writeFailed)
        }
        for _ in 0..<3 {
            do {
                try await transport.send(Data("{\"next\":1}".utf8))
                XCTFail("expected a throw")
            } catch {
                XCTAssertEqual(error as? BoundedTransportError, .writeFailed)
            }
        }
        XCTAssertEqual(sink.writes.count, 1, "the failed message is never written again")
        let failure = await transport.terminationFailure
        XCTAssertEqual(failure, .writeFailed)
    }

    func testPipeBackedStandardIOReaderStopsAtEOF() async throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        let payload = Data("{\"p\":1}\n".utf8)
        _ = payload.withUnsafeBytes { write(fds[1], $0.baseAddress, payload.count) }
        close(fds[1])
        let transport = BoundedStdioTransport(
            readChunk: StandardIO.reader(fd: fds[0], chunkBytes: 3),
            writeSink: { _ in }
        )
        let result = await drain(transport)
        close(fds[0])
        XCTAssertEqual(result.messages, ["{\"p\":1}"])
        XCTAssertNil(result.error)
    }
}
