import Darwin
import Foundation
import Logging
import MCP

enum BoundedTransportError: Error, Equatable {
    case lineTooLong
    case writeFailed
    case invalidOutbound
    /// The client kept sending while not reading our refusals; the transport fails closed.
    case overloaded
}

/// Thread-safe flags shared by the reader thread, the writer queue and the actor.
private final class BoundedTransportState: @unchecked Sendable {
    private let lock = NSLock()
    private var failure: BoundedTransportError?
    private var closed = false

    var isUsable: Bool { lock.withLock { failure == nil && !closed } }
    var currentFailure: BoundedTransportError? { lock.withLock { failure } }

    func fail(_ error: BoundedTransportError) {
        lock.withLock { if failure == nil { failure = error } }
    }

    func close() { lock.withLock { closed = true } }
}

/// One-slot hand-off from the blocking reader thread to the SDK's receive loop. The reader
/// blocks until the previous line was taken, so at most one complete line (plus the line
/// being assembled and one read chunk) is ever buffered.
private final class LineChannel: @unchecked Sendable {
    private let condition = NSCondition()
    private var slot: Data?
    private var finished = false
    private var failure: Error?
    private var waiter: CheckedContinuation<Data?, Error>?

    /// Returns false once the channel is finished.
    func put(_ line: Data) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        while slot != nil, !finished { condition.wait() }
        guard !finished else { return false }
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: line)
        } else {
            slot = line
        }
        return true
    }

    /// A clean EOF keeps an already buffered line so it is still delivered; an error or an
    /// explicit disconnect (`discard`) drops it.
    func finish(throwing error: Error? = nil, discard: Bool = false) {
        condition.lock()
        defer { condition.unlock() }
        guard !finished else { return }
        finished = true
        failure = error
        if error != nil || discard { slot = nil }
        if let waiter {
            self.waiter = nil
            if let error { waiter.resume(throwing: error) } else { waiter.resume(returning: nil) }
        }
        condition.broadcast()
    }

    func next() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            condition.lock()
            defer { condition.unlock() }
            if let line = slot {
                slot = nil
                condition.broadcast()
                continuation.resume(returning: line)
            } else if finished {
                if let failure { continuation.resume(throwing: failure) } else { continuation.resume(returning: nil) }
            } else {
                waiter = continuation
            }
        }
    }
}

/// Request admission. The SDK starts an unstructured task per inbound request, so the cap
/// is enforced here, before a request reaches it: excess requests get an immediate
/// JSON-RPC error and never start a broker call.
///
/// Accounting is exact and per request key (the canonical JSON-RPC id). A slot is only ever
/// freed for its own key; unknown keys (SDK parse-error responses with random ids, duplicates)
/// free nothing. Each admitted key moves through
/// `admitted -> handlerStarted -> responding -> (freed)`:
/// - answered: freed when the response for exactly that key has been written (or the write
///   failed), so a blocked stdout cannot free slots while response payloads pile up;
/// - a `tools/call` handler learns its key from a ticket the Reader injects into
///   `params._meta`; it reports `handlerStarted` (refused if the request was cancelled or
///   retired before the SDK started it), `handlerReturned` when it returns a result or an
///   error (a response follows, which frees the slot) and `retire` when it exits by
///   cancellation (the SDK sends no response, so this is the only end event);
/// - cancelled before its handler started: the slot is freed at once and a late-starting
///   handler for that key finds no matching entry and refuses to do any work;
/// - cancelled while its handler runs or its response is pending: the slot stays held until
///   that handler exits or that response is written;
/// - in every case an id cancelled before its response was written is quarantined;
/// - non-`tools/call` requests do no broker work: freed by their response, or immediately if
///   cancelled first.
/// Tickets carry a generation so a stale handler can never act on a reused id.
///
/// One cap (`maxPendingOutbound`) bounds all queued outbound work: responses, refusals and
/// notifications.
final class RequestAdmission: @unchecked Sendable {
    private enum Phase { case admitted, started, responding }

    private struct Entry {
        var generation: UInt64
        var isToolCall: Bool
        var phase: Phase = .admitted
        var cancelled = false
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var nextGeneration: UInt64 = 0
    private var pendingOutbound = 0
    private var peak = 0
    private var activeHandlers = 0
    private var peakHandlers = 0
    /// Ids cancelled before any response was sent. The SDK gives no link between a late
    /// response and the request it answers, so such an id is never admitted again in this
    /// session (fail closed instead of crediting a stale response to a new request). Bounded:
    /// overflowing it ends the transport. Real clients use increasing ids.
    private var cancelledUnanswered: Set<String> = []
    static let maxCancelledUnanswered = 1_024
    let maxInFlight: Int
    let maxPendingOutbound: Int

    init(maxInFlight: Int, maxPendingOutbound: Int) {
        self.maxInFlight = maxInFlight
        self.maxPendingOutbound = maxPendingOutbound
    }

    enum Decision { case admit, busy, duplicate, exhausted }

    func admit(_ key: String, isToolCall: Bool = false) -> Decision {
        lock.withLock {
            guard cancelledUnanswered.count < Self.maxCancelledUnanswered else { return .exhausted }
            guard entries[key] == nil, !cancelledUnanswered.contains(key) else { return .duplicate }
            guard entries.count < maxInFlight else { return .busy }
            nextGeneration += 1
            entries[key] = Entry(generation: nextGeneration, isToolCall: isToolCall)
            peak = max(peak, entries.count)
            return .admit
        }
    }

    /// The opaque ticket a handler presents for `key`: `<generation>/<key>`.
    func ticket(for key: String) -> String? {
        lock.withLock {
            entries[key].map { "\($0.generation)/\(key)" }
        }
    }

    static func parse(ticket: String) -> (key: String, generation: UInt64)? {
        guard let slash = ticket.firstIndex(of: "/"),
              let generation = UInt64(ticket[..<slash])
        else { return nil }
        let key = String(ticket[ticket.index(after: slash)...])
        return key.isEmpty ? nil : (key, generation)
    }

    /// The generation currently admitted under `key`, if any. `send` captures it the moment a
    /// response is handed to the transport so that completing that write can only ever retire
    /// the generation the response was produced for.
    func generation(of key: String) -> UInt64? {
        lock.withLock { entries[key]?.generation }
    }

    /// The response for exactly `key` was written (or its write failed). A key that is unknown,
    /// or whose handler is still running, is left alone. With a `generation`, only that
    /// generation can be retired: a reused id is never freed by an older response.
    func finish(_ key: String, generation: UInt64? = nil) {
        lock.withLock {
            guard let entry = entries[key], entry.phase != .started,
                  generation == nil || generation == entry.generation
            else { return }
            entries.removeValue(forKey: key)
        }
    }

    /// The client cancelled `key`. Before a handler started (or for work that needs no
    /// handler) the slot is freed at once; while a handler runs (or its response is pending)
    /// it stays held until that handler exits (or the response is written). The id is
    /// quarantined either way, because no response had been written for it yet.
    func markCancelled(_ key: String) {
        lock.withLock {
            guard var entry = entries[key] else { return }
            cancelledUnanswered.insert(key)
            switch entry.phase {
            case .admitted:
                entries.removeValue(forKey: key)
            case .started:
                entry.cancelled = true
                entries[key] = entry
            case .responding:
                break
            }
        }
    }

    /// A `tools/call` handler is about to do work. False means it must refuse: the request
    /// was cancelled or retired before it started (or the ticket is stale).
    func handlerStarted(_ key: String, generation: UInt64? = nil) -> Bool {
        lock.withLock {
            guard var entry = entries[key], entry.isToolCall, entry.phase == .admitted,
                  generation == nil || generation == entry.generation
            else { return false }
            entry.phase = .started
            entries[key] = entry
            activeHandlers += 1
            peakHandlers = max(peakHandlers, activeHandlers)
            return true
        }
    }

    /// The handler returned a result or threw an error that the SDK turns into a response; the
    /// slot is kept until that response is written.
    func handlerReturned(_ key: String, generation: UInt64? = nil) {
        lock.withLock {
            guard var entry = entries[key], entry.phase == .started,
                  generation == nil || generation == entry.generation
            else { return }
            entry.phase = .responding
            entries[key] = entry
            activeHandlers -= 1
        }
    }

    /// The handler for exactly `key` exited without a response (cancellation): free its slot.
    func retire(_ key: String, generation: UInt64? = nil) {
        lock.withLock {
            guard let entry = entries[key], generation == nil || generation == entry.generation else { return }
            if entry.phase == .started { activeHandlers -= 1 }
            entries.removeValue(forKey: key)
        }
    }

    var inFlightCount: Int { lock.withLock { entries.count } }
    /// Highest number of simultaneously held slots (for tests).
    var peakInFlight: Int { lock.withLock { peak } }
    /// Highest number of simultaneously running tool handlers (for tests).
    var peakConcurrentHandlers: Int { lock.withLock { peakHandlers } }

    /// Returns false when too much outbound work is already waiting for the client to read.
    func reserveOutbound() -> Bool {
        lock.withLock {
            guard pendingOutbound < maxPendingOutbound else { return false }
            pendingOutbound += 1
            return true
        }
    }

    func outboundWritten() { lock.withLock { pendingOutbound -= 1 } }
}

/// Minimal JSON-RPC classification for admission. Never logs or retains content.
///
/// An id is only usable when it is exactly what the SDK's `ID` decodes to without coercion: a
/// string, or a JSON integer that is an `Int`. Null, booleans, fractions, exponents,
/// out-of-range integers and containers are not; a message that has a `method` (or no
/// `method`/`result`/`error` at all) and an unusable `id` is `invalidRequest` and is never
/// forwarded, because the SDK would either coerce it (null becomes "") or silently turn a request
/// into a notification, or echo the raw id in a parse-error response.
enum JSONRPCShape {
    case request(id: Any, key: String, method: String)
    case invalidRequest
    case cancellation(key: String?)
    /// A cancellation whose `requestId` the SDK would honour but admission cannot key exactly.
    case discard
    case response(key: String)
    case batch
    case other(method: String?)

    /// The SDK's view of the same envelope; used to prove admission and the SDK agree.
    private struct EnvelopeProbe: Decodable {
        let id: ID
        let method: String
    }

    private struct CancelProbe: Decodable {
        struct Params: Decodable { let requestId: ID? }
        let params: Params?
    }

    static func key(of id: ID) -> String {
        switch id {
        case let .string(string): return "s:" + string
        case let .number(number): return "n:" + String(number)
        }
    }

    /// Exact string or exact `Int` only.
    static func key(for id: Any) -> String? {
        if let string = id as? String { return "s:" + string }
        guard let number = id as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              !CFNumberIsFloatType(number as CFNumber),
              let integer = Int(number.stringValue)
        else { return nil }
        return "n:" + String(integer)
    }

    static func classify(_ data: Data) -> JSONRPCShape {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return .other(method: nil)
        }
        if object is [Any] { return .batch }
        guard let message = object as? [String: Any] else { return .other(method: nil) }
        if let rawMethod = message["method"] {
            guard let method = rawMethod as? String else {
                return message["id"] != nil ? .invalidRequest : .other(method: nil)
            }
            if let rawID = message["id"] {
                guard let key = key(for: rawID),
                      let probe = try? JSONDecoder().decode(EnvelopeProbe.self, from: data),
                      probe.method == method,
                      Self.key(of: probe.id) == key
                else { return .invalidRequest }
                return .request(id: rawID, key: key, method: method)
            }
            if method == "notifications/cancelled" {
                guard let params = message["params"] as? [String: Any], let rawRequestID = params["requestId"] else {
                    return .cancellation(key: nil)
                }
                let ours = key(for: rawRequestID)
                let sdk = (try? JSONDecoder().decode(CancelProbe.self, from: data))?.params?.requestId
                if let sdk {
                    // The SDK would cancel this id; admission must key it identically or not forward it.
                    guard let ours, ours == key(of: sdk) else { return .discard }
                    return .cancellation(key: ours)
                }
                return .cancellation(key: nil)
            }
            return .other(method: method)
        }
        if let rawID = message["id"] {
            guard message["result"] != nil || message["error"] != nil else { return .invalidRequest }
            if let key = key(for: rawID) { return .response(key: key) }
        }
        return .other(method: nil)
    }
}

/// Newline-delimited JSON over stdio with hard bounds:
/// - inbound lines are capped (`maxLineBytes`) and pulled one at a time (no unbounded queue);
/// - at most `maxInFlightRequests` requests are admitted; the rest are refused immediately;
/// - batches are refused; a slot is held until the response write completes or, if the
///   request was cancelled, until its handler task ends (see `RequestAdmission`);
/// - each outbound message is written exactly once; a write failure ends the transport and
///   is never retried, so a disclosure is never duplicated. It never logs.
actor BoundedStdioTransport: Transport {
    static let defaultMaxLineBytes = 1024 * 1024
    static let defaultMaxInFlightRequests = 8
    static let defaultMaxPendingRefusals = 16

    nonisolated let logger: Logger
    private let readChunk: @Sendable () -> Data?
    private let writeSink: @Sendable (Data) throws -> Void
    private let maxLineBytes: Int
    private let state = BoundedTransportState()
    nonisolated let admission: RequestAdmission
    private let channel = LineChannel()
    private let writeQueue = DispatchQueue(label: "cr.mcp.stdout")
    private var readerStarted = false

    init(
        maxLineBytes: Int = BoundedStdioTransport.defaultMaxLineBytes,
        maxInFlightRequests: Int = BoundedStdioTransport.defaultMaxInFlightRequests,
        maxPendingRefusals: Int = BoundedStdioTransport.defaultMaxPendingRefusals,
        readChunk: @escaping @Sendable () -> Data?,
        writeSink: @escaping @Sendable (Data) throws -> Void
    ) {
        self.maxLineBytes = maxLineBytes
        self.readChunk = readChunk
        self.writeSink = writeSink
        admission = RequestAdmission(maxInFlight: maxInFlightRequests, maxPendingOutbound: maxPendingRefusals)
        logger = Logger(label: "cr.mcp.transport", factory: { _ in SwiftLogNoOpLogHandler() })
    }

    /// Why the transport ended abnormally, or nil for EOF / orderly shutdown.
    var terminationFailure: BoundedTransportError? { state.currentFailure }

    /// Requests admitted and not yet answered or cancelled (for tests and diagnostics).
    var inFlightRequestCount: Int { admission.inFlightCount }

    func connect() async throws {
        guard !readerStarted else { return }
        readerStarted = true
        let reader = Reader(
            readChunk: readChunk,
            channel: channel,
            state: state,
            admission: admission,
            limit: maxLineBytes,
            refuse: { [writeQueue, writeSink, state, admission, channel] payload in
                Self.enqueueRefusal(payload, queue: writeQueue, sink: writeSink, state: state, admission: admission, channel: channel)
            }
        )
        let thread = Thread { reader.run() }
        thread.name = "cr.mcp.stdin"
        thread.stackSize = 512 * 1024
        thread.start()
    }

    func disconnect() async {
        state.close()
        channel.finish(discard: true)
    }

    func send(_ data: Data) async throws {
        guard state.isUsable else { throw BoundedTransportError.writeFailed }
        guard !data.contains(0x0A) else { throw BoundedTransportError.invalidOutbound }
        // The generation this response belongs to is captured now, before anything is awaited,
        // and only that generation can be retired when its write completes. A response whose
        // request is already gone retires nothing.
        let responseTarget: (key: String, generation: UInt64)? = {
            guard case let .response(key) = JSONRPCShape.classify(data),
                  let generation = self.admission.generation(of: key)
            else { return nil }
            return (key, generation)
        }()
        // One cap for every kind of queued outbound work; at the cap the transport fails closed.
        guard admission.reserveOutbound() else {
            state.fail(.overloaded)
            channel.finish(throwing: BoundedTransportError.overloaded)
            throw BoundedTransportError.overloaded
        }
        var framed = data
        framed.append(0x0A)
        let sink = writeSink
        let state = state
        let channel = channel
        let admission = admission
        let payload = framed
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Swift.Error>) in
            writeQueue.async {
                // A failed transport is never written to again, so nothing is ever duplicated.
                var failure: BoundedTransportError?
                if state.isUsable {
                    do {
                        try sink(payload)
                    } catch {
                        state.fail(.writeFailed)
                        channel.finish(throwing: BoundedTransportError.writeFailed)
                        failure = .writeFailed
                    }
                } else {
                    failure = .writeFailed
                }
                // The request keeps its slot until this write has completed or failed.
                admission.outboundWritten()
                if let responseTarget { admission.finish(responseTarget.key, generation: responseTarget.generation) }
                if let failure { done.resume(throwing: failure) } else { done.resume() }
            }
        }
    }

    func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        let channel = channel
        return AsyncThrowingStream(unfolding: { try await channel.next() })
    }

    private static func enqueueRefusal(
        _ payload: Data,
        queue: DispatchQueue,
        sink: @escaping @Sendable (Data) throws -> Void,
        state: BoundedTransportState,
        admission: RequestAdmission,
        channel: LineChannel
    ) {
        guard admission.reserveOutbound() else {
            state.fail(.overloaded)
            channel.finish(throwing: BoundedTransportError.overloaded)
            return
        }
        var framed = payload
        framed.append(0x0A)
        let line = framed
        queue.async {
            defer { admission.outboundWritten() }
            guard state.isUsable else { return }
            do {
                try sink(line)
            } catch {
                state.fail(.writeFailed)
                channel.finish(throwing: BoundedTransportError.writeFailed)
            }
        }
    }

    private struct Reader: @unchecked Sendable {
        let readChunk: @Sendable () -> Data?
        let channel: LineChannel
        let state: BoundedTransportState
        let admission: RequestAdmission
        let limit: Int
        let refuse: @Sendable (Data) -> Void

        func run() {
            var line = Data()
            while state.isUsable, let chunk = readChunk() {
                var start = chunk.startIndex
                while start < chunk.endIndex {
                    let newline = chunk[start...].firstIndex(of: 0x0A)
                    let end = newline ?? chunk.endIndex
                    // The limit covers the line content only, including a trailing CR.
                    if line.count + (end - start) > limit {
                        state.fail(.lineTooLong)
                        channel.finish(throwing: BoundedTransportError.lineTooLong)
                        return
                    }
                    line.append(chunk[start..<end])
                    if newline != nil {
                        guard deliver(&line) else { return }
                        start = end + 1
                    } else {
                        start = end
                    }
                }
            }
            if state.isUsable { _ = deliver(&line) }
            channel.finish(throwing: state.currentFailure)
        }

        /// Returns false when the transport has ended.
        private func deliver(_ line: inout Data) -> Bool {
            defer { line.removeAll(keepingCapacity: true) }
            if line.last == 0x0D { line.removeLast() }
            guard !line.isEmpty else { return true }
            switch JSONRPCShape.classify(line) {
            case .batch:
                refuse(Self.errorResponse(id: NSNull(), code: -32600, message: "Batch requests are not supported."))
                return state.isUsable
            case .invalidRequest:
                refuse(Self.errorResponse(id: NSNull(), code: -32600, message: "Invalid request."))
                return state.isUsable
            case .discard:
                return true
            case let .request(id, key, method):
                switch admission.admit(key, isToolCall: method == "tools/call") {
                case .admit:
                    if method == "tools/call" {
                        if let injected = RequestTicketInjection.inject(into: line, ticket: admission.ticket(for: key)) {
                            line = injected
                        } else if RequestTicketInjection.hasObjectParams(line) {
                            // Never forward a tools/call that could carry a ticket we did not write.
                            admission.retire(key)
                            refuse(Self.errorResponse(id: id, code: -32600, message: "Invalid request."))
                            return state.isUsable
                        }
                    }
                case .busy:
                    refuse(Self.errorResponse(id: id, code: -32000, message: "Server busy; retry later."))
                    return state.isUsable
                case .duplicate:
                    refuse(Self.errorResponse(id: id, code: -32600, message: "Duplicate request id."))
                    return state.isUsable
                case .exhausted:
                    state.fail(.overloaded)
                    channel.finish(throwing: BoundedTransportError.overloaded)
                    return false
                }
            case let .cancellation(key):
                if let key { admission.markCancelled(key) }
            case let .other(method):
                // A tools/call that was not admitted never carries a ticket into the SDK.
                if method == "tools/call" {
                    guard let cleaned = RequestTicketInjection.strip(from: line) else {
                        refuse(Self.errorResponse(id: NSNull(), code: -32600, message: "Invalid request."))
                        return state.isUsable
                    }
                    line = cleaned
                }
            case .response:
                break
            }
            if let compatible = InitializeCompatibility.normalized(line) { line = compatible }
            return channel.put(line)
        }

        private static func errorResponse(id: Any, code: Int, message: String) -> Data {
            let object: [String: Any] = ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
            return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        }
    }
}

/// Correlates a `tools/call` with its admission entry. The SDK does not expose the JSON-RPC id
/// to handlers, so the Reader writes an admission ticket into `params._meta` under a private
/// name before the SDK decodes the line (any client-supplied value under that name is
/// dropped first, so a client can neither forge nor omit a ticket successfully). The message
/// is re-serialized with JSONSerialization, so number formatting and key order may change;
/// nothing else is altered. A line that cannot be rewritten is forwarded unchanged and its
/// handler refuses to run.
enum RequestTicketInjection {
    static let metaKey = "com.clipboardrouter.cr/requestKey"

    static func inject(into line: Data, ticket: String?) -> Data? {
        guard let ticket,
              var message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              var params = message["params"] as? [String: Any]
        else { return nil }
        var meta: [String: Any]
        if let existing = params["_meta"] {
            guard let object = existing as? [String: Any] else { return nil }
            meta = object
        } else {
            meta = [:]
        }
        meta[metaKey] = ticket
        params["_meta"] = meta
        message["params"] = params
        return try? JSONSerialization.data(withJSONObject: message)
    }

    static func hasObjectParams(_ line: Data) -> Bool {
        guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return false }
        return message["params"] is [String: Any]
    }

    /// Removes any ticket from `params._meta`; returns the line unchanged when it has none, and
    /// nil when a ticket is present but the line cannot be rewritten.
    static func strip(from line: Data) -> Data? {
        guard var message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              var params = message["params"] as? [String: Any],
              var meta = params["_meta"] as? [String: Any],
              meta[metaKey] != nil
        else { return line }
        meta.removeValue(forKey: metaKey)
        params["_meta"] = meta
        message["params"] = params
        return try? JSONSerialization.data(withJSONObject: message)
    }
}

/// Narrow client-compatibility shim. MCP lets clients advertise arbitrary objects under
/// `capabilities.experimental` (Codex 0.163 sends `{"codex/auth-change": {}}`), but MCP
/// Swift SDK 0.12.1 decodes that field as `[String: String]` and rejects `initialize`. This
/// server consumes no experimental client capability, so for `initialize` only an
/// experimental value that is not string-valued is dropped before the SDK decodes it.
/// Nothing else in any message is altered.
enum InitializeCompatibility {
    static func normalized(_ line: Data) -> Data? {
        guard var message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              message["method"] as? String == "initialize",
              var params = message["params"] as? [String: Any],
              var capabilities = params["capabilities"] as? [String: Any],
              let experimental = capabilities["experimental"],
              !(experimental is [String: String])
        else { return nil }
        capabilities.removeValue(forKey: "experimental")
        params["capabilities"] = capabilities
        message["params"] = params
        return try? JSONSerialization.data(withJSONObject: message)
    }
}

/// Blocking file-descriptor adapters for the production stdio transport.
enum StandardIO {
    static func reader(fd: Int32, chunkBytes: Int = 64 * 1024) -> @Sendable () -> Data? {
        {
            var buffer = [UInt8](repeating: 0, count: chunkBytes)
            while true {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, chunkBytes) }
                if count > 0 { return Data(buffer[0..<count]) }
                if count < 0 && errno == EINTR { continue }
                return nil
            }
        }
    }

    static func writer(fd: Int32) -> @Sendable (Data) throws -> Void {
        { data in
            var offset = 0
            try data.withUnsafeBytes { raw in
                while offset < raw.count {
                    let written = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if written > 0 {
                        offset += written
                    } else if written < 0 && (errno == EINTR || errno == EAGAIN) {
                        if errno == EAGAIN { usleep(1_000) }
                        continue
                    } else {
                        throw BoundedTransportError.writeFailed
                    }
                }
            }
        }
    }
}
