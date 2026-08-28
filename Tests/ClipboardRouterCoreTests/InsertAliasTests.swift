import Foundation
import XCTest
@testable import ClipboardRouterCore

final class InsertAliasTests: XCTestCase {
    func testInitializerNormalizesNameAndAbbreviation() throws {
        // Arrange
        let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let clipID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

        // Act
        let alias = try InsertAlias(
            id: id,
            name: "  Customer greeting\n",
            abbreviation: " ;WELCOME ",
            savedClipID: clipID,
            delivery: .pasteIntoFrontmostApplication
        )

        // Assert
        XCTAssertEqual(
            alias,
            try InsertAlias(
                id: id,
                name: "Customer greeting",
                abbreviation: "welcome",
                savedClipID: clipID,
                delivery: .pasteIntoFrontmostApplication
            )
        )
    }

    func testNormalizeComposesEquivalentUnicodeScalars() {
        // Arrange
        let decomposed = ";CAFE\u{301}"

        // Act
        let normalized = InsertAlias.normalize(decomposed)

        // Assert
        XCTAssertEqual(normalized, "café")
    }

    func testTriggerAddsExactlyOneLeadingSemicolon() throws {
        // Arrange
        let alias = try InsertAlias(
            name: "Greeting",
            abbreviation: ";hello",
            savedClipID: UUID()
        )

        // Act
        let trigger = alias.trigger

        // Assert
        XCTAssertEqual(trigger, ";hello")
    }

    func testInitializerRejectsWhitespaceOnlyName() {
        // Arrange / Act
        let error = capturedError {
            _ = try InsertAlias(name: " \n ", abbreviation: "ok", savedClipID: UUID())
        }

        // Assert
        XCTAssertEqual(error as? InsertAliasError, .invalidName)
    }

    func testInitializerRejectsNameOverUTF8ByteLimit() {
        // Arrange
        let name = String(repeating: "é", count: 41)

        // Act
        let error = capturedError {
            _ = try InsertAlias(name: name, abbreviation: "ok", savedClipID: UUID())
        }

        // Assert
        XCTAssertEqual(error as? InsertAliasError, .invalidName)
    }

    func testInitializerRejectsControlCharacterInName() {
        // Arrange / Act
        let error = capturedError {
            _ = try InsertAlias(name: "Sales\u{0007}", abbreviation: "ok", savedClipID: UUID())
        }

        // Assert
        XCTAssertEqual(error as? InsertAliasError, .invalidName)
    }

    func testInitializerRejectsOneCharacterAbbreviation() {
        // Arrange / Act
        let error = capturedError {
            _ = try InsertAlias(name: "Greeting", abbreviation: "x", savedClipID: UUID())
        }

        // Assert
        XCTAssertEqual(error as? InsertAliasError, .invalidAbbreviation)
    }

    func testInitializerRejectsAbbreviationOverCharacterLimit() {
        // Arrange
        let abbreviation = String(repeating: "a", count: InsertAlias.maximumAbbreviationLength + 1)

        // Act
        let error = capturedError {
            _ = try InsertAlias(name: "Greeting", abbreviation: abbreviation, savedClipID: UUID())
        }

        // Assert
        XCTAssertEqual(error as? InsertAliasError, .invalidAbbreviation)
    }

    func testInitializerRejectsAbbreviationContainingPunctuation() {
        // Arrange / Act
        let error = capturedError {
            _ = try InsertAlias(name: "Greeting", abbreviation: "hello!", savedClipID: UUID())
        }

        // Assert
        XCTAssertEqual(error as? InsertAliasError, .invalidAbbreviation)
    }

    func testDecoderNormalizesPersistedNameAndAbbreviation() throws {
        // Arrange
        let data = Data(
            """
            {
              "id": "11111111-1111-1111-1111-111111111111",
              "name": "  Greeting  ",
              "abbreviation": ";HELLO",
              "savedClipID": "22222222-2222-2222-2222-222222222222",
              "delivery": "copy"
            }
            """.utf8
        )

        // Act
        let alias = try JSONDecoder().decode(InsertAlias.self, from: data)

        // Assert
        XCTAssertEqual(alias.trigger, ";hello")
    }

    func testDecoderRejectsInvalidPersistedAbbreviation() {
        // Arrange
        let data = Data(
            """
            {
              "id": "11111111-1111-1111-1111-111111111111",
              "name": "Greeting",
              "abbreviation": "bad value",
              "savedClipID": "22222222-2222-2222-2222-222222222222",
              "delivery": "copy"
            }
            """.utf8
        )

        // Act
        let error = capturedError {
            _ = try JSONDecoder().decode(InsertAlias.self, from: data)
        }

        // Assert
        XCTAssertEqual(error as? InsertAliasError, .invalidAbbreviation)
    }
}

private func capturedError(_ operation: () throws -> Void) -> Error? {
    do {
        try operation()
        return nil
    } catch {
        return error
    }
}
