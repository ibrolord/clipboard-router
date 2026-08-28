import Foundation

/// Fail-closed validation errors for the local Developer Workspace domain.
public enum DeveloperWorkspaceError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedSchemaVersion(Int)
    case invalidProjectName
    case invalidRepositoryField(String)
    case invalidRepositoryBookmark
    case duplicateProject(UUID)
    case duplicateProjectName(String)
    case projectNotFound(UUID)
    case projectArchived(UUID)
    case invalidProjectDates(UUID)
    case duplicateMembership(UUID)
    case duplicateClipReference(UUID)
    case membershipLimitExceeded(Int)
    case duplicateDebugBundle(UUID)
    case debugBundleNotFound(UUID)
    case debugBundleItemLimitExceeded(Int)
    case debugBundleSizeLimitExceeded(actual: Int, maximum: Int)
    case debugBundleLimitExceeded(Int)
    case projectLimitExceeded(Int)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedSchemaVersion(version):
            "Developer Workspace schema version \(version) is not supported."
        case .invalidProjectName:
            "A project name must be non-empty, safe text of at most 200 UTF-8 bytes."
        case let .invalidRepositoryField(field):
            "The repository \(field) is invalid."
        case .invalidRepositoryBookmark:
            "The repository bookmark is empty or exceeds its local storage limit."
        case let .duplicateProject(id):
            "Project \(id) appears more than once."
        case let .duplicateProjectName(name):
            "A project named \(name) already exists."
        case let .projectNotFound(id):
            "Project \(id) was not found."
        case let .projectArchived(id):
            "Project \(id) is archived and cannot be activated or changed."
        case let .invalidProjectDates(id):
            "Project \(id) contains invalid lifecycle dates."
        case let .duplicateMembership(id):
            "Developer membership \(id) appears more than once."
        case let .duplicateClipReference(projectID):
            "A clip reference appears more than once in project \(projectID)."
        case let .membershipLimitExceeded(maximum):
            "Developer Workspace cannot contain more than \(maximum) clip memberships."
        case let .duplicateDebugBundle(id):
            "Debug Bundle snapshot \(id) appears more than once."
        case let .debugBundleNotFound(id):
            "Debug Bundle snapshot \(id) was not found."
        case let .debugBundleItemLimitExceeded(maximum):
            "A saved Debug Bundle cannot contain more than \(maximum) items."
        case let .debugBundleSizeLimitExceeded(actual, maximum):
            "The Debug Bundle snapshot is \(actual) bytes; the limit is \(maximum)."
        case let .debugBundleLimitExceeded(maximum):
            "Developer Workspace cannot contain more than \(maximum) Debug Bundle snapshots."
        case let .projectLimitExceeded(maximum):
            "Developer Workspace cannot contain more than \(maximum) projects."
        }
    }
}

/// Local-only repository identity. It deliberately stores a security-scoped bookmark and a
/// one-way canonical-path fingerprint instead of synchronizing or persisting a plaintext path.
public struct DeveloperRepositoryReference: Codable, Equatable, Sendable {
    public static let maximumBookmarkBytes = 1_024 * 1_024

    public let displayName: String
    public let securityScopedBookmark: Data
    public let canonicalPathFingerprint: String
    public let branch: String?
    public let inspectedAt: Date

    public init(
        displayName: String,
        securityScopedBookmark: Data,
        canonicalPathFingerprint: String,
        branch: String? = nil,
        inspectedAt: Date = Date()
    ) throws {
        self.displayName = try Self.validated(
            displayName,
            field: "display name",
            maximumBytes: 255
        )
        guard !securityScopedBookmark.isEmpty,
              securityScopedBookmark.count <= Self.maximumBookmarkBytes
        else { throw DeveloperWorkspaceError.invalidRepositoryBookmark }
        self.securityScopedBookmark = securityScopedBookmark

        let fingerprint = canonicalPathFingerprint.lowercased()
        guard fingerprint.utf8.count == 64,
              fingerprint.allSatisfy({ $0.isHexDigit })
        else { throw DeveloperWorkspaceError.invalidRepositoryField("path fingerprint") }
        self.canonicalPathFingerprint = fingerprint
        self.branch = try Self.optional(branch, field: "branch", maximumBytes: 255)
        self.inspectedAt = inspectedAt
    }

    private enum CodingKeys: String, CodingKey {
        case displayName, securityScopedBookmark, canonicalPathFingerprint
        case branch, inspectedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            displayName: container.decode(String.self, forKey: .displayName),
            securityScopedBookmark: container.decode(Data.self, forKey: .securityScopedBookmark),
            canonicalPathFingerprint: container.decode(
                String.self,
                forKey: .canonicalPathFingerprint
            ),
            branch: container.decodeIfPresent(String.self, forKey: .branch),
            inspectedAt: container.decode(Date.self, forKey: .inspectedAt)
        )
    }

    private static func optional(
        _ raw: String?,
        field: String,
        maximumBytes: Int
    ) throws -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return try validated(value, field: field, maximumBytes: maximumBytes)
    }

    private static func validated(
        _ raw: String,
        field: String,
        maximumBytes: Int
    ) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.utf8.count <= maximumBytes,
              value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { throw DeveloperWorkspaceError.invalidRepositoryField(field) }
        return value
    }
}

public struct DeveloperProject: Codable, Equatable, Identifiable, Sendable {
    public static let maximumAllowedSourceApplicationCount = 64

    public let id: UUID
    public let name: String
    public let createdAt: Date
    public let modifiedAt: Date
    public let archivedAt: Date?
    public let repository: DeveloperRepositoryReference?
    public let autoAddDeveloperClips: Bool
    public let allowedSourceBundleIdentifiers: [String]
    public let preferredIDEBundleIdentifier: String?

    public init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        modifiedAt: Date? = nil,
        archivedAt: Date? = nil,
        repository: DeveloperRepositoryReference? = nil,
        autoAddDeveloperClips: Bool = false,
        allowedSourceBundleIdentifiers: [String] = [],
        preferredIDEBundleIdentifier: String? = nil
    ) throws {
        self.id = id
        self.name = try Self.validatedName(name)
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt ?? createdAt
        self.archivedAt = archivedAt
        self.repository = repository
        self.autoAddDeveloperClips = autoAddDeveloperClips
        self.allowedSourceBundleIdentifiers = try Self.validatedBundleIdentifiers(
            allowedSourceBundleIdentifiers
        )
        self.preferredIDEBundleIdentifier = try preferredIDEBundleIdentifier.map {
            try Self.validatedBundleIdentifier($0)
        }
        guard self.modifiedAt >= createdAt,
              archivedAt.map({ $0 >= createdAt && $0 >= self.modifiedAt }) ?? true
        else { throw DeveloperWorkspaceError.invalidProjectDates(id) }
    }

    public var isArchived: Bool { archivedAt != nil }

    private enum CodingKeys: String, CodingKey {
        case id, name, createdAt, modifiedAt, archivedAt, repository
        case autoAddDeveloperClips, allowedSourceBundleIdentifiers, preferredIDEBundleIdentifier
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            name: container.decode(String.self, forKey: .name),
            createdAt: container.decode(Date.self, forKey: .createdAt),
            modifiedAt: container.decode(Date.self, forKey: .modifiedAt),
            archivedAt: container.decodeIfPresent(Date.self, forKey: .archivedAt),
            repository: container.decodeIfPresent(
                DeveloperRepositoryReference.self,
                forKey: .repository
            ),
            autoAddDeveloperClips: container.decodeIfPresent(
                Bool.self,
                forKey: .autoAddDeveloperClips
            ) ?? false,
            allowedSourceBundleIdentifiers: container.decodeIfPresent(
                [String].self,
                forKey: .allowedSourceBundleIdentifiers
            ) ?? [],
            preferredIDEBundleIdentifier: container.decodeIfPresent(
                String.self,
                forKey: .preferredIDEBundleIdentifier
            )
        )
    }

    static func validatedName(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.utf8.count <= 200,
              value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { throw DeveloperWorkspaceError.invalidProjectName }
        return value
    }

    private static func validatedBundleIdentifiers(_ raw: [String]) throws -> [String] {
        guard raw.count <= maximumAllowedSourceApplicationCount else {
            throw DeveloperWorkspaceError.invalidRepositoryField("source application list")
        }
        let values = try raw.map(validatedBundleIdentifier)
        guard Set(values).count == values.count else {
            throw DeveloperWorkspaceError.invalidRepositoryField("source application list")
        }
        return values.sorted()
    }

    private static func validatedBundleIdentifier(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        guard !value.isEmpty,
              value.utf8.count <= 255,
              value.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              !value.hasPrefix("."),
              !value.hasSuffix("."),
              value.contains(".")
        else { throw DeveloperWorkspaceError.invalidRepositoryField("application identifier") }
        return value
    }
}

/// A typed foreign key into the ordinary library. No clip body or metadata is duplicated here.
public enum DeveloperClipReference: Codable, Equatable, Hashable, Sendable {
    case history(UUID)
    case saved(UUID)

    public var itemID: UUID {
        switch self {
        case let .history(id), let .saved(id): id
        }
    }
}

public struct DeveloperClipMembership: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let projectID: UUID
    public let clip: DeveloperClipReference
    public let addedAt: Date

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        clip: DeveloperClipReference,
        addedAt: Date = Date()
    ) {
        self.id = id
        self.projectID = projectID
        self.clip = clip
        self.addedAt = addedAt
    }
}

/// An immutable reviewed artifact. Unlike timeline entries, the snapshot intentionally contains
/// its bounded Debug Bundle payload so it can be reopened after source history expires.
public struct PersistedDebugBundleSnapshot: Codable, Equatable, Identifiable, Sendable {
    public static let maximumItemCount = 100
    public static let maximumEncodedBytes = 1_024 * 1_024

    public let id: UUID
    public let projectID: UUID
    public let savedAt: Date
    public let bundle: DebugBundle

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        savedAt: Date = Date(),
        bundle: DebugBundle
    ) throws {
        guard bundle.items.count <= Self.maximumItemCount else {
            throw DeveloperWorkspaceError.debugBundleItemLimitExceeded(Self.maximumItemCount)
        }
        let bytes = try DebugBundleRenderer().renderJSON(bundle)
        guard bytes.count <= Self.maximumEncodedBytes else {
            throw DeveloperWorkspaceError.debugBundleSizeLimitExceeded(
                actual: bytes.count,
                maximum: Self.maximumEncodedBytes
            )
        }
        self.id = id
        self.projectID = projectID
        self.savedAt = savedAt
        self.bundle = bundle
    }

    private enum CodingKeys: String, CodingKey {
        case id, projectID, savedAt, bundle
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            projectID: container.decode(UUID.self, forKey: .projectID),
            savedAt: container.decode(Date.self, forKey: .savedAt),
            bundle: container.decode(DebugBundle.self, forKey: .bundle)
        )
    }
}

/// A deliberately closed, content-free event used to render a project timeline.
public struct DeveloperTimelineEntry: Equatable, Identifiable, Sendable {
    public enum Kind: Equatable, Sendable {
        case projectCreated
        case clipAdded(DeveloperClipReference)
        case debugBundleSaved(bundleID: UUID, itemCount: Int)
    }

    public let id: UUID
    public let occurredAt: Date
    public let kind: Kind

    public init(id: UUID, occurredAt: Date, kind: Kind) {
        self.id = id
        self.occurredAt = occurredAt
        self.kind = kind
    }
}

public struct DeveloperWorkspaceSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let maximumProjectCount = 256
    public static let maximumMembershipCount = 50_000
    public static let maximumDebugBundleCount = 512

    public let schemaVersion: Int
    public let projects: [DeveloperProject]
    public let activeProjectID: UUID?
    public let memberships: [DeveloperClipMembership]
    public let debugBundles: [PersistedDebugBundleSnapshot]

    public static let empty = try! DeveloperWorkspaceSnapshot()

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        projects: [DeveloperProject] = [],
        activeProjectID: UUID? = nil,
        memberships: [DeveloperClipMembership] = [],
        debugBundles: [PersistedDebugBundleSnapshot] = []
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw DeveloperWorkspaceError.unsupportedSchemaVersion(schemaVersion)
        }
        guard projects.count <= Self.maximumProjectCount else {
            throw DeveloperWorkspaceError.projectLimitExceeded(Self.maximumProjectCount)
        }
        guard memberships.count <= Self.maximumMembershipCount else {
            throw DeveloperWorkspaceError.membershipLimitExceeded(Self.maximumMembershipCount)
        }
        guard debugBundles.count <= Self.maximumDebugBundleCount else {
            throw DeveloperWorkspaceError.debugBundleLimitExceeded(Self.maximumDebugBundleCount)
        }

        let projectIDs = Set(projects.map(\.id))
        guard projectIDs.count == projects.count else {
            let duplicate = Dictionary(grouping: projects, by: \.id)
                .first(where: { $0.value.count > 1 })!.key
            throw DeveloperWorkspaceError.duplicateProject(duplicate)
        }
        var names = Set<String>()
        for project in projects where !project.isArchived {
            let folded = project.name.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            guard names.insert(folded).inserted else {
                throw DeveloperWorkspaceError.duplicateProjectName(project.name)
            }
        }
        if let activeProjectID {
            guard let project = projects.first(where: { $0.id == activeProjectID }) else {
                throw DeveloperWorkspaceError.projectNotFound(activeProjectID)
            }
            guard !project.isArchived else {
                throw DeveloperWorkspaceError.projectArchived(activeProjectID)
            }
        }

        let membershipIDs = Set(memberships.map(\.id))
        if membershipIDs.count != memberships.count {
            let duplicate = Dictionary(grouping: memberships, by: \.id)
                .first(where: { $0.value.count > 1 })!.key
            throw DeveloperWorkspaceError.duplicateMembership(duplicate)
        }
        var membershipKeys = Set<MembershipKey>()
        for membership in memberships {
            guard projectIDs.contains(membership.projectID) else {
                throw DeveloperWorkspaceError.projectNotFound(membership.projectID)
            }
            let key = MembershipKey(projectID: membership.projectID, clip: membership.clip)
            guard membershipKeys.insert(key).inserted else {
                throw DeveloperWorkspaceError.duplicateClipReference(membership.projectID)
            }
        }

        let bundleIDs = Set(debugBundles.map(\.id))
        if bundleIDs.count != debugBundles.count {
            let duplicate = Dictionary(grouping: debugBundles, by: \.id)
                .first(where: { $0.value.count > 1 })!.key
            throw DeveloperWorkspaceError.duplicateDebugBundle(duplicate)
        }
        for bundle in debugBundles where !projectIDs.contains(bundle.projectID) {
            throw DeveloperWorkspaceError.projectNotFound(bundle.projectID)
        }

        self.schemaVersion = schemaVersion
        self.projects = projects.sorted(by: Self.projectOrder)
        self.activeProjectID = activeProjectID
        self.memberships = memberships.sorted(by: Self.membershipOrder)
        self.debugBundles = debugBundles.sorted(by: Self.bundleOrder)
    }

    private struct MembershipKey: Hashable {
        let projectID: UUID
        let clip: DeveloperClipReference
    }

    private static func projectOrder(_ lhs: DeveloperProject, _ rhs: DeveloperProject) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func membershipOrder(
        _ lhs: DeveloperClipMembership,
        _ rhs: DeveloperClipMembership
    ) -> Bool {
        if lhs.addedAt != rhs.addedAt { return lhs.addedAt < rhs.addedAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func bundleOrder(
        _ lhs: PersistedDebugBundleSnapshot,
        _ rhs: PersistedDebugBundleSnapshot
    ) -> Bool {
        if lhs.savedAt != rhs.savedAt { return lhs.savedAt < rhs.savedAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
