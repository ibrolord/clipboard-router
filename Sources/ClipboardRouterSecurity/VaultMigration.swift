import Foundation

public enum VaultMigrationStage: String, Codable, Sendable {
    case pending
    case encrypted
    case sourceRemoved
}

public struct VaultMigrationEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var stage: VaultMigrationStage

    public init(id: UUID, stage: VaultMigrationStage = .pending) {
        self.id = id
        self.stage = stage
    }
}

public struct VaultMigrationJournal: Codable, Equatable, Sendable {
    public let migrationID: String
    public let fromVersion: Int
    public let toVersion: Int
    public var entries: [VaultMigrationEntry]
    public var completedAt: Date?

    public init(
        migrationID: String,
        fromVersion: Int,
        toVersion: Int,
        entries: [VaultMigrationEntry],
        completedAt: Date? = nil
    ) {
        self.migrationID = migrationID
        self.fromVersion = fromVersion
        self.toVersion = toVersion
        self.entries = entries
        self.completedAt = completedAt
    }
}

public protocol VaultMigrationJournalStore: Sendable {
    func load() async throws -> VaultMigrationJournal?
    func save(_ journal: VaultMigrationJournal) async throws
}

public protocol VaultMigrationSource: Sendable {
    func candidates() async throws -> [VaultItem]
    /// Must treat an already-removed identifier as success so a crash can be replayed.
    func removeCandidate(id: UUID) async throws
}

public protocol VaultMigrationDestination: Sendable {
    /// Returns the authenticated, decrypted destination value for equality validation.
    func existingItem(id: UUID) async throws -> VaultItem?
    /// Must be idempotent for an item with the same identifier.
    func insertIfAbsent(_ item: VaultItem) async throws
}

/// A crash-resumable three-stage migration. Every step is safe to replay.
public actor VaultMigrationCoordinator {
    private let journalStore: any VaultMigrationJournalStore
    private let source: any VaultMigrationSource
    private let destination: any VaultMigrationDestination
    private let now: @Sendable () -> Date

    public init(
        journalStore: any VaultMigrationJournalStore,
        source: any VaultMigrationSource,
        destination: any VaultMigrationDestination,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.journalStore = journalStore
        self.source = source
        self.destination = destination
        self.now = now
    }

    @discardableResult
    public func run(
        migrationID: String,
        fromVersion: Int,
        toVersion: Int
    ) async throws -> VaultMigrationJournal {
        let candidates = try await source.candidates()
        var journal: VaultMigrationJournal
        if let existing = try await journalStore.load() {
            guard existing.migrationID == migrationID,
                  existing.fromVersion == fromVersion,
                  existing.toVersion == toVersion
            else { throw VaultError.migrationConflict }
            journal = existing
        } else {
            journal = VaultMigrationJournal(
                migrationID: migrationID,
                fromVersion: fromVersion,
                toVersion: toVersion,
                entries: candidates.map { VaultMigrationEntry(id: $0.id) }
            )
            try await journalStore.save(journal)
        }

        var itemsByID: [UUID: VaultItem] = [:]
        for candidate in candidates {
            guard itemsByID.updateValue(candidate, forKey: candidate.id) == nil else {
                throw VaultError.duplicateItem(candidate.id)
            }
        }
        for index in journal.entries.indices {
            let id = journal.entries[index].id
            if journal.entries[index].stage == .pending {
                let sourceItem = itemsByID[id]
                if let existing = try await destination.existingItem(id: id) {
                    if let sourceItem, existing != sourceItem {
                        throw VaultError.migrationConflict
                    }
                } else {
                    guard let sourceItem else { throw VaultError.itemNotFound(id) }
                    try await destination.insertIfAbsent(sourceItem)
                    guard try await destination.existingItem(id: id) == sourceItem else {
                        throw VaultError.migrationConflict
                    }
                }
                journal.entries[index].stage = .encrypted
                try await journalStore.save(journal)
            }
            if journal.entries[index].stage == .encrypted {
                let existing = try await destination.existingItem(id: id)
                if let sourceItem = itemsByID[id] {
                    guard existing == sourceItem else { throw VaultError.migrationConflict }
                } else {
                    // A prior replay may already have removed the source. Still verify that
                    // authenticated destination ciphertext exists before marking completion.
                    guard existing != nil else { throw VaultError.migrationConflict }
                }
                try await source.removeCandidate(id: id)
                journal.entries[index].stage = .sourceRemoved
                try await journalStore.save(journal)
            }
        }
        journal.completedAt = now()
        try await journalStore.save(journal)
        return journal
    }
}

public actor InMemoryVaultMigrationJournalStore: VaultMigrationJournalStore {
    private var journal: VaultMigrationJournal?
    public init(journal: VaultMigrationJournal? = nil) { self.journal = journal }
    public func load() async throws -> VaultMigrationJournal? { journal }
    public func save(_ journal: VaultMigrationJournal) async throws { self.journal = journal }
}
