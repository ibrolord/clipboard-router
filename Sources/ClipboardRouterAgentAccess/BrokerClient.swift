// Bridge-side client. The app's code identity is verified before the bridge writes a byte.

import Darwin
import Foundation

public struct BrokerConnectTiming: Sendable, Equatable {
    public var connectMilliseconds: Int
    public var verifyMilliseconds: Int
}

public final class BrokerClient: @unchecked Sendable {
    public let fd: Int32
    public let server: VerifiedPeer
    public let timing: BrokerConnectTiming
    public private(set) var limits: TransportLimits
    private let lock = NSLock()
    private var closed = false

    init(fd: Int32, server: VerifiedPeer, timing: BrokerConnectTiming, limits: TransportLimits) {
        self.fd = fd
        self.server = server
        self.timing = timing
        self.limits = limits
    }

    deinit { close() }

    public static func connect(endpoint: AgentAccessEndpoint, serverPolicy: CodeIdentityPolicy) throws -> BrokerClient {
        try connect(socketPath: endpoint.socketPath, serverPolicy: serverPolicy)
    }

    public static func connect(socketPath: String, serverPolicy: CodeIdentityPolicy) throws -> BrokerClient {
        let start = MonotonicDeadline.now
        let fd = try LocalSocket.connect(to: socketPath)
        let connected = MonotonicDeadline.now
        do {
            let server = try CodeIdentityVerifier.authenticate(fd, policy: serverPolicy)
            let verified = MonotonicDeadline.now
            return BrokerClient(
                fd: fd,
                server: server,
                timing: BrokerConnectTiming(
                    connectMilliseconds: Int((connected.uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000),
                    verifyMilliseconds: Int((verified.uptimeNanoseconds &- connected.uptimeNanoseconds) / 1_000_000)
                ),
                limits: .standard
            )
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    public func hello(displayName: String?) throws -> BrokerHelloReply {
        try sendFrame(BridgeHello(clientDisplayName: displayName))
        let reply = try receive(BrokerHelloReply.self, timeout: limits.handshakeTimeout + 2)
        guard reply.protocolVersion == BrokerProtocol.version else { throw LocalIPCError.peerSignatureInvalid }
        limits = reply.limits
        return reply
    }

    public func call(sessionID: String, requestID: UInt32, _ operation: BrokerOperation) throws -> BrokerResponse {
        try sendFrame(BrokerRequest(sessionID: sessionID, requestID: requestID, operation: operation))
        let wait: TimeInterval
        switch operation {
        case .awaitPairing: wait = limits.pairingTimeout + 5
        case .requestVaultItem: wait = limits.vaultRequestTimeout + 5
        default: wait = 30
        }
        let response = try receive(BrokerResponse.self, timeout: wait)
        guard response.requestID == requestID || response.requestID == 0 else {
            throw LocalIPCError.peerSignatureInvalid
        }
        return response
    }

    func sendFrame(_ value: some Encodable) throws {
        try FrameIO.writeFrame(
            fd,
            try BrokerProtocol.encode(value),
            maxBytes: limits.maxRequestFrameBytes,
            timeout: limits.writeTimeout
        )
    }

    func receive<Value: Decodable>(_ type: Value.Type, timeout: TimeInterval) throws -> Value {
        let frame = try FrameIO.readFrame(
            fd,
            maxBytes: limits.maxResponseFrameBytes,
            headerDeadline: .after(timeout),
            bodyTimeout: limits.frameBodyTimeout
        )
        return try BrokerProtocol.decode(type, from: frame)
    }

    public func close() {
        lock.withLock {
            guard !closed else { return }
            closed = true
            Darwin.close(fd)
        }
    }

    /// Safe from any thread: wakes a call blocked on this connection (it fails with
    /// `peerClosed`) without closing the descriptor, so it cannot race fd reuse. The app
    /// sees EOF and cancels anything pending for this connection.
    public func interrupt() {
        lock.withLock {
            guard !closed else { return }
            _ = Darwin.shutdown(fd, SHUT_RDWR)
        }
    }
}
