import XCTest
@testable import ClipboardRouterCore

final class ClipboardBase64Tests: XCTestCase {
    func testRoundTripPreservesTypedClip() throws {
        let content = try ClipContent.detect(text: "https://example.com/a?b=1")
        let encoded = try ClipboardBase64Codec.encode(content)
        XCTAssertTrue(encoded.hasPrefix(ClipboardBase64Codec.prefix))
        XCTAssertEqual(try ClipboardBase64Codec.decode(encoded), content)
    }

    func testCodecRejectsUnprefixedAndNonCanonicalValues() throws {
        let content = try ClipContent.detect(text: "hello")
        let encoded = try ClipboardBase64Codec.encode(content)
        XCTAssertThrowsError(try ClipboardBase64Codec.decode(String(encoded.dropFirst()))) {
            XCTAssertEqual($0 as? ClipboardBase64Codec.Error, .missingPrefix)
        }
        let body = String(encoded.dropFirst(ClipboardBase64Codec.prefix.count))
        let padded = ClipboardBase64Codec.prefix + body + "="
        XCTAssertThrowsError(try ClipboardBase64Codec.decode(padded)) {
            XCTAssertEqual($0 as? ClipboardBase64Codec.Error, .nonCanonicalEncoding)
        }
    }

    func testCodecRejectsMalformedPayload() throws {
        XCTAssertThrowsError(
            try ClipboardBase64Codec.decode(ClipboardBase64Codec.prefix + "not-base64")
        ) {
            XCTAssertEqual($0 as? ClipboardBase64Codec.Error, .malformedBase64)
        }
    }

    func testCodecRejectsNonPortableRepresentations() throws {
        let file = try ClipFileReference(url: URL(fileURLWithPath: "/tmp/clipboard-router-secret.txt"))
        let content = try ClipContent(
            type: .fileURLs,
            text: "clipboard-router-secret.txt",
            representations: ClipRepresentations(files: [file])
        )

        XCTAssertThrowsError(try ClipboardBase64Codec.encode(content)) {
            XCTAssertEqual($0 as? ClipboardBase64Codec.Error, .unsupportedRepresentation)
        }

        let asset = try ClipAssetReference(
            digest: String(repeating: "a", count: 64),
            kind: .richText,
            uniformTypeIdentifier: "public.rtf",
            byteCount: 4,
            relativePath: "assets/example.rtf"
        )
        let richContent = try ClipContent(
            type: .richText,
            text: "rich",
            representations: ClipRepresentations(richText: asset)
        )
        XCTAssertThrowsError(try ClipboardBase64Codec.encode(richContent)) {
            XCTAssertEqual($0 as? ClipboardBase64Codec.Error, .unsupportedRepresentation)
        }
        let legacyPayload = try JSONEncoder().encode(richContent)
        let legacyValue = ClipboardBase64Codec.prefix + legacyPayload.base64EncodedString()
        XCTAssertThrowsError(try ClipboardBase64Codec.decode(legacyValue)) {
            XCTAssertEqual($0 as? ClipboardBase64Codec.Error, .unsupportedRepresentation)
        }
    }
}
