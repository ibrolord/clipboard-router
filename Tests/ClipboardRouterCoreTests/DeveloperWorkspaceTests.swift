import Foundation
import XCTest
@testable import ClipboardRouterCore

final class DeveloperWorkspaceTests: XCTestCase {
    func testProjectValidationNormalizesLocalAutomationSettings() throws {
        let project = try DeveloperProject(
            name: "  Payments API  ",
            autoAddDeveloperClips: true,
            allowedSourceBundleIdentifiers: ["com.apple.Terminal", "com.microsoft.VSCode"],
            preferredIDEBundleIdentifier: "com.microsoft.VSCode"
        )

        XCTAssertEqual(project.name, "Payments API")
        XCTAssertTrue(project.autoAddDeveloperClips)
        XCTAssertEqual(
            project.allowedSourceBundleIdentifiers,
            ["com.apple.Terminal", "com.microsoft.VSCode"]
        )
        XCTAssertEqual(project.preferredIDEBundleIdentifier, "com.microsoft.VSCode")
        XCTAssertThrowsError(try DeveloperProject(name: "\n\t")) {
            XCTAssertEqual($0 as? DeveloperWorkspaceError, .invalidProjectName)
        }
        XCTAssertThrowsError(
            try DeveloperProject(
                name: "Project",
                allowedSourceBundleIdentifiers: ["com.apple.Terminal", "com.apple.Terminal"]
            )
        ) {
            XCTAssertEqual(
                $0 as? DeveloperWorkspaceError,
                .invalidRepositoryField("source application list")
            )
        }
        XCTAssertThrowsError(
            try DeveloperProject(name: "Project", preferredIDEBundleIdentifier: "not a bundle id")
        )
    }

    func testRepositoryReferenceStoresBookmarkAndFingerprintWithoutPlaintextPath() throws {
        let repository = try DeveloperRepositoryReference(
            displayName: "clipboard-router",
            securityScopedBookmark: Data([1, 2, 3]),
            canonicalPathFingerprint: String(repeating: "a", count: 64),
            branch: "feature/projects",
            inspectedAt: Date(timeIntervalSince1970: 10)
        )

        let encoded = try JSONEncoder().encode(repository)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(text.contains("/Users/"))
        XCTAssertFalse(text.contains("remote"))
        XCTAssertThrowsError(
            try DeveloperRepositoryReference(
                displayName: "repo",
                securityScopedBookmark: Data(),
                canonicalPathFingerprint: String(repeating: "a", count: 64)
            )
        ) {
            XCTAssertEqual($0 as? DeveloperWorkspaceError, .invalidRepositoryBookmark)
        }
    }

    func testWorkspaceLifecycleMembershipIsIdempotentAndTimelineIsContentFree() async throws {
        let store = InMemoryDeveloperWorkspaceStore()
        let workspace = try DeveloperWorkspace(persistence: store)
        let createdAt = Date(timeIntervalSince1970: 100)
        let project = try await workspace.createProject(
            name: "Router",
            activate: true,
            at: createdAt
        )
        let historyID = UUID()
        let first = try await workspace.addMembership(
            projectID: project.id,
            clip: .history(historyID),
            at: Date(timeIntervalSince1970: 110)
        )
        let duplicate = try await workspace.addMembership(
            projectID: project.id,
            clip: .history(historyID),
            at: Date(timeIntervalSince1970: 120)
        )

        XCTAssertEqual(first, duplicate)
        let memberships = try await workspace.memberships(projectID: project.id)
        XCTAssertEqual(memberships.count, 1)
        let timeline = try await workspace.timeline(projectID: project.id)
        XCTAssertEqual(timeline.count, 2)
        guard case .clipAdded(.history(historyID)) = timeline[0].kind else {
            return XCTFail("Expected the history foreign key, not copied clip content")
        }
        XCTAssertEqual(timeline[1].kind, .projectCreated)

        let renamed = try await workspace.renameProject(
            id: project.id,
            name: "Router Core",
            at: Date(timeIntervalSince1970: 130)
        )
        XCTAssertEqual(renamed.name, "Router Core")
        let configured = try await workspace.updateSettings(
            projectID: project.id,
            autoAddDeveloperClips: true,
            allowedSourceBundleIdentifiers: ["com.apple.Terminal"],
            preferredIDEBundleIdentifier: "com.apple.dt.Xcode",
            at: Date(timeIntervalSince1970: 140)
        )
        XCTAssertTrue(configured.autoAddDeveloperClips)

        _ = try await workspace.archiveProject(
            id: project.id,
            at: Date(timeIntervalSince1970: 150)
        )
        let archivedSnapshot = await workspace.snapshot()
        XCTAssertNil(archivedSnapshot.activeProjectID)
        await XCTAssertThrowsErrorAsync(
            try await workspace.addMembership(projectID: project.id, clip: .saved(UUID()))
        ) { error in
            XCTAssertEqual(error as? DeveloperWorkspaceError, .projectArchived(project.id))
        }

        let reopened = try await DeveloperWorkspace.open(persistence: store)
        let reopenedSnapshot = await reopened.snapshot()
        let workspaceSnapshot = await workspace.snapshot()
        XCTAssertEqual(reopenedSnapshot, workspaceSnapshot)
    }

    func testConcurrentSourceApplicationUpdatesDoNotLoseSelections() async throws {
        let workspace = try DeveloperWorkspace()
        let project = try await workspace.createProject(name: "Capture Apps")

        async let first = workspace.setSourceApplication(
            projectID: project.id,
            bundleIdentifier: "com.apple.Terminal",
            allowed: true
        )
        async let second = workspace.setSourceApplication(
            projectID: project.id,
            bundleIdentifier: "com.microsoft.VSCode",
            allowed: true
        )
        _ = try await (first, second)

        let snapshot = await workspace.snapshot()
        XCTAssertEqual(
            snapshot.projects.first?.allowedSourceBundleIdentifiers,
            ["com.apple.Terminal", "com.microsoft.VSCode"]
        )
    }

    func testRemovingFinalSourceApplicationDisablesAutoCapture() async throws {
        let workspace = try DeveloperWorkspace()
        let project = try await workspace.createProject(
            name: "Capture Apps",
            autoAddDeveloperClips: true,
            allowedSourceBundleIdentifiers: ["com.apple.Terminal"]
        )

        let updated = try await workspace.setSourceApplication(
            projectID: project.id,
            bundleIdentifier: "com.apple.Terminal",
            allowed: false
        )

        XCTAssertTrue(updated.allowedSourceBundleIdentifiers.isEmpty)
        XCTAssertFalse(updated.autoAddDeveloperClips)
    }

    func testDebugBundleSnapshotPersistsAndAppearsInTimeline() async throws {
        let workspace = try DeveloperWorkspace()
        let project = try await workspace.createProject(name: "Compiler", at: .distantPast)
        let bundle = try makeBundle(generatedAt: Date(timeIntervalSince1970: 200))

        let saved = try await workspace.saveDebugBundle(
            projectID: project.id,
            bundle: bundle,
            at: Date(timeIntervalSince1970: 210)
        )
        let stored = try await workspace.debugBundles(projectID: project.id)
        XCTAssertEqual(stored, [saved])
        XCTAssertEqual(stored.first?.bundle, bundle)

        let timeline = try await workspace.timeline(projectID: project.id, limit: 1)
        XCTAssertEqual(timeline.count, 1)
        XCTAssertEqual(
            timeline.first?.kind,
            .debugBundleSaved(bundleID: saved.id, itemCount: 1)
        )

        try await workspace.deleteDebugBundle(id: saved.id)
        let remaining = try await workspace.debugBundles(projectID: project.id)
        XCTAssertTrue(remaining.isEmpty)
    }

    func testSavingIdenticalDebugBundleTwiceIsIdempotent() async throws {
        let workspace = try DeveloperWorkspace()
        let project = try await workspace.createProject(name: "Compiler")
        let bundle = try makeBundle(generatedAt: Date(timeIntervalSince1970: 200))
        let reopenedReview = try DebugBundle(
            id: bundle.id,
            generatedAt: Date(timeIntervalSince1970: 300),
            project: bundle.project,
            problemStatement: bundle.problemStatement,
            sourceContextPackID: bundle.sourceContextPackID,
            sourceContextPackName: bundle.sourceContextPackName,
            items: bundle.items,
            maximumRenderedUTF8Bytes: bundle.maximumRenderedUTF8Bytes
        )

        let first = try await workspace.saveDebugBundle(
            projectID: project.id,
            bundle: bundle,
            at: Date(timeIntervalSince1970: 210)
        )
        let second = try await workspace.saveDebugBundle(
            projectID: project.id,
            bundle: reopenedReview,
            at: Date(timeIntervalSince1970: 220)
        )

        XCTAssertEqual(second, first)
        let stored = try await workspace.debugBundles(projectID: project.id)
        let timeline = try await workspace.timeline(projectID: project.id)
        let bundleSaveCount = timeline.filter {
            if case .debugBundleSaved = $0.kind { return true }
            return false
        }.count
        XCTAssertEqual(stored, [first])
        XCTAssertEqual(bundleSaveCount, 1)
    }

    func testDebugBundlePersistenceRejectsOversizedSnapshot() throws {
        let item = try ContextPackItem(
            id: UUID(),
            title: "Large output",
            textRepresentation: String(
                repeating: "x",
                count: PersistedDebugBundleSnapshot.maximumEncodedBytes + 1
            )
        )
        let bundle = try DebugBundle(
            generatedAt: Date(),
            project: DeveloperProjectContext(name: "Large"),
            sourceContextPackID: UUID(),
            sourceContextPackName: "Output",
            items: [DebugBundleItem(
                source: item,
                analysis: DeveloperContentRecognizer().analyze(item.textRepresentation)
            )],
            maximumRenderedUTF8Bytes: 2 * 1_024 * 1_024
        )

        XCTAssertThrowsError(
            try PersistedDebugBundleSnapshot(projectID: UUID(), bundle: bundle)
        ) {
            guard case .debugBundleSizeLimitExceeded = $0 as? DeveloperWorkspaceError else {
                return XCTFail("Unexpected error: \($0)")
            }
        }
    }

    func testJSONStoreRoundTripsAndRejectsTamperedPayload() async throws {
        struct Envelope: Codable {
            let schemaVersion: Int
            let checksum: String
            let payload: Data
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("developer-workspace.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JSONFileDeveloperWorkspaceStore(fileURL: fileURL)
        let project = try DeveloperProject(
            id: UUID(),
            name: "Local",
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let snapshot = try DeveloperWorkspaceSnapshot(projects: [project])

        try await store.save(snapshot)
        let roundTripped = try await store.load()
        XCTAssertEqual(roundTripped, snapshot)
        let directoryMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions]
                as? NSNumber
        )
        let fileMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions]
                as? NSNumber
        )
        XCTAssertEqual(directoryMode.intValue & 0o777, 0o700)
        XCTAssertEqual(fileMode.intValue & 0o777, 0o600)

        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        let original = try Data(contentsOf: fileURL)
        let envelope = try decoder.decode(Envelope.self, from: original)
        let tampered = Envelope(
            schemaVersion: envelope.schemaVersion,
            checksum: envelope.checksum,
            payload: envelope.payload + Data([0])
        )
        try encoder.encode(tampered).write(to: fileURL, options: .atomic)

        await XCTAssertThrowsErrorAsync(try await store.load()) { error in
            XCTAssertEqual(
                error as? DeveloperWorkspacePersistenceError,
                .checksumMismatch(fileURL.standardizedFileURL)
            )
        }
    }

    func testConcurrentMutationsAreSerializedAcrossAwaitingPersistence() async throws {
        let store = YieldingDeveloperWorkspaceStore()
        let workspace = try DeveloperWorkspace(persistence: store)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0 ..< 20 {
                group.addTask {
                    _ = try await workspace.createProject(
                        name: "Project \(index)",
                        activate: false,
                        at: Date(timeIntervalSince1970: TimeInterval(index))
                    )
                }
            }
            try await group.waitForAll()
        }

        let snapshot = await workspace.snapshot()
        XCTAssertEqual(snapshot.projects.count, 20)
        let persisted = try await store.load()
        XCTAssertEqual(persisted, snapshot)
    }

    func testFailedPersistenceDoesNotExposeUncommittedProject() async throws {
        let workspace = try DeveloperWorkspace(persistence: FailingDeveloperWorkspaceStore())

        await XCTAssertThrowsErrorAsync(
            try await workspace.createProject(name: "Must not appear")
        )

        let snapshot = await workspace.snapshot()
        XCTAssertTrue(snapshot.projects.isEmpty)
        XCTAssertNil(snapshot.activeProjectID)
    }

    private func makeBundle(generatedAt: Date) throws -> DebugBundle {
        let item = try ContextPackItem(
            id: UUID(),
            title: "Compiler error",
            textRepresentation: "error: cannot find value in scope"
        )
        let pack = try ContextPack(name: "Build", items: [item])
        return try DebugBundleBuilder().build(
            project: DeveloperProjectContext(name: "Compiler"),
            from: pack,
            generatedAt: generatedAt
        )
    }
}

private actor YieldingDeveloperWorkspaceStore: DeveloperWorkspacePersisting {
    private var value = DeveloperWorkspaceSnapshot.empty

    func load() async throws -> DeveloperWorkspaceSnapshot {
        value
    }

    func save(_ snapshot: DeveloperWorkspaceSnapshot) async throws {
        await Task.yield()
        value = snapshot
    }
}

private struct FailingDeveloperWorkspaceStore: DeveloperWorkspacePersisting {
    struct Failure: Error {}

    func load() async throws -> DeveloperWorkspaceSnapshot {
        .empty
    }

    func save(_: DeveloperWorkspaceSnapshot) async throws {
        throw Failure()
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (any Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw")
    } catch {
        errorHandler(error)
    }
}
