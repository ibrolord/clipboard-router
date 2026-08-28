import Foundation
import XCTest
@testable import ClipboardRouterCore

final class ClipArchiveTests: XCTestCase {
    func testArchiveRoundTripIncludesAssetsFoldersAndOmissionReport() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let assetStore = FileClipAssetStore(rootURL: root.appendingPathComponent("asset-source"))
        let image: ClipAssetReference
        do {
            image = try await assetStore.put(
                Data("fake png bytes".utf8),
                kind: .image,
                uniformTypeIdentifier: "public.png",
                preferredExtension: "png"
            )
        } catch {
            return XCTFail("Asset setup failed: \(error)")
        }
        let imageContent = try ClipContent(
            type: .image,
            text: "Diagram",
            representations: ClipRepresentations(image: image, ocrText: "Architecture")
        )
        let folder = try ClipFolder(name: "Project", sortOrder: 0, createdAt: .distantPast)
        let imageClip = try SavedClip(
            name: "Diagram",
            content: imageContent,
            folderID: folder.id,
            createdAt: .distantPast
        )
        let localFile = try ClipFileReference(url: URL(fileURLWithPath: "/tmp/local-only.txt"))
        let localOnly = try SavedClip(
            name: "Local file",
            content: ClipContent(
                type: .fileURLs,
                text: "local-only.txt",
                representations: ClipRepresentations(files: [localFile])
            ),
            createdAt: .distantPast
        )
        let archiveURL = root.appendingPathComponent("Project.clipboardrouterarchive")
        let service = ClipArchiveService(assets: assetStore)

        let manifest: ClipArchiveManifest
        do {
            manifest = try await service.export(
                savedClips: [imageClip, localOnly],
                folders: [folder],
                to: archiveURL,
                at: Date(timeIntervalSince1970: 100)
            )
        } catch {
            return XCTFail("Archive export failed: \(error)")
        }
        XCTAssertEqual(manifest.entries.map(\.id), [imageClip.id])
        XCTAssertEqual(manifest.entries.first?.folderName, "Project")
        XCTAssertEqual(manifest.omissions.map(\.id), [localOnly.id])
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: archiveURL.appendingPathComponent("assets/\(image.relativePath)").path
            )
        )
        let roundTrip: ClipArchiveManifest
        do {
            roundTrip = try await service.readManifest(from: archiveURL)
        } catch {
            return XCTFail("Archive read failed: \(error)")
        }
        XCTAssertEqual(roundTrip, manifest)
    }

    func testArchiveNeverOverwritesExistingDestination() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-existing-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent("Existing.clipboardrouterarchive")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let service = ClipArchiveService(
            assets: FileClipAssetStore(rootURL: root.appendingPathComponent("assets"))
        )
        let clip = try SavedClip(
            name: "Text",
            content: ClipContent.detect(text: "text"),
            createdAt: .distantPast
        )

        do {
            _ = try await service.export(savedClips: [clip], folders: [], to: destination)
            XCTFail("Expected destination protection")
        } catch let error as ClipExportError {
            guard case .destinationExists = error else { return XCTFail("Unexpected \(error)") }
        }
    }

    func testArchiveOmitsWholeMixedClipsAndStructuredFileURLsWithoutLeakingPaths() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-local-reference-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let safe = try SavedClip(
            name: "Safe",
            content: ClipContent.detect(text: "portable note"),
            createdAt: .distantPast
        )
        let localPath = "/Users/alice/Private/customer-list.csv"
        let mixed = try SavedClip(
            name: "Mixed",
            content: ClipContent(
                type: .plainText,
                text: "A fallback that must not make the mixed clip exportable",
                representations: ClipRepresentations(
                    files: [try ClipFileReference(url: URL(fileURLWithPath: localPath))]
                )
            ),
            createdAt: .distantPast
        )
        let structuredFileURL = try SavedClip(
            name: "Structured file URL",
            content: ClipContent(
                type: .url,
                text: "Local document",
                representations: ClipRepresentations(
                    url: URLClipMetadata(originalURL: "file:///Users/alice/Private/plan.txt")
                )
            ),
            createdAt: .distantPast
        )
        let archiveURL = root.appendingPathComponent("Safe.clipboardrouterarchive")
        let service = ClipArchiveService(
            assets: FileClipAssetStore(rootURL: root.appendingPathComponent("assets"))
        )

        let manifest = try await service.export(
            savedClips: [safe, mixed, structuredFileURL],
            folders: [],
            to: archiveURL
        )

        XCTAssertEqual(manifest.entries.map(\.id), [safe.id])
        XCTAssertEqual(Set(manifest.omissions.map(\.id)), [mixed.id, structuredFileURL.id])
        let manifestData = try Data(contentsOf: archiveURL.appendingPathComponent("manifest.json"))
        let serialized = try XCTUnwrap(String(data: manifestData, encoding: .utf8))
        XCTAssertFalse(serialized.contains(localPath))
        XCTAssertFalse(serialized.contains("file:///"))
    }

    func testArchiveOmitsFlaggedSensitiveClipsUnlessExactIDIsExplicitlyIncluded() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-sensitive-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let safe = try SavedClip(
            name: "Safe",
            content: ClipContent.detect(text: "ordinary note"),
            createdAt: .distantPast
        )
        let sensitive = try SavedClip(
            name: "Detected secret",
            content: ClipContent.detect(text: "sk-proj-abcdefghijklmnopqrstuvwxyz123456"),
            createdAt: .distantPast,
            sensitivity: ClipSensitivityMetadata(
                category: "openAIAPIKey",
                confidence: 100,
                detectorVersion: 1
            )
        )
        let service = ClipArchiveService(
            assets: FileClipAssetStore(rootURL: root.appendingPathComponent("assets"))
        )
        let defaultURL = root.appendingPathComponent("Default.clipboardrouterarchive")

        let safeManifest = try await service.export(
            savedClips: [safe, sensitive],
            folders: [],
            to: defaultURL
        )
        XCTAssertEqual(safeManifest.entries.map(\.id), [safe.id])
        XCTAssertEqual(safeManifest.omissions.map(\.id), [sensitive.id])

        let explicitURL = root.appendingPathComponent("Explicit.clipboardrouterarchive")
        let explicitManifest = try await service.export(
            savedClips: [safe, sensitive],
            folders: [],
            to: explicitURL,
            includeFlaggedSensitiveClipIDs: [sensitive.id]
        )
        XCTAssertEqual(Set(explicitManifest.entries.map(\.id)), [safe.id, sensitive.id])
        XCTAssertTrue(explicitManifest.omissions.isEmpty)
    }
}
