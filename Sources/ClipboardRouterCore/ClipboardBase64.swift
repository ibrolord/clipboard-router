import Foundation

/// Explicit transport for a portable clip's canonical typed payload.
///
/// This is an encoding, not encryption. Callers must treat the resulting value as plaintext and
/// must use the encrypted-share API for secrets. The prefix prevents arbitrary user text from
/// being silently interpreted as a Clipboard Router payload.
public enum ClipboardBase64Codec {
    public static let prefix = "clipboard-router-b64:v1:"
    public static let maximumPayloadBytes = 2 * 1_024 * 1_024

    public enum Error: Swift.Error, Equatable, LocalizedError, Sendable {
        case missingPrefix
        case malformedBase64
        case emptyPayload
        case payloadTooLarge(Int)
        case nonCanonicalEncoding
        case invalidPayload
        case unsupportedRepresentation

        public var errorDescription: String? {
            switch self {
            case .missingPrefix: "This is not a Clipboard Router Base64 clip."
            case .malformedBase64: "The Base64 clip is malformed."
            case .emptyPayload: "The Base64 clip is empty."
            case let .payloadTooLarge(size): "The Base64 clip is too large (\(size) bytes)."
            case .nonCanonicalEncoding: "The Base64 clip is not in canonical form."
            case .invalidPayload: "The Base64 clip does not contain a valid typed clip payload."
            case .unsupportedRepresentation: "Base64 export supports only portable text and URL clips."
            }
        }
    }

    public static func encode(_ content: ClipContent) throws -> String {
        // Asset references and file URLs point into the sender's local storage. Encoding them
        // would produce a payload that cannot be restored on another machine and could disclose
        // the sender's filesystem layout, so fail closed just like encrypted share does.
        guard content.representations.referencedAssets.isEmpty,
              content.representations.files.isEmpty
        else { throw Error.unsupportedRepresentation }
        let data = try encoder.encode(content)
        guard !data.isEmpty else { throw Error.emptyPayload }
        guard data.count <= maximumPayloadBytes else {
            throw Error.payloadTooLarge(data.count)
        }
        return prefix + data.base64EncodedString()
    }

    public static func decode(_ value: String) throws -> ClipContent {
        guard value.hasPrefix(prefix) else { throw Error.missingPrefix }
        let encoded = String(value.dropFirst(prefix.count))
        guard !encoded.isEmpty else { throw Error.emptyPayload }
        guard let data = Data(base64Encoded: encoded), !data.isEmpty else {
            throw Error.malformedBase64
        }
        guard data.count <= maximumPayloadBytes else {
            throw Error.payloadTooLarge(data.count)
        }
        guard data.base64EncodedString() == encoded else {
            throw Error.nonCanonicalEncoding
        }
        do {
            let content = try decoder.decode(ClipContent.self, from: data)
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
