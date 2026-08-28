import Foundation
import XCTest
@testable import ClipboardRouterCore

final class ConcurrencyAndFailureTests: XCTestCase {
    func testConcurrentIdenticalCapturesAreSerializedAndDeduplicated() async throws {
        let library = try ClipboardLibrary()
        let content = try ClipContent.detect(text: "same concurrent payload")

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<100 {
                group.addTask {
                    _ = try await library.capture(
                        CaptureCandidate(
                            content: content,
                            capturedAt: Date(timeIntervalSince1970: TimeInterval(index))
                        )
                    )
                }
            }
            try await group.waitForAll()
        }

        let snapshot = await library.snapshot()
        XCTAssertEqual(snapshot.history.count, 1)
        XCTAssertEqual(snapshot.history.first?.captureCount, 100)
    }

    func testConcurrentDistinctCapturesLoseNoItems() async throws {
        let library = try ClipboardLibrary()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<200 {
                group.addTask {
                    let content = try ClipContent.detect(text: "payload \(index)")
                    _ = try await library.capture(
                        CaptureCandidate(
                            content: content,
                            capturedAt: Date(timeIntervalSince1970: TimeInterval(index))
                        )
                    )
                }
            }
            try await group.waitForAll()
        }

        let snapshot = await library.snapshot()
        XCTAssertEqual(snapshot.history.count, 200)
        XCTAssertEqual(Set(snapshot.history.map(\.content.text)).count, 200)
    }

    func testPersistenceFailureLeavesInMemoryStateUnchanged() async throws {
        let store = FailingClipboardLibraryStore()
        let library = try await ClipboardLibrary.open(persistence: store)
        let before = await library.snapshot()

        do {
            _ = try await library.capture(
                CaptureCandidate(content: try ClipContent.detect(text: "must roll back"))
            )
            XCTFail("Expected persistence failure")
        } catch {
            XCTAssertEqual(error as? TestStoreError, .intentionalFailure)
        }

        let after = await library.snapshot()
        XCTAssertEqual(after, before)
    }

    func testMalformedSnapshotsFailClosed() throws {
        let duplicateID = UUID()
        let first = HistoryItem(
            id: duplicateID,
            content: try ClipContent.detect(text: "one"),
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let second = HistoryItem(
            id: duplicateID,
            content: try ClipContent.detect(text: "two"),
            createdAt: Date(timeIntervalSince1970: 2)
        )

        XCTAssertThrowsError(
            try ClipboardLibrary(snapshot: ClipboardLibrarySnapshot(history: [first, second]))
        ) { error in
            XCTAssertEqual(error as? ClipboardLibraryError, .duplicateIdentifier(duplicateID))
        }
        XCTAssertThrowsError(
            try ClipboardLibrary(snapshot: ClipboardLibrarySnapshot(schemaVersion: 999))
        ) { error in
            XCTAssertEqual(error as? ClipboardLibraryError, .unsupportedSchemaVersion(999))
        }
    }
}

private enum TestStoreError: Error, Equatable {
    case intentionalFailure
}

private actor FailingClipboardLibraryStore: ClipboardLibraryPersisting {
    func load() async throws -> ClipboardLibrarySnapshot {
        .empty
    }

    func save(_ snapshot: ClipboardLibrarySnapshot) async throws {
        throw TestStoreError.intentionalFailure
    }
}
