import Foundation
import XCTest
@testable import ClipboardRouterCore

final class PersistenceAndSearchTests: XCTestCase {
    func testOpenPrunesHistoryThatExpiredWhileApplicationWasClosed() async throws {
        let expiredDate = Date(timeIntervalSinceNow: -(2 * 24 * 60 * 60))
        let content = try ClipContent.detect(text: "expired while closed")
        let snapshot = ClipboardLibrarySnapshot(
            history: [HistoryItem(content: content, createdAt: expiredDate)],
            settings: ClipboardLibrarySettings(retentionPolicy: .oneDay)
        )
        let persistence = InMemoryClipboardLibraryStore(snapshot: snapshot)

        let library = try await ClipboardLibrary.open(persistence: persistence)

        let reopened = await library.snapshot()
        let searchResults = await library.search(query: "expired")
        let persisted = try await persistence.load()
        XCTAssertTrue(reopened.history.isEmpty)
        XCTAssertTrue(searchResults.isEmpty)
        XCTAssertTrue(persisted.history.isEmpty)
    }

    func testJSONPersistenceRoundTripIncludesPolicyAndOrganization() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardRouterTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("library.json")
        let store = JSONFileClipboardLibraryStore(fileURL: fileURL)

        let timestamp = Date(timeIntervalSince1970: 1_700_000_000.123_456)
        let folder = try ClipFolder(name: "Prompts", sortOrder: 0, createdAt: timestamp)
        let history = HistoryItem(
            content: try ClipContent.detect(text: "https://example.com/path"),
            createdAt: timestamp,
            sourceApplicationBundleIdentifier: "com.apple.Safari",
            originatingDeviceIdentifier: "test-mac"
        )
        let saved = try SavedClip(
            name: "Example link",
            content: history.content,
            folderID: folder.id,
            sourceHistoryItemID: history.id,
            createdAt: timestamp
        )
        var policy = CapturePolicy()
        policy.setApplication("com.example.private", excluded: true)
        let expected = ClipboardLibrarySnapshot(
            history: [history],
            savedClips: [saved],
            folders: [folder],
            settings: ClipboardLibrarySettings(
                capturePolicy: policy,
                retentionPolicy: .sevenDays
            )
        )

        try await store.save(expected)
        let loaded = try await store.load()

        XCTAssertEqual(loaded, expected)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        let raw = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(raw.contains("\"schemaVersion\" : 3"))
    }

    func testMissingPersistenceFileLoadsEmptySnapshot() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString)/library.json")
        let store = JSONFileClipboardLibraryStore(fileURL: url)
        let loaded = try await store.load()
        XCTAssertEqual(loaded, .empty)
    }

    func testCorruptPersistenceFileReturnsTypedError() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardRouterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("library.json")
        try Data("not json".utf8).write(to: fileURL)
        let store = JSONFileClipboardLibraryStore(fileURL: fileURL)

        do {
            _ = try await store.load()
            XCTFail("Expected decoding failure")
        } catch {
            guard case .undecodableFile = error as? ClipboardLibraryPersistenceError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testOpenRepairsOrphanedFolderReferencesToUnfiled() async throws {
        let timestamp = Date(timeIntervalSince1970: 100)
        let orphan = try SavedClip(
            name: "Orphan",
            content: try ClipContent.detect(text: "still safe"),
            folderID: UUID(),
            createdAt: timestamp
        )
        let store = InMemoryClipboardLibraryStore(
            snapshot: ClipboardLibrarySnapshot(savedClips: [orphan])
        )

        let library = try await ClipboardLibrary.open(persistence: store)
        let snapshot = await library.snapshot()
        let persisted = try await store.load()
        XCTAssertNil(snapshot.savedClips.first?.folderID)
        XCTAssertNil(persisted.savedClips.first?.folderID)
    }

    func testSearchFindsOneMatchingClipAmongTenThousandWithoutNetwork() async throws {
        let base = Date(timeIntervalSince1970: 2_000_000)
        var history = (0..<10_000).map { index in
            HistoryItem(
                id: deterministicUUID(index),
                content: try! ClipContent.detect(text: "ordinary clipboard record \(index)"),
                createdAt: base.addingTimeInterval(TimeInterval(index))
            )
        }
        let needleID = history[7_777].id
        history[7_777] = HistoryItem(
            id: needleID,
            content: try ClipContent.detect(text: "Unique Café Needle 7788"),
            createdAt: base.addingTimeInterval(7_777)
        )
        let library = try ClipboardLibrary(
            snapshot: ClipboardLibrarySnapshot(history: history)
        )

        let clock = ContinuousClock()
        let start = clock.now
        let results = await library.search(query: "cafe needle", limit: 10)
        let elapsed = start.duration(to: clock.now)

        XCTAssertEqual(results.map(\.id), [needleID])
        XCTAssertLessThan(elapsed, .seconds(1), "10k search took \(elapsed)")
    }

    func testSearchRankingAndLimitsAreDeterministic() async throws {
        let timestamp = Date(timeIntervalSince1970: 10)
        let exact = try SavedClip(
            id: deterministicUUID(1),
            name: "Deploy",
            content: try ClipContent.detect(text: "release instructions"),
            createdAt: timestamp
        )
        let prefix = try SavedClip(
            id: deterministicUUID(2),
            name: "Deployment checklist",
            content: try ClipContent.detect(text: "deploy safely"),
            createdAt: timestamp.addingTimeInterval(1)
        )
        let library = try ClipboardLibrary(
            snapshot: ClipboardLibrarySnapshot(savedClips: [prefix, exact])
        )

        let results = await library.search(query: "deploy", limit: 1)
        XCTAssertEqual(results.map(\.id), [exact.id])
        let emptyResults = await library.search(query: "", limit: 0)
        XCTAssertTrue(emptyResults.isEmpty)
    }

    private func deterministicUUID(_ integer: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", integer))!
    }
}
