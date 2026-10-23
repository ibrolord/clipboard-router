// Single source of truth for agent authorization: enablement, the user's scope, live
// connections, paired sessions and pending Vault requests, all behind one lock.
//
// Disclosure boundary (handoff): a response that carries user content is released only by
// `release(...)` / `releaseVault(...)`. While holding the lock, they re-check enablement,
// the session's state and absolute lifetime, the request's deadline, the connection's
// liveness, and the item-specific guard the caller runs inside its own isolation. Then they
// hand the complete response frame to the authenticated bridge with one bounded,
// non-blocking send. A revocation that acquires the lock first therefore yields zero
// content bytes. Once the send succeeded, the bytes belong to the bridge (and from there to
// the agent) and cannot be recalled. A send that cannot complete marks the connection
// broken; it is never retried. Observers registered with `onChange` are notified after
// the lock is released and must re-read state.

import Darwin
import Foundation

public struct AgentAccessScope: Codable, Sendable, Equatable {
    public var savedClipIDs: Set<UUID>
    public var folderIDs: Set<UUID>

    public init(savedClipIDs: Set<UUID> = [], folderIDs: Set<UUID> = []) {
        self.savedClipIDs = savedClipIDs
        self.folderIDs = folderIDs
    }

    public static let empty = AgentAccessScope()
    public var isEmpty: Bool { savedClipIDs.isEmpty && folderIDs.isEmpty }
}

/// Items that must never be disclosed even if selected (for example collaborative shared
/// folders). Held by the authority so widening and the final handoff evaluation are
/// serialized by the same lock.
public struct AgentAccessExclusions: Sendable, Equatable {
    public var folderIDs: Set<UUID>
    public var savedClipIDs: Set<UUID>

    public init(folderIDs: Set<UUID> = [], savedClipIDs: Set<UUID> = []) {
        self.folderIDs = folderIDs
        self.savedClipIDs = savedClipIDs
    }
}

public struct AgentAccessSessionInfo: Sendable, Equatable, Identifiable {
    public var id: String
    public var pairingCode: String
    /// Self-reported by the MCP client; unverified and display-only.
    public var displayName: String
    public var state: SessionState
    public var disclosures: Int
}

public struct VaultRequestKey: Hashable, Sendable {
    public var sessionID: String
    public var requestID: UInt32

    public init(sessionID: String, requestID: UInt32) {
        self.sessionID = sessionID
        self.requestID = requestID
    }
}

public struct VaultRequestInfo: Sendable, Equatable, Identifiable {
    public var key: VaultRequestKey
    /// Supplied by the agent; untrusted and display-only.
    public var purpose: String
    public var displayName: String
    public var pairingCode: String
    public var id: VaultRequestKey { key }
}

public enum ReleaseOutcome: Equatable, Sendable {
    /// The full response frame was handed to the bridge.
    case handedOff
    /// Not released; the connection thread writes this content-free result instead.
    case refused(BrokerResult)
    /// The connection could not take the frame; it was shut down. Never retried.
    case transportFailed
}

public enum VaultReleaseOutcome: Equatable, Sendable {
    case handedOff
    case notPending
    case expired
    case sessionNotApproved
    case disabled
    case connectionGone
    case transportFailed
    /// The Vault locked or reached its idle deadline before the handoff.
    case vaultLocked
}

public enum VaultWaitOutcome: Equatable, Sendable {
    case handedOff
    case failed(BrokerErrorCode)
    case connectionGone
}

public enum AgentAccessRevocationReason: String, Sendable {
    case userRevoked, disabled, screenLocked, systemSleep, appTerminating, vaultLocked,
         appBackgrounded, listenerStopped
}

/// Handle a backend uses to release exactly one response for one request.
public struct ReleaseChannel: Sendable {
    let authority: AgentAccessAuthority
    let connectionID: UInt64
    public let sessionID: String
    let requestID: UInt32

    /// `build` runs under the authority lock with the current scope. It must be synchronous
    /// and side-effect free. Call this from inside the data owner's isolation (for saved
    /// clips: `ClipboardLibrary.withCommittedSnapshot`) so the data cannot change between
    /// the guard and the handoff.
    public func release(_ build: (AgentAccessScope) -> BrokerResult) -> ReleaseOutcome {
        authority.release(connectionID: connectionID, sessionID: sessionID, requestID: requestID) { scope, _ in build(scope) }
    }

    /// Like `release`, but `build` also receives the current exclusions, read under the
    /// same lock as the send, so an exclusion widened at any earlier instant applies.
    public func releaseScoped(_ build: (AgentAccessScope, AgentAccessExclusions) -> BrokerResult) -> ReleaseOutcome {
        authority.release(connectionID: connectionID, sessionID: sessionID, requestID: requestID, build)
    }
}

public final class AgentAccessAuthority: @unchecked Sendable {
    public typealias Clock = @Sendable () -> UInt64

    private enum VaultRequestState {
        case pending
        case handedOff
        case finished(BrokerErrorCode)
    }

    private struct VaultRequestRecord {
        var info: VaultRequestInfo
        var connectionID: UInt64
        var deadline: UInt64
        var state: VaultRequestState
    }

    private struct SessionRecord {
        var info: AgentAccessSessionInfo
        var connectionID: UInt64
        var pairingDeadline: UInt64
        var lifetimeDeadline: UInt64
    }

    private struct ConnectionRecord {
        var fd: Int32
        var broken = false
    }

    private let condition = NSCondition()
    private let clock: Clock
    private let maxResponseFrameBytes: Int
    private let maxConnections: Int
    private var enabled = false
    private var scope = AgentAccessScope.empty
    private var exclusions = AgentAccessExclusions()
    private var connections: [UInt64: ConnectionRecord] = [:]
    private var nextConnectionID: UInt64 = 1
    private var sessions: [String: SessionRecord] = [:]
    private var vaultRequests: [VaultRequestKey: VaultRequestRecord] = [:]
    private let changeHandler: @Sendable () -> Void

    /// `clock` returns monotonic nanoseconds; tests inject a manual clock.
    public init(
        limits: TransportLimits = .standard,
        clock: @escaping Clock = { DispatchTime.now().uptimeNanoseconds },
        onChange: @escaping @Sendable () -> Void = {}
    ) {
        self.clock = clock
        self.maxResponseFrameBytes = limits.maxResponseFrameBytes
        self.maxConnections = limits.maxConcurrentConnections
        self.changeHandler = onChange
    }

    private func locked<T>(_ body: () -> T) -> T {
        condition.lock()
        defer { condition.unlock() }
        return body()
    }

    /// Runs `body` under the lock, wakes waiters, then notifies the observer after unlocking.
    private func mutate<T>(_ body: () -> T) -> T {
        condition.lock()
        let value = body()
        condition.broadcast()
        condition.unlock()
        changeHandler()
        return value
    }

    private static func nanoseconds(_ seconds: TimeInterval) -> UInt64 {
        UInt64(max(seconds, 0) * 1_000_000_000)
    }

    // MARK: Configuration

    public var isEnabled: Bool { locked { enabled } }
    public var currentScope: AgentAccessScope { locked { scope } }
    public var currentExclusions: AgentAccessExclusions { locked { exclusions } }

    /// Widen-only: an exclusion is never removed during the authority's lifetime.
    public func widenExclusions(folderIDs: Set<UUID>, savedClipIDs: Set<UUID>) {
        mutate {
            exclusions.folderIDs.formUnion(folderIDs)
            exclusions.savedClipIDs.formUnion(savedClipIDs)
        }
    }

    /// Turning access off revokes every session, cancels pending Vault requests and shuts
    /// down every connection (paired or not) so all slots free promptly.
    public func setEnabled(_ isEnabled: Bool) {
        mutate {
            enabled = isEnabled
            if !isEnabled {
                revokeAllLocked()
                shutdownConnectionsLocked { _ in true }
            }
        }
    }

    /// A narrowed scope applies to every later handoff, including reads already in flight.
    public func setScope(_ newScope: AgentAccessScope) {
        mutate { scope = newScope }
    }

    // MARK: Connections

    public var connectionCount: Int { locked { connections.count } }

    /// Registers an accepted socket. Returns nil when the connection cap is reached.
    public func registerConnection(fd: Int32) -> UInt64? {
        locked {
            guard connections.count < maxConnections else { return nil }
            let id = nextConnectionID
            nextConnectionID &+= 1
            connections[id] = ConnectionRecord(fd: fd)
            return id
        }
    }

    /// Called by the owning thread before it closes `fd`; drops the session and anything it
    /// was waiting for. Only the owning thread ever closes the descriptor.
    public func unregisterConnection(_ connectionID: UInt64) {
        mutate {
            connections.removeValue(forKey: connectionID)
            let ended = sessions.filter { $0.value.connectionID == connectionID }.map(\.key)
            for id in ended { sessions.removeValue(forKey: id) }
            vaultRequests = vaultRequests.filter { $0.value.connectionID != connectionID }
        }
    }

    /// Wakes every blocked connection thread with shutdown(2); used when the listener stops.
    public func shutdownAllConnections(_: AgentAccessRevocationReason) {
        mutate {
            revokeAllLocked()
            shutdownConnectionsLocked { _ in true }
        }
    }

    private func shutdownConnectionsLocked(_ predicate: (UInt64) -> Bool) {
        for (id, record) in connections where predicate(id) {
            connections[id]?.broken = true
            _ = Darwin.shutdown(record.fd, SHUT_RDWR)
        }
    }

    private func isConnectionUsableLocked(_ connectionID: UInt64) -> Bool {
        guard let record = connections[connectionID], !record.broken else { return false }
        return LocalSocket.probe(record.fd) == .idle
    }

    // MARK: Sessions

    public func openSession(
        connectionID: UInt64,
        displayName: String,
        pairingTimeout: TimeInterval,
        lifetime: TimeInterval
    ) -> AgentAccessSessionInfo? {
        mutate {
            guard enabled, connections[connectionID]?.broken == false,
                  !sessions.values.contains(where: { $0.connectionID == connectionID })
            else { return nil }
            var id = BrokerProtocol.makeSessionID()
            while sessions[id] != nil { id = BrokerProtocol.makeSessionID() }
            let info = AgentAccessSessionInfo(
                id: id,
                pairingCode: BrokerProtocol.makePairingCode(),
                displayName: BrokerProtocol.sanitizedDisplayName(displayName),
                state: .pendingApproval,
                disclosures: 0
            )
            let now = clock()
            sessions[id] = SessionRecord(
                info: info,
                connectionID: connectionID,
                pairingDeadline: now &+ Self.nanoseconds(pairingTimeout),
                lifetimeDeadline: now &+ Self.nanoseconds(lifetime)
            )
            return info
        }
    }

    public var sessionList: [AgentAccessSessionInfo] {
        locked {
            expireOverdueLocked()
            return sessions.values.map(\.info).sorted { $0.id < $1.id }
        }
    }

    public func sessionState(_ id: String) -> SessionState? {
        locked {
            expireOverdueLocked()
            return sessions[id]?.info.state
        }
    }

    /// Only a pending session can be decided; terminal states are sticky so a late click
    /// cannot resurrect a revoked or expired session.
    @discardableResult
    public func decidePairing(_ id: String, approve: Bool) -> Bool {
        mutate {
            expireOverdueLocked()
            guard enabled, var record = sessions[id], record.info.state == .pendingApproval else { return false }
            record.info.state = approve ? .approved : .denied
            sessions[id] = record
            return true
        }
    }

    /// Revokes one session and shuts down its connection so its slot frees immediately.
    public func revokeSession(_ id: String) {
        mutate {
            guard let record = sessions[id] else { return }
            if !record.info.state.isTerminal { sessions[id]?.info.state = .revoked }
            cancelVaultRequestsLocked { $0.sessionID == id }
            shutdownConnectionsLocked { $0 == record.connectionID }
        }
    }

    public func revokeAllSessions(_: AgentAccessRevocationReason) {
        mutate {
            let paired = Set(sessions.values.map(\.connectionID))
            revokeAllLocked()
            shutdownConnectionsLocked { paired.contains($0) }
        }
    }

    /// Blocks the connection thread until the user decides, a deadline passes, the session
    /// is revoked, or the peer goes away.
    public func awaitPairing(_ id: String) -> SessionState {
        condition.lock()
        defer { condition.unlock() }
        while true {
            expireOverdueLocked()
            guard let record = sessions[id] else { return .revoked }
            if record.info.state != .pendingApproval { return record.info.state }
            if !isConnectionUsableLocked(record.connectionID) {
                sessions[id]?.info.state = .revoked
                return .revoked
            }
            _ = condition.wait(until: Date().addingTimeInterval(0.2))
        }
    }

    private func expireOverdueLocked() {
        let now = clock()
        for (id, record) in sessions where !record.info.state.isTerminal {
            if now >= record.lifetimeDeadline
                || (record.info.state == .pendingApproval && now >= record.pairingDeadline)
            {
                sessions[id]?.info.state = .expired
                cancelVaultRequestsLocked { $0.sessionID == id }
            }
        }
        for (key, record) in vaultRequests {
            if case .pending = record.state, now >= record.deadline {
                vaultRequests[key]?.state = .finished(.vaultRequestExpired)
            }
        }
    }

    private func revokeAllLocked() {
        for id in sessions.keys where !(sessions[id]?.info.state.isTerminal ?? true) {
            sessions[id]?.info.state = .revoked
        }
        cancelVaultRequestsLocked { _ in true }
    }

    private func approvedSessionLocked(_ sessionID: String, connectionID: UInt64) -> SessionRecord? {
        guard let record = sessions[sessionID],
              record.connectionID == connectionID,
              record.info.state == .approved,
              clock() < record.lifetimeDeadline
        else { return nil }
        return record
    }

    // MARK: Handoff

    /// Content-free authorization check used before reaching the backend.
    public func authorizeMetadata(sessionID: String) -> BrokerErrorCode? {
        locked {
            expireOverdueLocked()
            guard enabled else { return .accessDisabled }
            return sessions[sessionID]?.info.state == .approved ? nil : .notApproved
        }
    }

    func release(
        connectionID: UInt64,
        sessionID: String,
        requestID: UInt32,
        _ build: (AgentAccessScope, AgentAccessExclusions) -> BrokerResult
    ) -> ReleaseOutcome {
        mutate {
            expireOverdueLocked()
            guard enabled else { return .refused(.failure(.accessDisabled)) }
            guard approvedSessionLocked(sessionID, connectionID: connectionID) != nil else {
                let state = sessions[sessionID]?.info.state ?? .revoked
                return .refused(state.isTerminal ? .sessionState(state) : .failure(.notApproved))
            }
            guard isConnectionUsableLocked(connectionID), let fd = connections[connectionID]?.fd else {
                return .transportFailed
            }
            let result = build(scope, exclusions)
            // Re-checked after build and encoding, immediately before the send: the session's
            // absolute lifetime may have passed while the payload was being prepared.
            let response = BrokerResponse(requestID: requestID, result: result)
            switch handOffLocked(fd: fd, connectionID: connectionID, response: response, beforeSend: {
                expireOverdueLocked()
                return sessions[sessionID]?.info.state == .approved
            }) {
            case .complete:
                if result.carriesContent { sessions[sessionID]?.info.disclosures += 1 }
                return .handedOff
            case .preconditionFailed:
                let state = sessions[sessionID]?.info.state ?? .revoked
                return .refused(state.isTerminal ? .sessionState(state) : .failure(.notApproved))
            case .failed:
                return .transportFailed
            }
        }
    }

    private enum HandOff { case complete, failed, preconditionFailed }

    /// One bounded, non-blocking attempt to place the whole frame in the socket. Anything
    /// short of the full frame breaks the connection; nothing is retried. `beforeSend` is
    /// evaluated after the payload is built and encoded, immediately before the send; if it
    /// fails nothing is sent and the connection stays usable.
    private func handOffLocked(
        fd: Int32,
        connectionID: UInt64,
        response: BrokerResponse,
        beforeSend: () -> Bool = { true }
    ) -> HandOff {
        var frame: [UInt8]
        do {
            var payload = try BrokerProtocol.encode(response)
            if payload.count > maxResponseFrameBytes {
                payload = try BrokerProtocol.encode(BrokerResponse(requestID: response.requestID, result: .failure(.contentTooLarge)))
            }
            frame = try FrameIO.encodeFrame(payload, maxBytes: maxResponseFrameBytes)
        } catch {
            connections[connectionID]?.broken = true
            _ = Darwin.shutdown(fd, SHUT_RDWR)
            return .failed
        }
        defer { frame.withUnsafeMutableBytes { _ = memset($0.baseAddress!, 0, $0.count) } }
        guard beforeSend() else { return .preconditionFailed }
        if FrameIO.sendWithoutBlocking(fd, frame) { return .complete }
        connections[connectionID]?.broken = true
        _ = Darwin.shutdown(fd, SHUT_RDWR)
        return .failed
    }

    // MARK: Vault requests

    public func openVaultRequest(
        connectionID: UInt64,
        sessionID: String,
        requestID: UInt32,
        purpose: String,
        timeout: TimeInterval
    ) -> Result<VaultRequestKey, BrokerErrorCode> {
        mutate {
            expireOverdueLocked()
            guard enabled else { return .failure(.accessDisabled) }
            guard let record = approvedSessionLocked(sessionID, connectionID: connectionID) else {
                return .failure(.notApproved)
            }
            let hasPending = vaultRequests.contains { key, value in
                guard key.sessionID == sessionID, case .pending = value.state else { return false }
                return true
            }
            guard !hasPending else { return .failure(.vaultRequestBusy) }
            let key = VaultRequestKey(sessionID: sessionID, requestID: requestID)
            vaultRequests[key] = VaultRequestRecord(
                info: VaultRequestInfo(
                    key: key,
                    purpose: BrokerProtocol.sanitizedPurpose(purpose),
                    displayName: record.info.displayName,
                    pairingCode: record.info.pairingCode
                ),
                connectionID: connectionID,
                deadline: clock() &+ Self.nanoseconds(timeout),
                state: .pending
            )
            return .success(key)
        }
    }

    public var pendingVaultRequests: [VaultRequestInfo] {
        locked {
            expireOverdueLocked()
            return vaultRequests.values.compactMap { record in
                guard case .pending = record.state else { return nil }
                return record.info
            }.sorted { ($0.key.sessionID, $0.key.requestID) < ($1.key.sessionID, $1.key.requestID) }
        }
    }

    public func isVaultRequestPending(_ key: VaultRequestKey) -> Bool {
        locked {
            expireOverdueLocked()
            guard enabled, let record = vaultRequests[key], case .pending = record.state else { return false }
            return approvedSessionLocked(key.sessionID, connectionID: record.connectionID) != nil
        }
    }

    /// The Vault handoff. Exactly one release of a pending, unexpired request on an approved,
    /// live session succeeds; the deadline is fixed at creation and never extended. Call it
    /// from inside `VaultSession`'s epoch-checked isolation so a lock cannot interleave.
    /// `build` returns the payload the user approved (already decrypted by the caller).
    /// `stillUnlocked`, the session's lifetime and the request's deadline are evaluated under
    /// the lock immediately before the send, so a deadline that passed while waiting for this
    /// lock or while building the payload prevents the handoff.
    public func releaseVault(
        _ key: VaultRequestKey,
        stillUnlocked: () -> Bool = { true },
        _ build: () -> VaultHandoff
    ) -> VaultReleaseOutcome {
        mutate {
            expireOverdueLocked()
            guard enabled else { return .disabled }
            guard let record = vaultRequests[key] else { return .notPending }
            switch record.state {
            case .pending: break
            case .finished(.vaultRequestExpired): return .expired
            default: return .notPending
            }
            guard approvedSessionLocked(key.sessionID, connectionID: record.connectionID) != nil else {
                return .sessionNotApproved
            }
            guard isConnectionUsableLocked(record.connectionID), let fd = connections[record.connectionID]?.fd else {
                vaultRequests[key]?.state = .finished(.vaultRequestCancelled)
                return .connectionGone
            }
            guard stillUnlocked() else {
                vaultRequests[key]?.state = .finished(.vaultRequestCancelled)
                return .vaultLocked
            }
            let response = BrokerResponse(requestID: key.requestID, result: .vaultItem(build()))
            // Re-checked after build and encoding, immediately before the send.
            switch handOffLocked(fd: fd, connectionID: record.connectionID, response: response, beforeSend: {
                expireOverdueLocked()
                guard sessions[key.sessionID]?.info.state == .approved,
                      case .pending? = vaultRequests[key]?.state
                else { return false }
                return stillUnlocked()
            }) {
            case .complete:
                vaultRequests[key]?.state = .handedOff
                sessions[key.sessionID]?.info.disclosures += 1
                return .handedOff
            case .preconditionFailed:
                // Expiry already settled the request (session expiry cancels it first, then
                // request expiry); otherwise the Vault locked and the request is cancelled.
                if case .finished(.vaultRequestExpired)? = vaultRequests[key]?.state { return .expired }
                let sessionApproved = sessions[key.sessionID]?.info.state == .approved
                if case .pending? = vaultRequests[key]?.state {
                    vaultRequests[key]?.state = .finished(.vaultRequestCancelled)
                }
                return sessionApproved ? .vaultLocked : .sessionNotApproved
            case .failed:
                vaultRequests[key]?.state = .finished(.vaultRequestCancelled)
                return .transportFailed
            }
        }
    }

    @discardableResult
    public func denyVaultRequest(_ key: VaultRequestKey) -> Bool {
        mutate {
            guard let record = vaultRequests[key], case .pending = record.state else { return false }
            vaultRequests[key]?.state = .finished(.vaultRequestDenied)
            return true
        }
    }

    /// Vault lock, app background, sleep and screen lock cancel every pending request.
    public func cancelPendingVaultRequests(_: AgentAccessRevocationReason) {
        mutate { cancelVaultRequestsLocked { _ in true } }
    }

    private func cancelVaultRequestsLocked(_ predicate: (VaultRequestKey) -> Bool) {
        for (key, record) in vaultRequests where predicate(key) {
            if case .pending = record.state { vaultRequests[key]?.state = .finished(.vaultRequestCancelled) }
        }
    }

    /// Blocks the connection thread until the request was handed off or ended.
    public func awaitVaultRequest(_ key: VaultRequestKey) -> VaultWaitOutcome {
        condition.lock()
        defer { condition.unlock() }
        while true {
            expireOverdueLocked()
            guard let record = vaultRequests[key] else { return .connectionGone }
            switch record.state {
            case .handedOff:
                vaultRequests.removeValue(forKey: key)
                return .handedOff
            case let .finished(code):
                vaultRequests.removeValue(forKey: key)
                return .failed(code)
            case .pending:
                if !isConnectionUsableLocked(record.connectionID) {
                    vaultRequests.removeValue(forKey: key)
                    return .connectionGone
                }
            }
            _ = condition.wait(until: Date().addingTimeInterval(0.2))
        }
    }

    /// Wakes waiters so they re-evaluate deadlines (used by tests with a manual clock).
    public func wakeWaiters() {
        locked { condition.broadcast() }
    }
}
