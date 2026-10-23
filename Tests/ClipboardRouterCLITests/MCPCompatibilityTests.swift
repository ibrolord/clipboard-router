import Foundation
import MCP
import XCTest
@testable import ClipboardRouterCLI

final class MCPCompatibilityTests: XCTestCase {
    private func initialize(capabilities: String) async throws -> [String: Any]? {
        let session = BrokerSession(connector: BlockingConnector(), displayName: { nil }, stderr: { _ in }, pairingWait: .seconds(1))
        let server = await MCPServerFactory.make(session: session)
        let source = PushSource()
        let sink = MessageSink()
        let transport = BoundedStdioTransport(readChunk: { source.next() }, writeSink: { try sink.write($0) })
        try await server.start(transport: transport)
        source.push("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":\(capabilities),\"clientInfo\":{\"name\":\"codex-mcp-client\",\"title\":\"Codex\",\"version\":\"0.163.0\"}}}")
        _ = await waitUntil { sink.response(id: 1) != nil }
        let response = sink.response(id: 1)
        source.close()
        await server.stop()
        await session.shutdown()
        return response
    }

    func testCodexShapedExperimentalCapabilityIsAccepted() async throws {
        let raw = try await initialize(capabilities: "{\"elicitation\":{},\"experimental\":{\"codex/auth-change\":{}}}")
        let response = try XCTUnwrap(raw)
        XCTAssertNil(response["error"], "initialize must not fail on object-valued experimental capabilities: \(response)")
        XCTAssertNotNil(response["result"])
    }

    func testStringExperimentalAndOtherMessagesAreUntouched() throws {
        XCTAssertNil(InitializeCompatibility.normalized(Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"capabilities\":{\"experimental\":{\"a\":\"b\"}}}}".utf8)))
        XCTAssertNil(InitializeCompatibility.normalized(Data("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"capabilities\":{\"experimental\":{\"x\":{}}}}}".utf8)))
        let normalized = try XCTUnwrap(InitializeCompatibility.normalized(Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"capabilities\":{\"roots\":{},\"experimental\":{\"x\":{}}}}}".utf8)))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: normalized) as? [String: Any])
        let capabilities = (object["params"] as? [String: Any])?["capabilities"] as? [String: Any]
        XCTAssertNil(capabilities?["experimental"])
        XCTAssertNotNil(capabilities?["roots"])
    }
}
