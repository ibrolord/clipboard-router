import CryptoKit
import ClipboardRouterCore
import Foundation
import XCTest
@testable import ClipboardRouterSecurity

final class SecureShareTests: XCTestCase {
    func testCrossSessionRoundTripWithPersistedInMemoryKey() async throws {
        let firstSessionKeyProvider = InMemorySecureShareKeyProvider()
        let keyBytes = firstSessionKeyProvider.rawPrivateKeyRepresentation
        let secondSessionKeyProvider = try InMemorySecureShareKeyProvider(
            rawPrivateKeyRepresentation: keyBytes
        )
        let payload = Data("cross-session confidential clipboard payload".utf8)
        let id = UUID()

        let transport = try SecureShare.seal(
            payload,
            for: firstSessionKeyProvider.recipientPublicKey(),
            id: id
        )
        let receiver = SecureShareReceiver(keyProvider: secondSessionKeyProvider)

        let opened = try await receiver.open(transport)
        XCTAssertEqual(opened, payload)
        XCTAssertFalse(transport.contains("cross-session"))
    }

    func testTamperingAndWrongRecipientFailClosed() async throws {
        let provider = InMemorySecureShareKeyProvider()
        let envelope = try SecureShareEnvelope.seal(
            Data("do not expose".utf8),
            for: provider.recipientPublicKey()
        )
        let wrongProvider = InMemorySecureShareKeyProvider()
        let receiver = SecureShareReceiver(keyProvider: wrongProvider)

        do {
            _ = try await receiver.open(try envelope.transportString())
            XCTFail("wrong recipient must not decrypt")
        } catch {
            XCTAssertEqual(error as? SecureShareError, .authenticationFailed)
        }

        var ciphertext = envelope.ciphertext
        if !ciphertext.isEmpty {
            ciphertext[ciphertext.startIndex] ^= 1
        }
        let tampered = SecureShareEnvelope(
            id: envelope.id,
            version: envelope.version,
            ephemeralPublicKey: envelope.ephemeralPublicKey,
            nonce: envelope.nonce,
            ciphertext: ciphertext,
            tag: envelope.tag
        )
        do {
            _ = try await SecureShareReceiver(keyProvider: provider).open(
                try tampered.transportString()
            )
            XCTFail("tampered ciphertext must not decrypt")
        } catch {
            XCTAssertEqual(error as? SecureShareError, .authenticationFailed)
        }
    }

    func testCanonicalBase64AndBoundsRejectMalformedOrOversizedTransport() throws {
        let provider = InMemorySecureShareKeyProvider()
        let envelope = try SecureShareEnvelope.seal(
            Data("canonical transport".utf8),
            for: provider.recipientPublicKey()
        )
        let transport = try envelope.transportString()

        XCTAssertEqual(try SecureShareEnvelope.decodeTransport(transport), envelope)
        XCTAssertThrowsError(try SecureShareEnvelope.decodeTransport(" \(transport)")) {
            XCTAssertEqual($0 as? SecureShareError, .malformedTransport)
        }
        XCTAssertThrowsError(try SecureShareEnvelope.decodeTransport(
            String(repeating: "A", count: SecureShareEnvelope.maximumTransportCharacters + 1)
        )) {
            XCTAssertEqual($0 as? SecureShareError, .transportTooLarge)
        }

        XCTAssertThrowsError(try SecureShareEnvelope.seal(
            Data(repeating: 0x7f, count: SecureShareEnvelope.maximumPayloadBytes + 1),
            for: provider.recipientPublicKey()
        )) {
            XCTAssertEqual(
                $0 as? SecureShareError,
                .payloadTooLarge(SecureShareEnvelope.maximumPayloadBytes + 1)
            )
        }
    }

    func testUnknownVersionAndDuplicateIDAreRejected() async throws {
        let provider = InMemorySecureShareKeyProvider()
        let id = UUID()
        let envelope = try SecureShareEnvelope.seal(
            Data("one time".utf8),
            for: provider.recipientPublicKey(),
            id: id
        )
        let unknownVersion = SecureShareEnvelope(
            id: envelope.id,
            version: SecureShareEnvelope.currentVersion + 1,
            ephemeralPublicKey: envelope.ephemeralPublicKey,
            nonce: envelope.nonce,
            ciphertext: envelope.ciphertext,
            tag: envelope.tag
        )
        XCTAssertThrowsError(try unknownVersion.transportString()) {
            XCTAssertEqual(
                $0 as? SecureShareError,
                .unsupportedVersion(SecureShareEnvelope.currentVersion + 1)
            )
        }

        let replayStore = InMemorySecureShareReplayStore()
        let receiver = SecureShareReceiver(keyProvider: provider, replayStore: replayStore)
        let transport = try envelope.transportString()
        let first = try await receiver.open(transport)
        XCTAssertEqual(first, Data("one time".utf8))
        do {
            _ = try await receiver.open(transport)
            XCTFail("duplicate envelope must be rejected")
        } catch {
            XCTAssertEqual(error as? SecureShareError, .replayDetected(id))
        }
        let replayCount = await replayStore.count
        XCTAssertEqual(replayCount, 1)
    }

    func testTypedClipShareUsesExplicitPrefixAndRoundTrips() async throws {
        let provider = InMemorySecureShareKeyProvider()
        let content = try ClipContent.detect(text: "https://example.com/private-share")
        let transport = try SecureShareClipCodec.seal(
            content,
            for: provider.recipientPublicKey()
        )
        XCTAssertTrue(transport.hasPrefix(SecureShareClipCodec.prefix))

        let receiver = SecureShareReceiver(keyProvider: provider)
        let opened = try await SecureShareClipCodec.open(transport, using: receiver)
        XCTAssertEqual(opened, content)
        do {
            _ = try await SecureShareClipCodec.open(
                String(transport.dropFirst(SecureShareClipCodec.prefix.count)),
                using: receiver
            )
            XCTFail("missing prefix must be rejected")
        } catch {
            XCTAssertEqual(error as? SecureShareClipCodec.Error, .missingPrefix)
        }
    }

    func testMalformedTypedPayloadDoesNotConsumeEnvelopeReplayID() async throws {
        let provider = InMemorySecureShareKeyProvider()
        let envelope = try SecureShareEnvelope.seal(
            Data("{\"not\":\"a clip\"}".utf8),
            for: provider.recipientPublicKey()
        )
        let transport = SecureShareClipCodec.prefix + (try envelope.transportString())
        let receiver = SecureShareReceiver(keyProvider: provider)

        for _ in 0..<2 {
            do {
                _ = try await SecureShareClipCodec.open(transport, using: receiver)
                XCTFail("malformed typed payload must fail")
            } catch {
                XCTAssertEqual(error as? SecureShareClipCodec.Error, .invalidPayload)
            }
        }
    }

    func testTypedClipShareRejectsLocalOnlyAssets() throws {
        let provider = InMemorySecureShareKeyProvider()
        let reference = try ClipAssetReference(
            digest: String(repeating: "a", count: 64),
            kind: .image,
            uniformTypeIdentifier: "public.png",
            byteCount: 3,
            relativePath: "assets/image"
        )
        let content = try ClipContent(
            type: .image,
            text: "image fallback",
            representations: ClipRepresentations(image: reference)
        )

        XCTAssertThrowsError(try SecureShareClipCodec.seal(
            content,
            for: provider.recipientPublicKey()
        )) {
            XCTAssertEqual(
                $0 as? SecureShareClipCodec.Error,
                .unsupportedRepresentation
            )
        }
    }

    func testFileReplayStoreSurvivesRelaunchAndBoundsIDs() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("secure-share-replay-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("replay.json")
        let first = FileSecureShareReplayStore(fileURL: fileURL, maximumIDs: 2)
        let ids = [UUID(), UUID(), UUID()]

        for id in ids {
            let reserved = await first.reserve(id)
            XCTAssertTrue(reserved)
            await first.commit(id)
        }

        let second = FileSecureShareReplayStore(fileURL: fileURL, maximumIDs: 2)
        let retainedMiddle = await second.reserve(ids[1])
        let retainedNewest = await second.reserve(ids[2])
        let evictedOldest = await second.reserve(ids[0])
        XCTAssertFalse(retainedMiddle)
        XCTAssertFalse(retainedNewest)
        XCTAssertTrue(evictedOldest)
    }
}
