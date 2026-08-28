import Foundation
import SQLite3
import XCTest
@testable import ClipboardRouterCore

final class SearchQueryTests: XCTestCase {
    func testNaturalRetrievalPhrasesBecomeDeterministicFilters() throws {
        let now = utcDate(2026, 8, 12, hour: 15)
        let today = utcDate(2026, 8, 12, hour: 9)
        let yesterday = utcDate(2026, 8, 11, hour: 9)
        let previousWeek = utcDate(2026, 8, 6, hour: 9)
        let currentWeek = utcDate(2026, 8, 10, hour: 9)

        let chromeYesterday = history(
            1,
            text: "quarterly research",
            at: yesterday,
            source: "Chrome"
        )
        let figmaImage = HistoryItem(
            id: uuid(2),
            content: try ClipContent(type: .image, text: "checkout mockup"),
            createdAt: today,
            captureContext: ClipCaptureContext(sourceApplicationName: "Figma")
        )
        let capeTownLink = HistoryItem(
            id: uuid(3),
            content: try ClipContent.detect(text: "https://example.com/leads"),
            createdAt: today,
            captureContext: ClipCaptureContext(
                sourceApplicationName: "Safari",
                coarseLocation: try CoarseLocationContext(label: "Cape Town")
            )
        )
        let vsCodeAWS = history(
            4,
            text: "AWS deployment checklist",
            at: today,
            source: "VS Code"
        )
        let pdfFile = try ClipFileReference(
            url: URL(fileURLWithPath: "/tmp/customer-brief.pdf"),
            displayName: "customer-brief.pdf"
        )
        let previousWeekPDF = HistoryItem(
            id: uuid(5),
            content: try ClipContent(
                type: .fileURLs,
                text: "customer-brief.pdf",
                representations: ClipRepresentations(files: [pdfFile])
            ),
            createdAt: previousWeek
        )
        let macBookClip = HistoryItem(
            id: uuid(6),
            content: try ClipContent.detect(text: "device-specific note"),
            createdAt: today,
            captureContext: ClipCaptureContext(deviceLabel: "My MacBook")
        )
        let secretToday = HistoryItem(
            id: uuid(7),
            content: try ClipContent.detect(text: "credential retained by user"),
            createdAt: today,
            sensitivity: try ClipSensitivityMetadata(
                category: "apiKey",
                confidence: 99,
                detectorVersion: 1
            )
        )

        let distractors = [
            history(101, text: "quarterly research", at: today, source: "Chrome"),
            history(102, text: "quarterly research", at: yesterday, source: "Safari"),
            history(103, text: "AWS deployment checklist", at: today, source: "Slack"),
            history(104, text: "Azure deployment checklist", at: today, source: "VS Code"),
            HistoryItem(
                id: uuid(105),
                content: try ClipContent(
                    type: .fileURLs,
                    text: "current-week.pdf",
                    representations: ClipRepresentations(files: [pdfFile])
                ),
                createdAt: currentWeek
            ),
            HistoryItem(
                id: uuid(106),
                content: try ClipContent.detect(text: "not a link"),
                createdAt: today,
                captureContext: ClipCaptureContext(
                    coarseLocation: try CoarseLocationContext(label: "Cape Town")
                )
            ),
            HistoryItem(
                id: uuid(107),
                content: try ClipContent.detect(text: "old credential"),
                createdAt: yesterday,
                sensitivity: try ClipSensitivityMetadata(
                    category: "apiKey",
                    confidence: 99,
                    detectorVersion: 1
                )
            ),
        ]
        let index = ClipSearchIndex(snapshot: ClipboardLibrarySnapshot(history: [
            chromeYesterday,
            figmaImage,
            capeTownLink,
            vsCodeAWS,
            previousWeekPDF,
            macBookClip,
            secretToday,
        ] + distractors))

        XCTAssertEqual(index.search(query: "from Chrome yesterday", limit: 20, now: now).map(\.id), [chromeYesterday.id])
        XCTAssertEqual(index.search(query: "images from Figma", limit: 20, now: now).map(\.id), [figmaImage.id])
        XCTAssertEqual(index.search(query: "links copied in Cape Town", limit: 20, now: now).map(\.id), [capeTownLink.id])
        XCTAssertEqual(index.search(query: "clips from VS Code containing AWS", limit: 20, now: now).map(\.id), [vsCodeAWS.id])
        XCTAssertEqual(index.search(query: "PDFs copied last week", limit: 20, now: now).map(\.id), [previousWeekPDF.id])
        XCTAssertEqual(index.search(query: "things copied on my MacBook", limit: 20, now: now).map(\.id), [macBookClip.id])
        XCTAssertEqual(index.search(query: "secrets copied today", limit: 20, now: now).map(\.id), [secretToday.id])
    }

    func testExactFieldTokensRemainSupportedAndDateUsesCaptureTime() throws {
        let captured = utcDate(2026, 8, 11, hour: 8)
        let modified = utcDate(2026, 8, 12, hour: 8)
        let saved = try SavedClip(
            id: uuid(200),
            name: "Saved research",
            content: try ClipContent.detect(text: "https://example.com/aws"),
            createdAt: captured,
            modifiedAt: modified,
            sourceApplicationBundleIdentifier: "com.google.Chrome",
            captureContext: ClipCaptureContext(
                sourceApplicationName: "Chrome",
                sourceDomain: "example.com",
                deviceLabel: "My MacBook",
                coarseLocation: try CoarseLocationContext(label: "Cape Town")
            ),
            originallyCapturedAt: captured,
            sensitivity: try ClipSensitivityMetadata(
                category: "apiKey",
                confidence: 100,
                detectorVersion: 1
            )
        )
        let index = ClipSearchIndex(snapshot: ClipboardLibrarySnapshot(savedClips: [saved]))

        for query in [
            "source:chrome",
            "sourceexact:Chrome",
            "domain:example.com",
            "domainexact:example.com",
            "type:url",
            "device:my",
            "location:cape",
            "secret:apiKey",
            "date:2026-08-11",
        ] {
            XCTAssertEqual(index.search(query: query, limit: 10).map(\.id), [saved.id], query)
        }
        XCTAssertTrue(index.search(query: "date:2026-08-12", limit: 10).isEmpty)
    }

    func testExactSmartViewFacetsDoNotBroadenToRelatedAppsOrSubdomains() throws {
        let visualStudio = history(210, text: "studio", at: utcDate(2026, 8, 12, hour: 8), source: "Visual Studio")
        let visualDesigner = history(211, text: "designer", at: utcDate(2026, 8, 12, hour: 9), source: "Visual Designer")
        let rootDomain = HistoryItem(
            id: uuid(212),
            content: try ClipContent.detect(text: "https://example.com"),
            createdAt: utcDate(2026, 8, 12, hour: 10),
            captureContext: ClipCaptureContext(sourceDomain: "example.com")
        )
        let subdomain = HistoryItem(
            id: uuid(213),
            content: try ClipContent.detect(text: "https://docs.example.com"),
            createdAt: utcDate(2026, 8, 12, hour: 11),
            captureContext: ClipCaptureContext(sourceDomain: "docs.example.com")
        )
        let index = ClipSearchIndex(snapshot: ClipboardLibrarySnapshot(history: [
            visualStudio, visualDesigner, rootDomain, subdomain,
        ]))

        XCTAssertEqual(index.search(query: "sourceexact:Visual+Studio", limit: 10).map(\.id), [visualStudio.id])
        XCTAssertEqual(index.search(query: "domainexact:example.com", limit: 10).map(\.id), [rootDomain.id])
    }

    func testExactFilterReturnsGloballyNewestResultsBeyondFormerCandidateWindow() async throws {
        let base = utcDate(2026, 8, 1, hour: 0)
        let records = (0..<150).map { index in
            history(
                300 + index,
                text: "shared source record \(index)",
                at: base.addingTimeInterval(TimeInterval(index)),
                source: "Chrome"
            )
        }
        let expected = records.suffix(5).reversed().map(\.id)

        let memoryIndex = ClipSearchIndex(snapshot: ClipboardLibrarySnapshot(history: records))
        XCTAssertEqual(memoryIndex.search(query: "source:chrome", limit: 5).map(\.id), expected)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sqlite-exact-order-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteFileClipboardLibraryStore(
            fileURL: directory.appendingPathComponent("library.sqlite")
        )
        try await store.save(ClipboardLibrarySnapshot(history: records))
        let diskResults = await store.search(query: "source:chrome", limit: 5)
        XCTAssertEqual(diskResults.map(\.id), expected)
    }

    func testDiskBackedTenThousandRowNaturalSearchDecodesOnlyMatchingCandidates() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sqlite-candidate-search-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("library.sqlite")
        let base = Date()
        var history = try (0..<10_000).map { index in
            HistoryItem(
                id: uuid(index + 1_000),
                content: try ClipContent.detect(text: "ordinary clipboard record \(index)"),
                createdAt: base.addingTimeInterval(TimeInterval(-index))
            )
        }
        let needle = HistoryItem(
            id: uuid(20_001),
            content: try ClipContent.detect(text: "AWS production runbook candidate-only-needle"),
            createdAt: base,
            captureContext: ClipCaptureContext(sourceApplicationName: "VS Code")
        )
        history.append(needle)

        do {
            let store = SQLiteFileClipboardLibraryStore(fileURL: databaseURL)
            try await store.save(ClipboardLibrarySnapshot(history: history))
        }

        // A full snapshot decode would fail on this unrelated row. Candidate-only retrieval must
        // never touch it when FTS selects the unique VS Code/AWS row.
        let corruptID = history[0].id.uuidString.lowercased()
        try executeSearchSQLite(
            databaseURL,
            sql: "UPDATE objects SET payload = X'00' WHERE id = '\(corruptID)'"
        )
        let freshStore = SQLiteFileClipboardLibraryStore(fileURL: databaseURL)
        let clock = ContinuousClock()
        let start = clock.now
        let results = await freshStore.search(
            query: "clips from VS Code containing AWS",
            limit: 10
        )
        let elapsed = start.duration(to: clock.now)

        XCTAssertEqual(results.map(\.id), [needle.id])
        XCTAssertLessThan(elapsed, .seconds(1), "Candidate-only 10k query took \(elapsed)")
    }

    func testCanonicalMetadataQueriesHaveInMemoryAndSQLiteParity() async throws {
        let folder = try ClipFolder(
            id: uuid(30_001),
            name: "Launch Research",
            sortOrder: 0,
            createdAt: utcDate(2026, 8, 10, hour: 8)
        )
        let asset = try ClipAssetReference(
            digest: String(repeating: "a", count: 64),
            kind: .image,
            uniformTypeIdentifier: "public.png",
            byteCount: 2 * 1_048_576,
            relativePath: "aa/asset.png"
        )
        let historyItem = HistoryItem(
            id: uuid(30_002),
            content: try ClipContent(
                type: .image,
                text: "Dashboard preview",
                representations: ClipRepresentations(
                    image: asset,
                    ocrText: "Northstar revenue pipeline"
                )
            ),
            createdAt: utcDate(2026, 8, 10, hour: 9),
            captureCount: 7,
            sourceApplicationBundleIdentifier: "com.figma.Desktop",
            originatingDeviceIdentifier: "workstation-17",
            captureContext: ClipCaptureContext(
                sourceApplicationName: "Figma",
                sourceDomain: "figma.com",
                deviceLabel: "Studio Mac",
                coarseLocation: try CoarseLocationContext(label: "Toronto")
            ),
            sensitivity: try ClipSensitivityMetadata(
                category: "customerRecord",
                confidence: 91,
                detectorVersion: 1
            ),
            pasteboardTypeIdentifiers: ["public.png"],
            pasteCount: 3
        )
        let savedClip = try SavedClip(
            id: uuid(30_003),
            name: "Outbound template",
            content: try ClipContent.detect(text: "Qualified lead follow-up"),
            folderID: folder.id,
            createdAt: utcDate(2026, 8, 10, hour: 10),
            pinnedAt: utcDate(2026, 8, 10, hour: 11),
            tags: ["Sales", "Priority"],
            sourceApplicationBundleIdentifier: "com.apple.Safari",
            captureContext: ClipCaptureContext(sourceApplicationName: "Safari"),
            pasteboardTypeIdentifiers: ["public.utf8-plain-text"]
        )
        let snapshot = ClipboardLibrarySnapshot(
            history: [historyItem],
            savedClips: [savedClip],
            folders: [folder]
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sqlite-metadata-parity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteFileClipboardLibraryStore(
            fileURL: directory.appendingPathComponent("library.sqlite")
        )
        try await store.save(snapshot)
        let memory = ClipSearchIndex(snapshot: snapshot)

        let cases: [(String, [UUID])] = [
            ("northstar", [historyItem.id]),
            ("source:figma", [historyItem.id]),
            ("app:figma", [historyItem.id]),
            ("domain:figma.com", [historyItem.id]),
            ("type:image", [historyItem.id]),
            ("device:workstation", [historyItem.id]),
            ("location:toronto", [historyItem.id]),
            ("sensitivity:customerrecord", [historyItem.id]),
            ("uti:public.png", [historyItem.id]),
            ("size:>1mb", [historyItem.id]),
            ("captures:>=7", [historyItem.id]),
            ("pastes:>2", [historyItem.id]),
            ("origin:history", [historyItem.id]),
            ("folder:launch", [savedClip.id]),
            ("tag:sales", [savedClip.id]),
            ("pinned:true", [savedClip.id]),
            ("origin:saved", [savedClip.id]),
            ("type:text", [savedClip.id]),
        ]
        for (query, expected) in cases {
            let memoryIDs = memory.search(query: query, limit: 20).map(\.id)
            let diskIDs = await store.search(query: query, limit: 20).map(\.id)
            XCTAssertEqual(memoryIDs, expected, "memory: \(query)")
            XCTAssertEqual(diskIDs, expected, "disk: \(query)")
        }
    }

    func testFolderRenameAndDeleteUpdateDerivedSearchStateAtomically() async throws {
        let folderID = uuid(31_001)
        let clipID = uuid(31_002)
        let createdAt = utcDate(2026, 8, 10, hour: 9)
        let originalFolder = try ClipFolder(
            id: folderID,
            name: "Alpha",
            sortOrder: 0,
            createdAt: createdAt
        )
        let clip = try SavedClip(
            id: clipID,
            name: "Folder-bound clip",
            content: try ClipContent.detect(text: "stable content"),
            folderID: folderID,
            createdAt: createdAt
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sqlite-folder-index-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteFileClipboardLibraryStore(
            fileURL: directory.appendingPathComponent("library.sqlite")
        )
        try await store.save(ClipboardLibrarySnapshot(savedClips: [clip], folders: [originalFolder]))
        var results = await store.search(query: "folder:alpha", limit: 10)
        XCTAssertEqual(results.map(\.id), [clipID])

        let renamedFolder = try ClipFolder(
            id: folderID,
            name: "Beta",
            sortOrder: 0,
            createdAt: createdAt,
            modifiedAt: createdAt.addingTimeInterval(1)
        )
        try await store.save(ClipboardLibrarySnapshot(savedClips: [clip], folders: [renamedFolder]))
        results = await store.search(query: "folder:alpha", limit: 10)
        XCTAssertTrue(results.isEmpty)
        results = await store.search(query: "folder:beta", limit: 10)
        XCTAssertEqual(results.map(\.id), [clipID])

        var unfiled = clip
        unfiled.folderID = nil
        try await store.save(ClipboardLibrarySnapshot(savedClips: [unfiled], folders: []))
        results = await store.search(query: "folder:beta", limit: 10)
        XCTAssertTrue(results.isEmpty)
        results = await store.search(query: "origin:saved", limit: 10)
        XCTAssertEqual(results.map(\.id), [clipID])
        results = await store.search(query: "origin:saved folder:unfiled", limit: 10)
        XCTAssertEqual(results.map(\.id), [clipID])
    }

    func testNumericOnlyFacetSearchIsCandidateBoundedAtTenThousandRows() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sqlite-numeric-candidates-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("library.sqlite")
        var history = (0..<10_000).map { index in
            HistoryItem(
                id: uuid(40_000 + index),
                content: try! ClipContent.detect(text: "numeric ordinary \(index)"),
                createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                captureCount: 1,
                pasteCount: 0
            )
        }
        let needle = HistoryItem(
            id: uuid(60_001),
            content: try ClipContent.detect(text: "numeric needle"),
            createdAt: Date(timeIntervalSince1970: 20_000),
            captureCount: 50,
            pasteCount: 12
        )
        history.append(needle)
        do {
            let store = SQLiteFileClipboardLibraryStore(fileURL: databaseURL)
            try await store.save(ClipboardLibrarySnapshot(history: history))
        }
        try executeSearchSQLite(
            databaseURL,
            sql: "UPDATE objects SET payload = X'00' WHERE id = '\(history[0].id.uuidString.lowercased())'"
        )
        let store = SQLiteFileClipboardLibraryStore(fileURL: databaseURL)
        let clock = ContinuousClock()
        let start = clock.now
        let results = await store.search(query: "captures:>40 pastes:>=10", limit: 5)
        let elapsed = start.duration(to: clock.now)
        XCTAssertEqual(results.map(\.id), [needle.id])
        XCTAssertLessThan(elapsed, .seconds(1), "Numeric-only 10k facet query took \(elapsed)")
    }

    func testStructuredSubstringCandidatesNeverDropFieldValidRows() async throws {
        let folder = try ClipFolder(
            id: uuid(70_001),
            name: "Launch Research",
            sortOrder: 0,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let chrome = HistoryItem(
            id: uuid(70_002),
            content: try ClipContent.detect(text: "browser record"),
            createdAt: Date(timeIntervalSince1970: 2),
            captureContext: ClipCaptureContext(sourceApplicationName: "Chrome")
        )
        let code = HistoryItem(
            id: uuid(70_003),
            content: try ClipContent.detect(text: "editor record"),
            createdAt: Date(timeIntervalSince1970: 3),
            captureContext: ClipCaptureContext(sourceApplicationName: "VS Code")
        )
        let saved = try SavedClip(
            id: uuid(70_004),
            name: "Filed",
            content: try ClipContent.detect(text: "saved record"),
            folderID: folder.id,
            createdAt: Date(timeIntervalSince1970: 4)
        )
        let snapshot = ClipboardLibrarySnapshot(
            history: [chrome, code],
            savedClips: [saved],
            folders: [folder]
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sqlite-substring-candidates-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteFileClipboardLibraryStore(fileURL: directory.appendingPathComponent("library.sqlite"))
        try await store.save(snapshot)
        let memory = ClipSearchIndex(snapshot: snapshot)

        for (query, expected) in [
            ("source:ome", chrome.id),
            ("source:code", code.id),
            ("folder:search", saved.id),
        ] {
            XCTAssertEqual(memory.search(query: query, limit: 10).map(\.id), [expected], "memory: \(query)")
            let disk = await store.search(query: query, limit: 10)
            XCTAssertEqual(disk.map(\.id), [expected], "disk: \(query)")
        }
    }

    func testLinkedSavedClipUsageStaysConsistentAcrossIncrementalSQLiteReindex() async throws {
        let historyID = uuid(71_001)
        let savedID = uuid(71_002)
        var history = HistoryItem(
            id: historyID,
            content: try ClipContent.detect(text: "reused payload"),
            createdAt: Date(timeIntervalSince1970: 10),
            captureCount: 1,
            pasteCount: 0
        )
        let saved = try SavedClip(
            id: savedID,
            name: "Reusable",
            content: history.content,
            sourceHistoryItemID: historyID,
            createdAt: Date(timeIntervalSince1970: 11)
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sqlite-linked-usage-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteFileClipboardLibraryStore(fileURL: directory.appendingPathComponent("library.sqlite"))
        try await store.save(ClipboardLibrarySnapshot(history: [history], savedClips: [saved]))
        var disk = await store.search(query: "captures:>=2", limit: 10)
        XCTAssertTrue(disk.isEmpty)

        history.captureCount = 4
        history.pasteCount = 3
        try await store.save(ClipboardLibrarySnapshot(history: [history], savedClips: [saved]))
        let snapshot = ClipboardLibrarySnapshot(history: [history], savedClips: [saved])
        let memory = ClipSearchIndex(snapshot: snapshot).search(query: "captures:>=2 pastes:>0", limit: 10)
        disk = await store.search(query: "captures:>=2 pastes:>0", limit: 10)
        XCTAssertEqual(Set(memory.map(\.id)), Set([historyID, savedID]))
        XCTAssertEqual(Set(disk.map(\.id)), Set([historyID, savedID]))
        XCTAssertTrue(memory.allSatisfy { $0.captureCount == 4 && $0.pasteCount == 3 })
        XCTAssertTrue(disk.allSatisfy { $0.captureCount == 4 && $0.pasteCount == 3 })
    }

    func testExactDateUsesLocalDayWhileFTSCandidatesCoverIntersectingUTCDates() async throws {
        let calendar = Calendar.current
        let localDate = calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: 2026,
            month: 8,
            day: 10,
            hour: 23,
            minute: 30
        ))!
        let item = HistoryItem(
            id: uuid(72_001),
            content: try ClipContent.detect(text: "local midnight boundary"),
            createdAt: localDate
        )
        let query = "date:2026-08-10"
        let parsed = ClipSearchIndex.parse(query: query, now: localDate)
        XCTAssertTrue(parsed.dates[0].contains(localDate))
        XCTAssertTrue(parsed.dates[0].indexedDateTokens.contains(ClipSearchIndex.dateToken(localDate)))

        let snapshot = ClipboardLibrarySnapshot(history: [item])
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sqlite-local-date-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteFileClipboardLibraryStore(fileURL: directory.appendingPathComponent("library.sqlite"))
        try await store.save(snapshot)
        XCTAssertEqual(ClipSearchIndex(snapshot: snapshot).search(query: query, limit: 10).map(\.id), [item.id])
        let disk = await store.search(query: query, limit: 10)
        XCTAssertEqual(disk.map(\.id), [item.id])
    }

    func testInvalidNumericAndBooleanFiltersFailClosedInMemoryAndSQLite() async throws {
        let item = HistoryItem(
            id: uuid(73_001),
            content: try ClipContent.detect(text: "must never leak through invalid filters"),
            createdAt: Date()
        )
        let snapshot = ClipboardLibrarySnapshot(history: [item])
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sqlite-invalid-filter-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteFileClipboardLibraryStore(fileURL: directory.appendingPathComponent("library.sqlite"))
        try await store.save(snapshot)
        let memory = ClipSearchIndex(snapshot: snapshot)
        for query in ["size:bogus", "size:", "pinned:maybe", "captures:2mb", "pastes:>=-1"] {
            XCTAssertTrue(memory.search(query: query, limit: 10).isEmpty, "memory: \(query)")
            let disk = await store.search(query: query, limit: 10)
            XCTAssertTrue(disk.isEmpty, "disk: \(query)")
        }
    }

    func testDiskAndMemoryRankingBothIncludeCanonicalMetadataScore() async throws {
        let metadataAndBody = HistoryItem(
            id: uuid(74_001),
            content: try ClipContent.detect(text: "chrome deployment"),
            createdAt: Date(timeIntervalSince1970: 1),
            captureContext: ClipCaptureContext(sourceApplicationName: "Chrome")
        )
        let bodyOnlyNewer = HistoryItem(
            id: uuid(74_002),
            content: try ClipContent.detect(text: "chrome checklist"),
            createdAt: Date(timeIntervalSince1970: 2)
        )
        let snapshot = ClipboardLibrarySnapshot(history: [metadataAndBody, bodyOnlyNewer])
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sqlite-metadata-score-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteFileClipboardLibraryStore(fileURL: directory.appendingPathComponent("library.sqlite"))
        try await store.save(snapshot)
        let expected = [metadataAndBody.id, bodyOnlyNewer.id]
        XCTAssertEqual(ClipSearchIndex(snapshot: snapshot).search(query: "chrome", limit: 10).map(\.id), expected)
        let disk = await store.search(query: "chrome", limit: 10)
        XCTAssertEqual(disk.map(\.id), expected)
    }

    private func history(
        _ integer: Int,
        text: String,
        at date: Date,
        source: String
    ) -> HistoryItem {
        HistoryItem(
            id: uuid(integer),
            content: try! ClipContent.detect(text: text),
            createdAt: date,
            captureContext: ClipCaptureContext(sourceApplicationName: source)
        )
    }

    private func uuid(_ integer: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", integer))!
    }

    private func utcDate(_ year: Int, _ month: Int, _ day: Int, hour: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour
        ))!
    }
}

private func executeSearchSQLite(_ databaseURL: URL, sql: String) throws {
    var database: OpaquePointer?
    let result = sqlite3_open_v2(
        databaseURL.path,
        &database,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
        nil
    )
    guard result == SQLITE_OK, let database else {
        if let database { sqlite3_close(database) }
        throw NSError(domain: "SearchQueryTests", code: Int(result))
    }
    defer { sqlite3_close(database) }
    sqlite3_busy_timeout(database, 5_000)
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
        throw NSError(
            domain: "SearchQueryTests",
            code: Int(sqlite3_errcode(database)),
            userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(database))]
        )
    }
}
