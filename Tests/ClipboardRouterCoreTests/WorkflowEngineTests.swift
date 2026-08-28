import Foundation
import XCTest
@testable import ClipboardRouterCore

final class WorkflowEngineTests: XCTestCase {
    func testContextPackRendersOrderedDeterministicMarkdown() throws {
        let firstID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let secondID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let first = try ContextPackItem(
            id: firstID,
            title: " API notes ",
            textRepresentation: "alpha\n```\nomega",
            capturedAt: Date(timeIntervalSince1970: 0),
            sourceApplication: "Safari",
            sourceURL: URL(string: "https://example.com/docs"),
            metadata: ["zeta": "last", "alpha": "first"]
        )
        let second = try ContextPackItem(
            id: secondID,
            title: "Second",
            textRepresentation: "body"
        )
        var pack = try ContextPack(name: " Research ", items: [first, second])

        let initial = try pack.renderMarkdown()
        let repeated = try pack.renderMarkdown()

        XCTAssertEqual(initial, repeated)
        XCTAssertEqual(pack.name, "Research")
        XCTAssertLessThan(
            try XCTUnwrap(initial.range(of: "## 1. API notes")?.lowerBound),
            try XCTUnwrap(initial.range(of: "## 2. Second")?.lowerBound)
        )
        XCTAssertLessThan(
            try XCTUnwrap(initial.range(of: "- alpha: first")?.lowerBound),
            try XCTUnwrap(initial.range(of: "- zeta: last")?.lowerBound)
        )
        XCTAssertTrue(initial.contains("- Captured: `1970-01-01T00:00:00.000Z`"))
        XCTAssertTrue(initial.contains("````text\nalpha\n```\nomega\n````"))

        try pack.move(from: 1, to: 0)
        let reordered = try pack.renderMarkdown()
        XCTAssertLessThan(
            try XCTUnwrap(reordered.range(of: "## 1. Second")?.lowerBound),
            try XCTUnwrap(reordered.range(of: "## 2. API notes")?.lowerBound)
        )
    }

    func testContextPackEnforcesItemCountSizeAndDuplicateBounds() throws {
        let limits = try ContextPackLimits(
            maximumItemCount: 1,
            maximumItemUTF8Bytes: 4,
            maximumRenderedUTF8Bytes: 10_000
        )
        let id = UUID()
        let item = try ContextPackItem(id: id, title: "One", textRepresentation: "1234")
        let oversized = try ContextPackItem(
            id: UUID(),
            title: "Large",
            textRepresentation: "12345"
        )
        var pack = try ContextPack(name: "Bounded", limits: limits)

        try pack.append(item)
        XCTAssertThrowsError(try pack.append(item)) { error in
            XCTAssertEqual(error as? ContextPackError, .duplicateItem(id))
        }
        XCTAssertThrowsError(try ContextPack(name: "Large", items: [oversized], limits: limits)) {
            error in
            XCTAssertEqual(
                error as? ContextPackError,
                .itemSizeExceedsLimit(itemID: oversized.id, actual: 5, maximum: 4)
            )
        }

        let second = try ContextPackItem(id: UUID(), title: "Two", textRepresentation: "12")
        XCTAssertThrowsError(try pack.append(second)) { error in
            XCTAssertEqual(error as? ContextPackError, .itemCountExceedsLimit(1))
        }
        XCTAssertEqual(pack.items.map(\.id), [id])
    }

    func testContextPackRejectsRenderedOverflowAndRollsBackInsert() throws {
        let limits = try ContextPackLimits(
            maximumItemCount: 5,
            maximumItemUTF8Bytes: 100,
            maximumRenderedUTF8Bytes: 20
        )
        let item = try ContextPackItem(id: UUID(), title: "One", textRepresentation: "x")
        var pack = try ContextPack(name: "P", limits: limits)

        XCTAssertThrowsError(try pack.append(item)) { error in
            guard case let ContextPackError.renderedSizeExceedsLimit(actual, maximum) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertGreaterThan(actual, maximum)
            XCTAssertEqual(maximum, 20)
        }
        XCTAssertTrue(pack.items.isEmpty)
    }

    func testContextPackDecodeRevalidatesBounds() throws {
        let limits = try ContextPackLimits(
            maximumItemCount: 1,
            maximumItemUTF8Bytes: 100,
            maximumRenderedUTF8Bytes: 10_000
        )
        let items = try [
            ContextPackItem(id: UUID(), title: "One", textRepresentation: "1"),
            ContextPackItem(id: UUID(), title: "Two", textRepresentation: "2"),
        ]
        let valid = try ContextPack(name: "Pack", items: [items[0]], limits: limits)
        let encoder = JSONEncoder()
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try encoder.encode(valid)) as? [String: Any]
        )
        object["items"] = try JSONSerialization.jsonObject(with: encoder.encode(items))
        let invalidData = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try JSONDecoder().decode(ContextPack.self, from: invalidData)) {
            error in
            XCTAssertEqual(error as? ContextPackError, .itemCountExceedsLimit(1))
        }
    }

    func testCombinedNoteExpectationRejectsADeletedSourceAtomically() async throws {
        let history = HistoryItem(
            content: try ClipContent.detect(text: "Reviewed source"),
            createdAt: Date(),
            sourceApplicationBundleIdentifier: "com.example.source"
        )
        let library = try ClipboardLibrary(snapshot: ClipboardLibrarySnapshot(history: [history]))
        let item = try ContextPackItem(
            id: history.id,
            title: "Reviewed source",
            textRepresentation: history.content.searchableText,
            capturedAt: history.lastCapturedAt,
            sourceApplication: history.sourceApplicationBundleIdentifier,
            metadata: [
                "Content type": history.content.type.rawValue,
                "Approximate size": "\(history.content.estimatedStorageByteCount) bytes",
            ]
        )
        let expectation = ContextPackSourceExpectation(item: item, source: .history)

        try await library.deleteHistoryItem(id: history.id)

        do {
            _ = try await library.createNote(
                title: "Combined Clips",
                body: "Reviewed source",
                expectingCombinedClips: [expectation]
            )
            XCTFail("Expected the deleted source to invalidate the atomic note save")
        } catch {
            XCTAssertEqual(
                error as? ClipboardLibraryError,
                .combinedClipSourceChanged(history.id)
            )
        }
        let snapshot = await library.snapshot()
        XCTAssertTrue(snapshot.savedClips.isEmpty)
    }

    func testPasteStackAdvancesOnlyAfterConfirmedSuccess() throws {
        let first = PasteStackEntry(payload: "first")
        let second = PasteStackEntry(payload: "second")
        var stack = try PasteStack(entries: [first, second])

        let failedAttempt = try XCTUnwrap(stack.next(action: .paste))
        XCTAssertEqual(failedAttempt.entry, first)
        XCTAssertEqual(try stack.confirm(attemptID: failedAttempt.id, outcome: .failed), first)
        XCTAssertEqual(stack.currentEntry, first)

        let successfulAttempt = try XCTUnwrap(stack.next(action: .copy))
        XCTAssertEqual(try stack.confirm(attemptID: successfulAttempt.id, outcome: .succeeded), second)
        XCTAssertEqual(stack.currentEntry, second)

        let lastAttempt = try XCTUnwrap(stack.next(action: .paste))
        XCTAssertNil(try stack.confirm(attemptID: lastAttempt.id, outcome: .succeeded))
        XCTAssertTrue(stack.isComplete)
    }

    func testPasteStackAttemptIsStableAndStaleConfirmationCannotAdvance() throws {
        let entry = PasteStackEntry(payload: "value")
        var stack = try PasteStack(entries: [entry])

        let first = try XCTUnwrap(stack.next(action: .copy))
        let repeated = try XCTUnwrap(stack.next(action: .paste))
        XCTAssertEqual(repeated.id, first.id)
        XCTAssertEqual(repeated.action, .copy)

        XCTAssertThrowsError(
            try stack.confirm(attemptID: UUID(), outcome: .succeeded)
        ) { error in
            guard case .staleAttempt = error as? PasteStackError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(stack.currentEntry, entry)
    }

    func testPasteStackSkipPreviousRestartAndClear() throws {
        let first = PasteStackEntry(payload: 1)
        let second = PasteStackEntry(payload: 2)
        let third = PasteStackEntry(payload: 3)
        var stack = try PasteStack(entries: [first, second, third])

        XCTAssertEqual(stack.skip(), second)
        XCTAssertEqual(stack.skip(), third)
        XCTAssertEqual(stack.previous(), second)
        XCTAssertEqual(stack.restart(), first)
        stack.clear()

        XCTAssertTrue(stack.isEmpty)
        XCTAssertFalse(stack.isComplete)
        XCTAssertNil(stack.currentEntry)
        XCTAssertNil(stack.next(action: .copy))
    }

    func testPasteStackRejectsDuplicateEntries() {
        let id = UUID()
        let entries = [
            PasteStackEntry(id: id, payload: "one"),
            PasteStackEntry(id: id, payload: "two"),
        ]

        XCTAssertThrowsError(try PasteStack(entries: entries)) { error in
            XCTAssertEqual(error as? PasteStackError, .duplicateEntry(id))
        }
    }

    func testSafeTransformsAreDeterministicAndDoNotMutateOriginal() throws {
        let original = "  hello\r\nWORLD  "

        XCTAssertEqual(try SafeTextTransformer.apply(.plainText, to: original), original)
        XCTAssertEqual(try SafeTextTransformer.apply(.trim, to: original), "hello\r\nWORLD")
        XCTAssertEqual(
            try SafeTextTransformer.apply(.lineEndings(.lineFeed), to: original),
            "  hello\nWORLD  "
        )
        XCTAssertEqual(try SafeTextTransformer.apply(.uppercase, to: "Hello"), "HELLO")
        XCTAssertEqual(try SafeTextTransformer.apply(.lowercase, to: "Hello"), "hello")
        XCTAssertEqual(try SafeTextTransformer.apply(.titleCase, to: "hello WORLD"), "Hello World")
        XCTAssertEqual(try SafeTextTransformer.apply(.quote, to: "one\r\ntwo"), "> one\n> two")
        XCTAssertEqual(original, "  hello\r\nWORLD  ")
    }

    func testSafeTransformPipelineAndCodeFenceAreStable() throws {
        let transformed = try SafeTextTransformer.apply(
            [.trim, .lowercase, .codeBlock(language: "swift")],
            to: "  LET value = ```  "
        )

        XCTAssertEqual(transformed, "````swift\nlet value = ```\n````")
        XCTAssertThrowsError(
            try SafeTextTransformer.apply(.codeBlock(language: "swift evil"), to: "x")
        ) { error in
            XCTAssertEqual(
                error as? SafeTextTransformError,
                .invalidCodeBlockLanguage("swift evil")
            )
        }
    }

    func testRedactionUsesUnicodeCharacterOffsetsAndMergesOverlaps() throws {
        let original = "A👨‍👩‍👧‍👦BCDEF"
        let ranges = try [
            TextRedactionRange(location: 1, length: 2),
            TextRedactionRange(location: 2, length: 3),
        ]

        let transformed = try SafeTextTransformer.apply(
            .redact(ranges: ranges, replacement: "[X]"),
            to: original
        )

        XCTAssertEqual(transformed, "A[X]EF")
        XCTAssertEqual(original, "A👨‍👩‍👧‍👦BCDEF")
    }

    func testRedactionRejectsOutOfBoundsRange() throws {
        let range = try TextRedactionRange(location: 2, length: 2)
        XCTAssertThrowsError(
            try SafeTextTransformer.apply(
                .redact(ranges: [range], replacement: "x"),
                to: "abc"
            )
        ) { error in
            XCTAssertEqual(
                error as? SafeTextTransformError,
                .redactionRangeOutOfBounds(location: 2, length: 2, characterCount: 3)
            )
        }
    }

    func testPrivateSessionRingBufferOverwritesOldestInMemoryValue() async throws {
        let session = try PrivateSession<String>(capacity: 3)
        await session.begin()

        try await session.append("one")
        try await session.append("two")
        try await session.append("three")
        try await session.append("four")

        let isActive = await session.isActive
        let count = await session.count
        let snapshot = await session.snapshot()
        XCTAssertTrue(isActive)
        XCTAssertEqual(count, 3)
        XCTAssertEqual(snapshot, ["two", "three", "four"])
    }

    func testPrivateSessionClearAndEndDestroyBufferedValues() async throws {
        let session = try PrivateSession<Int>(capacity: 2)

        await XCTAssertThrowsErrorAsync(try await session.append(1)) { error in
            XCTAssertEqual(error as? PrivateSessionError, .sessionInactive)
        }

        await session.begin()
        try await session.append(1)
        await session.clear()
        let activeAfterClear = await session.isActive
        let snapshotAfterClear = await session.snapshot()
        XCTAssertTrue(activeAfterClear)
        XCTAssertTrue(snapshotAfterClear.isEmpty)

        try await session.append(2)
        await session.end()
        let activeAfterEnd = await session.isActive
        let countAfterEnd = await session.count
        let snapshotAfterEnd = await session.snapshot()
        XCTAssertFalse(activeAfterEnd)
        XCTAssertEqual(countAfterEnd, 0)
        XCTAssertTrue(snapshotAfterEnd.isEmpty)
    }

    func testPrivateSessionRejectsInvalidCapacity() {
        XCTAssertThrowsError(try PrivateSession<String>(capacity: 0)) { error in
            XCTAssertEqual(error as? PrivateSessionError, .invalidCapacity(0))
        }
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw")
    } catch {
        errorHandler(error)
    }
}
