import CryptoKit
import Foundation

public enum VaultCrypto {
    public static let keyByteCount = 32
    public static let maximumItemPlaintextBytes = 2 * 1_024 * 1_024
    public static let maximumItemCiphertextBytes = maximumItemPlaintextBytes + 64

    public static func generateKeyData() -> Data {
        Data(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
    }

    public static func seal(_ item: VaultItem, using keyData: Data) throws -> VaultCiphertextEnvelope {
        let key = try symmetricKey(from: keyData)
        let plaintext = try canonicalEncoder.encode(item)
        guard plaintext.count <= maximumItemPlaintextBytes else {
            throw VaultError.assetTooLarge(plaintext.count)
        }
        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(
            plaintext,
            using: key,
            nonce: nonce,
            authenticating: authenticatedData(id: item.id, version: VaultCiphertextEnvelope.currentVersion)
        )
        return VaultCiphertextEnvelope(
            id: item.id,
            version: VaultCiphertextEnvelope.currentVersion,
            nonce: Data(nonce),
            ciphertext: sealed.ciphertext,
            tag: sealed.tag
        )
    }

    public static func open(
        _ envelope: VaultCiphertextEnvelope,
        using keyData: Data
    ) throws -> VaultItem {
        guard envelope.version == 1 || envelope.version == VaultCiphertextEnvelope.currentVersion else {
            throw VaultError.unsupportedEnvelopeVersion(envelope.version)
        }
        guard envelope.nonce.count == 12,
              envelope.tag.count == 16,
              !envelope.ciphertext.isEmpty,
              envelope.ciphertext.count <= maximumItemCiphertextBytes
        else { throw VaultError.invalidEnvelope }
        let key = try symmetricKey(from: keyData)
        do {
            let nonce = try AES.GCM.Nonce(data: envelope.nonce)
            let box = try AES.GCM.SealedBox(
                nonce: nonce,
                ciphertext: envelope.ciphertext,
                tag: envelope.tag
            )
            let plaintext = try AES.GCM.open(
                box,
                using: key,
                authenticating: authenticatedData(id: envelope.id, version: envelope.version)
            )
            guard plaintext.count <= maximumItemPlaintextBytes else {
                throw VaultError.invalidEnvelope
            }
            let item = try canonicalDecoder.decode(VaultItem.self, from: plaintext)
            guard item.id == envelope.id else { throw VaultError.itemIdentityMismatch }
            return item
        } catch let error as VaultError {
            throw error
        } catch {
            throw VaultError.invalidEnvelope
        }
    }

    public static func authenticatedData(id: UUID, version: Int) -> Data {
        Data("clipboard-router:vault:\(version):\(id.uuidString.lowercased())".utf8)
    }

    private static func symmetricKey(from data: Data) throws -> SymmetricKey {
        guard data.count == keyByteCount else { throw VaultError.invalidKeyLength }
        return SymmetricKey(data: data)
    }

    private static let canonicalEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }()

    private static let canonicalDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()
}
