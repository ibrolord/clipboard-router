import Foundation

/// A local-only capability produced by an explicit user folder selection. The bookmark is never
/// part of a sync model; callers must persist it only in the app's local project store.
public struct ProjectRootAccessGrant: Equatable, Sendable {
    public let bookmarkData: Data
    public let rootLabel: String

    public init(bookmarkData: Data, rootLabel: String) throws {
        let label = rootLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bookmarkData.isEmpty, !label.isEmpty, label.utf8.count <= 255 else {
            throw ProjectRootAccessError.invalidGrant
        }
        self.bookmarkData = bookmarkData
        self.rootLabel = label
    }
}

public protocol ProjectRootBookmarkCoding: Sendable {
    func makeReadOnlyBookmark(for url: URL) throws -> Data
    func resolveReadOnlyBookmark(_ data: Data) throws -> (url: URL, isStale: Bool)
    func startAccessing(_ url: URL) -> Bool
    func stopAccessing(_ url: URL)
}

public final class SystemProjectRootBookmarkCoder: ProjectRootBookmarkCoding, @unchecked Sendable {
    public init() {}

    public func makeReadOnlyBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            relativeTo: nil
        )
    }

    public func resolveReadOnlyBookmark(_ data: Data) throws -> (url: URL, isStale: Bool) {
        var stale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        return (url, stale)
    }

    public func startAccessing(_ url: URL) -> Bool {
        url.startAccessingSecurityScopedResource()
    }

    public func stopAccessing(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }
}

/// Owns the balanced security-scope lifetime. `close()` is idempotent and is also called on
/// deinitialization so a failed downstream inspection cannot leak a sandbox extension.
public final class ProjectRootAccessSession: @unchecked Sendable {
    public let url: URL
    public let rootLabel: String

    private let lock = NSLock()
    private var isOpen = true
    private let stop: @Sendable (URL) -> Void

    fileprivate init(
        url: URL,
        rootLabel: String,
        stop: @escaping @Sendable (URL) -> Void
    ) {
        self.url = url
        self.rootLabel = rootLabel
        self.stop = stop
    }

    public func close() {
        lock.lock()
        let shouldStop = isOpen
        isOpen = false
        lock.unlock()
        if shouldStop { stop(url) }
    }

    deinit { close() }
}

public struct ProjectRootAccess: Sendable {
    private let coder: any ProjectRootBookmarkCoding

    public init(coder: any ProjectRootBookmarkCoding = SystemProjectRootBookmarkCoder()) {
        self.coder = coder
    }

    public func grant(forExplicitlySelectedURL url: URL) throws -> ProjectRootAccessGrant {
        let root = try Self.validatedDirectory(url)
        return try ProjectRootAccessGrant(
            bookmarkData: coder.makeReadOnlyBookmark(for: root),
            rootLabel: root.lastPathComponent
        )
    }

    public func open(_ grant: ProjectRootAccessGrant) throws -> ProjectRootAccessSession {
        let resolved = try coder.resolveReadOnlyBookmark(grant.bookmarkData)
        guard !resolved.isStale else { throw ProjectRootAccessError.staleBookmark }
        guard coder.startAccessing(resolved.url) else {
            throw ProjectRootAccessError.accessDenied
        }
        let root: URL
        do {
            root = try Self.validatedDirectory(resolved.url)
        } catch {
            coder.stopAccessing(resolved.url)
            throw error
        }
        return ProjectRootAccessSession(
            url: root,
            rootLabel: grant.rootLabel,
            stop: { [coder, resolvedURL = resolved.url] _ in
                coder.stopAccessing(resolvedURL)
            }
        )
    }

    private static func validatedDirectory(_ url: URL) throws -> URL {
        guard url.isFileURL else { throw ProjectRootAccessError.notAFileURL }
        let standardized = url.standardizedFileURL
        let values = try standardized.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        guard values.isDirectory == true else { throw ProjectRootAccessError.notDirectory }
        guard values.isSymbolicLink != true else { throw ProjectRootAccessError.symbolicLink }
        return standardized
    }
}

public enum ProjectRootAccessError: Error, Equatable, LocalizedError, Sendable {
    case invalidGrant
    case notAFileURL
    case notDirectory
    case symbolicLink
    case staleBookmark
    case accessDenied

    public var errorDescription: String? {
        switch self {
        case .invalidGrant: "The selected project grant is invalid."
        case .notAFileURL: "Choose a project folder on this Mac."
        case .notDirectory: "The selected project root is not a folder."
        case .symbolicLink: "Choose the project folder itself, not a symbolic link."
        case .staleBookmark: "Choose the project folder again to renew access."
        case .accessDenied: "macOS did not grant read-only access to this project folder."
        }
    }
}
