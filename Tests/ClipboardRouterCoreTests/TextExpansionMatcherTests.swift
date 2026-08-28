import ClipboardRouterCore
import XCTest

final class TextExpansionMatcherTests: XCTestCase {
    func testDelimiterCompletedAliasMatchesExactly() {
        var matcher = TextExpansionMatcher()
        let definition = definition(";hello", replacement: "world")

        let result = feed(";hello ", to: &matcher, definitions: [definition])

        XCTAssertEqual(result, TextExpansionMatch(definition: definition, delimiter: " "))
    }

    func testReplacementLengthUsesAXUTF16Units() {
        var matcher = TextExpansionMatcher()
        let definition = definition(";hello𐐀", replacement: "world")

        let result = feed(";hello𐐀 ", to: &matcher, definitions: [definition])

        XCTAssertEqual(result?.replacedUTF16Length, definition.trigger.utf16.count + 1)
        XCTAssertEqual(result?.replacedUTF16Length, 9)
    }

    func testPartialWordAndPartialAliasDoNotExpand() {
        var matcher = TextExpansionMatcher()
        let definition = definition(";hello", replacement: "world")

        let results = ["x;hello ", ";hell "].map {
            feed($0, to: &matcher, definitions: [definition])
        }

        XCTAssertEqual(results.compactMap { $0 }.count, 0)
    }

    func testTimeoutAndContextChangeClearToken() {
        var matcher = TextExpansionMatcher()
        let definition = definition(";hello", replacement: "world")
        let start = Date(timeIntervalSince1970: 100)
        for character in ";hel" {
            _ = matcher.consume(character, at: start, contextID: "a", definitions: [definition])
        }

        let result = matcher.consume(" ", at: start.addingTimeInterval(4), contextID: "b", definitions: [definition])

        XCTAssertNil(result)
    }

    func testNewFocusKnownToBeMidwordRejectsAliasUntilDelimiter() {
        var matcher = TextExpansionMatcher()
        let definition = definition(";hello", replacement: "world")
        var result: TextExpansionMatch?
        var first = true

        for character in ";hello " {
            result = matcher.consume(
                character,
                at: Date(),
                contextID: "midword",
                mayStartAtContextChange: first ? false : true,
                definitions: [definition]
            )
            first = false
        }

        XCTAssertNil(result)
    }

    func testTenThousandAliasesStayWithinLocalInteractionBudget() {
        var matcher = TextExpansionMatcher()
        let definitions = (0..<10_000).map {
            definition(";alias\($0)", replacement: "value\($0)")
        }
        let clock = ContinuousClock()

        let duration = clock.measure {
            _ = feed(";alias9999 ", to: &matcher, definitions: definitions)
        }

        XCTAssertLessThan(duration, .milliseconds(100))
    }

    private func definition(_ trigger: String, replacement: String) -> TextExpansionDefinition {
        TextExpansionDefinition(aliasID: UUID(), trigger: trigger, replacement: replacement)
    }

    private func feed(
        _ text: String,
        to matcher: inout TextExpansionMatcher,
        definitions: [TextExpansionDefinition]
    ) -> TextExpansionMatch? {
        var result: TextExpansionMatch?
        var date = Date(timeIntervalSince1970: 100)
        for character in text {
            result = matcher.consume(character, at: date, contextID: "focus", definitions: definitions)
            date.addTimeInterval(0.01)
        }
        return result
    }
}
