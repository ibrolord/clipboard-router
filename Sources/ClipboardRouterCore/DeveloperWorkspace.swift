import Foundation

/// Actor-isolated source of truth for local Developer Projects. It stores only typed references
/// to ordinary clips; clipboard content remains owned by `ClipboardLibrary`.
public actor DeveloperWorkspace {
    private var state: DeveloperWorkspaceSnapshot
    private let persistence: any DeveloperWorkspacePersisting
    private var isMutationInProgress = false
    private var mutationWaiters: [CheckedContinuation<Void, Never>] = []

    public static func open(
        persistence: any DeveloperWorkspacePersisting
    ) async throws -> DeveloperWorkspace {
        let snapshot = try await persistence.load()
        return try DeveloperWorkspace(snapshot: snapshot, persistence: persistence)
    }

    public init(
        snapshot: DeveloperWorkspaceSnapshot = .empty,
        persistence: any DeveloperWorkspacePersisting = InMemoryDeveloperWorkspaceStore()
    ) throws {
        self.state = try DeveloperWorkspaceSnapshot(
            schemaVersion: snapshot.schemaVersion,
            projects: snapshot.projects,
            activeProjectID: snapshot.activeProjectID,
            memberships: snapshot.memberships,
            debugBundles: snapshot.debugBundles
        )
        self.persistence = persistence
    }

    public func snapshot() -> DeveloperWorkspaceSnapshot {
        state
    }

    @discardableResult
    public func createProject(
        name: String,
        repository: DeveloperRepositoryReference? = nil,
        autoAddDeveloperClips: Bool = false,
        allowedSourceBundleIdentifiers: [String] = [],
        preferredIDEBundleIdentifier: String? = nil,
        activate: Bool = true,
        at date: Date = Date()
    ) async throws -> DeveloperProject {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        let project = try DeveloperProject(
            name: name,
            createdAt: date,
            repository: repository,
            autoAddDeveloperClips: autoAddDeveloperClips,
            allowedSourceBundleIdentifiers: allowedSourceBundleIdentifiers,
            preferredIDEBundleIdentifier: preferredIDEBundleIdentifier
        )
        var projects = state.projects
        projects.append(project)
        let next = try DeveloperWorkspaceSnapshot(
            projects: projects,
            activeProjectID: activate ? project.id : state.activeProjectID,
            memberships: state.memberships,
            debugBundles: state.debugBundles
        )
        try await commit(next)
        return project
    }

    @discardableResult
    public func renameProject(
        id: UUID,
        name: String,
        at date: Date = Date()
    ) async throws -> DeveloperProject {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        guard let index = state.projects.firstIndex(where: { $0.id == id }) else {
            throw DeveloperWorkspaceError.projectNotFound(id)
        }
        let current = state.projects[index]
        guard !current.isArchived else { throw DeveloperWorkspaceError.projectArchived(id) }
        let renamed = try DeveloperProject(
            id: current.id,
            name: name,
            createdAt: current.createdAt,
            modifiedAt: date,
            repository: current.repository,
            autoAddDeveloperClips: current.autoAddDeveloperClips,
            allowedSourceBundleIdentifiers: current.allowedSourceBundleIdentifiers,
            preferredIDEBundleIdentifier: current.preferredIDEBundleIdentifier
        )
        var projects = state.projects
        projects[index] = renamed
        let next = try DeveloperWorkspaceSnapshot(
            projects: projects,
            activeProjectID: state.activeProjectID,
            memberships: state.memberships,
            debugBundles: state.debugBundles
        )
        try await commit(next)
        return renamed
    }

    @discardableResult
    public func setRepository(
        projectID: UUID,
        repository: DeveloperRepositoryReference?,
        at date: Date = Date()
    ) async throws -> DeveloperProject {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        guard let index = state.projects.firstIndex(where: { $0.id == projectID }) else {
            throw DeveloperWorkspaceError.projectNotFound(projectID)
        }
        let current = state.projects[index]
        guard !current.isArchived else {
            throw DeveloperWorkspaceError.projectArchived(projectID)
        }
        let updated = try DeveloperProject(
            id: current.id,
            name: current.name,
            createdAt: current.createdAt,
            modifiedAt: date,
            repository: repository,
            autoAddDeveloperClips: current.autoAddDeveloperClips,
            allowedSourceBundleIdentifiers: current.allowedSourceBundleIdentifiers,
            preferredIDEBundleIdentifier: current.preferredIDEBundleIdentifier
        )
        var projects = state.projects
        projects[index] = updated
        let next = try DeveloperWorkspaceSnapshot(
            projects: projects,
            activeProjectID: state.activeProjectID,
            memberships: state.memberships,
            debugBundles: state.debugBundles
        )
        try await commit(next)
        return updated
    }

    @discardableResult
    public func updateSettings(
        projectID: UUID,
        autoAddDeveloperClips: Bool? = nil,
        allowedSourceBundleIdentifiers: [String]? = nil,
        preferredIDEBundleIdentifier: String? = nil,
        at date: Date = Date()
    ) async throws -> DeveloperProject {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        guard let index = state.projects.firstIndex(where: { $0.id == projectID }) else {
            throw DeveloperWorkspaceError.projectNotFound(projectID)
        }
        let current = state.projects[index]
        guard !current.isArchived else {
            throw DeveloperWorkspaceError.projectArchived(projectID)
        }
        let updated = try DeveloperProject(
            id: current.id,
            name: current.name,
            createdAt: current.createdAt,
            modifiedAt: date,
            repository: current.repository,
            autoAddDeveloperClips: autoAddDeveloperClips ?? current.autoAddDeveloperClips,
            allowedSourceBundleIdentifiers: allowedSourceBundleIdentifiers
                ?? current.allowedSourceBundleIdentifiers,
            preferredIDEBundleIdentifier: preferredIDEBundleIdentifier
                ?? current.preferredIDEBundleIdentifier
        )
        var projects = state.projects
        projects[index] = updated
        let next = try DeveloperWorkspaceSnapshot(
            projects: projects,
            activeProjectID: state.activeProjectID,
            memberships: state.memberships,
            debugBundles: state.debugBundles
        )
        try await commit(next)
        return updated
    }

    /// Atomically adds or removes one approved capture application. This avoids lost updates when
    /// a user toggles several applications before an earlier persistence operation completes.
    @discardableResult
    public func setSourceApplication(
        projectID: UUID,
        bundleIdentifier: String,
        allowed: Bool,
        at date: Date = Date()
    ) async throws -> DeveloperProject {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        guard let index = state.projects.firstIndex(where: { $0.id == projectID }) else {
            throw DeveloperWorkspaceError.projectNotFound(projectID)
        }
        let current = state.projects[index]
        guard !current.isArchived else {
            throw DeveloperWorkspaceError.projectArchived(projectID)
        }
        var identifiers = Set(current.allowedSourceBundleIdentifiers)
        if allowed { identifiers.insert(bundleIdentifier) }
        else { identifiers.remove(bundleIdentifier) }
        let autoAddDeveloperClips = identifiers.isEmpty
            ? false
            : current.autoAddDeveloperClips
        let updated = try DeveloperProject(
            id: current.id,
            name: current.name,
            createdAt: current.createdAt,
            modifiedAt: date,
            repository: current.repository,
            autoAddDeveloperClips: autoAddDeveloperClips,
            allowedSourceBundleIdentifiers: identifiers.sorted(),
            preferredIDEBundleIdentifier: current.preferredIDEBundleIdentifier
        )
        var projects = state.projects
        projects[index] = updated
        let next = try DeveloperWorkspaceSnapshot(
            projects: projects,
            activeProjectID: state.activeProjectID,
            memberships: state.memberships,
            debugBundles: state.debugBundles
        )
        try await commit(next)
        return updated
    }

    @discardableResult
    public func archiveProject(
        id: UUID,
        at date: Date = Date()
    ) async throws -> DeveloperProject {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        guard let index = state.projects.firstIndex(where: { $0.id == id }) else {
            throw DeveloperWorkspaceError.projectNotFound(id)
        }
        let current = state.projects[index]
        if current.isArchived { return current }
        let archived = try DeveloperProject(
            id: current.id,
            name: current.name,
            createdAt: current.createdAt,
            modifiedAt: current.modifiedAt,
            archivedAt: date,
            repository: current.repository,
            autoAddDeveloperClips: current.autoAddDeveloperClips,
            allowedSourceBundleIdentifiers: current.allowedSourceBundleIdentifiers,
            preferredIDEBundleIdentifier: current.preferredIDEBundleIdentifier
        )
        var projects = state.projects
        projects[index] = archived
        let next = try DeveloperWorkspaceSnapshot(
            projects: projects,
            activeProjectID: state.activeProjectID == id ? nil : state.activeProjectID,
            memberships: state.memberships,
            debugBundles: state.debugBundles
        )
        try await commit(next)
        return archived
    }

    public func setActiveProject(_ id: UUID?) async throws {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        if let id {
            guard let project = state.projects.first(where: { $0.id == id }) else {
                throw DeveloperWorkspaceError.projectNotFound(id)
            }
            guard !project.isArchived else { throw DeveloperWorkspaceError.projectArchived(id) }
        }
        guard state.activeProjectID != id else { return }
        let next = try DeveloperWorkspaceSnapshot(
            projects: state.projects,
            activeProjectID: id,
            memberships: state.memberships,
            debugBundles: state.debugBundles
        )
        try await commit(next)
    }

    /// Idempotently associates a history or saved-library ID with a project.
    @discardableResult
    public func addMembership(
        projectID: UUID,
        clip: DeveloperClipReference,
        at date: Date = Date()
    ) async throws -> DeveloperClipMembership {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        guard let project = state.projects.first(where: { $0.id == projectID }) else {
            throw DeveloperWorkspaceError.projectNotFound(projectID)
        }
        guard !project.isArchived else {
            throw DeveloperWorkspaceError.projectArchived(projectID)
        }
        if let existing = state.memberships.first(where: {
            $0.projectID == projectID && $0.clip == clip
        }) {
            return existing
        }
        let membership = DeveloperClipMembership(
            projectID: projectID,
            clip: clip,
            addedAt: date
        )
        var memberships = state.memberships
        memberships.append(membership)
        let next = try DeveloperWorkspaceSnapshot(
            projects: state.projects,
            activeProjectID: state.activeProjectID,
            memberships: memberships,
            debugBundles: state.debugBundles
        )
        try await commit(next)
        return membership
    }

    @discardableResult
    public func saveDebugBundle(
        projectID: UUID,
        bundle: DebugBundle,
        at date: Date = Date()
    ) async throws -> PersistedDebugBundleSnapshot {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        guard let project = state.projects.first(where: { $0.id == projectID }) else {
            throw DeveloperWorkspaceError.projectNotFound(projectID)
        }
        guard !project.isArchived else {
            throw DeveloperWorkspaceError.projectArchived(projectID)
        }
        if let existing = state.debugBundles.first(where: {
            $0.projectID == projectID
                && Self.isSameReviewedBundle($0.bundle, bundle)
        }) {
            return existing
        }
        let saved = try PersistedDebugBundleSnapshot(
            projectID: projectID,
            savedAt: date,
            bundle: bundle
        )
        var bundles = state.debugBundles
        bundles.append(saved)
        let next = try DeveloperWorkspaceSnapshot(
            projects: state.projects,
            activeProjectID: state.activeProjectID,
            memberships: state.memberships,
            debugBundles: bundles
        )
        try await commit(next)
        return saved
    }

    /// A reopened review receives a fresh presentation timestamp. That timestamp must not turn
    /// the same reviewed content into another durable snapshot. Deliberate edits to the project
    /// label, problem statement, source collection, items, or render limit still create a new
    /// snapshot.
    private static func isSameReviewedBundle(_ lhs: DebugBundle, _ rhs: DebugBundle) -> Bool {
        lhs.id == rhs.id
            && lhs.schemaVersion == rhs.schemaVersion
            && lhs.project == rhs.project
            && lhs.problemStatement == rhs.problemStatement
            && lhs.sourceContextPackID == rhs.sourceContextPackID
            && lhs.sourceContextPackName == rhs.sourceContextPackName
            && lhs.items == rhs.items
            && lhs.maximumRenderedUTF8Bytes == rhs.maximumRenderedUTF8Bytes
    }

    public func deleteDebugBundle(id: UUID) async throws {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        guard let index = state.debugBundles.firstIndex(where: { $0.id == id }) else {
            throw DeveloperWorkspaceError.debugBundleNotFound(id)
        }
        var bundles = state.debugBundles
        bundles.remove(at: index)
        let next = try DeveloperWorkspaceSnapshot(
            projects: state.projects,
            activeProjectID: state.activeProjectID,
            memberships: state.memberships,
            debugBundles: bundles
        )
        try await commit(next)
    }

    public func memberships(projectID: UUID) throws -> [DeveloperClipMembership] {
        _ = try requireProject(projectID)
        return state.memberships.filter { $0.projectID == projectID }
    }

    public func debugBundles(projectID: UUID) throws -> [PersistedDebugBundleSnapshot] {
        _ = try requireProject(projectID)
        return state.debugBundles.filter { $0.projectID == projectID }
    }

    public func timeline(projectID: UUID, limit: Int = 200) throws -> [DeveloperTimelineEntry] {
        let project = try requireProject(projectID)
        guard limit > 0 else { return [] }

        var entries = [DeveloperTimelineEntry(
            id: project.id,
            occurredAt: project.createdAt,
            kind: .projectCreated
        )]
        entries.append(contentsOf: state.memberships.lazy
            .filter { $0.projectID == projectID }
            .map {
                DeveloperTimelineEntry(id: $0.id, occurredAt: $0.addedAt, kind: .clipAdded($0.clip))
            })
        entries.append(contentsOf: state.debugBundles.lazy
            .filter { $0.projectID == projectID }
            .map {
                DeveloperTimelineEntry(
                    id: $0.id,
                    occurredAt: $0.savedAt,
                    kind: .debugBundleSaved(bundleID: $0.id, itemCount: $0.bundle.items.count)
                )
            })
        entries.sort {
            if $0.occurredAt != $1.occurredAt { return $0.occurredAt > $1.occurredAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        return Array(entries.prefix(limit))
    }

    private func requireProject(_ id: UUID) throws -> DeveloperProject {
        guard let project = state.projects.first(where: { $0.id == id }) else {
            throw DeveloperWorkspaceError.projectNotFound(id)
        }
        return project
    }

    private func commit(_ snapshot: DeveloperWorkspaceSnapshot) async throws {
        try await persistence.save(snapshot)
        state = snapshot
    }

    private func acquireMutationPermit() async {
        if !isMutationInProgress {
            isMutationInProgress = true
            return
        }
        await withCheckedContinuation { continuation in
            mutationWaiters.append(continuation)
        }
    }

    private func releaseMutationPermit() {
        if mutationWaiters.isEmpty {
            isMutationInProgress = false
            return
        }
        mutationWaiters.removeFirst().resume()
    }
}
