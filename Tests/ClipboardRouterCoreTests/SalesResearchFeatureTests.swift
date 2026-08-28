import Foundation
import XCTest
@testable import ClipboardRouterCore

final class SalesResearchFeatureTests: XCTestCase {
    func testTagNormalizationIsBoundedDeterministicAndCaseInsensitive() throws {
        XCTAssertEqual(
            try ClipTag.normalize(["  Priority  account ", "priority account", "Buyer", "buyer"]),
            ["Buyer", "Priority account"]
        )
        XCTAssertThrowsError(try ClipTag("\n\t")) { error in
            XCTAssertEqual(error as? ClipTagValidationError, .empty)
        }
        XCTAssertThrowsError(try ClipTag(String(repeating: "é", count: 33))) { error in
            XCTAssertEqual(
                error as? ClipTagValidationError,
                .tooLong(maximumUTF8Bytes: ClipTag.maximumUTF8Bytes)
            )
        }
        XCTAssertThrowsError(
            try ClipTag.normalize((0...ClipTag.maximumCountPerItem).map { "tag \($0)" })
        ) { error in
            XCTAssertEqual(
                error as? ClipTagValidationError,
                .tooMany(maximum: ClipTag.maximumCountPerItem)
            )
        }
    }

    func testReplaceTagsUpdatesSearchAndJournalAtomically() async throws {
        let clip = try SavedClip(
            name: "Acme pricing",
            content: ClipContent.detect(text: "Annual contract research"),
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let library = try ClipboardLibrary(snapshot: ClipboardLibrarySnapshot(savedClips: [clip]))
        let expectation = SavedClipEditExpectation(
            name: clip.name,
            modifiedAt: clip.modifiedAt,
            folderID: clip.folderID,
            contentFingerprint: clip.content.deduplicationFingerprint
        )

        let updated = try await library.replaceTags(
            for: clip.id,
            with: [" Pricing ", "pricing", "Decision Maker"],
            expecting: expectation,
            at: Date(timeIntervalSince1970: 2)
        )
        XCTAssertEqual(updated.tags, ["Decision Maker", "Pricing"])
        let searchResults = await library.search(query: "tag:pricing", limit: 10)
        XCTAssertEqual(searchResults.map(\.id), [clip.id])
        let snapshot = await library.snapshot()
        XCTAssertEqual(
            snapshot.pendingSavedLibraryMutations.filter {
                $0.id == clip.id && $0.kind == .savedClip
            }.count,
            1
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await library.replaceTags(
                for: clip.id,
                with: ["stale"],
                expecting: expectation
            )
        } validate: { error in
            XCTAssertEqual(
                error as? ClipboardLibraryError,
                .savedItemChangedDuringEdit(clip.id)
            )
        }
        let afterConflict = await library.snapshot()
        XCTAssertEqual(afterConflict.savedClips.first?.tags, ["Decision Maker", "Pricing"])
    }

    func testSalesWorkspaceRecipeCommitsRootAndChildrenTogether() async throws {
        let library = try ClipboardLibrary()
        let created = try await library.createFolderRecipe(
            .salesWorkspace(named: "Q4 Enterprise"),
            at: Date(timeIntervalSince1970: 10)
        )
        XCTAssertEqual(created.root.name, "Q4 Enterprise")
        XCTAssertEqual(
            created.children.map(\.name),
            ["Accounts", "Messaging", "Competitors", "Unsorted"]
        )
        XCTAssertTrue(created.children.allSatisfy { $0.parentFolderID == created.root.id })

        let snapshot = await library.snapshot()
        XCTAssertEqual(snapshot.folders.count, 5)
        XCTAssertEqual(
            Set(snapshot.pendingSavedLibraryMutations.map(\.id)),
            Set(([created.root] + created.children).map(\.id))
        )

        let beforeFailure = snapshot
        await XCTAssertThrowsErrorAsync {
            _ = try await library.createFolderRecipe(.salesWorkspace(named: "Q4 Enterprise"))
        }
        let afterFailure = await library.snapshot()
        XCTAssertEqual(afterFailure, beforeFailure)
    }

    func testHandoffProjectionUsesSelectedSubtreeAndReportsEveryUnsafeItem() throws {
        let root = try ClipFolder(
            name: "Campaign",
            sortOrder: 0,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let accounts = try ClipFolder(
            name: "Accounts",
            parentFolderID: root.id,
            sortOrder: 0,
            createdAt: Date(timeIntervalSince1970: 2)
        )
        let outside = try ClipFolder(
            name: "Other",
            sortOrder: 1,
            createdAt: Date(timeIntervalSince1970: 3)
        )
        let safe = try SavedClip(
            name: "Acme",
            content: ClipContent.detect(text: "https://acme.example/pricing"),
            folderID: accounts.id,
            createdAt: Date(timeIntervalSince1970: 4),
            tags: ["Pricing"],
            sourceApplicationBundleIdentifier: "com.apple.Safari",
            originallyCapturedAt: Date(timeIntervalSince1970: 3)
        )
        let sensitive = try SavedClip(
            name: "Secret",
            content: ClipContent.detect(text: "secret body"),
            folderID: accounts.id,
            createdAt: Date(timeIntervalSince1970: 5),
            sensitivity: ClipSensitivityMetadata(
                category: "apiKey",
                confidence: 100,
                detectorVersion: 1
            )
        )
        let located = try SavedClip(
            name: "Located",
            content: ClipContent.detect(text: "local context"),
            folderID: accounts.id,
            createdAt: Date(timeIntervalSince1970: 6),
            captureContext: ClipCaptureContext(
                coarseLocation: CoarseLocationContext(label: "Toronto")
            )
        )
        let localFile = try SavedClip(
            name: "Local file",
            content: ClipContent(
                type: .fileURLs,
                text: "private.csv",
                representations: ClipRepresentations(
                    files: [try ClipFileReference(url: URL(fileURLWithPath: "/tmp/private.csv"))]
                )
            ),
            folderID: accounts.id,
            createdAt: Date(timeIntervalSince1970: 7)
        )
        let excludedBySubtree = try SavedClip(
            name: "Outside",
            content: ClipContent.detect(text: "outside"),
            folderID: outside.id,
            createdAt: Date(timeIntervalSince1970: 8)
        )
        let snapshot = ClipboardLibrarySnapshot(
            savedClips: [safe, sensitive, located, localFile, excludedBySubtree],
            folders: [root, accounts, outside]
        )

        let projection = try FolderHandoffProjector().project(
            rootFolderID: root.id,
            snapshot: snapshot,
            at: Date(timeIntervalSince1970: 100)
        )

        XCTAssertEqual(projection.rootFolderPath, "Campaign")
        XCTAssertEqual(projection.records.map(\.itemID), [safe.id])
        XCTAssertEqual(projection.records.first?.folderPath, "Campaign / Accounts")
        XCTAssertEqual(projection.records.first?.domain, "acme.example")
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: projection.omissions.map { ($0.itemID, $0.reasonCode) }),
            [
                sensitive.id: .sensitive,
                located.id: .locationMetadataNotShareable,
                localFile.id: .localFileReference,
            ]
        )
        XCTAssertTrue(projection.omissions.allSatisfy { $0.title == "Excluded item" })
        let rendered = try XCTUnwrap(String(
            data: try MarkdownHandoffRenderer().render(projection),
            encoding: .utf8
        ))
        XCTAssertFalse(rendered.contains("Secret"))
        XCTAssertFalse(rendered.contains("secret body"))
        XCTAssertFalse(rendered.contains("Located"))
        XCTAssertFalse(rendered.contains("local context"))
        XCTAssertFalse(rendered.contains("private.csv"))
        XCTAssertFalse(rendered.contains("Toronto"))
        XCTAssertFalse(projection.omissions.contains(where: { $0.itemID == excludedBySubtree.id }))
    }

    func testCSVNeutralizesFormulasAndQuotesRFC4180Characters() throws {
        let record = HandoffRecord(
            itemID: UUID(),
            kind: .note,
            title: " =HYPERLINK(\"https://evil.example\")",
            body: "+SUM(1,2)\nsecond row",
            contentType: .plainText,
            url: nil,
            domain: nil,
            sourceApplicationBundleIdentifier: "@source",
            originallyCapturedAt: nil,
            createdAt: Date(timeIntervalSince1970: 1),
            modifiedAt: Date(timeIntervalSince1970: 2),
            folderPath: "Campaign, Accounts",
            tags: ["one|two"]
        )
        let projection = HandoffProjection(
            exportedAt: Date(timeIntervalSince1970: 3),
            rootFolderPath: "Campaign",
            records: [record],
            omissions: []
        )

        let rendered = try XCTUnwrap(
            String(data: CSVHandoffRenderer().render(projection), encoding: .utf8)
        )
        XCTAssertTrue(rendered.contains("' =HYPERLINK"))
        XCTAssertTrue(rendered.contains("\"'+SUM(1,2)\nsecond row\""))
        XCTAssertTrue(rendered.contains("'@source"))
        XCTAssertTrue(rendered.contains("\"Campaign, Accounts\""))
        XCTAssertTrue(rendered.contains("one\\|two"))
    }

    func testMarkdownJSONAndAtomicWriterShareOneProjection() throws {
        let record = HandoffRecord(
            itemID: UUID(),
            kind: .clip,
            title: "Pricing #signal",
            body: "Annual plan",
            contentType: .plainText,
            url: nil,
            domain: "example.com",
            sourceApplicationBundleIdentifier: nil,
            originallyCapturedAt: nil,
            createdAt: Date(timeIntervalSince1970: 1),
            modifiedAt: Date(timeIntervalSince1970: 2),
            folderPath: "Campaign / Accounts",
            tags: ["pricing"]
        )
        let projection = HandoffProjection(
            exportedAt: Date(timeIntervalSince1970: 3),
            rootFolderPath: "Campaign",
            records: [record],
            omissions: []
        )
        let markdown = try XCTUnwrap(
            String(data: MarkdownHandoffRenderer().render(projection), encoding: .utf8)
        )
        XCTAssertTrue(markdown.contains("### Pricing \\#signal"))
        let decoded = try JSONDecoder.iso8601.decode(
            HandoffProjection.self,
            from: JSONHandoffRenderer().render(projection)
        )
        XCTAssertEqual(decoded, projection)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("handoff-writer-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("brief.md")
        let writer = HandoffFileWriter()
        try writer.write(Data("first".utf8), to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), Data("first".utf8))
        XCTAssertThrowsError(try writer.write(Data("second".utf8), to: destination))
        try writer.write(Data("second".utf8), to: destination, replacingExisting: true)
        XCTAssertEqual(try Data(contentsOf: destination), Data("second".utf8))
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    validate: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {
        validate(error)
    }
}
