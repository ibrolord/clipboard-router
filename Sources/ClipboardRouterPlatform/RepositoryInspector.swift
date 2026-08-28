import Foundation

public struct RepositoryInspection: Equatable, Sendable {
    public enum Head: Equatable, Sendable {
        case branch(String)
        case detachedCommit(String)
    }

    public let projectName: String
    public let head: Head?

    public init(projectName: String, head: Head?) {
        self.projectName = projectName
        self.head = head
    }

    public var branchLabel: String? {
        switch head {
        case let .branch(name): name
        case let .detachedCommit(commit): "detached@\(commit)"
        case nil: nil
        }
    }
}

/// Performs bounded, read-only repository detection. It never launches Git and deliberately does
/// not inspect configuration, remotes, worktrees, hooks, or repository contents.
public struct RepositoryInspector: Sendable {
    public static let maximumHEADBytes = 4_096

    public init() {}

    public func inspect(_ session: ProjectRootAccessSession) throws -> RepositoryInspection {
        let root = session.url
        let git = root.appendingPathComponent(".git", isDirectory: true)
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: git.path)) != nil {
            throw RepositoryInspectionError.symbolicLink(".git")
        }
        guard FileManager.default.fileExists(atPath: git.path) else {
            return RepositoryInspection(projectName: session.rootLabel, head: nil)
        }
        let gitValues = try git.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .isRegularFileKey,
        ])
        guard gitValues.isSymbolicLink != true else {
            throw RepositoryInspectionError.symbolicLink(".git")
        }
        // A `.git` file may redirect outside the selected root. Worktrees/submodules therefore
        // require a future explicitly reviewed access model instead of following `gitdir:`.
        guard gitValues.isDirectory == true, gitValues.isRegularFile != true else {
            throw RepositoryInspectionError.unsupportedGitLayout
        }

        let headURL = git.appendingPathComponent("HEAD", isDirectory: false)
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: headURL.path)) != nil {
            throw RepositoryInspectionError.symbolicLink(".git/HEAD")
        }
        guard FileManager.default.fileExists(atPath: headURL.path) else {
            throw RepositoryInspectionError.missingHEAD
        }
        let headValues = try headURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard headValues.isSymbolicLink != true else {
            throw RepositoryInspectionError.symbolicLink(".git/HEAD")
        }
        guard headValues.isRegularFile == true else {
            throw RepositoryInspectionError.invalidHEAD
        }

        let handle = try FileHandle(forReadingFrom: headURL)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maximumHEADBytes + 1) ?? Data()
        guard !data.isEmpty, data.count <= Self.maximumHEADBytes,
              let raw = String(data: data, encoding: .utf8)
        else { throw RepositoryInspectionError.invalidHEAD }
        return RepositoryInspection(
            projectName: session.rootLabel,
            head: try Self.parseHEAD(raw)
        )
    }

    private static func parseHEAD(_ raw: String) throws -> RepositoryInspection.Head {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains("\0") else {
            throw RepositoryInspectionError.invalidHEAD
        }
        if value.hasPrefix("ref: ") {
            let reference = String(value.dropFirst(5))
            let prefix = "refs/heads/"
            guard reference.hasPrefix(prefix) else {
                throw RepositoryInspectionError.unsupportedHEADReference
            }
            let branch = String(reference.dropFirst(prefix.count))
            guard Self.isSafeBranch(branch) else {
                throw RepositoryInspectionError.invalidHEAD
            }
            return .branch(branch)
        }
        guard value.count == 40 || value.count == 64,
              value.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0) })
        else { throw RepositoryInspectionError.invalidHEAD }
        return .detachedCommit(String(value.prefix(12)).lowercased())
    }

    private static func isSafeBranch(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 512,
              !value.hasPrefix("/"), !value.hasSuffix("/"),
              !value.contains(".."), !value.contains("//"),
              !value.contains("@{"), !value.hasSuffix("."),
              !value.hasSuffix(".lock")
        else { return false }
        let forbidden = CharacterSet(charactersIn: " ~^:?*[\\")
            .union(.controlCharacters)
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy {
            !$0.isEmpty && !$0.hasPrefix(".") && !$0.hasSuffix(".") && !$0.hasSuffix(".lock")
        } && value.unicodeScalars.allSatisfy { !forbidden.contains($0) }
    }
}

public enum RepositoryInspectionError: Error, Equatable, LocalizedError, Sendable {
    case symbolicLink(String)
    case unsupportedGitLayout
    case missingHEAD
    case invalidHEAD
    case unsupportedHEADReference

    public var errorDescription: String? {
        switch self {
        case let .symbolicLink(path): "Repository inspection refused the symbolic link at \(path)."
        case .unsupportedGitLayout: "This repository uses an external Git directory that is not inspected."
        case .missingHEAD: "The repository has no readable .git/HEAD file."
        case .invalidHEAD: "The repository HEAD value is invalid or too large."
        case .unsupportedHEADReference: "Only local branch and detached-commit HEAD values are shown."
        }
    }
}
