import AppKit
import Foundation

public struct IDEApplicationSelection: Equatable, Sendable {
    public let displayName: String
    public let bundleIdentifier: String
    public let teamIdentifier: String
    public let applicationURL: URL

    public init(
        displayName: String,
        bundleIdentifier: String,
        teamIdentifier: String?,
        applicationURL: URL
    ) throws {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let identifier = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let team = teamIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 200,
              !identifier.isEmpty, identifier.utf8.count <= 255,
              let team, !team.isEmpty, team.utf8.count <= 64,
              applicationURL.isFileURL,
              applicationURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame
        else { throw IDEHandoffError.invalidApplication }
        self.displayName = name
        self.bundleIdentifier = identifier
        self.teamIdentifier = team
        self.applicationURL = applicationURL.standardizedFileURL
    }
}

@MainActor
public protocol IDEWorkspaceOpening: AnyObject {
    func openProject(_ projectURL: URL, withApplicationAt applicationURL: URL) async throws
}

public protocol IDEApplicationIdentityInspecting: Sendable {
    func identity(forApplicationAt url: URL) -> IDEApplicationIdentity?
}

public struct IDEApplicationIdentity: Equatable, Sendable {
    public let bundleIdentifier: String
    public let teamIdentifier: String

    public init(bundleIdentifier: String, teamIdentifier: String) {
        self.bundleIdentifier = bundleIdentifier
        self.teamIdentifier = teamIdentifier
    }
}

public struct SystemIDEApplicationIdentityInspector: IDEApplicationIdentityInspecting {
    public init() {}

    public func identity(forApplicationAt url: URL) -> IDEApplicationIdentity? {
        guard let metadata = SystemApplicationMetadataInspector.metadataSnapshot(
            forApplicationAt: url
        ), let bundleIdentifier = metadata.bundleIdentifier,
        case let .valid(teamIdentifier?) = metadata.signature
        else { return nil }
        return IDEApplicationIdentity(
            bundleIdentifier: bundleIdentifier,
            teamIdentifier: teamIdentifier
        )
    }
}

@MainActor
public final class SystemIDEWorkspaceOpener: IDEWorkspaceOpening {
    private let workspace: NSWorkspace

    public init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
    }

    public func openProject(_ projectURL: URL, withApplicationAt applicationURL: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            workspace.open(
                [projectURL],
                withApplicationAt: applicationURL,
                configuration: configuration
            ) { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }
}

@MainActor
public final class IDEHandoff {
    private let opener: any IDEWorkspaceOpening
    private let identityInspector: any IDEApplicationIdentityInspecting

    public init(
        opener: any IDEWorkspaceOpening = SystemIDEWorkspaceOpener(),
        identityInspector: any IDEApplicationIdentityInspecting = SystemIDEApplicationIdentityInspector()
    ) {
        self.opener = opener
        self.identityInspector = identityInspector
    }

    /// Opens only a file-system project root with an explicitly selected, currently installed app.
    /// No shell, AppleScript, URL scheme, arguments, or clipboard mutation is involved.
    public func open(
        project session: ProjectRootAccessSession,
        in application: IDEApplicationSelection
    ) async throws {
        let projectValues = try session.url.resourceValues(forKeys: [.isDirectoryKey])
        guard projectValues.isDirectory == true else { throw IDEHandoffError.projectUnavailable }
        let applicationValues = try application.applicationURL.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        guard applicationValues.isDirectory == true,
              applicationValues.isSymbolicLink != true
        else { throw IDEHandoffError.invalidApplication }
        guard identityInspector.identity(forApplicationAt: application.applicationURL)
            == IDEApplicationIdentity(
                bundleIdentifier: application.bundleIdentifier,
                teamIdentifier: application.teamIdentifier
            )
        else { throw IDEHandoffError.applicationIdentityChanged }
        try await opener.openProject(
            session.url,
            withApplicationAt: application.applicationURL
        )
    }
}

public enum IDEHandoffError: Error, Equatable, LocalizedError, Sendable {
    case invalidApplication
    case projectUnavailable
    case applicationIdentityChanged

    public var errorDescription: String? {
        switch self {
        case .invalidApplication: "Choose an installed macOS application."
        case .projectUnavailable: "The selected project folder is no longer available."
        case .applicationIdentityChanged: "The selected application's identity changed. Choose it again."
        }
    }
}
