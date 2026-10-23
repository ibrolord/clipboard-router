import ClipboardRouterAgentAccess
import Darwin
import Foundation
import Logging
import MCP

/// The static tool catalog. It is identical before and after pairing and never reveals
/// clip names, counts, Vault names or identifiers.
enum MCPToolCatalog {
    static let listSharedClips = "list_shared_clips"
    static let getSharedClip = "get_shared_clip"
    static let requestVaultItem = "request_vault_item"
    static let syncStatus = "sync_status"

    static let tools: [Tool] = [
        Tool(
            name: listSharedClips,
            title: "List shared clips",
            description: """
            Lists saved Clipboard Router clips the user has chosen to share with agents: id, title, kind, \
            byteCount and modifiedAt. Returns metadata only; use get_shared_clip for the text.
            """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "limit": [
                        "type": "integer",
                        "minimum": 1,
                        "maximum": 100,
                        "default": 50,
                        "description": "Maximum number of clips to list.",
                    ],
                ],
                "additionalProperties": false,
            ],
            annotations: .init(title: "List shared clips", readOnlyHint: true, idempotentHint: true, openWorldHint: false)
        ),
        Tool(
            name: getSharedClip,
            title: "Get shared clip",
            description: "Returns the text of one shared clip by the id from list_shared_clips.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "Clip id from list_shared_clips."],
                ],
                "required": ["id"],
                "additionalProperties": false,
            ],
            annotations: .init(title: "Get shared clip", readOnlyHint: true, idempotentHint: true, openWorldHint: false)
        ),
        Tool(
            name: requestVaultItem,
            title: "Request a Vault item",
            description: """
            Asks the user for one text or URL item from their Clipboard Router Vault. The user picks the item \
            in Clipboard Router and must approve it there; the agent cannot name or choose an item. State \
            plainly why it is needed in purpose (shown to the user, at most 280 characters). The request can \
            be denied, can expire, and may take a while.
            """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "purpose": [
                        "type": "string",
                        "maxLength": 280,
                        "description": "Why the item is needed. Shown to the user.",
                    ],
                ],
                "required": ["purpose"],
                "additionalProperties": false,
            ],
            annotations: .init(title: "Request a Vault item", readOnlyHint: true, idempotentHint: false, openWorldHint: false)
        ),
        Tool(
            name: syncStatus,
            title: "Sync status",
            description: """
            Reports whether the app's local library snapshot is ready and the sync and projection state. \
            lastProjection and its timestamp describe past activity only; they are not a freshness guarantee.
            """,
            inputSchema: ["type": "object", "properties": [:], "additionalProperties": false],
            annotations: .init(title: "Sync status", readOnlyHint: true, idempotentHint: true, openWorldHint: false)
        ),
    ]
}

enum MCPToolMessages {
    static let notFound = "No shared clip with that id is available."
    static let unavailable = "Clipboard Router is not running, Agent Access is off, or the app could not be verified."
    static let notGranted = "Access was not granted in Clipboard Router (denied, expired or revoked). Try again to start a new request."
    static let accessDisabled = "Agent Access was turned off in Clipboard Router."
    static let disconnected = "The connection to Clipboard Router was lost. Try again."
    static let invalidArguments = "Invalid arguments."
    static let tooLarge = "That item is too large to share with an agent."
    static let vaultDenied = "The user declined the Vault request."
    static let vaultExpired = "The Vault request timed out without an answer."
    static let vaultCancelled = "The Vault request was cancelled."
    static let vaultBusy = "Another Vault request is already waiting in Clipboard Router."
    static let generic = "Clipboard Router could not complete the request."

    static func waiting(code: String) -> String {
        "Waiting for approval in Clipboard Router (pairing code \(code)). Approve it in the app, then try again."
    }
}

/// Maps MCP tool calls onto broker operations. Holds no clip content.
struct MCPToolHandler: Sendable {
    let session: BrokerSession
    /// Per-request accounting shared with the transport. Each tools/call carries a ticket (see
    /// `RequestTicketInjection`) naming exactly its own admission entry.
    var admission: RequestAdmission?

    func list() -> ListTools.Result { ListTools.Result(tools: MCPToolCatalog.tools) }

    /// A cancelled call throws so the SDK sends no response (per the MCP spec); nothing
    /// is retried.
    private func perform(_ operation: BrokerOperation) async throws -> BrokerCallOutcome {
        try Task.checkCancellation()
        let outcome = await session.perform(operation)
        if outcome == .cancelled || Task.isCancelled { throw CancellationError() }
        return outcome
    }

    func call(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let admission else { return try await dispatch(params) }
        guard let raw = params._meta?[RequestTicketInjection.metaKey]?.stringValue,
              let ticket = RequestAdmission.parse(ticket: raw)
        else { throw MCPError.invalidRequest("Request could not be admitted.") }
        // Cancelled or retired before this handler began: do no work at all.
        guard admission.handlerStarted(ticket.key, generation: ticket.generation) else {
            throw CancellationError()
        }
        do {
            let result = try await dispatch(params)
            admission.handlerReturned(ticket.key, generation: ticket.generation)
            return result
        } catch is CancellationError {
            // The SDK sends no response for a cancelled handler; this exit retires exactly this key.
            admission.retire(ticket.key, generation: ticket.generation)
            throw CancellationError()
        } catch {
            // The SDK answers with an error response, whose write frees the slot.
            admission.handlerReturned(ticket.key, generation: ticket.generation)
            throw error
        }
    }

    private func dispatch(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let arguments = params.arguments ?? [:]
        switch params.name {
        case MCPToolCatalog.listSharedClips:
            var limit = 50
            if let raw = arguments["limit"] {
                guard let value = raw.intValue, (1...BrokerProtocol.maxListLimit).contains(value) else {
                    return Self.error(MCPToolMessages.invalidArguments)
                }
                limit = value
            }
            return Self.render(try await perform(.listSharedClips(limit: limit)), for: params.name)
        case MCPToolCatalog.getSharedClip:
            guard let id = arguments["id"]?.stringValue, !id.isEmpty,
                  id.utf8.count <= BrokerProtocol.maxClipIDBytes
            else { return Self.error(MCPToolMessages.invalidArguments) }
            return Self.render(try await perform(.getSharedClip(id: id)), for: params.name)
        case MCPToolCatalog.requestVaultItem:
            guard let purpose = arguments["purpose"]?.stringValue,
                  !purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  purpose.unicodeScalars.count <= BrokerProtocol.maxPurposeScalars
            else { return Self.error(MCPToolMessages.invalidArguments) }
            return Self.render(try await perform(.requestVaultItem(purpose: purpose)), for: params.name)
        case MCPToolCatalog.syncStatus:
            return Self.render(try await perform(.syncStatus), for: params.name)
        default:
            throw MCPError.invalidParams("Unknown tool")
        }
    }

    static func error(_ text: String) -> CallTool.Result {
        CallTool.Result(content: [plain(text)], isError: true)
    }

    private static func plain(_ text: String) -> Tool.Content {
        .text(text: text, annotations: nil, _meta: nil)
    }

    private struct ClipRow: Encodable {
        var id: String
        var title: String
        var kind: String
        var byteCount: Int
        var modifiedAt: String
    }

    static func render(_ outcome: BrokerCallOutcome, for tool: String) -> CallTool.Result {
        switch outcome {
        case let .waiting(code): return error(MCPToolMessages.waiting(code: code))
        case .notGranted: return error(MCPToolMessages.notGranted)
        case .accessDisabled: return error(MCPToolMessages.accessDisabled)
        case .disconnected: return error(MCPToolMessages.disconnected)
        case .unavailable: return error(MCPToolMessages.unavailable)
        case .cancelled: return error(MCPToolMessages.generic)
        case let .result(result): return render(result, for: tool)
        }
    }

    static func render(_ result: BrokerResult, for tool: String) -> CallTool.Result {
        switch (tool, result) {
        case let (MCPToolCatalog.listSharedClips, .sharedClips(clips)):
            let rows = clips.map {
                ClipRow(
                    id: $0.id,
                    title: $0.title,
                    kind: $0.kind.rawValue,
                    byteCount: $0.byteCount,
                    modifiedAt: Date(timeIntervalSince1970: TimeInterval($0.modifiedAtEpochSeconds)).ISO8601Format()
                )
            }
            return json(rows)
        case let (MCPToolCatalog.getSharedClip, .sharedClip(content)):
            return CallTool.Result(content: [plain(content.text), plain("Kind: \(content.kind.rawValue)")])
        case let (MCPToolCatalog.requestVaultItem, .vaultItem(item)):
            return CallTool.Result(content: [plain(item.text), plain("Kind: \(item.kind.rawValue)")])
        case let (MCPToolCatalog.syncStatus, .syncStatus(report)):
            return json(report)
        case let (_, .failure(code)):
            switch code {
            case .notFound: return error(MCPToolMessages.notFound)
            case .invalidArgument: return error(MCPToolMessages.invalidArguments)
            case .contentTooLarge: return error(MCPToolMessages.tooLarge)
            case .vaultRequestDenied: return error(MCPToolMessages.vaultDenied)
            case .vaultRequestExpired: return error(MCPToolMessages.vaultExpired)
            case .vaultRequestCancelled: return error(MCPToolMessages.vaultCancelled)
            case .vaultRequestBusy: return error(MCPToolMessages.vaultBusy)
            default: return error(MCPToolMessages.generic)
            }
        default:
            return error(MCPToolMessages.generic)
        }
    }

    private static func json(_ value: some Encodable) -> CallTool.Result {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else {
            return error(MCPToolMessages.generic)
        }
        return CallTool.Result(content: [plain(text)])
    }
}

/// Holds the MCP client's self-reported name for display only. Never logged.
final class MCPClientNameBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    func set(_ name: String) { lock.withLock { value = name } }
    var current: String? { lock.withLock { value } }
}

enum MCPServerFactory {
    static func make(session: BrokerSession, admission: RequestAdmission? = nil) async -> Server {
        let handler = MCPToolHandler(session: session, admission: admission)
        let server = Server(
            name: "clipboard-router",
            version: "1",
            capabilities: Server.Capabilities(tools: .init(listChanged: false))
        )
        await server.withMethodHandler(ListTools.self) { _ in handler.list() }
        await server.withMethodHandler(CallTool.self) { params in try await handler.call(params) }
        return server
    }
}

/// Injectable pieces of `cr mcp`. Production wiring is `MCPCommand.productionEnvironment()`.
struct MCPEnvironment: Sendable {
    /// The startup gate: verifies the helper's own identity and returns the only connector
    /// that may be used. Failure means `cr mcp` never speaks MCP.
    var resolve: @Sendable () throws -> any AgentBrokerConnector
    var readChunk: @Sendable () -> Data?
    var writeStdout: @Sendable (Data) throws -> Void
    var writeStderrLine: @Sendable (String) -> Void
    var pairingWait: Duration = .seconds(45)
    var maxLineBytes: Int = BoundedStdioTransport.defaultMaxLineBytes
}

enum MCPCommand {
    static let exitUnavailable: Int32 = 69

    private static let bootstrapLogging: Void = {
        LoggingSystem.bootstrap { _ in SwiftLogNoOpLogHandler() }
    }()

    static func productionEnvironment() -> MCPEnvironment {
        _ = bootstrapLogging
        // A closed stdout must surface as a write error, not kill the process mid-disclosure.
        signal(SIGPIPE, SIG_IGN)
        return MCPEnvironment(
            resolve: { BrokerClientConnector(context: try BridgeIdentityContext.resolve()) },
            readChunk: StandardIO.reader(fd: STDIN_FILENO),
            writeStdout: StandardIO.writer(fd: STDOUT_FILENO),
            writeStderrLine: { line in
                let bytes = Data((line + "\n").utf8)
                _ = try? StandardIO.writer(fd: STDERR_FILENO)(bytes)
            }
        )
    }

    /// Returns the process exit code.
    static func run(_ environment: MCPEnvironment) async -> Int32 {
        let connector: any AgentBrokerConnector
        do {
            connector = try environment.resolve()
        } catch {
            environment.writeStderrLine("cr mcp: unavailable (\(BrokerReason.code(for: error)))")
            return exitUnavailable
        }

        let names = MCPClientNameBox()
        let session = BrokerSession(
            connector: connector,
            displayName: { names.current },
            stderr: environment.writeStderrLine,
            pairingWait: environment.pairingWait
        )
        let transport = BoundedStdioTransport(
            maxLineBytes: environment.maxLineBytes,
            readChunk: environment.readChunk,
            writeSink: environment.writeStdout
        )
        let server = await MCPServerFactory.make(session: session, admission: transport.admission)
        do {
            try await server.start(transport: transport) { info, _ in names.set(info.name) }
        } catch {
            environment.writeStderrLine("cr mcp: failed to start")
            await session.shutdown()
            return 1
        }
        await server.waitUntilCompleted()
        let failure = await transport.terminationFailure
        await server.stop()
        await session.shutdown()
        if failure != nil {
            environment.writeStderrLine("cr mcp: transport closed")
            return 1
        }
        return 0
    }
}
