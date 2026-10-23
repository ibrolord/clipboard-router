// Bridge <-> app broker wire contract (v1). One JSON document per length-prefixed frame.
// There is deliberately no operation that addresses a Vault item by identifier.

import Foundation
import Security

public enum BrokerProtocol {
    public static let version = 1
    public static let maxDisplayNameScalars = 64
    public static let maxPurposeScalars = 280
    public static let maxClipIDBytes = 64
    public static let maxListLimit = 100
    /// Largest clip/Vault text released in one response; larger items are refused, never
    /// truncated or flattened.
    public static let maxContentBytes = 128 * 1024

    public static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    public static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        try JSONDecoder().decode(type, from: data)
    }

    /// Model- or client-supplied text is display-only: strip controls and bidi overrides,
    /// collapse whitespace, cap length. Never used for authentication or authorization.
    public static func sanitizedDisplayText(_ raw: String?, maxScalars: Int, fallback: String) -> String {
        let scalars = (raw ?? "").unicodeScalars.map { scalar -> Unicode.Scalar in
            CharacterSet.whitespacesAndNewlines.contains(scalar) ? " " : scalar
        }.filter { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
                && !(0x200B...0x200F).contains(scalar.value)
                && !(0x202A...0x202E).contains(scalar.value)
                && !(0x2066...0x2069).contains(scalar.value)
                && scalar.value != 0xFEFF
        }
        let collapsed = String(String.UnicodeScalarView(scalars))
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        let capped = String(String.UnicodeScalarView(collapsed.unicodeScalars.prefix(maxScalars)))
        return capped.isEmpty ? fallback : capped
    }

    public static func sanitizedDisplayName(_ raw: String?) -> String {
        sanitizedDisplayText(raw, maxScalars: maxDisplayNameScalars, fallback: "Unnamed client")
    }

    public static func sanitizedPurpose(_ raw: String?) -> String {
        sanitizedDisplayText(raw, maxScalars: maxPurposeScalars, fallback: "No purpose given")
    }

    static func randomBytes(_ count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "secure random unavailable")
        return bytes
    }

    /// 128-bit server-generated session identifier.
    public static func makeSessionID() -> String {
        randomBytes(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Six-digit code shown by both the bridge (stderr and tool result) and the app so the
    /// user can match the request they approve. Rejection sampling avoids modulo bias.
    public static func makePairingCode() -> String {
        while true {
            let value = randomBytes(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            if value < 4_294_000_000 {
                return String(format: "%06u", value % 1_000_000)
            }
        }
    }

    public static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices {
            difference |= left[index] ^ right[index]
        }
        return difference == 0
    }
}

public enum SessionState: String, Codable, Sendable, Equatable {
    case pendingApproval
    case approved
    case denied
    case expired
    case revoked

    public var isTerminal: Bool { self == .denied || self == .expired || self == .revoked }
}

public struct BridgeHello: Codable, Sendable, Equatable {
    public var protocolVersion: Int
    /// Display-only, unverified (typically the MCP client's self-reported name).
    public var clientDisplayName: String?

    public init(protocolVersion: Int = BrokerProtocol.version, clientDisplayName: String?) {
        self.protocolVersion = protocolVersion
        self.clientDisplayName = clientDisplayName
    }
}

public struct BrokerHelloReply: Codable, Sendable, Equatable {
    public var protocolVersion: Int
    public var sessionID: String
    public var pairingCode: String
    public var state: SessionState
    public var limits: TransportLimits
}

public enum BrokerOperation: Codable, Sendable, Equatable {
    /// Waits until the user approves/denies this connection in the app, or it expires.
    case awaitPairing
    /// Minimal metadata for saved clips inside the user's current agent scope.
    case listSharedClips(limit: Int)
    /// Text of one in-scope saved clip. Out-of-scope and nonexistent IDs are indistinguishable.
    case getSharedClip(id: String)
    /// Asks the user to pick and approve one Vault text/URL item in the app. The purpose is
    /// shown to the user verbatim (sanitized) and is not trusted.
    case requestVaultItem(purpose: String)
    /// Snapshot readiness and sync/projection state, without counts.
    case syncStatus
}

public struct BrokerRequest: Codable, Sendable, Equatable {
    public var sessionID: String
    public var requestID: UInt32
    public var operation: BrokerOperation

    public init(sessionID: String, requestID: UInt32, operation: BrokerOperation) {
        self.sessionID = sessionID
        self.requestID = requestID
        self.operation = operation
    }
}

public enum BrokerErrorCode: String, Codable, Sendable, Equatable, Error {
    case notApproved
    case accessDisabled
    case sessionMismatch
    case requestLimitExceeded
    case malformedRequest
    case invalidArgument
    case notFound
    case contentTooLarge
    case vaultRequestDenied
    case vaultRequestExpired
    case vaultRequestCancelled
    case vaultRequestBusy
    case unavailable
}

public enum SharedContentKind: String, Codable, Sendable, Equatable {
    case text
    case url
}

public struct SharedClipSummary: Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var kind: SharedContentKind
    public var byteCount: Int
    public var modifiedAtEpochSeconds: Int64

    public init(id: String, title: String, kind: SharedContentKind, byteCount: Int, modifiedAtEpochSeconds: Int64) {
        self.id = id
        self.title = title
        self.kind = kind
        self.byteCount = byteCount
        self.modifiedAtEpochSeconds = modifiedAtEpochSeconds
    }
}

public struct SharedClipContent: Codable, Sendable, Equatable {
    public var id: String
    public var kind: SharedContentKind
    public var text: String

    public init(id: String, kind: SharedContentKind, text: String) {
        self.id = id
        self.kind = kind
        self.text = text
    }
}

/// The one item the user picked and approved. Carries no Vault identifier or name.
public struct VaultHandoff: Codable, Sendable, Equatable {
    public var kind: SharedContentKind
    public var text: String

    public init(kind: SharedContentKind, text: String) {
        self.kind = kind
        self.text = text
    }
}

public struct SyncStatusReport: Codable, Sendable, Equatable {
    public enum Sync: String, Codable, Sendable {
        case disabled, idle, syncing, offline, accountUnavailable, failed
    }

    public enum Projection: String, Codable, Sendable {
        /// No remote projection has been applied since launch; local data is still served.
        case notAppliedThisLaunch
        case applied
        case failed
    }

    /// The app has loaded its committed local library snapshot.
    public var snapshotReady: Bool
    public var sync: Sync
    public var lastProjection: Projection
    public var lastProjectionAtEpochSeconds: Int64?

    public init(snapshotReady: Bool, sync: Sync, lastProjection: Projection, lastProjectionAtEpochSeconds: Int64?) {
        self.snapshotReady = snapshotReady
        self.sync = sync
        self.lastProjection = lastProjection
        self.lastProjectionAtEpochSeconds = lastProjectionAtEpochSeconds
    }
}

public enum BrokerResult: Codable, Sendable, Equatable {
    case sessionState(SessionState)
    case sharedClips([SharedClipSummary])
    case sharedClip(SharedClipContent)
    case vaultItem(VaultHandoff)
    case syncStatus(SyncStatusReport)
    case failure(BrokerErrorCode)

    /// True when the result carries user content and therefore crosses the disclosure
    /// linearization point.
    public var carriesContent: Bool {
        switch self {
        case .sharedClip, .vaultItem: true
        case let .sharedClips(list): !list.isEmpty
        default: false
        }
    }
}

public struct BrokerResponse: Codable, Sendable, Equatable {
    public var requestID: UInt32
    public var result: BrokerResult

    public init(requestID: UInt32, result: BrokerResult) {
        self.requestID = requestID
        self.result = result
    }
}
