import CryptoKit
import Foundation

/// Errors returned by the encrypted clipboard-share transport.
///
/// The cryptographic failure is intentionally shared by tampered ciphertext and a private key
/// for a different recipient. This prevents the receiver from becoming a recipient-oracle.
public enum SecureShareError: Error, Equatable, LocalizedError, Sendable {
    case malformedTransport
    case transportTooLarge
    case payloadTooLarge(Int)
    case unsupportedVersion(Int)
    case invalidEnvelope
    case authenticationFailed
    case replayDetected(UUID)
    case keyUnavailable

    public var errorDescription: String? {
        switch self {
        case .malformedTransport: "The share transport is malformed."
        case .transportTooLarge: "The share transport exceeds the permitted size."
        case let .payloadTooLarge(size): "The share payload exceeds the permitted size (\(size) bytes)."
        case let .unsupportedVersion(version): "The share envelope version \(version) is unsupported."
        case .invalidEnvelope: "The share envelope is invalid."
        case .authenticationFailed: "The share could not be authenticated for this recipient."
        case let .replayDetected(id): "The share envelope \(id) has already been accepted."
        case .keyUnavailable: "The recipient key is unavailable."
        }
    }
}

/// Supplies the recipient's Curve25519 key agreement key pair.
///
/// Key exchange is deliberately outside this module. The caller must obtain and authenticate
/// `recipientPublicKey()` out of band (for example, by comparing a separately authenticated
/// fingerprint). This API does not discover, authenticate, rotate, or transmit public keys.
public protocol SecureShareKeyProvider: Sendable {
    func recipientPublicKey() throws -> Curve25519.KeyAgreement.PublicKey
    func recipientPrivateKey() throws -> Curve25519.KeyAgreement.PrivateKey
}

/// A process-independent key provider useful for tests and local integrations.
///
/// Persist `rawPrivateKeyRepresentation` in a real protected key store when a recipient must
/// decrypt after relaunch. This provider intentionally has no persistence or key-exchange logic.
public struct InMemorySecureShareKeyProvider: SecureShareKeyProvider, Equatable, Sendable {
    private let privateKeyData: Data
    private let publicKeyData: Data

    public init() {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        self.privateKeyData = privateKey.rawRepresentation
        self.publicKeyData = privateKey.publicKey.rawRepresentation
    }

    public init(rawPrivateKeyRepresentation: Data) throws {
        guard rawPrivateKeyRepresentation.count == 32 else {
            throw SecureShareError.keyUnavailable
        }
        do {
            let privateKey = try Curve25519.KeyAgreement.PrivateKey(
                rawRepresentation: rawPrivateKeyRepresentation
            )
            self.privateKeyData = rawPrivateKeyRepresentation
            self.publicKeyData = privateKey.publicKey.rawRepresentation
        } catch {
            throw SecureShareError.keyUnavailable
        }
    }

    public var rawPrivateKeyRepresentation: Data { privateKeyData }

    public func recipientPublicKey() throws -> Curve25519.KeyAgreement.PublicKey {
        do {
            return try Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKeyData)
        } catch {
            throw SecureShareError.keyUnavailable
        }
    }

    public func recipientPrivateKey() throws -> Curve25519.KeyAgreement.PrivateKey {
        do {
            return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKeyData)
        } catch {
            throw SecureShareError.keyUnavailable
        }
    }
}

/// Atomic acceptance state for replay-like duplicate envelope IDs.
///
/// `reserve` is called before decryption, and `commit` only after successful authentication.
/// Failed ciphertexts are released so an attacker cannot permanently block an ID by submitting
/// a forged envelope first.
public protocol SecureShareReplayStore: Sendable {
    func reserve(_ id: UUID) async -> Bool
    func commit(_ id: UUID) async
    func release(_ id: UUID) async
}

/// An in-memory replay store. Use a durable, bounded implementation for a production receiver
/// whose accepted IDs must survive relaunch.
public actor InMemorySecureShareReplayStore: SecureShareReplayStore {
    private var reservedIDs: Set<UUID> = []
    private var committedIDs: Set<UUID> = []

    public init() {}

    public func reserve(_ id: UUID) -> Bool {
        guard !reservedIDs.contains(id), !committedIDs.contains(id) else { return false }
        reservedIDs.insert(id)
        return true
    }

    public func commit(_ id: UUID) {
        reservedIDs.remove(id)
        committedIDs.insert(id)
    }

    public func release(_ id: UUID) {
        reservedIDs.remove(id)
    }

    public func contains(_ id: UUID) -> Bool {
        committedIDs.contains(id)
    }

    public var count: Int { committedIDs.count }
}

/// A bounded replay store persisted in the app support directory. Envelope IDs are metadata,
/// not plaintext clip content, so keeping them on disk prevents an accepted share from being
/// replayed after relaunch without expanding the transport's trust model.
public actor FileSecureShareReplayStore: SecureShareReplayStore {
    private let fileURL: URL
    private let maximumIDs: Int
    private var loaded = false
    private var unavailable = false
    private var reservedIDs: Set<UUID> = []
    private var committedIDs: [UUID] = []

    public init(fileURL: URL, maximumIDs: Int = 4_096) {
        self.fileURL = fileURL
        self.maximumIDs = max(1, maximumIDs)
    }

    public func reserve(_ id: UUID) -> Bool {
        guard loadIfNeeded(),
              !reservedIDs.contains(id),
              !committedIDs.contains(id)
        else { return false }
        reservedIDs.insert(id)
        return true
    }

    public func commit(_ id: UUID) {
        guard loadIfNeeded() else { return }
        reservedIDs.remove(id)
        committedIDs.removeAll { $0 == id }
        committedIDs.append(id)
        if committedIDs.count > maximumIDs {
            committedIDs.removeFirst(committedIDs.count - maximumIDs)
        }
        // Keep the ID reserved in memory if the durable write fails. A later replay in this
        // process must still fail closed even though a future relaunch cannot use this record.
        if !persist() { reservedIDs.insert(id) }
    }

    public func release(_ id: UUID) {
        guard loadIfNeeded() else { return }
        reservedIDs.remove(id)
    }

    private func loadIfNeeded() -> Bool {
        guard !loaded else { return !unavailable }
        loaded = true
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return true }
        do {
            let data = try Data(contentsOf: fileURL)
            let ids = try JSONDecoder().decode([UUID].self, from: data)
            guard ids.count <= maximumIDs,
                  Set(ids).count == ids.count
            else {
                unavailable = true
                return false
            }
            committedIDs = ids
            return true
        } catch {
            unavailable = true
            return false
        }
    }

    private func persist() -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(committedIDs)
            try data.write(to: fileURL, options: [.atomic])
            return true
        } catch {
            return false
        }
    }
}

/// Versioned, authenticated encrypted data intended for transport through a clipboard or text
/// channel. The clear envelope contains only routing metadata and ciphertext; payload bytes are
/// never placed in logs or clear transport fields.
public struct SecureShareEnvelope: Codable, Equatable, Identifiable, Sendable {
    public static let currentVersion = 1
    public static let maximumPayloadBytes = 1 * 1_024 * 1_024
    public static let maximumTransportCharacters = 1_500_000

    public let id: UUID
    public let version: Int
    /// An ephemeral X25519 public key. It is not a long-term sender identity.
    public let ephemeralPublicKey: Data
    public let nonce: Data
    public let ciphertext: Data
    public let tag: Data

    public init(
        id: UUID,
        version: Int = currentVersion,
        ephemeralPublicKey: Data,
        nonce: Data,
        ciphertext: Data,
        tag: Data
    ) {
        self.id = id
        self.version = version
        self.ephemeralPublicKey = ephemeralPublicKey
        self.nonce = nonce
        self.ciphertext = ciphertext
        self.tag = tag
    }

    /// Encrypts bytes to an already authenticated recipient public key.
    ///
    /// Public-key authentication and exchange are intentionally caller responsibilities. The
    /// returned envelope can be moved between processes and opened with the matching private key.
    public static func seal(
        _ plaintext: Data,
        for recipientPublicKey: Curve25519.KeyAgreement.PublicKey,
        id: UUID = UUID()
    ) throws -> SecureShareEnvelope {
        guard plaintext.count <= maximumPayloadBytes else {
            throw SecureShareError.payloadTooLarge(plaintext.count)
        }

        let ephemeralPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        let ephemeralPublicKey = ephemeralPrivateKey.publicKey.rawRepresentation
        let aad = authenticatedData(
            version: currentVersion,
            id: id,
            ephemeralPublicKey: ephemeralPublicKey,
            recipientPublicKey: recipientPublicKey.rawRepresentation
        )
        do {
            let sharedSecret = try ephemeralPrivateKey.sharedSecretFromKeyAgreement(
                with: recipientPublicKey
            )
            let key = derivedKey(sharedSecret: sharedSecret, authenticatedData: aad)
            let nonce = AES.GCM.Nonce()
            let sealed = try AES.GCM.seal(
                plaintext,
                using: key,
                nonce: nonce,
                authenticating: aad
            )
            return SecureShareEnvelope(
                id: id,
                ephemeralPublicKey: ephemeralPublicKey,
                nonce: Data(nonce),
                ciphertext: sealed.ciphertext,
                tag: sealed.tag
            )
        } catch let error as SecureShareError {
            throw error
        } catch {
            throw SecureShareError.authenticationFailed
        }
    }

    /// Returns canonical standard Base64 of canonical sorted-key JSON.
    public func transportString() throws -> String {
        try validate()
        let wireData: Data
        do {
            wireData = try Self.encoder.encode(self)
        } catch {
            throw SecureShareError.malformedTransport
        }
        let transport = wireData.base64EncodedString()
        guard transport.utf8.count <= Self.maximumTransportCharacters else {
            throw SecureShareError.transportTooLarge
        }
        return transport
    }

    /// Decodes and validates canonical standard Base64 transport.
    public static func decodeTransport(_ transport: String) throws -> SecureShareEnvelope {
        guard transport.utf8.count <= maximumTransportCharacters else {
            throw SecureShareError.transportTooLarge
        }
        guard !transport.isEmpty,
              transport.utf8.allSatisfy({ byte in
                  byte == 61 || byte == 43 || byte == 47
                      || (byte >= 48 && byte <= 57)
                      || (byte >= 65 && byte <= 90)
                      || (byte >= 97 && byte <= 122)
              }),
              transport.count.isMultiple(of: 4),
              let wireData = Data(base64Encoded: transport, options: []),
              wireData.base64EncodedString() == transport
        else { throw SecureShareError.malformedTransport }

        do {
            let envelope = try decoder.decode(SecureShareEnvelope.self, from: wireData)
            guard try encoder.encode(envelope) == wireData else {
                throw SecureShareError.malformedTransport
            }
            try envelope.validate()
            return envelope
        } catch let error as SecureShareError {
            throw error
        } catch {
            throw SecureShareError.malformedTransport
        }
    }

    /// Validates the bounded wire shape before any key operation occurs.
    public func validate() throws {
        guard version == Self.currentVersion else {
            throw SecureShareError.unsupportedVersion(version)
        }
        guard ephemeralPublicKey.count == 32,
              nonce.count == 12,
              tag.count == 16,
              ciphertext.count <= Self.maximumPayloadBytes
        else { throw SecureShareError.invalidEnvelope }
    }

    /// Decrypts and authenticates an envelope with the matching recipient private key.
    public func open(using privateKey: Curve25519.KeyAgreement.PrivateKey) throws -> Data {
        try validate()
        do {
            let ephemeralPublicKey = try Curve25519.KeyAgreement.PublicKey(
                rawRepresentation: self.ephemeralPublicKey
            )
            let aad = Self.authenticatedData(
                version: version,
                id: id,
                ephemeralPublicKey: self.ephemeralPublicKey,
                recipientPublicKey: privateKey.publicKey.rawRepresentation
            )
            let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: ephemeralPublicKey)
            let key = Self.derivedKey(sharedSecret: sharedSecret, authenticatedData: aad)
            let nonce = try AES.GCM.Nonce(data: nonce)
            let box = try AES.GCM.SealedBox(
                nonce: nonce,
                ciphertext: ciphertext,
                tag: tag
            )
            let plaintext = try AES.GCM.open(box, using: key, authenticating: aad)
            guard plaintext.count <= Self.maximumPayloadBytes else {
                throw SecureShareError.payloadTooLarge(plaintext.count)
            }
            return plaintext
        } catch let error as SecureShareError {
            throw error
        } catch {
            // Do not distinguish tampering from a key belonging to another recipient.
            throw SecureShareError.authenticationFailed
        }
    }

    private static func authenticatedData(
        version: Int,
        id: UUID,
        ephemeralPublicKey: Data,
        recipientPublicKey: Data
    ) -> Data {
        Data(
            "clipboard-router:secure-share:\(version):\(id.uuidString.lowercased()):".utf8
        ) + ephemeralPublicKey + recipientPublicKey
    }

    private static func derivedKey(
        sharedSecret: SharedSecret,
        authenticatedData: Data
    ) -> SymmetricKey {
        sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("clipboard-router:secure-share:hkdf:v1".utf8),
            sharedInfo: authenticatedData,
            outputByteCount: 32
        )
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static let decoder = JSONDecoder()
}

/// A receiving endpoint that performs transport validation, key agreement, authentication, and
/// atomic replay protection. It intentionally returns only plaintext bytes to its caller.
public actor SecureShareReceiver {
    private let keyProvider: any SecureShareKeyProvider
    private let replayStore: any SecureShareReplayStore

    public init(
        keyProvider: any SecureShareKeyProvider,
        replayStore: any SecureShareReplayStore = InMemorySecureShareReplayStore()
    ) {
        self.keyProvider = keyProvider
        self.replayStore = replayStore
    }

    public func open(_ transport: String) async throws -> Data {
        try await openValidated(transport) { _ in }
    }

    /// Opens an envelope and runs caller validation before the replay ID is committed. This keeps
    /// a malformed authenticated typed payload retryable instead of consuming its envelope ID.
    public func openValidated(
        _ transport: String,
        validator: @Sendable (Data) throws -> Void
    ) async throws -> Data {
        let envelope = try SecureShareEnvelope.decodeTransport(transport)
        guard await replayStore.reserve(envelope.id) else {
            throw SecureShareError.replayDetected(envelope.id)
        }
        do {
            let privateKey: Curve25519.KeyAgreement.PrivateKey
            do {
                privateKey = try keyProvider.recipientPrivateKey()
            } catch {
                throw SecureShareError.keyUnavailable
            }
            let plaintext = try envelope.open(using: privateKey)
            try validator(plaintext)
            await replayStore.commit(envelope.id)
            return plaintext
        } catch {
            await replayStore.release(envelope.id)
            throw error
        }
    }

    public func receive(_ transport: String) async throws -> Data {
        try await open(transport)
    }
}

/// Convenience namespace for callers that do not need a stateful receiver.
public enum SecureShare {
    public static let keyExchangeLimitation =
        "SecureShare does not exchange or authenticate public keys. Authenticate the recipient public key out of band before sealing."

    public static func seal(
        _ plaintext: Data,
        for recipientPublicKey: Curve25519.KeyAgreement.PublicKey,
        id: UUID = UUID()
    ) throws -> String {
        try SecureShareEnvelope.seal(plaintext, for: recipientPublicKey, id: id).transportString()
    }

    public static func decode(_ transport: String) throws -> SecureShareEnvelope {
        try SecureShareEnvelope.decodeTransport(transport)
    }
}
