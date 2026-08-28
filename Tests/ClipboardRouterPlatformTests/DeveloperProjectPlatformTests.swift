import ClipboardRouterPlatform
import Foundation
import XCTest

final class DeveloperProjectPlatformTests: XCTestCase {
    func testExplicitGrantBalancesReadOnlySecurityScope() throws {
        let root = try temporaryDirectory()
        let coder = FakeBookmarkCoder(url: root)
        let access = ProjectRootAccess(coder: coder)

        let grant = try access.grant(forExplicitlySelectedURL: root)
        XCTAssertEqual(grant.rootLabel, root.lastPathComponent)
        let session = try access.open(grant)
        XCTAssertEqual(session.url, root.standardizedFileURL)
        XCTAssertEqual(coder.startCount, 1)

        session.close()
        session.close()
        XCTAssertEqual(coder.stopCount, 1)
    }

    func testStaleGrantDoesNotStartSecurityScope() throws {
        let root = try temporaryDirectory()
        let coder = FakeBookmarkCoder(url: root, stale: true)
        let access = ProjectRootAccess(coder: coder)
        let grant = try ProjectRootAccessGrant(bookmarkData: Data([1]), rootLabel: "Project")

        XCTAssertThrowsError(try access.open(grant)) { error in
            XCTAssertEqual(error as? ProjectRootAccessError, .staleBookmark)
        }
        XCTAssertEqual(coder.startCount, 0)
    }

    func testRepositoryInspectorReadsOnlyLocalHEAD() throws {
        let root = try temporaryDirectory()
        let git = root.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: false)
        try Data("ref: refs/heads/feature/safe-projects\n".utf8)
            .write(to: git.appendingPathComponent("HEAD"))
        let session = try session(for: root)
        defer { session.close() }

        let inspection = try RepositoryInspector().inspect(session)

        XCTAssertEqual(inspection.projectName, root.lastPathComponent)
        XCTAssertEqual(inspection.head, .branch("feature/safe-projects"))
        XCTAssertEqual(inspection.branchLabel, "feature/safe-projects")
    }

    func testRepositoryInspectorRejectsGitdirFileAndSymlinkedHEAD() throws {
        let worktree = try temporaryDirectory()
        try Data("gitdir: /outside/repository\n".utf8)
            .write(to: worktree.appendingPathComponent(".git"))
        let worktreeSession = try session(for: worktree)
        defer { worktreeSession.close() }
        XCTAssertThrowsError(try RepositoryInspector().inspect(worktreeSession)) { error in
            XCTAssertEqual(error as? RepositoryInspectionError, .unsupportedGitLayout)
        }

        let linkedRoot = try temporaryDirectory()
        let linkedGitTarget = linkedRoot.appendingPathComponent("real-git", isDirectory: true)
        try FileManager.default.createDirectory(
            at: linkedGitTarget,
            withIntermediateDirectories: false
        )
        try FileManager.default.createSymbolicLink(
            at: linkedRoot.appendingPathComponent(".git"),
            withDestinationURL: linkedGitTarget
        )
        let linkedRootSession = try session(for: linkedRoot)
        defer { linkedRootSession.close() }
        XCTAssertThrowsError(try RepositoryInspector().inspect(linkedRootSession)) { error in
            XCTAssertEqual(error as? RepositoryInspectionError, .symbolicLink(".git"))
        }

        let root = try temporaryDirectory()
        let git = root.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: false)
        let outside = root.appendingPathComponent("outside-head")
        try Data("ref: refs/heads/main\n".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: git.appendingPathComponent("HEAD"),
            withDestinationURL: outside
        )
        let symlinkSession = try session(for: root)
        defer { symlinkSession.close() }
        XCTAssertThrowsError(try RepositoryInspector().inspect(symlinkSession)) { error in
            XCTAssertEqual(error as? RepositoryInspectionError, .symbolicLink(".git/HEAD"))
        }
    }

    @MainActor
    func testIDEHandoffUsesExplicitSelectedApplicationWithoutScriptOrURLScheme() async throws {
        let root = try temporaryDirectory()
        let app = try temporaryDirectory(suffix: ".app")
        let session = try session(for: root)
        defer { session.close() }
        let selection = try IDEApplicationSelection(
            displayName: "Test IDE",
            bundleIdentifier: "example.ide",
            teamIdentifier: "TEAM123",
            applicationURL: app
        )
        let opener = RecordingIDEOpener()
        let handoff = IDEHandoff(
            opener: opener,
            identityInspector: FixedIDEIdentityInspector(
                identity: IDEApplicationIdentity(
                    bundleIdentifier: "example.ide",
                    teamIdentifier: "TEAM123"
                )
            )
        )

        try await handoff.open(project: session, in: selection)

        XCTAssertEqual(opener.projectURL, root.standardizedFileURL)
        XCTAssertEqual(opener.applicationURL, app.standardizedFileURL)
    }

    @MainActor
    func testIDEHandoffRejectsTeamIdentityChangeBeforeWorkspaceOpen() async throws {
        let root = try temporaryDirectory()
        let app = try temporaryDirectory(suffix: ".app")
        let session = try session(for: root)
        defer { session.close() }
        let selection = try IDEApplicationSelection(
            displayName: "Test IDE",
            bundleIdentifier: "example.ide",
            teamIdentifier: "EXPECTED",
            applicationURL: app
        )
        let opener = RecordingIDEOpener()
        let handoff = IDEHandoff(
            opener: opener,
            identityInspector: FixedIDEIdentityInspector(
                identity: IDEApplicationIdentity(
                    bundleIdentifier: "example.ide",
                    teamIdentifier: "REPLACED"
                )
            )
        )

        do {
            try await handoff.open(project: session, in: selection)
            XCTFail("A replaced application identity must be rejected")
        } catch let error as IDEHandoffError {
            XCTAssertEqual(error, .applicationIdentityChanged)
        }
        XCTAssertNil(opener.projectURL)
        XCTAssertNil(opener.applicationURL)
    }

    private func session(for root: URL) throws -> ProjectRootAccessSession {
        let coder = FakeBookmarkCoder(url: root)
        let access = ProjectRootAccess(coder: coder)
        let grant = try access.grant(forExplicitlySelectedURL: root)
        return try access.open(grant)
    }

    private func temporaryDirectory(suffix: String = "") throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-router-project-\(UUID().uuidString)\(suffix)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
}

private final class FakeBookmarkCoder: ProjectRootBookmarkCoding, @unchecked Sendable {
    let url: URL
    let stale: Bool
    private let lock = NSLock()
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(url: URL, stale: Bool = false) {
        self.url = url
        self.stale = stale
    }

    func makeReadOnlyBookmark(for url: URL) throws -> Data { Data(url.path.utf8) }
    func resolveReadOnlyBookmark(_ data: Data) throws -> (url: URL, isStale: Bool) {
        (url, stale)
    }
    func startAccessing(_ url: URL) -> Bool {
        lock.withLock { startCount += 1 }
        return true
    }
    func stopAccessing(_ url: URL) {
        lock.withLock { stopCount += 1 }
    }
}

private struct FixedIDEIdentityInspector: IDEApplicationIdentityInspecting {
    let identity: IDEApplicationIdentity
    func identity(forApplicationAt url: URL) -> IDEApplicationIdentity? { identity }
}

@MainActor
private final class RecordingIDEOpener: IDEWorkspaceOpening {
    var projectURL: URL?
    var applicationURL: URL?

    func openProject(_ projectURL: URL, withApplicationAt applicationURL: URL) async throws {
        self.projectURL = projectURL
        self.applicationURL = applicationURL
    }
}
