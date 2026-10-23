// Authenticated AF_UNIX primitives shared by the sandboxed Clipboard Router broker and the
// `cr mcp` bridge. Nothing in this file reads, logs or formats frame contents.

import Darwin
import Foundation
import Security

public enum LocalIPCError: Error, Equatable, Sendable {
    case endpointPathTooLong
    case endpointDirectoryUnsafe
    case endpointNotOwnedSocket
    case endpointInUse
    case socketFailure(String, Int32)
    case peerCredentialsUnavailable
    case peerUserMismatch
    case peerTokenUnavailable
    case peerCodeUnavailable(OSStatus)
    case invalidRequirement(OSStatus)
    case peerRequirementFailed(OSStatus)
    case peerSigningInfoUnavailable(OSStatus)
    case peerSignatureInvalid
    case peerNotHardened
    case peerDebugged
    case peerPathMismatch
    case peerEntitlementForbidden(String)
    case peerEntitlementMissing(String)
    case frameEmpty
    case frameTooLarge(Int)
    case peerClosed
    case timedOut

    /// Stable, content-free reason code suitable for diagnostics.
    public var reasonCode: String {
        switch self {
        case .endpointPathTooLong: "endpoint_path_too_long"
        case .endpointDirectoryUnsafe: "endpoint_directory_unsafe"
        case .endpointNotOwnedSocket: "endpoint_not_owned_socket"
        case .endpointInUse: "endpoint_in_use"
        case let .socketFailure(call, code): "socket_\(call)_errno_\(code)"
        case .peerCredentialsUnavailable: "peer_credentials_unavailable"
        case .peerUserMismatch: "peer_user_mismatch"
        case .peerTokenUnavailable: "peer_token_unavailable"
        case let .peerCodeUnavailable(status): "peer_code_unavailable_\(status)"
        case let .invalidRequirement(status): "invalid_requirement_\(status)"
        case let .peerRequirementFailed(status): "peer_requirement_failed_\(status)"
        case let .peerSigningInfoUnavailable(status): "peer_signing_info_unavailable_\(status)"
        case .peerSignatureInvalid: "peer_signature_invalid"
        case .peerNotHardened: "peer_not_hardened"
        case .peerDebugged: "peer_debugged"
        case .peerPathMismatch: "peer_path_mismatch"
        case .peerEntitlementForbidden: "peer_entitlement_forbidden"
        case .peerEntitlementMissing: "peer_entitlement_missing"
        case .frameEmpty: "frame_empty"
        case .frameTooLarge: "frame_too_large"
        case .peerClosed: "peer_closed"
        case .timedOut: "timed_out"
        }
    }
}

/// Monotonic deadline. Wall-clock changes cannot extend or shorten transport timeouts.
public struct MonotonicDeadline: Sendable, Comparable {
    public let uptimeNanoseconds: UInt64

    public init(uptimeNanoseconds: UInt64) { self.uptimeNanoseconds = uptimeNanoseconds }

    public static var now: MonotonicDeadline {
        MonotonicDeadline(uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds)
    }

    public static func after(_ seconds: TimeInterval) -> MonotonicDeadline {
        let delta = UInt64(max(seconds, 0) * 1_000_000_000)
        return MonotonicDeadline(uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds &+ delta)
    }

    public var remaining: TimeInterval {
        let now = DispatchTime.now().uptimeNanoseconds
        guard uptimeNanoseconds > now else { return 0 }
        return TimeInterval(uptimeNanoseconds - now) / 1_000_000_000
    }

    public var hasPassed: Bool { remaining <= 0 }

    public static func < (lhs: MonotonicDeadline, rhs: MonotonicDeadline) -> Bool {
        lhs.uptimeNanoseconds < rhs.uptimeNanoseconds
    }
}

/// Hard caps applied by both ends. The broker only moves bounded clip text, never bulk exports.
public struct TransportLimits: Sendable, Codable, Equatable {
    public var maxRequestFrameBytes = 16 * 1024
    public var maxResponseFrameBytes = 256 * 1024
    /// From accepted connection to a complete hello. The bridge validates the app's code
    /// signature before its first byte; measured cold runs took milliseconds, so this is
    /// headroom for loaded machines, not a fix for any observed failure.
    public var handshakeTimeout: TimeInterval = 15
    public var frameBodyTimeout: TimeInterval = 2
    public var writeTimeout: TimeInterval = 5
    public var idleTimeout: TimeInterval = 15 * 60
    public var pairingTimeout: TimeInterval = 120
    public var vaultRequestTimeout: TimeInterval = 120
    public var maxSessionLifetime: TimeInterval = 8 * 60 * 60
    public var maxRequestsPerSession = 2_048
    public var maxConcurrentConnections = 4

    public init() {}

    public static let standard = TransportLimits()
}

public enum LocalSocket {
    public static func address(for path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8)
        guard !bytes.isEmpty, bytes.count <= maxPathBytes, !bytes.contains(0) else {
            throw LocalIPCError.endpointPathTooLong
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
        }
        return address
    }

    /// Longest absolute socket path accepted by `sockaddr_un` (excluding the terminator).
    public static var maxPathBytes: Int { MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1 }

    /// Creates (or validates) a private 0700 directory owned by the current user. Refuses
    /// symlinks and foreign owners rather than repairing them.
    public static func preparePrivateDirectory(_ path: String) throws {
        if mkdir(path, 0o700) != 0, errno != EEXIST {
            throw LocalIPCError.socketFailure("mkdir", errno)
        }
        var info = stat()
        guard lstat(path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid()
        else { throw LocalIPCError.endpointDirectoryUnsafe }
        if (info.st_mode & 0o077) != 0, chmod(path, 0o700) != 0 {
            throw LocalIPCError.endpointDirectoryUnsafe
        }
    }

    public static func makeSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LocalIPCError.socketFailure("socket", errno) }
        configure(fd)
        return fd
    }

    public static func configure(_ fd: Int32) {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        // Both directions hold at least two maximum frames, so a response handed off while
        // the bridge waits for it fits in one non-blocking send.
        var size = Int32(socketBufferBytes)
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
    }

    public static let socketBufferBytes = 2 * (TransportLimits.standard.maxResponseFrameBytes + 4)

    /// Binds a 0600 listening socket inside a private directory. A stale socket file owned by
    /// this user is replaced only when nothing is accepting on it. umask is process-wide, so
    /// it is never changed; the 0700 directory protects the window before chmod.
    public static func listen(at path: String, backlog: Int32 = 8) throws -> Int32 {
        var address = try address(for: path)
        var info = stat()
        if lstat(path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFSOCK, info.st_uid == getuid() else {
                throw LocalIPCError.endpointNotOwnedSocket
            }
            if let live = try? connect(to: path) {
                close(live)
                throw LocalIPCError.endpointInUse
            }
            unlink(path)
        }
        let fd = try makeSocket()
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        let bindErrno = errno
        guard bound == 0 else {
            close(fd)
            throw LocalIPCError.socketFailure("bind", bindErrno)
        }
        guard chmod(path, 0o600) == 0 else {
            let chmodErrno = errno
            close(fd)
            unlink(path)
            throw LocalIPCError.socketFailure("chmod", chmodErrno)
        }
        guard Darwin.listen(fd, backlog) == 0 else {
            let listenErrno = errno
            close(fd)
            unlink(path)
            throw LocalIPCError.socketFailure("listen", listenErrno)
        }
        return fd
    }

    public static func connect(to path: String) throws -> Int32 {
        var address = try address(for: path)
        let fd = try makeSocket()
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            let connectErrno = errno
            close(fd)
            throw LocalIPCError.socketFailure("connect", connectErrno)
        }
        guard setNonBlocking(fd) else {
            let flagErrno = errno
            close(fd)
            throw LocalIPCError.socketFailure("fcntl", flagErrno)
        }
        return fd
    }

    /// Every connection descriptor is O_NONBLOCK for its whole life. `MSG_DONTWAIT` alone
    /// does not stop a blocking AF_UNIX send from waiting on this platform, so all reads and
    /// writes poll with explicit monotonic deadlines instead.
    @discardableResult
    public static func setNonBlocking(_ fd: Int32) -> Bool {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0 else { return false }
        return flags & O_NONBLOCK != 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0
    }

    public static func isNonBlocking(_ fd: Int32) -> Bool {
        let flags = fcntl(fd, F_GETFL)
        return flags >= 0 && flags & O_NONBLOCK != 0
    }

    /// Waits until `fd` is ready for `events` or the deadline passes. EINTR is retried
    /// against the same deadline.
    static func wait(_ fd: Int32, events: Int16, deadline: MonotonicDeadline) throws {
        while true {
            let remaining = deadline.remaining
            guard remaining > 0 else { throw LocalIPCError.timedOut }
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let milliseconds = Int32(min(max(remaining * 1000, 1), Double(Int32.max)))
            let ready = poll(&descriptor, 1, milliseconds)
            if ready > 0 {
                if descriptor.revents & Int16(POLLNVAL) != 0 { throw LocalIPCError.socketFailure("poll", EBADF) }
                return
            }
            if ready == 0 { throw LocalIPCError.timedOut }
            if errno != EINTR { throw LocalIPCError.socketFailure("poll", errno) }
        }
    }

    public enum PeerProbe: Equatable, Sendable { case idle, closed, unexpectedData }

    /// Non-blocking liveness probe used while a request waits on the user. Bytes arriving
    /// during the wait are reported so callers treat pipelining as a protocol violation.
    public static func probe(_ fd: Int32) -> PeerProbe {
        var byte: UInt8 = 0
        let received = recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        if received > 0 { return .unexpectedData }
        if received == 0 { return .closed }
        return (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) ? .idle : .closed
    }

    public static func peerUserID(_ fd: Int32) throws -> uid_t {
        var credentials = xucred()
        var length = socklen_t(MemoryLayout<xucred>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERCRED, &credentials, &length) == 0,
              length == socklen_t(MemoryLayout<xucred>.size),
              credentials.cr_version == XUCRED_VERSION
        else { throw LocalIPCError.peerCredentialsUnavailable }
        return credentials.cr_uid
    }

    public static func peerAuditToken(_ fd: Int32) throws -> audit_token_t {
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0,
              length == socklen_t(MemoryLayout<audit_token_t>.size)
        else { throw LocalIPCError.peerTokenUnavailable }
        return token
    }
}

/// Length-prefixed (4-byte big-endian) frames with a hard size cap checked before any body
/// byte is read, and monotonic deadlines.
public enum FrameIO {
    public static func readExactly(_ fd: Int32, count: Int, deadline: MonotonicDeadline) throws -> [UInt8] {
        guard LocalSocket.isNonBlocking(fd) else { throw LocalIPCError.socketFailure("blocking_descriptor", EINVAL) }
        var buffer = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            guard !deadline.hasPassed else { throw LocalIPCError.timedOut }
            let received = buffer.withUnsafeMutableBytes { raw in
                recv(fd, raw.baseAddress! + offset, count - offset, 0)
            }
            if received > 0 {
                offset += received
            } else if received == 0 {
                throw LocalIPCError.peerClosed
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                try LocalSocket.wait(fd, events: Int16(POLLIN), deadline: deadline)
            } else if errno == ECONNRESET {
                throw LocalIPCError.peerClosed
            } else {
                throw LocalIPCError.socketFailure("recv", errno)
            }
        }
        return buffer
    }

    /// `headerDeadline` bounds the wait for a frame to start; once a header arrives the body
    /// must complete within `bodyTimeout`.
    public static func readFrame(
        _ fd: Int32,
        maxBytes: Int,
        headerDeadline: MonotonicDeadline,
        bodyTimeout: TimeInterval
    ) throws -> Data {
        let header = try readExactly(fd, count: 4, deadline: headerDeadline)
        let length = Int(header[0]) << 24 | Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
        guard length > 0 else { throw LocalIPCError.frameEmpty }
        guard length <= maxBytes else { throw LocalIPCError.frameTooLarge(length) }
        return Data(try readExactly(fd, count: length, deadline: .after(bodyTimeout)))
    }

    public static func encodeFrame(_ payload: Data, maxBytes: Int) throws -> [UInt8] {
        guard !payload.isEmpty else { throw LocalIPCError.frameEmpty }
        guard payload.count <= maxBytes else { throw LocalIPCError.frameTooLarge(payload.count) }
        let length = UInt32(payload.count)
        var bytes: [UInt8] = [
            UInt8(truncatingIfNeeded: length >> 24),
            UInt8(truncatingIfNeeded: length >> 16),
            UInt8(truncatingIfNeeded: length >> 8),
            UInt8(truncatingIfNeeded: length),
        ]
        bytes.append(contentsOf: payload)
        return bytes
    }

    public static func writeFrame(_ fd: Int32, _ payload: Data, maxBytes: Int, timeout: TimeInterval) throws {
        try writeAll(fd, encodeFrame(payload, maxBytes: maxBytes), deadline: .after(timeout))
    }

    /// Writes once. A failure part-way leaves the frame truncated; callers close the
    /// connection and never retry, so a disclosure is never duplicated.
    public static func writeAll(_ fd: Int32, _ bytes: [UInt8], deadline: MonotonicDeadline) throws {
        guard LocalSocket.isNonBlocking(fd) else { throw LocalIPCError.socketFailure("blocking_descriptor", EINVAL) }
        var offset = 0
        while offset < bytes.count {
            guard !deadline.hasPassed else { throw LocalIPCError.timedOut }
            let sent = bytes.withUnsafeBytes { raw in
                send(fd, raw.baseAddress! + offset, bytes.count - offset, 0)
            }
            if sent > 0 {
                offset += sent
            } else if sent < 0, errno == EINTR {
                continue
            } else if sent == 0 || errno == EAGAIN || errno == EWOULDBLOCK || errno == ENOBUFS {
                try LocalSocket.wait(fd, events: Int16(POLLOUT), deadline: deadline)
            } else if errno == EPIPE || errno == ECONNRESET {
                throw LocalIPCError.peerClosed
            } else {
                throw LocalIPCError.socketFailure("send", errno)
            }
        }
    }

    /// Bounded handoff used while holding the authority lock: never waits for the peer.
    /// Refuses (returns false) on a blocking descriptor rather than risk blocking. Returns
    /// true only when every byte was accepted by the socket; EINTR retries are bounded.
    public static func sendWithoutBlocking(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        guard LocalSocket.isNonBlocking(fd) else { return false }
        var offset = 0
        var interrupts = 0
        while offset < bytes.count {
            let sent = bytes.withUnsafeBytes { raw in
                send(fd, raw.baseAddress! + offset, bytes.count - offset, 0)
            }
            if sent > 0 {
                offset += sent
            } else if sent < 0, errno == EINTR, interrupts < 16 {
                interrupts += 1
                continue
            } else {
                return false
            }
        }
        return true
    }
}

public struct CodeIdentityPolicy: Sendable, Equatable {
    /// Compiled in or derived from validated signed state; never accepted from arguments,
    /// environment or configuration files.
    public var requirement: String
    public var requireHardenedRuntime: Bool
    /// When non-empty, the peer's on-disk code location (SecCodeCopyPath: the bundle for
    /// bundled code, the file for a bare helper) must resolve to exactly one of these paths.
    public var expectedCodePaths: [String]
    public var requiredTrueEntitlements: [String]
    public var forbiddenEntitlements: [String]

    /// Entitlements that let another process inject into, debug or re-host the peer.
    public static let injectionEntitlements = [
        "com.apple.security.get-task-allow",
        "com.apple.security.cs.disable-library-validation",
        "com.apple.security.cs.allow-dyld-environment-variables",
        "com.apple.security.cs.allow-unsigned-executable-memory",
        "com.apple.security.cs.allow-jit",
        "com.apple.security.cs.debugger",
        "com.apple.security.inherit",
    ]

    public init(
        requirement: String,
        requireHardenedRuntime: Bool = true,
        expectedCodePaths: [String] = [],
        requiredTrueEntitlements: [String] = [],
        forbiddenEntitlements: [String] = CodeIdentityPolicy.injectionEntitlements
    ) {
        self.requirement = requirement
        self.requireHardenedRuntime = requireHardenedRuntime
        self.expectedCodePaths = expectedCodePaths
        self.requiredTrueEntitlements = requiredTrueEntitlements
        self.forbiddenEntitlements = forbiddenEntitlements
    }
}

public struct VerifiedPeer: Sendable, Equatable {
    public var identifier: String
    public var teamIdentifier: String?
    public var processIdentifier: pid_t

    public init(identifier: String, teamIdentifier: String?, processIdentifier: pid_t) {
        self.identifier = identifier
        self.teamIdentifier = teamIdentifier
        self.processIdentifier = processIdentifier
    }
}

public enum CodeIdentityVerifier {
    // Stable code-signing ABI values (CSCommon.h).
    static let statusValid: UInt32 = 0x0000_0001
    static let statusDebugged: UInt32 = 0x1000_0000
    static let flagRuntime: UInt32 = 0x0001_0000
    // kSecCSSigningInformation | kSecCSRequirementInformation | kSecCSDynamicInformation
    static let infoFlags = SecCSFlags(rawValue: (1 << 1) | (1 << 2) | (1 << 3))

    /// Verifies the process behind a socket audit token. The audit token carries the pid
    /// version, so a recycled pid or a post-connect exec fails closed.
    public static func verify(auditToken: audit_token_t, policy: CodeIdentityPolicy) throws -> VerifiedPeer {
        var token = auditToken
        let tokenData = withUnsafeBytes(of: &token) { Data($0) }
        let attributes = [kSecGuestAttributeAudit: tokenData] as CFDictionary
        var code: SecCode?
        let status = SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(), &code)
        guard status == errSecSuccess, let code else { throw LocalIPCError.peerCodeUnavailable(status) }
        let summary = try validate(code: code, policy: policy)
        if !policy.expectedCodePaths.isEmpty {
            var url: CFURL?
            let pathStatus = SecCodeCopyPath(unsafeBitCast(code, to: SecStaticCode.self), SecCSFlags(), &url)
            guard pathStatus == errSecSuccess,
                  let observed = (url as URL?).map(CodeIdentityVerifier.canonicalPath),
                  policy.expectedCodePaths.map({ canonicalPath(URL(fileURLWithPath: $0)) }).contains(observed)
            else { throw LocalIPCError.peerPathMismatch }
        }
        return VerifiedPeer(
            identifier: summary.identifier,
            teamIdentifier: summary.team,
            // audit_token_t.val[5] is the pid (audit_token_to_pid lives in libbsm).
            processIdentifier: pid_t(bitPattern: auditToken.val.5)
        )
    }

    struct SigningSummary {
        var identifier: String
        var team: String?
    }

    static func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    static func validate(code: SecCode, policy: CodeIdentityPolicy) throws -> SigningSummary {
        var requirement: SecRequirement?
        var status = SecRequirementCreateWithString(policy.requirement as CFString, SecCSFlags(), &requirement)
        guard status == errSecSuccess, let requirement else { throw LocalIPCError.invalidRequirement(status) }

        status = SecCodeCheckValidity(code, SecCSFlags(), requirement)
        guard status == errSecSuccess else { throw LocalIPCError.peerRequirementFailed(status) }

        var information: CFDictionary?
        status = SecCodeCopySigningInformation(unsafeBitCast(code, to: SecStaticCode.self), infoFlags, &information)
        guard status == errSecSuccess, let info = information as? [String: Any] else {
            throw LocalIPCError.peerSigningInfoUnavailable(status)
        }
        guard let identifier = info[kSecCodeInfoIdentifier as String] as? String else {
            throw LocalIPCError.peerSignatureInvalid
        }
        let dynamicStatus = (info[kSecCodeInfoStatus as String] as? NSNumber)?.uint32Value ?? 0
        guard dynamicStatus & statusValid != 0 else { throw LocalIPCError.peerSignatureInvalid }
        guard dynamicStatus & statusDebugged == 0 else { throw LocalIPCError.peerDebugged }
        if policy.requireHardenedRuntime {
            let staticFlags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
            guard staticFlags & flagRuntime != 0 else { throw LocalIPCError.peerNotHardened }
        }
        let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
        try check(entitlements: entitlements, policy: policy)
        return SigningSummary(identifier: identifier, team: info[kSecCodeInfoTeamIdentifier as String] as? String)
    }

    /// Any value other than an explicit `false` for a forbidden key is rejected.
    static func check(entitlements: [String: Any], policy: CodeIdentityPolicy) throws {
        for key in policy.forbiddenEntitlements {
            if let value = entitlements[key], (value as? Bool) != false {
                throw LocalIPCError.peerEntitlementForbidden(key)
            }
        }
        for key in policy.requiredTrueEntitlements where (entitlements[key] as? Bool) != true {
            throw LocalIPCError.peerEntitlementMissing(key)
        }
    }

    /// Same-user check plus code identity, performed before any byte is read or written.
    public static func authenticate(_ fd: Int32, policy: CodeIdentityPolicy) throws -> VerifiedPeer {
        guard try LocalSocket.peerUserID(fd) == getuid() else { throw LocalIPCError.peerUserMismatch }
        return try verify(auditToken: LocalSocket.peerAuditToken(fd), policy: policy)
    }
}
