import ClipboardRouterCore
import CryptoKit
import Foundation

/// Typed clipboard sharing over `SecureShareEnvelope`.
///
/// The prefix is required to prevent ordinary user text from being interpreted as an encrypted
/// Clipboard Router share. It is routing metadata only; the clip JSON remains inside ciphertext.
public enum SecureShareClipCodec {
    public static let prefix = "clipboard-router-share:v1:"

    public enum Error: Swift.Error, Equatable, LocalizedError, Sendable {
        case missingPrefix
        case emptyPayload
        case invalidPayload
        case unsupportedRepresentation

        public var errorDescription: String? {
            switch self {
            case .missingPrefix: "This is not a Clipboard Router encrypted share."
            case .emptyPayload: "The encrypted share contains no clip payload."
            case .invalidPayload: "The decrypted share is not a valid typed clip payload."
            case .unsupportedRepresentation:
                "This clip contains local-only files or binary assets and cannot be shared yet."
            }
        }
    }

    /// Encodes and encrypts a typed clip. The recipient public key must have been authenticated
    /// by the caller through an out-of-band key exchange before this method is called.
    public static func seal(
        _ content: ClipContent,
        for recipientPublicKey: Curve25519.KeyAgreement.PublicKey,
        id: UUID = UUID()
    ) throws -> String {
        guard content.representations.referencedAssets.isEmpty,
              content.representations.files.isEmpty
        else { throw Error.unsupportedRepresentation }
        let plaintext = try encoder.encode(content)
        guard !plaintext.isEmpty else { throw Error.emptyPayload }
        let envelope = try SecureShareEnvelope.seal(
            plaintext,
            for: recipientPublicKey,
            id: id
        )
        return prefix + (try envelope.transportString())
    }

    /// Opens a prefixed encrypted share and validates the typed clip after authentication.
    public static func open(
        _ transport: String,
        using receiver: SecureShareReceiver
    ) async throws -> ClipContent {
        guard transport.hasPrefix(prefix) else { throw Error.missingPrefix }
        let envelopeTransport = String(transport.dropFirst(prefix.count))
        let plaintext: Data
        do {
            plaintext = try await receiver.openValidated(envelopeTransport) { data in
                guard !data.isEmpty else { throw Error.emptyPayload }
                do {
                    let content = try decoder.decode(ClipContent.self, from: data)
                    guard content.representations.referencedAssets.isEmpty,
                          content.representations.files.isEmpty
                    else { throw Error.unsupportedRepresentation }
                } catch {
                    if let error = error as? Error { throw error }
                    throw Error.invalidPayload
                }
            }
        } catch {
            throw error
        }
        guard !plaintext.isEmpty else { throw Error.emptyPayload }
        do {
            let content = try decoder.decode(ClipContent.self, from: plaintext)
            guard content.representations.referencedAssets.isEmpty,
                  content.representations.files.isEmpty
            else { throw Error.unsupportedRepresentation }
            return content
        } catch {
            if let error = error as? Error { throw error }
            throw Error.invalidPayload
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()
}
