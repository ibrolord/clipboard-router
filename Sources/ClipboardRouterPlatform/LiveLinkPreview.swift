import Darwin
import Foundation
import ImageIO
import Network
import Security

public struct LiveLinkPreviewMetadata: Equatable, Sendable {
    public let sourceURL: URL
    public let title: String
    public let siteName: String?
    public let summary: String?
    public let imageData: Data?
    public let fetchedAt: Date

    public init(
        sourceURL: URL,
        title: String,
        siteName: String? = nil,
        summary: String? = nil,
        imageData: Data? = nil,
        fetchedAt: Date = Date()
    ) {
        self.sourceURL = sourceURL
        self.title = title
        self.siteName = siteName
        self.summary = summary
        self.imageData = imageData
        self.fetchedAt = fetchedAt
    }
}

public enum LiveLinkPreviewError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedScheme
    case embeddedCredentials
    case sensitiveQuery
    case missingHost
    case localNetworkAddress
    case addressResolutionFailed
    case tooManyRedirects
    case invalidRedirect
    case offline
    case timedOut
    case responseTooLarge(maximum: Int)
    case unsupportedContentType
    case httpStatus(Int)
    case invalidResponse
    case noMetadata

    public var errorDescription: String? {
        switch self {
        case .unsupportedScheme:
            "Live previews require an HTTPS link."
        case .embeddedCredentials:
            "Links containing a username or password cannot be previewed."
        case .sensitiveQuery:
            "Signed, login, reset, unsubscribe, and action links cannot be previewed. Open the stored link directly instead."
        case .missingHost:
            "This link has no valid host."
        case .localNetworkAddress:
            "Local, private, and link-local addresses cannot be previewed."
        case .addressResolutionFailed:
            "The website address could not be resolved."
        case .tooManyRedirects:
            "The website redirected too many times."
        case .invalidRedirect:
            "The website redirected to an unsafe or malformed address."
        case .offline:
            "You appear to be offline. The stored link is still available."
        case .timedOut:
            "The preview request timed out. The stored link is still available."
        case let .responseTooLarge(maximum):
            "The preview exceeded the \(ByteCountFormatter.string(fromByteCount: Int64(maximum), countStyle: .file)) safety limit."
        case .unsupportedContentType:
            "This address does not return a supported web page."
        case let .httpStatus(status):
            "The website returned HTTP \(status)."
        case .invalidResponse:
            "The website returned an unreadable preview response."
        case .noMetadata:
            "The page did not provide preview metadata."
        }
    }

    public var isBlocked: Bool {
        switch self {
        case .unsupportedScheme, .embeddedCredentials, .sensitiveQuery, .missingHost,
             .localNetworkAddress, .invalidRedirect:
            true
        default:
            false
        }
    }
}

public protocol LiveLinkPreviewFetching: Sendable {
    func preview(for url: URL, refresh: Bool) async throws -> LiveLinkPreviewMetadata
    func removeCachedPreview(for url: URL) async
    func clearCache() async
}

public protocol LiveLinkPreviewHostResolving: Sendable {
    /// Returns only numeric, publicly routable addresses. A mixed public/private
    /// DNS answer is rejected instead of silently discarding the private answer.
    func resolvePublicAddresses(_ host: String) async throws -> [String]
}

public protocol LiveLinkPreviewHTTPTransporting: Sendable {
    func fetch(
        _ request: URLRequest,
        maximumBytes: Int,
        resolvedAddresses: [String]
    ) async throws -> LiveLinkPreviewHTTPResponse
}

/// Narrow seam used by the pinned HTTP transport. Production connects to a
/// numeric endpoint with Network.framework; tests can assert the exact endpoint,
/// TLS name, and serialized request without opening a socket.
public protocol LiveLinkPreviewPinnedConnecting: Sendable {
    func exchange(
        address: String,
        port: UInt16,
        tlsServerName: String,
        request: Data,
        maximumResponseBytes: Int,
        timeout: TimeInterval
    ) async throws -> Data
}

public struct LiveLinkPreviewHTTPResponse: Sendable {
    public let data: Data
    public let response: HTTPURLResponse

    public init(data: Data, response: HTTPURLResponse) {
        self.data = data
        self.response = response
    }
}

public struct LiveLinkPreviewURLPolicy: Sendable {
    public init() {}

    public func validated(_ url: URL) throws -> URL {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              components.scheme?.lowercased() == "https"
        else { throw LiveLinkPreviewError.unsupportedScheme }
        guard components.user == nil, components.password == nil else {
            throw LiveLinkPreviewError.embeddedCredentials
        }
        let sensitiveQueryTokens: Set<String> = [
            "action", "auth", "challenge", "code", "confirm", "confirmation",
            "credential", "key", "login", "magic", "otp", "passcode", "password",
            "reset", "secret", "sig", "signature", "token", "unsubscribe", "verify",
        ]
        if components.queryItems?.contains(where: {
            $0.name
                .lowercased(with: Locale(identifier: "en_US_POSIX"))
                .split(whereSeparator: { !$0.isLetter })
                .contains(where: { sensitiveQueryTokens.contains(String($0)) })
        }) == true {
            throw LiveLinkPreviewError.sensitiveQuery
        }
        let sensitivePathTokens: Set<String> = [
            "action", "actions", "activate", "activation", "auth", "authenticate",
            "authentication", "confirm", "confirmation", "login", "logout", "magic",
            "oauth", "password", "recover", "recovery", "reset", "signin", "signout",
            "token", "unsubscribe", "verify", "verification",
        ]
        let sensitiveCompoundSegments: Set<String> = [
            "confirmemail", "magiclink", "passwordreset", "resetpassword",
        ]
        let containsSensitivePath = components.percentEncodedPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .contains { rawSegment in
                let decoded = String(rawSegment).removingPercentEncoding ?? String(rawSegment)
                let lowered = decoded.lowercased(with: Locale(identifier: "en_US_POSIX"))
                let tokens = lowered.split(whereSeparator: { !$0.isLetter })
                if tokens.contains(where: { sensitivePathTokens.contains(String($0)) }) {
                    return true
                }
                return sensitiveCompoundSegments.contains(lowered.filter(\.isLetter))
            }
        if containsSensitivePath { throw LiveLinkPreviewError.sensitiveQuery }
        guard let rawHost = components.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawHost.isEmpty
        else { throw LiveLinkPreviewError.missingHost }

        let host = Self.unbracketedHost(rawHost)
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
        guard host != "localhost", !host.hasSuffix(".localhost"), !host.hasSuffix(".local") else {
            throw LiveLinkPreviewError.localNetworkAddress
        }
        if Self.isIPAddress(host), !Self.isPublicIPAddress(host) {
            throw LiveLinkPreviewError.localNetworkAddress
        }

        var normalized = components
        normalized.fragment = nil
        guard let result = normalized.url else { throw LiveLinkPreviewError.invalidResponse }
        return result
    }

    static func isIPAddress(_ host: String) -> Bool {
        var address4 = in_addr()
        var address6 = in6_addr()
        return host.withCString { inet_pton(AF_INET, $0, &address4) == 1 }
            || host.withCString { inet_pton(AF_INET6, $0, &address6) == 1 }
    }

    static func unbracketedHost(_ host: String) -> String {
        guard host.first == "[", host.last == "]" else { return host }
        return String(host.dropFirst().dropLast())
    }

    static func isPublicIPAddress(_ host: String) -> Bool {
        var address4 = in_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &address4) }) == 1 {
            return isPublicIPv4(address4)
        }
        var address6 = in6_addr()
        if host.withCString({ inet_pton(AF_INET6, $0, &address6) }) == 1 {
            return isPublicIPv6(address6)
        }
        return true
    }

    static func isPublicIPv4(_ address: in_addr) -> Bool {
        let value = UInt32(bigEndian: address.s_addr)
        let first = UInt8((value >> 24) & 0xff)
        let second = UInt8((value >> 16) & 0xff)
        let third = UInt8((value >> 8) & 0xff)
        if first == 0 || first == 10 || first == 127 || first >= 224 { return false }
        if first == 100, (64...127).contains(second) { return false }
        if first == 169, second == 254 { return false }
        if first == 172, (16...31).contains(second) { return false }
        if first == 192, second == 168 { return false }
        if first == 192, second == 0, third == 0 { return false }
        if first == 192, second == 0, third == 2 { return false }
        if first == 192, second == 88, third == 99 { return false }
        if first == 198, second == 18 || second == 19 { return false }
        if first == 198, second == 51, third == 100 { return false }
        if first == 203, second == 0, third == 113 { return false }
        return true
    }

    static func isPublicIPv6(_ address: in6_addr) -> Bool {
        let bytes = withUnsafeBytes(of: address) { Array($0) }
        guard bytes.count == 16 else { return false }
        if bytes.allSatisfy({ $0 == 0 }) { return false }
        if bytes.dropLast().allSatisfy({ $0 == 0 }), bytes.last == 1 { return false }
        if bytes.prefix(12).allSatisfy({ $0 == 0 }) { return false }
        if bytes[0...11].elementsEqual([0x00, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0]) {
            return false
        }
        if bytes[0...5].elementsEqual([0x00, 0x64, 0xff, 0x9b, 0x00, 0x01]) { return false }
        if bytes[0...7].elementsEqual([0x01, 0x00, 0, 0, 0, 0, 0, 0]) { return false }
        if bytes[0] & 0xfe == 0xfc { return false }
        if bytes[0] == 0xfe, bytes[1] & 0xc0 == 0x80 { return false }
        if bytes[0] == 0xfe, bytes[1] & 0xc0 == 0xc0 { return false }
        if bytes[0] == 0xff { return false }
        if bytes[0] == 0x20, bytes[1] == 0x01, bytes[2] == 0x0d, bytes[3] == 0xb8 {
            return false
        }
        if bytes[0] == 0x20, bytes[1] == 0x02 { return false }
        if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
            var mapped = in_addr()
            withUnsafeMutableBytes(of: &mapped) { destination in
                destination.copyBytes(from: bytes[12...15])
            }
            return isPublicIPv4(mapped)
        }
        return true
    }
}

public struct SystemLiveLinkPreviewHostResolver: LiveLinkPreviewHostResolving {
    public init() {}

    public func resolvePublicAddresses(_ host: String) async throws -> [String] {
        try await Task.detached(priority: .utility) {
            var hints = addrinfo(
                ai_flags: AI_ADDRCONFIG,
                ai_family: AF_UNSPEC,
                ai_socktype: SOCK_STREAM,
                ai_protocol: IPPROTO_TCP,
                ai_addrlen: 0,
                ai_canonname: nil,
                ai_addr: nil,
                ai_next: nil
            )
            var result: UnsafeMutablePointer<addrinfo>?
            let status = getaddrinfo(host, "443", &hints, &result)
            guard status == 0, let result else {
                throw LiveLinkPreviewError.addressResolutionFailed
            }
            defer { freeaddrinfo(result) }

            var cursor: UnsafeMutablePointer<addrinfo>? = result
            var addresses: [String] = []
            while let current = cursor {
                defer { cursor = current.pointee.ai_next }
                guard let socketAddress = current.pointee.ai_addr else { continue }
                switch Int32(current.pointee.ai_family) {
                case AF_INET:
                    let address = socketAddress.withMemoryRebound(
                        to: sockaddr_in.self,
                        capacity: 1
                    ) { $0.pointee.sin_addr }
                    guard LiveLinkPreviewURLPolicy.isPublicIPv4(address) else {
                        throw LiveLinkPreviewError.localNetworkAddress
                    }
                    var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    guard inet_ntop(AF_INET, [address], &buffer, socklen_t(buffer.count)) != nil else {
                        throw LiveLinkPreviewError.addressResolutionFailed
                    }
                    addresses.append(Self.string(from: buffer))
                case AF_INET6:
                    let address = socketAddress.withMemoryRebound(
                        to: sockaddr_in6.self,
                        capacity: 1
                    ) { $0.pointee.sin6_addr }
                    guard LiveLinkPreviewURLPolicy.isPublicIPv6(address) else {
                        throw LiveLinkPreviewError.localNetworkAddress
                    }
                    var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                    guard inet_ntop(AF_INET6, [address], &buffer, socklen_t(buffer.count)) != nil else {
                        throw LiveLinkPreviewError.addressResolutionFailed
                    }
                    addresses.append(Self.string(from: buffer))
                default:
                    break
                }
            }
            let unique = Array(Set(addresses)).sorted()
            guard !unique.isEmpty else { throw LiveLinkPreviewError.addressResolutionFailed }
            return unique
        }.value
    }

    private static func string(from buffer: [CChar]) -> String {
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

public final class BoundedLiveLinkPreviewHTTPTransport: LiveLinkPreviewHTTPTransporting,
    @unchecked Sendable
{
    public static let requestTimeout: TimeInterval = 8
    public static let resourceTimeout: TimeInterval = 12
    static let maximumHeaderBytes = 32 * 1_024
    static let maximumChunkOverheadBytes = 64 * 1_024

    private let connector: any LiveLinkPreviewPinnedConnecting

    public init(connector: any LiveLinkPreviewPinnedConnecting = NetworkLiveLinkPreviewConnector()) {
        self.connector = connector
    }

    public func fetch(
        _ request: URLRequest,
        maximumBytes: Int,
        resolvedAddresses: [String]
    ) async throws -> LiveLinkPreviewHTTPResponse {
        try Task.checkCancellation()
        guard request.httpMethod == nil || request.httpMethod == "GET",
              request.httpBody == nil,
              let url = request.url,
              let rawHost = url.host,
              !resolvedAddresses.isEmpty
        else { throw LiveLinkPreviewError.invalidResponse }
        let host = LiveLinkPreviewURLPolicy.unbracketedHost(rawHost)
        let portValue = url.port ?? 443
        guard (1...65_535).contains(portValue) else {
            throw LiveLinkPreviewError.invalidResponse
        }

        let serialized = try Self.serializedRequest(request, host: host, port: portValue)
        let wireMaximum = maximumBytes + Self.maximumHeaderBytes + Self.maximumChunkOverheadBytes
        var lastError: (any Error)?
        let deadline = Date().addingTimeInterval(Self.resourceTimeout)
        for address in resolvedAddresses.prefix(4) {
            try Task.checkCancellation()
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw LiveLinkPreviewError.timedOut }
            do {
                let raw = try await connector.exchange(
                    address: address,
                    port: UInt16(portValue),
                    tlsServerName: host,
                    request: serialized,
                    maximumResponseBytes: wireMaximum,
                    timeout: min(Self.requestTimeout, remaining)
                )
                return try Self.decodeResponse(raw, url: url, maximumBodyBytes: maximumBytes)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as LiveLinkPreviewError where error == .timedOut {
                lastError = error
            } catch {
                lastError = error
            }
        }
        throw lastError ?? LiveLinkPreviewError.offline
    }

    private static func serializedRequest(_ request: URLRequest, host: String, port: Int) throws -> Data {
        guard let url = request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { throw LiveLinkPreviewError.invalidResponse }
        let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        let target = components.percentEncodedQuery.map { "\(path)?\($0)" } ?? path
        let headerHost = host.contains(":") ? "[\(host)]" : host
        let hostHeader = port == 443 ? headerHost : "\(headerHost):\(port)"
        // Deliberately omit Authorization, Cookie, Referer, and all caller-supplied
        // headers except the two inert content-negotiation fields above.
        let value = "GET \(target) HTTP/1.1\r\n"
            + "Host: \(hostHeader)\r\n"
            + "Accept: text/html,application/xhtml+xml,image/*;q=0.8\r\n"
            + "Accept-Encoding: identity\r\n"
            + "User-Agent: ClipboardRouter/0.1 LinkPreview\r\n"
            + "Connection: close\r\n\r\n"
        guard let data = value.data(using: String.Encoding.utf8), data.count <= 8 * 1_024 else {
            throw LiveLinkPreviewError.invalidResponse
        }
        return data
    }

    private static func decodeResponse(
        _ raw: Data,
        url: URL,
        maximumBodyBytes: Int
    ) throws -> LiveLinkPreviewHTTPResponse {
        let separator = Data("\r\n\r\n".utf8)
        guard let boundary = raw.range(of: separator), boundary.lowerBound <= maximumHeaderBytes else {
            throw LiveLinkPreviewError.invalidResponse
        }
        let headerData = raw[..<boundary.lowerBound]
        guard let headerText = String(data: headerData, encoding: .isoLatin1) else {
            throw LiveLinkPreviewError.invalidResponse
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { throw LiveLinkPreviewError.invalidResponse }
        let statusParts = statusLine.split(separator: " ", maxSplits: 2)
        guard statusParts.count >= 2,
              statusParts[0] == "HTTP/1.1" || statusParts[0] == "HTTP/1.0",
              let status = Int(statusParts[1]), (100...599).contains(status)
        else { throw LiveLinkPreviewError.invalidResponse }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard !line.isEmpty, line.utf8.count <= 8 * 1_024,
                  line.first != " ", line.first != "\t",
                  let colon = line.firstIndex(of: ":")
            else { throw LiveLinkPreviewError.invalidResponse }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, headers.count < 64 else {
                throw LiveLinkPreviewError.invalidResponse
            }
            let key = name.lowercased(with: Locale(identifier: "en_US_POSIX"))
            if key == "set-cookie" { continue }
            if let existing = headers[key] { headers[key] = existing + "," + value }
            else { headers[key] = value }
        }

        let wireBody = Data(raw[boundary.upperBound...])
        let body: Data
        if let transferEncoding = headers["transfer-encoding"]?.lowercased() {
            guard transferEncoding.split(separator: ",").last?.trimmingCharacters(in: .whitespaces) == "chunked" else {
                throw LiveLinkPreviewError.invalidResponse
            }
            body = try decodeChunkedBody(wireBody, maximumBytes: maximumBodyBytes)
        } else if let rawLength = headers["content-length"] {
            let values = rawLength.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard let first = values.first, values.allSatisfy({ $0 == first }),
                  let length = Int(first), length >= 0
            else { throw LiveLinkPreviewError.invalidResponse }
            guard length <= maximumBodyBytes else {
                throw LiveLinkPreviewError.responseTooLarge(maximum: maximumBodyBytes)
            }
            guard wireBody.count == length else { throw LiveLinkPreviewError.invalidResponse }
            body = wireBody
        } else {
            guard wireBody.count <= maximumBodyBytes else {
                throw LiveLinkPreviewError.responseTooLarge(maximum: maximumBodyBytes)
            }
            body = wireBody
        }
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: String(statusParts[0]),
            headerFields: headers
        ) else { throw LiveLinkPreviewError.invalidResponse }
        return LiveLinkPreviewHTTPResponse(data: body, response: response)
    }

    private static func decodeChunkedBody(_ wire: Data, maximumBytes: Int) throws -> Data {
        let crlf = Data("\r\n".utf8)
        var cursor = wire.startIndex
        var output = Data()
        while true {
            guard let lineRange = wire[cursor...].range(of: crlf),
                  lineRange.lowerBound - cursor <= 128
            else { throw LiveLinkPreviewError.invalidResponse }
            guard let line = String(data: wire[cursor..<lineRange.lowerBound], encoding: .ascii),
                  let rawSize = line.split(separator: ";", maxSplits: 1).first,
                  let size = Int(rawSize.trimmingCharacters(in: .whitespaces), radix: 16),
                  size >= 0
            else { throw LiveLinkPreviewError.invalidResponse }
            cursor = lineRange.upperBound
            if size == 0 {
                // Allow no trailers or bounded RFC-style trailers, but require the
                // terminating CRLF and reject bytes after the message.
                guard let trailerEnd = wire[cursor...].range(of: Data("\r\n\r\n".utf8))
                        ?? (wire[cursor...].starts(with: crlf) ? cursor..<cursor + 2 : nil),
                      trailerEnd.upperBound == wire.endIndex
                else { throw LiveLinkPreviewError.invalidResponse }
                return output
            }
            guard size <= maximumBytes - output.count,
                  cursor <= wire.endIndex - size,
                  cursor + size + 2 <= wire.endIndex,
                  wire[(cursor + size)..<(cursor + size + 2)] == crlf
            else {
                if size > maximumBytes - output.count {
                    throw LiveLinkPreviewError.responseTooLarge(maximum: maximumBytes)
                }
                throw LiveLinkPreviewError.invalidResponse
            }
            output.append(wire[cursor..<(cursor + size)])
            cursor += size + 2
        }
    }
}

public struct NetworkLiveLinkPreviewConnector: LiveLinkPreviewPinnedConnecting {
    private static let trustQueue = DispatchQueue(
        label: "ClipboardRouter.LiveLinkPreview.Trust",
        qos: .utility
    )

    public init() {}

    public func exchange(
        address: String,
        port: UInt16,
        tlsServerName: String,
        request: Data,
        maximumResponseBytes: Int,
        timeout: TimeInterval
    ) async throws -> Data {
        guard LiveLinkPreviewURLPolicy.isIPAddress(address),
              LiveLinkPreviewURLPolicy.isPublicIPAddress(address),
              let nwPort = NWEndpoint.Port(rawValue: port)
        else { throw LiveLinkPreviewError.localNetworkAddress }

        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, tlsServerName)
        sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
        sec_protocol_options_set_verify_block(
            tls.securityProtocolOptions,
            { _, trust, complete in
                let trustReference = sec_trust_copy_ref(trust).takeRetainedValue()
                let hostnamePolicy = SecPolicyCreateSSL(true, tlsServerName as CFString)
                guard SecTrustSetPolicies(trustReference, hostnamePolicy) == errSecSuccess else {
                    complete(false)
                    return
                }
                complete(SecTrustEvaluateWithError(trustReference, nil))
            },
            Self.trustQueue
        )
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.includePeerToPeer = false
        let connection = NWConnection(
            host: NWEndpoint.Host(address),
            port: nwPort,
            using: parameters
        )
        let operation = PinnedNetworkExchangeOperation(
            connection: connection,
            request: request,
            maximumBytes: maximumResponseBytes,
            timeout: timeout
        )
        return try await withTaskCancellationHandler {
            try await operation.perform()
        } onCancel: {
            operation.cancel()
        }
    }
}

private final class PinnedNetworkExchangeOperation: @unchecked Sendable {
    private let connection: NWConnection
    private let request: Data
    private let maximumBytes: Int
    private let timeout: TimeInterval
    private let queue = DispatchQueue(label: "ClipboardRouter.LiveLinkPreview.PinnedConnection")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, any Error>?
    private var timeoutWork: DispatchWorkItem?
    private var received = Data()
    private var isFinished = false

    init(connection: NWConnection, request: Data, maximumBytes: Int, timeout: TimeInterval) {
        self.connection = connection
        self.request = request
        self.maximumBytes = max(1, maximumBytes)
        self.timeout = max(0.1, timeout)
    }

    func perform() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            guard !isFinished else {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                return
            }
            self.continuation = continuation
            lock.unlock()
            queue.async { [self] in
                connection.stateUpdateHandler = { [weak self] state in self?.handle(state) }
                let timeoutWork = DispatchWorkItem { [weak self] in
                    self?.finish(.failure(LiveLinkPreviewError.timedOut))
                }
                lock.lock()
                self.timeoutWork = timeoutWork
                lock.unlock()
                queue.asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
                connection.start(queue: queue)
            }
        }
    }

    func cancel() { finish(.failure(CancellationError())) }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            connection.send(content: request, completion: .contentProcessed { [weak self] error in
                if let error { self?.finish(.failure(Self.map(error))) }
                else { self?.receive() }
            })
        case let .failed(error):
            finish(.failure(Self.map(error)))
        case .cancelled:
            finish(.failure(CancellationError()))
        default:
            break
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1_024) {
            [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                guard received.count <= maximumBytes - data.count else {
                    finish(.failure(LiveLinkPreviewError.responseTooLarge(maximum: maximumBytes)))
                    return
                }
                received.append(data)
            }
            if let error {
                finish(.failure(Self.map(error)))
            } else if complete {
                finish(.success(received))
            } else {
                receive()
            }
        }
    }

    private func finish(_ result: Result<Data, any Error>) {
        lock.lock()
        guard !isFinished else { lock.unlock(); return }
        isFinished = true
        let continuation = continuation
        self.continuation = nil
        let timeoutWork = timeoutWork
        self.timeoutWork = nil
        lock.unlock()
        timeoutWork?.cancel()
        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation?.resume(with: result)
    }

    private static func map(_ error: NWError) -> any Error {
        if case let .posix(code) = error, code == .ETIMEDOUT { return LiveLinkPreviewError.timedOut }
        return LiveLinkPreviewError.offline
    }
}

public actor MemoryLiveLinkPreviewCache {
    private struct Entry: Sendable {
        let metadata: LiveLinkPreviewMetadata
        var access: UInt64
        var byteCount: Int
    }

    private let maximumEntries: Int
    private let maximumBytes: Int
    private let timeToLive: TimeInterval
    private var entries: [String: Entry] = [:]
    private var accessCounter: UInt64 = 0
    private var byteCount = 0

    public init(
        maximumEntries: Int = 64,
        maximumBytes: Int = 8 * 1_024 * 1_024,
        timeToLive: TimeInterval = 24 * 60 * 60
    ) {
        self.maximumEntries = max(1, maximumEntries)
        self.maximumBytes = max(1, maximumBytes)
        self.timeToLive = max(1, timeToLive)
    }

    public func value(for url: URL, now: Date = Date()) -> LiveLinkPreviewMetadata? {
        let key = Self.key(for: url)
        guard var entry = entries[key] else { return nil }
        guard now.timeIntervalSince(entry.metadata.fetchedAt) <= timeToLive else {
            entries.removeValue(forKey: key)
            byteCount -= entry.byteCount
            return nil
        }
        accessCounter &+= 1
        entry.access = accessCounter
        entries[key] = entry
        return entry.metadata
    }

    public func insert(_ metadata: LiveLinkPreviewMetadata, for url: URL) {
        let key = Self.key(for: url)
        let size = metadata.title.utf8.count
            + (metadata.siteName?.utf8.count ?? 0)
            + (metadata.summary?.utf8.count ?? 0)
            + (metadata.imageData?.count ?? 0)
        guard size <= maximumBytes else { return }
        if let old = entries.removeValue(forKey: key) { byteCount -= old.byteCount }
        accessCounter &+= 1
        entries[key] = Entry(metadata: metadata, access: accessCounter, byteCount: size)
        byteCount += size
        evictIfNeeded()
    }

    public func clear() {
        entries.removeAll(keepingCapacity: false)
        byteCount = 0
        accessCounter = 0
    }

    public func remove(_ url: URL) {
        let key = Self.key(for: url)
        guard let removed = entries.removeValue(forKey: key) else { return }
        byteCount -= removed.byteCount
    }

    private func evictIfNeeded() {
        while entries.count > maximumEntries || byteCount > maximumBytes {
            guard let oldest = entries.min(by: { $0.value.access < $1.value.access }) else { break }
            entries.removeValue(forKey: oldest.key)
            byteCount -= oldest.value.byteCount
        }
    }

    private static func key(for url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            return url.absoluteString
        }
        components.scheme = components.scheme?
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
        components.host = components.host?
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
        return components.url?.absoluteString ?? url.absoluteString
    }
}

public final class LiveLinkPreviewClient: LiveLinkPreviewFetching, @unchecked Sendable {
    public static let maximumHTMLBytes = 256 * 1_024
    public static let maximumImageBytes = 1 * 1_024 * 1_024
    public static let maximumRedirects = 3

    private let policy: LiveLinkPreviewURLPolicy
    private let resolver: any LiveLinkPreviewHostResolving
    private let transport: any LiveLinkPreviewHTTPTransporting
    private let cache: MemoryLiveLinkPreviewCache
    private let now: @Sendable () -> Date

    public init(
        policy: LiveLinkPreviewURLPolicy = LiveLinkPreviewURLPolicy(),
        resolver: any LiveLinkPreviewHostResolving = SystemLiveLinkPreviewHostResolver(),
        transport: any LiveLinkPreviewHTTPTransporting = BoundedLiveLinkPreviewHTTPTransport(),
        cache: MemoryLiveLinkPreviewCache = MemoryLiveLinkPreviewCache(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.policy = policy
        self.resolver = resolver
        self.transport = transport
        self.cache = cache
        self.now = now
    }

    public func preview(for url: URL, refresh: Bool = false) async throws
        -> LiveLinkPreviewMetadata
    {
        let safeURL = try policy.validated(url)
        if !refresh, let cached = await cache.value(for: safeURL, now: now()) { return cached }

        let document = try await fetchFollowingRedirects(
            safeURL,
            maximumBytes: Self.maximumHTMLBytes
        )
        guard document.response.statusCode == 200 else {
            throw LiveLinkPreviewError.httpStatus(document.response.statusCode)
        }
        guard Self.isHTML(document.response) else {
            throw LiveLinkPreviewError.unsupportedContentType
        }
        let parsed = try LiveLinkPreviewHTMLParser.parse(document.data, baseURL: document.response.url ?? safeURL)

        let imageData: Data?
        if let imageURL = parsed.imageURL,
           Self.sameOrigin(imageURL, document.response.url ?? safeURL)
        {
            imageData = try? await fetchImage(imageURL)
        } else {
            imageData = nil
        }
        let metadata = LiveLinkPreviewMetadata(
            sourceURL: document.response.url ?? safeURL,
            title: parsed.title,
            siteName: parsed.siteName,
            summary: parsed.summary,
            imageData: imageData,
            fetchedAt: now()
        )
        await cache.insert(metadata, for: safeURL)
        return metadata
    }

    public func clearCache() async { await cache.clear() }

    public func removeCachedPreview(for url: URL) async { await cache.remove(url) }

    private func fetchImage(_ url: URL) async throws -> Data {
        let response = try await fetchFollowingRedirects(
            url,
            maximumBytes: Self.maximumImageBytes,
            allowRedirects: false
        )
        guard response.response.statusCode == 200 else {
            throw LiveLinkPreviewError.httpStatus(response.response.statusCode)
        }
        let mime = response.response.mimeType?.lowercased() ?? ""
        guard ["image/png", "image/jpeg", "image/heic", "image/heif", "image/tiff"]
            .contains(mime), Self.isSafeImage(response.data)
        else { throw LiveLinkPreviewError.unsupportedContentType }
        return response.data
    }

    private func fetchFollowingRedirects(
        _ initialURL: URL,
        maximumBytes: Int,
        allowRedirects: Bool = true
    ) async throws -> LiveLinkPreviewHTTPResponse {
        var currentURL = try policy.validated(initialURL)
        var visited = Set<String>()
        for redirectCount in 0...Self.maximumRedirects {
            try Task.checkCancellation()
            guard visited.insert(currentURL.absoluteString).inserted else {
                throw LiveLinkPreviewError.tooManyRedirects
            }
            guard let host = currentURL.host else { throw LiveLinkPreviewError.missingHost }
            let addresses = try await resolver.resolvePublicAddresses(
                LiveLinkPreviewURLPolicy.unbracketedHost(host)
            )
            guard !addresses.isEmpty else { throw LiveLinkPreviewError.addressResolutionFailed }

            var request = URLRequest(url: currentURL)
            request.httpMethod = "GET"
            request.setValue("text/html,application/xhtml+xml,image/*;q=0.8", forHTTPHeaderField: "Accept")
            request.setValue("ClipboardRouter/0.1 LinkPreview", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = BoundedLiveLinkPreviewHTTPTransport.requestTimeout
            let result = try await transport.fetch(
                request,
                maximumBytes: maximumBytes,
                resolvedAddresses: addresses
            )
            guard (300...399).contains(result.response.statusCode) else { return result }
            guard allowRedirects else { throw LiveLinkPreviewError.invalidRedirect }
            guard redirectCount < Self.maximumRedirects,
                  let location = result.response.value(forHTTPHeaderField: "Location"),
                  let nextURL = URL(string: location, relativeTo: currentURL)?.absoluteURL
            else {
                throw redirectCount >= Self.maximumRedirects
                    ? LiveLinkPreviewError.tooManyRedirects
                    : LiveLinkPreviewError.invalidRedirect
            }
            do {
                currentURL = try policy.validated(nextURL)
            } catch let error as LiveLinkPreviewError {
                throw error.isBlocked ? error : LiveLinkPreviewError.invalidRedirect
            }
        }
        throw LiveLinkPreviewError.tooManyRedirects
    }

    private static func isHTML(_ response: HTTPURLResponse) -> Bool {
        let mime = response.mimeType?.lowercased() ?? ""
        return mime == "text/html" || mime == "application/xhtml+xml"
    }

    private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && (lhs.port ?? 443) == (rhs.port ?? 443)
    }

    private static func isSafeImage(_ data: Data) -> Bool {
        guard !data.isEmpty,
              data.count <= maximumImageBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let type = CGImageSourceGetType(source) as String?,
              ["public.png", "public.jpeg", "public.heic", "public.heif", "public.tiff"].contains(type),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0, width <= 4_096, height <= 4_096
        else { return false }
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        return !overflow && pixels <= 16_000_000
    }
}

struct LiveLinkPreviewHTMLParser {
    struct Parsed: Equatable {
        let title: String
        let siteName: String?
        let summary: String?
        let imageURL: URL?
    }

    static func parse(_ data: Data, baseURL: URL) throws -> Parsed {
        guard data.count <= LiveLinkPreviewClient.maximumHTMLBytes,
              let html = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
        else { throw LiveLinkPreviewError.invalidResponse }

        let metadata = metaValues(in: html)
        let rawTitle = metadata["og:title"] ?? metadata["twitter:title"] ?? title(in: html)
        guard let rawTitle, let normalizedTitle = normalized(rawTitle, maximum: 200) else {
            throw LiveLinkPreviewError.noMetadata
        }
        let siteName = normalized(metadata["og:site_name"], maximum: 100)
        let summary = normalized(
            metadata["og:description"] ?? metadata["twitter:description"] ?? metadata["description"],
            maximum: 600
        )
        let rawImage = metadata["og:image:secure_url"]
            ?? metadata["og:image"]
            ?? metadata["twitter:image"]
        let imageURL = rawImage.flatMap { URL(string: decodeEntities($0), relativeTo: baseURL)?.absoluteURL }
        return Parsed(title: normalizedTitle, siteName: siteName, summary: summary, imageURL: imageURL)
    }

    private static func metaValues(in html: String) -> [String: String] {
        guard let tags = try? NSRegularExpression(pattern: "(?is)<meta\\s+[^>]*>") else { return [:] }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        var values: [String: String] = [:]
        tags.enumerateMatches(in: html, range: range) { match, _, _ in
            guard let match, let tagRange = Range(match.range, in: html) else { return }
            let attributes = attributes(in: String(html[tagRange]))
            guard let name = (attributes["property"] ?? attributes["name"])?
                .lowercased(with: Locale(identifier: "en_US_POSIX")),
                let content = attributes["content"], values[name] == nil
            else { return }
            values[name] = content
        }
        return values
    }

    private static func attributes(in tag: String) -> [String: String] {
        let pattern = #"([A-Za-z_:.-]+)\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s>]+))"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [:] }
        let range = NSRange(tag.startIndex..<tag.endIndex, in: tag)
        var result: [String: String] = [:]
        expression.enumerateMatches(in: tag, range: range) { match, _, _ in
            guard let match, let keyRange = Range(match.range(at: 1), in: tag) else { return }
            let value = (2...4).compactMap { index -> String? in
                let range = match.range(at: index)
                guard range.location != NSNotFound, let swiftRange = Range(range, in: tag) else { return nil }
                return String(tag[swiftRange])
            }.first ?? ""
            result[String(tag[keyRange]).lowercased()] = value
        }
        return result
    }

    private static func title(in html: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: "(?is)<title[^>]*>(.*?)</title>"),
              let match = expression.firstMatch(
                in: html,
                range: NSRange(html.startIndex..<html.endIndex, in: html)
              ),
              let range = Range(match.range(at: 1), in: html)
        else { return nil }
        return String(html[range])
    }

    private static func normalized(_ raw: String?, maximum: Int) -> String? {
        guard let raw else { return nil }
        let withoutTags = raw.replacingOccurrences(
            of: "<[^>]+>",
            with: " ",
            options: .regularExpression
        )
        let collapsed = decodeEntities(withoutTags)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(maximum))
    }

    private static func decodeEntities(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }
}
