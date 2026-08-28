import Foundation

public enum UserSmartViewError: Error, LocalizedError, Equatable, Sendable {
    case emptyName
    case nameTooLong
    case invalidName
    case emptyQuery
    case queryTooLong
    case invalidQuery
    case duplicateName
    case tooManyViews
    case viewNotFound(UUID)

    public var errorDescription: String? {
        switch self {
        case .emptyName: "Enter a name for this Smart View."
        case .nameTooLong: "Smart View names must be 100 characters or fewer."
        case .invalidName: "Smart View names cannot contain control characters."
        case .emptyQuery: "Enter a search query before saving this Smart View."
        case .queryTooLong: "Smart View queries must be 2,048 bytes or fewer."
        case .invalidQuery: "This query contains an invalid search filter."
        case .duplicateName: "A Smart View with that name already exists."
        case .tooManyViews: "You can save up to 100 Smart Views."
        case let .viewNotFound(id): "Smart View \(id) no longer exists."
        }
    }
}

/// A user-owned, local definition. Results are always recomputed by the ordinary search engine;
/// no clip IDs, result bodies, Vault data, or private-session data are persisted here.
public struct UserSmartView: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var query: String
    public var isPinned: Bool
    public var sortOrder: Int
    public let createdAt: Date
    public var modifiedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        query: String,
        isPinned: Bool = false,
        sortOrder: Int = 0,
        createdAt: Date = Date(),
        modifiedAt: Date? = nil
    ) throws {
        self.id = id
        self.name = try Self.validateName(name)
        self.query = try ClipSearchQuery.validate(query).normalized
        self.isPinned = isPinned
        self.sortOrder = max(0, sortOrder)
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt ?? createdAt
    }

    public static func validateName(_ candidate: String) throws -> String {
        let value = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw UserSmartViewError.emptyName }
        guard value.count <= 100, value.utf8.count <= 400 else {
            throw UserSmartViewError.nameTooLong
        }
        guard value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw UserSmartViewError.invalidName
        }
        return value
    }
}

public struct ClipSearchQuery: Equatable, Sendable {
    public let normalized: String
    public let explanations: [String]

    public static func validate(_ candidate: String, now: Date = Date()) throws -> Self {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw UserSmartViewError.emptyQuery }
        guard trimmed.utf8.count <= 2_048 else { throw UserSmartViewError.queryTooLong }
        let parsed = ClipSearchIndex.parse(query: trimmed, now: now)
        guard !parsed.isInvalid, !parsed.isEmpty else { throw UserSmartViewError.invalidQuery }
        return Self(
            normalized: parsed.normalizedInput,
            explanations: Self.explain(parsed)
        )
    }

    private static func explain(_ query: ClipSearchIndex.ParsedQuery) -> [String] {
        var values: [String] = []
        func add(_ label: String, _ terms: [String]) {
            values.append(contentsOf: terms.map { "\(label): \($0)" })
        }
        add("Text", query.generalTerms + query.contentTerms)
        add("Source", query.sources + query.exactSources)
        add("Domain", query.domains + query.exactDomains)
        add("Type", query.types)
        add("Device", query.devices)
        add("Location", query.locations)
        add("Sensitivity", query.secrets)
        if !query.dates.isEmpty { values.append("Date filter") }
        add("Folder", query.folders)
        add("Tag", query.tags)
        add("File type", query.utis)
        add("Origin", query.origins)
        add("Kind", query.savedItemKinds.map(\.rawValue))
        if !query.pinned.isEmpty { values.append("Pinned: \(query.pinned.map(String.init).joined(separator: ", "))") }
        if !query.sizes.isEmpty { values.append("Size filter") }
        if !query.captures.isEmpty { values.append("Capture count filter") }
        if !query.pastes.isEmpty { values.append("Paste count filter") }
        return values
    }
}

public protocol UserSmartViewPersisting: Sendable {
    func load() async throws -> [UserSmartView]
    func save(_ views: [UserSmartView]) async throws
}

public actor InMemoryUserSmartViewStore: UserSmartViewPersisting {
    private var views: [UserSmartView]

    public init(views: [UserSmartView] = []) { self.views = views }
    public func load() async throws -> [UserSmartView] { views }
    public func save(_ views: [UserSmartView]) async throws { self.views = views }
}

public actor JSONFileUserSmartViewStore: UserSmartViewPersisting {
    public let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    public init(fileURL: URL) {
        self.fileURL = fileURL.standardizedFileURL
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder
    }

    public func load() async throws -> [UserSmartView] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            return try decoder.decode([UserSmartView].self, from: Data(contentsOf: fileURL))
        } catch {
            throw ClipboardLibraryPersistenceError.undecodableFile(fileURL, String(describing: error))
        }
    }

    public func save(_ views: [UserSmartView]) async throws {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try encoder.encode(views).write(to: fileURL, options: [.atomic])
        } catch {
            throw ClipboardLibraryPersistenceError.unwritableFile(fileURL, String(describing: error))
        }
    }
}

public actor UserSmartViewLibrary {
    public static let maximumViewCount = 100
    private var views: [UserSmartView]
    private let persistence: any UserSmartViewPersisting

    public static func open(persistence: any UserSmartViewPersisting) async throws -> UserSmartViewLibrary {
        let loaded = try await persistence.load()
        var seenIDs = Set<UUID>()
        var seenNames = Set<String>()
        var valid: [UserSmartView] = []
        for view in loaded.sorted(by: Self.order) {
            guard valid.count < maximumViewCount else { break }
            guard seenIDs.insert(view.id).inserted,
                  seenNames.insert(Self.nameKey(view.name)).inserted,
                  let normalized = try? UserSmartView(
                    id: view.id,
                    name: view.name,
                    query: view.query,
                    isPinned: view.isPinned,
                    sortOrder: valid.count,
                    createdAt: view.createdAt,
                    modifiedAt: view.modifiedAt
                  )
            else { continue }
            valid.append(normalized)
        }
        if valid != loaded { try await persistence.save(valid) }
        return UserSmartViewLibrary(views: valid, persistence: persistence)
    }

    private init(views: [UserSmartView], persistence: any UserSmartViewPersisting) {
        self.views = views
        self.persistence = persistence
    }

    public func snapshot() -> [UserSmartView] { views.sorted(by: Self.order) }

    @discardableResult
    public func create(name: String, query: String, pinned: Bool = false, at date: Date = Date()) async throws -> UserSmartView {
        guard views.count < Self.maximumViewCount else { throw UserSmartViewError.tooManyViews }
        let name = try UserSmartView.validateName(name)
        guard !views.contains(where: { Self.nameKey($0.name) == Self.nameKey(name) }) else {
            throw UserSmartViewError.duplicateName
        }
        let view = try UserSmartView(
            name: name,
            query: query,
            isPinned: pinned,
            sortOrder: views.count,
            createdAt: date
        )
        var next = views
        next.append(view)
        try await persistence.save(next)
        views = next
        return view
    }

    public func rename(id: UUID, name: String, at date: Date = Date()) async throws {
        guard let index = views.firstIndex(where: { $0.id == id }) else {
            throw UserSmartViewError.viewNotFound(id)
        }
        let name = try UserSmartView.validateName(name)
        guard !views.contains(where: { $0.id != id && Self.nameKey($0.name) == Self.nameKey(name) }) else {
            throw UserSmartViewError.duplicateName
        }
        var next = views
        next[index].name = name
        next[index].modifiedAt = date
        try await persistence.save(next)
        views = next
    }

    public func updateQuery(id: UUID, query: String, at date: Date = Date()) async throws {
        guard let index = views.firstIndex(where: { $0.id == id }) else {
            throw UserSmartViewError.viewNotFound(id)
        }
        var next = views
        next[index].query = try ClipSearchQuery.validate(query).normalized
        next[index].modifiedAt = date
        try await persistence.save(next)
        views = next
    }

    public func update(
        id: UUID,
        name: String,
        query: String,
        pinned: Bool,
        at date: Date = Date()
    ) async throws {
        guard let index = views.firstIndex(where: { $0.id == id }) else {
            throw UserSmartViewError.viewNotFound(id)
        }
        let name = try UserSmartView.validateName(name)
        guard !views.contains(where: { $0.id != id && Self.nameKey($0.name) == Self.nameKey(name) }) else {
            throw UserSmartViewError.duplicateName
        }
        var next = views
        next[index].name = name
        next[index].query = try ClipSearchQuery.validate(query).normalized
        next[index].isPinned = pinned
        next[index].modifiedAt = date
        try await persistence.save(next)
        views = next
    }

    public func setPinned(id: UUID, pinned: Bool, at date: Date = Date()) async throws {
        guard let index = views.firstIndex(where: { $0.id == id }) else {
            throw UserSmartViewError.viewNotFound(id)
        }
        var next = views
        next[index].isPinned = pinned
        next[index].modifiedAt = date
        try await persistence.save(next)
        views = next
    }

    public func reorder(ids: [UUID], at date: Date = Date()) async throws {
        guard Set(ids) == Set(views.map(\.id)), ids.count == views.count else {
            throw UserSmartViewError.invalidQuery
        }
        let byID = Dictionary(uniqueKeysWithValues: views.map { ($0.id, $0) })
        var next = ids.enumerated().compactMap { offset, id -> UserSmartView? in
            guard var view = byID[id] else { return nil }
            view.sortOrder = offset
            view.modifiedAt = date
            return view
        }
        next.sort(by: Self.order)
        try await persistence.save(next)
        views = next
    }

    public func delete(id: UUID) async throws {
        guard views.contains(where: { $0.id == id }) else {
            throw UserSmartViewError.viewNotFound(id)
        }
        var next = views.filter { $0.id != id }
        for index in next.indices { next[index].sortOrder = index }
        try await persistence.save(next)
        views = next
    }

    private static func nameKey(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private static func order(_ lhs: UserSmartView, _ rhs: UserSmartView) -> Bool {
        if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
        if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
        return lhs.createdAt < rhs.createdAt
    }
}

public enum BulkLibraryItemOrigin: Equatable, Sendable {
    case history
    case saved
    case privateSession
    case vault
}

public struct BulkLibrarySelection: Equatable, Sendable {
    public let id: UUID
    public let origin: BulkLibraryItemOrigin

    public init(id: UUID, origin: BulkLibraryItemOrigin) {
        self.id = id
        self.origin = origin
    }
}

public enum BulkLibraryOperation: Equatable, Sendable {
    case saveHistory(folderID: UUID?)
    case moveSaved(folderID: UUID?)
    case addTags([String])
    case setPinned(Bool)
}

public enum BulkLibraryFailureReason: String, Equatable, Sendable {
    case notFound
    case immutableHistory
    case alreadySaved
    case privateSession
    case vault
    case sensitive
    case permissionDenied
    case crossSpaceMove
}

public struct BulkLibraryFailure: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let reason: BulkLibraryFailureReason
    public init(id: UUID, reason: BulkLibraryFailureReason) {
        self.id = id
        self.reason = reason
    }
}

public struct BulkSavedClipExpectation: Equatable, Sendable {
    public let id: UUID
    public let modifiedAt: Date
    public let folderID: UUID?
    public let tags: [String]
    public let pinnedAt: Date?
    public let contentFingerprint: String
}

public struct BulkHistoryExpectation: Equatable, Sendable {
    public let id: UUID
    public let modifiedAt: Date
    public let contentFingerprint: String
}

public struct BulkLibraryMutationPlan: Equatable, Sendable {
    public let operation: BulkLibraryOperation
    public let saved: [BulkSavedClipExpectation]
    public let history: [BulkHistoryExpectation]
    public let failures: [BulkLibraryFailure]

    public var eligibleCount: Int { saved.count + history.count }
}

public enum BulkLibraryMutationError: Error, LocalizedError, Equatable, Sendable {
    case emptySelection
    case authorizationChanged
    case sourceChanged(UUID)

    public var errorDescription: String? {
        switch self {
        case .emptySelection: "Select at least one eligible item."
        case .authorizationChanged: "Folder access changed before the bulk update could be committed."
        case let .sourceChanged(id): "Item \(id) changed after bulk review. Review the selection again."
        }
    }
}

public enum BulkLibraryMutationPlanner {
    public static func plan(
        selections: [BulkLibrarySelection],
        snapshot: ClipboardLibrarySnapshot,
        operation: BulkLibraryOperation,
        forbiddenSavedIDs: Set<UUID> = [],
        crossSpaceSavedIDs: Set<UUID> = [],
        detectedSensitiveIDs: Set<UUID> = []
    ) throws -> BulkLibraryMutationPlan {
        var seen = Set<UUID>()
        var savedExpectations: [BulkSavedClipExpectation] = []
        var historyExpectations: [BulkHistoryExpectation] = []
        var failures: [BulkLibraryFailure] = []
        let savedByID = Dictionary(uniqueKeysWithValues: snapshot.savedClips.map { ($0.id, $0) })
        let historyByID = Dictionary(uniqueKeysWithValues: snapshot.history.map { ($0.id, $0) })

        for selection in selections where seen.insert(selection.id).inserted {
            switch selection.origin {
            case .privateSession:
                failures.append(.init(id: selection.id, reason: .privateSession))
            case .vault:
                failures.append(.init(id: selection.id, reason: .vault))
            case .history:
                guard case .saveHistory = operation else {
                    failures.append(.init(id: selection.id, reason: .immutableHistory))
                    continue
                }
                guard let item = historyByID[selection.id] else {
                    failures.append(.init(id: selection.id, reason: .notFound))
                    continue
                }
                guard item.sensitivity == nil, !detectedSensitiveIDs.contains(item.id) else {
                    failures.append(.init(id: selection.id, reason: .sensitive))
                    continue
                }
                historyExpectations.append(.init(
                    id: item.id,
                    modifiedAt: item.modifiedAt,
                    contentFingerprint: item.content.deduplicationFingerprint
                ))
            case .saved:
                guard case .saveHistory = operation else {
                    guard let item = savedByID[selection.id] else {
                        failures.append(.init(id: selection.id, reason: .notFound))
                        continue
                    }
                    if forbiddenSavedIDs.contains(item.id) {
                        failures.append(.init(id: item.id, reason: .permissionDenied))
                    } else if crossSpaceSavedIDs.contains(item.id) {
                        failures.append(.init(id: item.id, reason: .crossSpaceMove))
                    } else if item.sensitivity != nil || detectedSensitiveIDs.contains(item.id) {
                        failures.append(.init(id: item.id, reason: .sensitive))
                    } else {
                        savedExpectations.append(.init(
                            id: item.id,
                            modifiedAt: item.modifiedAt,
                            folderID: item.folderID,
                            tags: item.tags ?? [],
                            pinnedAt: item.pinnedAt,
                            contentFingerprint: item.content.deduplicationFingerprint
                        ))
                    }
                    continue
                }
                failures.append(.init(id: selection.id, reason: .alreadySaved))
            }
        }
        guard !savedExpectations.isEmpty || !historyExpectations.isEmpty else {
            if selections.isEmpty { throw BulkLibraryMutationError.emptySelection }
            return BulkLibraryMutationPlan(
                operation: operation,
                saved: [],
                history: [],
                failures: failures
            )
        }
        return BulkLibraryMutationPlan(
            operation: operation,
            saved: savedExpectations,
            history: historyExpectations,
            failures: failures
        )
    }
}
