import Foundation
import SQLite3
import XCTest
@testable import ClipboardRouterCore

final class SQLitePersistenceMigrationTests: XCTestCase {
    func testExistingSQLiteV2ReopensAsV3AndPersistsUpgrade() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sqlite-v2-reopen-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("library.sqlite")
        let saved = try SavedClip(
            name: "Legacy saved clip",
            content: try ClipContent.detect(text: "legacy sqlite body"),
            createdAt: Date(timeIntervalSince1970: 10)
        )
        do {
            let writer = SQLiteFileClipboardLibraryStore(fileURL: databaseURL)
            try await writer.save(ClipboardLibrarySnapshot(savedClips: [saved]))
        }
        // Simulate the actual durable schema marker left by the v2 application. Entity payloads
        // are independently backward-compatible and decode missing v3 fields with safe defaults.
        try executeSQLite(
            databaseURL,
            sql: "UPDATE metadata SET value = CAST('2' AS BLOB) WHERE key = 'schemaVersion'"
        )
        XCTAssertEqual(
            try readSQLiteText(
                databaseURL,
                sql: "SELECT CAST(value AS TEXT) FROM metadata WHERE key = 'schemaVersion'"
            ),
            "2"
        )

        let reopenedStore = SQLiteFileClipboardLibraryStore(fileURL: databaseURL)
        let loaded = try await reopenedStore.load()
        XCTAssertEqual(loaded.schemaVersion, 3)
        XCTAssertEqual(loaded.savedClips.first?.kind, .clip)
        XCTAssertEqual(loaded.savedClips.first?.content.text, "legacy sqlite body")
        XCTAssertEqual(
            try readSQLiteText(
                databaseURL,
                sql: "SELECT CAST(value AS TEXT) FROM metadata WHERE key = 'schemaVersion'"
            ),
            "3"
        )

        let secondReopen = SQLiteFileClipboardLibraryStore(fileURL: databaseURL)
        let secondLoaded = try await secondReopen.load()
        XCTAssertEqual(secondLoaded, loaded)
    }

    func testLegacyJSONImportsOnceKeepsBackupAndRejectsContentBeforeFTS() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sqlite-migration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let jsonURL = directory.appendingPathComponent("library.json")
        let sqliteURL = directory.appendingPathComponent("library.sqlite")
        let canary = "CRQA_SECRET_\(UUID().uuidString)"
        let snapshot = ClipboardLibrarySnapshot(
            history: [
                HistoryItem(
                    content: try ClipContent.detect(text: "safe legacy clip"),
                    createdAt: Date(timeIntervalSince1970: 1)
                ),
                HistoryItem(
                    content: try ClipContent.detect(text: canary),
                    createdAt: Date(timeIntervalSince1970: 2)
                ),
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var encoded = String(decoding: try encoder.encode(snapshot), as: UTF8.self)
        encoded = encoded.replacingOccurrences(of: "\"schemaVersion\":3", with: "\"schemaVersion\":1")
        try Data(encoded.utf8).write(to: jsonURL, options: [.atomic])

        let store = SQLiteFileClipboardLibraryStore(
            fileURL: sqliteURL,
            legacyJSONURL: jsonURL,
            legacyContentAdmission: { !$0.text.contains("CRQA_SECRET_") }
        )
        let loaded = try await store.load()
        XCTAssertEqual(loaded.history.map(\.content.text), ["safe legacy clip"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: jsonURL.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("library.v1.migrated.json").path
            )
        )

        // The rejected canary may remain in the deliberately retained legacy backup, but never in
        // the ordinary SQLite database, FTS index, WAL, or SHM files.
        for name in ["library.sqlite", "library.sqlite-wal", "library.sqlite-shm"] {
            let url = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            XCTAssertFalse(Data(try Data(contentsOf: url)).contains(Data(canary.utf8)), name)
        }

        let reopened = SQLiteFileClipboardLibraryStore(
            fileURL: sqliteURL,
            legacyJSONURL: jsonURL,
            legacyContentAdmission: { _ in false }
        )
        let reopenedSnapshot = try await reopened.load()
        XCTAssertEqual(reopenedSnapshot, loaded)
    }

    func testLegacyJSONMigrationVerifiesMultipleEntitiesIndependentOfSQLiteRowOrder() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sqlite-migration-order-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let jsonURL = directory.appendingPathComponent("library.json")
        let sqliteURL = directory.appendingPathComponent("library.sqlite")

        let recentHistoryID = try XCTUnwrap(
            UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")
        )
        let olderHistoryID = try XCTUnwrap(
            UUID(uuidString: "11111111-1111-1111-1111-111111111111")
        )
        let firstFolderID = try XCTUnwrap(
            UUID(uuidString: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee")
        )
        let secondFolderID = try XCTUnwrap(
            UUID(uuidString: "22222222-2222-2222-2222-222222222222")
        )
        let firstSavedID = try XCTUnwrap(
            UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")
        )
        let secondSavedID = try XCTUnwrap(
            UUID(uuidString: "33333333-3333-3333-3333-333333333333")
        )
        let now = Date()
        let recentContent = try ClipContent.detect(text: "recent legacy history")
        let olderContent = try ClipContent.detect(text: "older legacy history")
        let firstFolder = try ClipFolder(
            id: firstFolderID,
            name: "First Folder",
            sortOrder: 0,
            createdAt: now.addingTimeInterval(-40)
        )
        let secondFolder = try ClipFolder(
            id: secondFolderID,
            name: "Second Folder",
            sortOrder: 1,
            createdAt: now.addingTimeInterval(-30)
        )
        let snapshot = ClipboardLibrarySnapshot(
            history: [
                HistoryItem(
                    id: recentHistoryID,
                    content: recentContent,
                    createdAt: now
                ),
                HistoryItem(
                    id: olderHistoryID,
                    content: olderContent,
                    createdAt: now.addingTimeInterval(-20)
                ),
            ],
            savedClips: [
                try SavedClip(
                    id: firstSavedID,
                    name: "First Saved",
                    content: recentContent,
                    folderID: firstFolderID,
                    sourceHistoryItemID: recentHistoryID,
                    createdAt: now.addingTimeInterval(-10),
                    sensitivity: try ClipSensitivityMetadata(
                        category: "apiKey",
                        confidence: 99,
                        detectorVersion: 1
                    )
                ),
                try SavedClip(
                    id: secondSavedID,
                    name: "Second Saved",
                    content: olderContent,
                    folderID: secondFolderID,
                    sourceHistoryItemID: olderHistoryID,
                    createdAt: now.addingTimeInterval(-30)
                ),
            ],
            folders: [firstFolder, secondFolder]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var encoded = String(decoding: try encoder.encode(snapshot), as: UTF8.self)
        encoded = encoded.replacingOccurrences(of: "\"schemaVersion\":3", with: "\"schemaVersion\":1")
        try Data(encoded.utf8).write(to: jsonURL, options: [.atomic])

        let store = SQLiteFileClipboardLibraryStore(
            fileURL: sqliteURL,
            legacyJSONURL: jsonURL
        )
        let library = try await ClipboardLibrary.open(persistence: store)
        let loaded = await library.snapshot()

        XCTAssertEqual(loaded.history.map(\.id), [recentHistoryID, olderHistoryID])
        XCTAssertEqual(loaded.folders.map(\.id), [firstFolderID, secondFolderID])
        XCTAssertEqual(Set(loaded.savedClips.map(\.id)), Set([firstSavedID, secondSavedID]))
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: loaded.savedClips.map { ($0.id, $0.folderID) }),
            [firstSavedID: firstFolderID, secondSavedID: secondFolderID]
        )
        let contentSearchIDs = await library.search(query: "recent legacy", limit: 10).map(\.id)
        XCTAssertEqual(contentSearchIDs, [recentHistoryID, firstSavedID])
        let secretSearchIDs = await library.search(query: "secret:apiKey", limit: 10).map(\.id)
        XCTAssertEqual(secretSearchIDs, [firstSavedID])
        XCTAssertFalse(FileManager.default.fileExists(atPath: jsonURL.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("library.v1.migrated.json").path
            )
        )

        let reopenedStore = SQLiteFileClipboardLibraryStore(fileURL: sqliteURL)
        let reopened = try await ClipboardLibrary.open(persistence: reopenedStore)
        let reopenedSnapshot = await reopened.snapshot()
        XCTAssertEqual(reopenedSnapshot, loaded)
    }

    func testSQLiteRoundTripUpdatesAndDeletesWithoutLosingOrganization() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sqlite-roundtrip-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("library.sqlite")
        let store = SQLiteFileClipboardLibraryStore(fileURL: databaseURL)
        let library = try await ClipboardLibrary.open(persistence: store)
        let first = try await library.capture(
            CaptureCandidate(
                content: try ClipContent.detect(text: "First"),
                capturedAt: Date(timeIntervalSince1970: 1)
            )
        )
        guard case let .inserted(history) = first else { return XCTFail("Expected insert") }
        let folder = try await library.createFolder(name: "Research")
        let saved = try await library.saveHistoryItem(id: history.id, folderID: folder.id)
        try await library.setSavedClipPinned(id: saved.id, pinned: true)
        try await library.deleteHistoryItem(id: history.id)
        let expected = await library.snapshot()

        let reopenedStore = SQLiteFileClipboardLibraryStore(fileURL: databaseURL)
        let reopened = try await ClipboardLibrary.open(persistence: reopenedStore)
        let actual = await reopened.snapshot()
        XCTAssertEqual(actual, expected)
        XCTAssertTrue(actual.savedClips.first?.isPinned == true)
        XCTAssertEqual(actual.savedClips.first?.folderID, folder.id)
    }

    func testDiskBackedTenThousandRowFTSRepairsMissingAndInconsistentIndex() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sqlite-fts-repair-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("library.sqlite")
        let base = Date(timeIntervalSince1970: 10_000)
        let history = try (0..<10_000).map { index in
            HistoryItem(
                content: try ClipContent.detect(text: "disk record \(index) diskneedle\(index)"),
                createdAt: base.addingTimeInterval(TimeInterval(index))
            )
        }
        let needle = try XCTUnwrap(history.last)
        do {
            let store = SQLiteFileClipboardLibraryStore(fileURL: databaseURL)
            try await store.save(ClipboardLibrarySnapshot(history: history))
        }

        // Opening creates an absent table, then load must detect that the empty derived index is
        // inconsistent with its 10k source rows and rebuild it before returning.
        try executeSQLite(databaseURL, sql: "DROP TABLE clip_search")
        let repairedMissing = SQLiteFileClipboardLibraryStore(fileURL: databaseURL)
        let repairedSnapshot = try await repairedMissing.load()
        let repairedSearch = await repairedMissing.search(query: "diskneedle9999", limit: 5)
        XCTAssertEqual(repairedSnapshot.history.count, 10_000)
        XCTAssertEqual(repairedSearch.map(\.id), [needle.id])

        _ = await repairedMissing.search(query: "diskneedle5000", limit: 5)
        let clock = ContinuousClock()
        let start = clock.now
        let warmResults = await repairedMissing.search(query: "diskneedle5000", limit: 5)
        let elapsed = start.duration(to: clock.now)
        XCTAssertEqual(warmResults.map(\.id), [history[5_000].id])
        XCTAssertLessThan(elapsed, .milliseconds(250), "Warm disk-backed 10k query took \(elapsed)")

        let needleID = needle.id.uuidString.lowercased()
        try executeSQLite(
            databaseURL,
            sql: "UPDATE clip_search SET body = 'stale body' WHERE id = '\(needleID)'"
        )
        let repairedInconsistent = SQLiteFileClipboardLibraryStore(fileURL: databaseURL)
        _ = try await repairedInconsistent.load()
        let repairedInconsistentSearch = await repairedInconsistent.search(
            query: "diskneedle9999",
            limit: 5
        )
        XCTAssertEqual(repairedInconsistentSearch.map(\.id), [needle.id])
    }
}

private func executeSQLite(_ databaseURL: URL, sql: String) throws {
    var database: OpaquePointer?
    let openResult = sqlite3_open_v2(
        databaseURL.path,
        &database,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
        nil
    )
    guard openResult == SQLITE_OK, let database else {
        if let database { sqlite3_close(database) }
        throw NSError(domain: "SQLitePersistenceMigrationTests", code: Int(openResult))
    }
    defer { sqlite3_close(database) }
    sqlite3_busy_timeout(database, 5_000)
    let result = sqlite3_exec(database, sql, nil, nil, nil)
    guard result == SQLITE_OK else {
        throw NSError(
            domain: "SQLitePersistenceMigrationTests",
            code: Int(result),
            userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(database))]
        )
    }
}

private func readSQLiteText(_ databaseURL: URL, sql: String) throws -> String? {
    var database: OpaquePointer?
    let openResult = sqlite3_open_v2(
        databaseURL.path,
        &database,
        SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
        nil
    )
    guard openResult == SQLITE_OK, let database else {
        if let database { sqlite3_close(database) }
        throw NSError(domain: "SQLitePersistenceMigrationTests", code: Int(openResult))
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    let prepareResult = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
    guard prepareResult == SQLITE_OK, let statement else {
        throw NSError(domain: "SQLitePersistenceMigrationTests", code: Int(prepareResult))
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
    return sqlite3_column_text(statement, 0).map { String(cString: $0) }
}

private extension Data {
    func contains(_ needle: Data) -> Bool {
        range(of: needle) != nil
    }
}
