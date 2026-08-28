import Foundation
import SQLite3

public enum SQLiteClipboardLibraryError: Error, LocalizedError, Sendable {
    case openFailed(String)
    case schemaFailed(String)
    case statementFailed(String)
    case transactionFailed(String)
    case corruptObject(String)
    case migrationVerificationFailed

    public var errorDescription: String? {
        switch self {
        case let .openFailed(reason): "Could not open the clipboard database: \(reason)"
        case let .schemaFailed(reason): "Could not prepare the clipboard database: \(reason)"
        case let .statementFailed(reason): "Clipboard database operation failed: \(reason)"
        case let .transactionFailed(reason): "Clipboard database transaction failed: \(reason)"
        case let .corruptObject(identifier): "Clipboard database object \(identifier) is corrupt."
        case .migrationVerificationFailed: "The legacy clipboard migration could not be verified."
        }
    }
}

/// Transactional SQLite source of truth with a same-transaction FTS5 index. A legacy JSON file is
/// imported once, verified, and renamed to a retained backup. Vault data is a separate store.
public actor SQLiteFileClipboardLibraryStore:
    ClipboardLibrarySearchPersisting,
    ClipboardLibrarySensitiveDeletionFlushing
{
    public let fileURL: URL
    public let legacyJSONURL: URL?

    private final class DatabaseHandle: @unchecked Sendable {
        let pointer: OpaquePointer

        init(_ pointer: OpaquePointer) {
            self.pointer = pointer
        }

        deinit { sqlite3_close(pointer) }
    }

    private var databaseHandle: DatabaseHandle?
    private var database: OpaquePointer? { databaseHandle?.pointer }
    private var cachedSnapshot: ClipboardLibrarySnapshot?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let legacyContentAdmission: @Sendable (ClipContent) -> Bool

    private enum ObjectKind: Int32 {
        case history = 1
        case savedClip = 2
        case folder = 3
    }

    private struct SearchDocument: Equatable {
        let id: String
        let kind: Int64
        let name: String
        let body: String
        let metadata: String
        let sizeByteCount: Int64
        let captureCount: Int64
        let pasteCount: Int64
        let isPinned: Int64

        var key: String { "\(kind):\(id)" }
    }

    public init(
        fileURL: URL,
        legacyJSONURL: URL? = nil,
        legacyContentAdmission: @escaping @Sendable (ClipContent) -> Bool = { _ in true }
    ) {
        self.fileURL = fileURL.standardizedFileURL
        self.legacyJSONURL = legacyJSONURL?.standardizedFileURL
        self.legacyContentAdmission = legacyContentAdmission
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .deferredToDate
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        self.decoder = decoder
    }

    public func load() async throws -> ClipboardLibrarySnapshot {
        try openIfNeeded()
        if try objectCount() == 0,
           try metadataData(for: "settings") == nil,
           let legacyJSONURL,
           FileManager.default.fileExists(atPath: legacyJSONURL.path)
        {
            try importLegacyJSON(at: legacyJSONURL)
        }
        var snapshot = try readSnapshot()
        if (1...2).contains(snapshot.schemaVersion) {
            let legacy = snapshot
            snapshot.schemaVersion = ClipboardLibrarySnapshot.currentSchemaVersion
            // Persist the metadata upgrade before exposing schema v3. Entity payloads are decoded
            // with safe defaults and will be rewritten only when they next change.
            try persist(snapshot, previous: legacy)
        }
        try repairSearchIndexIfNeeded(for: snapshot)
        cachedSnapshot = snapshot
        return snapshot
    }

    public func save(_ snapshot: ClipboardLibrarySnapshot) async throws {
        try openIfNeeded()
        let previous: ClipboardLibrarySnapshot
        if let cachedSnapshot {
            previous = cachedSnapshot
        } else {
            previous = try readSnapshot()
            try repairSearchIndexIfNeeded(for: previous)
        }
        try persist(snapshot, previous: previous)
        cachedSnapshot = snapshot
    }

    public func flushSensitiveDeletions() async throws {
        try openIfNeeded()
        guard let database else { throw SQLiteClipboardLibraryError.openFailed("not open") }
        var logFrames: Int32 = -1
        var checkpointedFrames: Int32 = -1
        let result = sqlite3_wal_checkpoint_v2(
            database,
            nil,
            SQLITE_CHECKPOINT_TRUNCATE,
            &logFrames,
            &checkpointedFrames
        )
        guard result == SQLITE_OK, logFrames == 0, checkpointedFrames == 0 else {
            throw SQLiteClipboardLibraryError.transactionFailed(
                "Sensitive deletion WAL checkpoint did not truncate (result \(result), log \(logFrames), checkpointed \(checkpointedFrames))."
            )
        }
    }

    public func search(query: String, limit: Int) async -> [ClipSearchResult] {
        guard limit > 0 else { return [] }
        do {
            try openIfNeeded()
            let parsed = ClipSearchIndex.parse(query: query)
            guard !parsed.isInvalid else { return [] }
            guard !parsed.isEmpty else {
                let snapshot: ClipboardLibrarySnapshot
                if let cachedSnapshot {
                    snapshot = cachedSnapshot
                } else {
                    snapshot = try readSnapshot()
                    try repairSearchIndexIfNeeded(for: snapshot)
                    cachedSnapshot = snapshot
                }
                let allResults = Self.searchResults(from: snapshot)
                return Array(allResults.sorted(by: ClipSearchIndex.resultOrder).prefix(limit))
            }
            guard let database else { return [] }

            let expression = ClipSearchIndex.ftsMatchExpression(for: parsed)
            var clauses: [String] = []
            var textBindings: [String] = []
            var integerBindings: [Int64] = []
            func appendNumeric(
                _ column: String,
                _ predicates: [ClipSearchIndex.NumericPredicate]
            ) {
                for predicate in predicates {
                    clauses.append("facets.\(column) \(predicate.sqlOperator) ?")
                    integerBindings.append(Int64(predicate.value))
                }
            }
            appendNumeric("size_bytes", parsed.sizes)
            appendNumeric("capture_count", parsed.captures)
            appendNumeric("paste_count", parsed.pastes)
            for value in parsed.pinned {
                clauses.append("facets.is_pinned = ?")
                integerBindings.append(value ? 1 : 0)
            }
            let metadataGroups = ClipSearchIndex.metadataCandidateGroups(for: parsed)
            for group in metadataGroups {
                clauses.append(
                    "(" + group.map { _ in "instr(clip_search.metadata, ?) > 0" }
                        .joined(separator: " OR ") + ")"
                )
                textBindings.append(contentsOf: group)
            }
            if expression != nil { clauses.insert("clip_search MATCH ?", at: 0) }
            let selector: String
            if expression != nil || !metadataGroups.isEmpty {
                selector = "SELECT facets.id, facets.kind FROM clip_search "
                    + "JOIN clip_search_facets AS facets "
                    + "ON facets.id = clip_search.id AND facets.kind = clip_search.kind"
            } else {
                selector = "SELECT facets.id, facets.kind FROM clip_search_facets AS facets"
            }
            let sql = selector + (clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND "))

            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                database,
                sql,
                -1,
                &statement,
                nil
            ) == SQLITE_OK, let statement else { return [] }
            defer { sqlite3_finalize(statement) }
            var bindingIndex: Int32 = 1
            if let expression {
                Self.bindText(expression, to: statement, index: bindingIndex)
                bindingIndex += 1
            }
            for value in integerBindings {
                sqlite3_bind_int64(statement, bindingIndex, value)
                bindingIndex += 1
            }
            for value in textBindings {
                Self.bindText(value, to: statement, index: bindingIndex)
                bindingIndex += 1
            }
            var candidateKeys: [(id: UUID, kind: ObjectKind)] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let idText = sqlite3_column_text(statement, 0),
                      let id = UUID(uuidString: String(cString: idText))
                else { continue }
                let storedKind = sqlite3_column_int64(statement, 1)
                let kind: ObjectKind
                if storedKind == Int64(ObjectKind.history.rawValue) {
                    kind = .history
                } else if storedKind == Int64(ObjectKind.savedClip.rawValue) {
                    kind = .savedClip
                } else {
                    continue
                }
                candidateKeys.append((id, kind))
            }
            // The FTS table is the candidate selector. Decode only those object payloads instead
            // of projecting every cached history/saved row into a search result for each keystroke.
            let candidates = try readSearchResults(for: candidateKeys)
            return candidates
                .compactMap { result -> (ClipSearchResult, Int)? in
                    let projection = ClipSearchIndex.projection(for: result)
                    let name = projection.normalizedName
                    let content = projection.normalizedContent
                    let metadata = projection.normalizedMetadata
                    guard ClipSearchIndex.matches(
                        parsed,
                        result: result,
                        normalizedName: name,
                        normalizedContent: content,
                        normalizedMetadata: metadata
                    ) else { return nil }
                    let score = ClipSearchIndex.score(
                        parsed,
                        normalizedName: name,
                        normalizedContent: content,
                        normalizedMetadata: metadata
                    )
                    return (result, score)
                }
                .sorted {
                    if $0.1 != $1.1 { return $0.1 > $1.1 }
                    return ClipSearchIndex.resultOrder($0.0, $1.0)
                }
                .prefix(limit)
                .map(\.0)
        } catch {
            return []
        }
    }

    private func openIfNeeded() throws {
        guard database == nil else { return }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var handle: OpaquePointer?
        guard sqlite3_open_v2(
            fileURL.path,
            &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let handle else {
            let reason = handle.map(Self.errorMessage) ?? "unknown SQLite error"
            if let handle { sqlite3_close(handle) }
            throw SQLiteClipboardLibraryError.openFailed(reason)
        }
        databaseHandle = DatabaseHandle(handle)
        let schema = """
        PRAGMA journal_mode=WAL;
        PRAGMA synchronous=FULL;
        PRAGMA foreign_keys=ON;
        PRAGMA secure_delete=ON;
        CREATE TABLE IF NOT EXISTS metadata (
            key TEXT PRIMARY KEY NOT NULL,
            value BLOB NOT NULL
        );
        CREATE TABLE IF NOT EXISTS objects (
            kind INTEGER NOT NULL,
            id TEXT NOT NULL,
            payload BLOB NOT NULL,
            PRIMARY KEY(kind, id)
        );
        CREATE VIRTUAL TABLE IF NOT EXISTS clip_search USING fts5(
            id UNINDEXED,
            kind UNINDEXED,
            name,
            body,
            metadata,
            tokenize='unicode61 remove_diacritics 2'
        );
        CREATE TABLE IF NOT EXISTS clip_search_facets (
            id TEXT NOT NULL,
            kind INTEGER NOT NULL,
            size_bytes INTEGER NOT NULL,
            capture_count INTEGER NOT NULL,
            paste_count INTEGER NOT NULL,
            is_pinned INTEGER NOT NULL CHECK(is_pinned IN (0, 1)),
            PRIMARY KEY(kind, id)
        );
        CREATE INDEX IF NOT EXISTS clip_search_facets_size ON clip_search_facets(size_bytes);
        CREATE INDEX IF NOT EXISTS clip_search_facets_captures ON clip_search_facets(capture_count);
        CREATE INDEX IF NOT EXISTS clip_search_facets_pastes ON clip_search_facets(paste_count);
        CREATE INDEX IF NOT EXISTS clip_search_facets_pinned ON clip_search_facets(is_pinned);
        """
        guard sqlite3_exec(handle, schema, nil, nil, nil) == SQLITE_OK else {
            let reason = Self.errorMessage(handle)
            databaseHandle = nil
            throw SQLiteClipboardLibraryError.schemaFailed(reason)
        }
    }

    private func importLegacyJSON(at url: URL) throws {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw ClipboardLibraryPersistenceError.unreadableFile(url, String(describing: error))
        }
        let decoded: ClipboardLibrarySnapshot
        do {
            decoded = try decoder.decode(ClipboardLibrarySnapshot.self, from: data)
        } catch {
            throw ClipboardLibraryPersistenceError.undecodableFile(url, String(describing: error))
        }
        var admitted = decoded
        admitted.history.removeAll { !legacyContentAdmission($0.content) }
        admitted.savedClips.removeAll { !legacyContentAdmission($0.content) }
        let admittedSavedIDs = Set(admitted.savedClips.map(\.id))
        admitted.pendingSavedLibraryMutations.removeAll {
            $0.kind == .savedClip && !admittedSavedIDs.contains($0.id)
        }
        let empty = ClipboardLibrarySnapshot()
        try persist(admitted, previous: empty)
        let verified = try readSnapshot()
        guard Self.migrationSnapshotsAreSemanticallyEquivalent(verified, admitted) else {
            throw SQLiteClipboardLibraryError.migrationVerificationFailed
        }
        cachedSnapshot = admitted

        let backup = url.deletingLastPathComponent().appendingPathComponent("library.v1.migrated.json")
        if !FileManager.default.fileExists(atPath: backup.path) {
            try FileManager.default.moveItem(at: url, to: backup)
        }
    }

    /// SQLite object rows are keyed entities, not ordered array elements. Verify that migration
    /// preserved every entity and its value without requiring the query planner to return rows in
    /// the legacy JSON array order. Product ordering is normalized by `ClipboardLibrary` after the
    /// store loads (history by recency and folders by `sortOrder`).
    private static func migrationSnapshotsAreSemanticallyEquivalent(
        _ lhs: ClipboardLibrarySnapshot,
        _ rhs: ClipboardLibrarySnapshot
    ) -> Bool {
        guard lhs.schemaVersion == rhs.schemaVersion,
              lhs.settings == rhs.settings,
              let lhsHistory = uniquelyKeyed(lhs.history, id: \HistoryItem.id),
              let rhsHistory = uniquelyKeyed(rhs.history, id: \HistoryItem.id),
              lhsHistory == rhsHistory,
              let lhsSaved = uniquelyKeyed(lhs.savedClips, id: \SavedClip.id),
              let rhsSaved = uniquelyKeyed(rhs.savedClips, id: \SavedClip.id),
              lhsSaved == rhsSaved,
              let lhsFolders = uniquelyKeyed(lhs.folders, id: \ClipFolder.id),
              let rhsFolders = uniquelyKeyed(rhs.folders, id: \ClipFolder.id),
              lhsFolders == rhsFolders,
              let lhsPending = uniquelyKeyedPendingMutations(lhs.pendingSavedLibraryMutations),
              let rhsPending = uniquelyKeyedPendingMutations(rhs.pendingSavedLibraryMutations),
              lhsPending == rhsPending
        else { return false }
        return true
    }

    private static func uniquelyKeyed<Value: Equatable>(
        _ values: [Value],
        id: KeyPath<Value, UUID>
    ) -> [UUID: Value]? {
        var result: [UUID: Value] = [:]
        for value in values {
            guard result.updateValue(value, forKey: value[keyPath: id]) == nil else {
                return nil
            }
        }
        return result
    }

    private static func uniquelyKeyedPendingMutations(
        _ mutations: [PendingSavedLibraryMutation]
    ) -> [String: PendingSavedLibraryMutation]? {
        var result: [String: PendingSavedLibraryMutation] = [:]
        for mutation in mutations {
            let key = "\(mutation.kind.rawValue):\(mutation.id.uuidString.lowercased())"
            guard result.updateValue(mutation, forKey: key) == nil else { return nil }
        }
        return result
    }

    private func persist(
        _ snapshot: ClipboardLibrarySnapshot,
        previous: ClipboardLibrarySnapshot
    ) throws {
        guard let database else { throw SQLiteClipboardLibraryError.openFailed("not open") }
        guard sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
            throw SQLiteClipboardLibraryError.transactionFailed(Self.errorMessage(database))
        }
        do {
            try applyHistoryChanges(from: previous.history, to: snapshot.history)
            try applySavedChanges(
                from: previous.savedClips,
                to: snapshot.savedClips,
                folders: snapshot.folders,
                history: snapshot.history
            )
            try applyFolderChanges(from: previous.folders, to: snapshot.folders)
            try reindexSavedClipsAffectedByFolderChanges(from: previous, to: snapshot)
            try reindexSavedClipsAffectedByHistoryUsageChanges(from: previous, to: snapshot)
            try upsertMetadata(key: "schemaVersion", data: try encoder.encode(snapshot.schemaVersion))
            try upsertMetadata(key: "settings", data: try encoder.encode(snapshot.settings))
            try upsertMetadata(
                key: "pendingSavedLibraryMutations",
                data: try encoder.encode(snapshot.pendingSavedLibraryMutations)
            )
            guard sqlite3_exec(database, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                throw SQLiteClipboardLibraryError.transactionFailed(Self.errorMessage(database))
            }
        } catch {
            sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    private func applyHistoryChanges(from old: [HistoryItem], to new: [HistoryItem]) throws {
        let oldByID = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
        let newByID = Dictionary(uniqueKeysWithValues: new.map { ($0.id, $0) })
        for id in oldByID.keys where newByID[id] == nil {
            try deleteObject(kind: .history, id: id)
        }
        for item in new where oldByID[item.id] != item {
            try upsertObject(kind: .history, id: item.id, payload: try encoder.encode(item))
            try replaceSearchDocument(for: item)
        }
    }

    private func applySavedChanges(
        from old: [SavedClip],
        to new: [SavedClip],
        folders: [ClipFolder],
        history: [HistoryItem]
    ) throws {
        let oldByID = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
        let newByID = Dictionary(uniqueKeysWithValues: new.map { ($0.id, $0) })
        let foldersByID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0.name) })
        let folderPathsByID = ClipSearchIndex.folderPaths(in: folders)
        let historyByID = Dictionary(uniqueKeysWithValues: history.map { ($0.id, $0) })
        for id in oldByID.keys where newByID[id] == nil {
            try deleteObject(kind: .savedClip, id: id)
        }
        for item in new where oldByID[item.id] != item {
            try upsertObject(kind: .savedClip, id: item.id, payload: try encoder.encode(item))
            try replaceSearchDocument(
                for: item,
                folderName: item.folderID.flatMap { foldersByID[$0] },
                folderPath: item.folderID.flatMap { folderPathsByID[$0] },
                sourceHistoryItem: item.sourceHistoryItemID.flatMap { historyByID[$0] }
            )
        }
    }

    private func reindexSavedClipsAffectedByFolderChanges(
        from old: ClipboardLibrarySnapshot,
        to new: ClipboardLibrarySnapshot
    ) throws {
        let oldFolders = Dictionary(uniqueKeysWithValues: old.folders.map { ($0.id, $0.name) })
        let newFolders = Dictionary(uniqueKeysWithValues: new.folders.map { ($0.id, $0.name) })
        let oldPaths = ClipSearchIndex.folderPaths(in: old.folders)
        let newPaths = ClipSearchIndex.folderPaths(in: new.folders)
        let changedClipIDs = Set(new.savedClips.compactMap { clip -> UUID? in
            guard let folderID = clip.folderID,
                  oldFolders[folderID] != newFolders[folderID]
                    || oldPaths[folderID] != newPaths[folderID]
            else { return nil }
            return clip.id
        })
        let oldClips = Dictionary(uniqueKeysWithValues: old.savedClips.map { ($0.id, $0) })
        for clip in new.savedClips where changedClipIDs.contains(clip.id) && oldClips[clip.id] == clip {
            let newHistory = Dictionary(uniqueKeysWithValues: new.history.map { ($0.id, $0) })
            try replaceSearchDocument(
                for: clip,
                folderName: clip.folderID.flatMap { newFolders[$0] },
                folderPath: clip.folderID.flatMap { newPaths[$0] },
                sourceHistoryItem: clip.sourceHistoryItemID.flatMap { newHistory[$0] }
            )
        }
    }

    private func reindexSavedClipsAffectedByHistoryUsageChanges(
        from old: ClipboardLibrarySnapshot,
        to new: ClipboardLibrarySnapshot
    ) throws {
        let oldHistory = Dictionary(uniqueKeysWithValues: old.history.map { ($0.id, $0) })
        let newHistory = Dictionary(uniqueKeysWithValues: new.history.map { ($0.id, $0) })
        let folders = Dictionary(uniqueKeysWithValues: new.folders.map { ($0.id, $0.name) })
        let folderPaths = ClipSearchIndex.folderPaths(in: new.folders)
        let oldClips = Dictionary(uniqueKeysWithValues: old.savedClips.map { ($0.id, $0) })
        for clip in new.savedClips {
            guard let sourceID = clip.sourceHistoryItemID,
                  oldHistory[sourceID] != newHistory[sourceID],
                  oldClips[clip.id] == clip
            else { continue }
            try replaceSearchDocument(
                for: clip,
                folderName: clip.folderID.flatMap { folders[$0] },
                folderPath: clip.folderID.flatMap { folderPaths[$0] },
                sourceHistoryItem: newHistory[sourceID]
            )
        }
    }

    private func applyFolderChanges(from old: [ClipFolder], to new: [ClipFolder]) throws {
        let oldByID = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
        let newByID = Dictionary(uniqueKeysWithValues: new.map { ($0.id, $0) })
        for id in oldByID.keys where newByID[id] == nil {
            try deleteObject(kind: .folder, id: id)
        }
        for item in new where oldByID[item.id] != item {
            try upsertObject(kind: .folder, id: item.id, payload: try encoder.encode(item))
        }
    }

    private func deleteObject(kind: ObjectKind, id: UUID) throws {
        try execute(
            "DELETE FROM objects WHERE kind = ? AND id = ?",
            bindings: [.integer(Int64(kind.rawValue)), .text(id.uuidString.lowercased())]
        )
        if kind != .folder {
            try execute(
                "DELETE FROM clip_search WHERE id = ? AND kind = ?",
                bindings: [.text(id.uuidString.lowercased()), .integer(Int64(kind.rawValue))]
            )
            try execute(
                "DELETE FROM clip_search_facets WHERE id = ? AND kind = ?",
                bindings: [.text(id.uuidString.lowercased()), .integer(Int64(kind.rawValue))]
            )
        }
    }

    private func upsertObject(kind: ObjectKind, id: UUID, payload: Data) throws {
        try execute(
            "INSERT INTO objects(kind, id, payload) VALUES (?, ?, ?) "
                + "ON CONFLICT(kind, id) DO UPDATE SET payload = excluded.payload",
            bindings: [
                .integer(Int64(kind.rawValue)),
                .text(id.uuidString.lowercased()),
                .blob(payload),
            ]
        )
    }

    private func replaceSearchDocument(for item: HistoryItem) throws {
        try replaceSearchDocument(Self.searchDocument(for: item))
    }

    private func replaceSearchDocument(
        for item: SavedClip,
        folderName: String?,
        folderPath: String? = nil,
        sourceHistoryItem: HistoryItem?
    ) throws {
        try replaceSearchDocument(Self.searchDocument(
            for: item,
            folderName: folderName,
            folderPath: folderPath,
            sourceHistoryItem: sourceHistoryItem
        ))
    }

    private func replaceSearchDocument(_ document: SearchDocument) throws {
        try execute(
            "DELETE FROM clip_search WHERE id = ? AND kind = ?",
            bindings: [.text(document.id), .integer(document.kind)]
        )
        try execute(
            "DELETE FROM clip_search_facets WHERE id = ? AND kind = ?",
            bindings: [.text(document.id), .integer(document.kind)]
        )
        try insertSearchDocument(document)
    }

    private func insertSearchDocument(_ document: SearchDocument) throws {
        try execute(
            "INSERT INTO clip_search(id, kind, name, body, metadata) VALUES (?, ?, ?, ?, ?)",
            bindings: [
                .text(document.id),
                .integer(document.kind),
                .text(document.name),
                .text(document.body),
                .text(document.metadata),
            ]
        )
        try execute(
            "INSERT INTO clip_search_facets(id, kind, size_bytes, capture_count, paste_count, is_pinned) "
                + "VALUES (?, ?, ?, ?, ?, ?)",
            bindings: [
                .text(document.id),
                .integer(document.kind),
                .integer(document.sizeByteCount),
                .integer(document.captureCount),
                .integer(document.pasteCount),
                .integer(document.isPinned),
            ]
        )
    }

    private static func searchDocument(for item: HistoryItem) -> SearchDocument {
        searchDocument(from: ClipSearchIndex.projection(for: item), kind: .history)
    }

    private static func searchDocument(
        for item: SavedClip,
        folderName: String?,
        folderPath: String? = nil,
        sourceHistoryItem: HistoryItem?
    ) -> SearchDocument {
        searchDocument(
            from: ClipSearchIndex.projection(
                for: item,
                folderName: folderName,
                folderPath: folderPath,
                sourceHistoryItem: sourceHistoryItem
            ),
            kind: .savedClip
        )
    }

    private static func searchDocument(
        from projection: ClipSearchIndex.Projection,
        kind: ObjectKind
    ) -> SearchDocument {
        let result = projection.result
        return SearchDocument(
            id: result.id.uuidString.lowercased(),
            kind: Int64(kind.rawValue),
            name: projection.name,
            body: projection.body,
            metadata: projection.normalizedMetadata,
            sizeByteCount: Int64(result.sizeByteCount),
            captureCount: Int64(result.captureCount),
            pasteCount: Int64(result.pasteCount),
            isPinned: result.isPinned ? 1 : 0
        )
    }

    /// FTS is derived data. Validate values, row cardinality, and table type on every open so an
    /// interrupted migration or an externally damaged/removed index cannot make clips disappear.
    private func repairSearchIndexIfNeeded(for snapshot: ClipboardLibrarySnapshot) throws {
        let foldersByID = Dictionary(uniqueKeysWithValues: snapshot.folders.map { ($0.id, $0.name) })
        let folderPathsByID = ClipSearchIndex.folderPaths(in: snapshot.folders)
        let historyByID = Dictionary(uniqueKeysWithValues: snapshot.history.map { ($0.id, $0) })
        let expected = Self.sortedSearchDocuments(
            snapshot.history.map(Self.searchDocument(for:))
                + snapshot.savedClips.map {
                    Self.searchDocument(
                        for: $0,
                        folderName: $0.folderID.flatMap { foldersByID[$0] },
                        folderPath: $0.folderID.flatMap { folderPathsByID[$0] },
                        sourceHistoryItem: $0.sourceHistoryItemID.flatMap { historyByID[$0] }
                    )
                }
        )

        do {
            try validateSearchTableType()
            if Self.sortedSearchDocuments(try readSearchDocuments()) == expected {
                return
            }
        } catch {
            try recreateSearchTable()
        }

        try rebuildSearchIndex(with: expected)
    }

    private func validateSearchTableType() throws {
        guard let database else { throw SQLiteClipboardLibraryError.openFailed("not open") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'clip_search'",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            throw SQLiteClipboardLibraryError.statementFailed(Self.errorMessage(database))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let sqlText = sqlite3_column_text(statement, 0),
              String(cString: sqlText).lowercased().contains("using fts5")
        else {
            throw SQLiteClipboardLibraryError.schemaFailed("clip_search is not an FTS5 table")
        }
    }

    private func readSearchDocuments() throws -> [SearchDocument] {
        guard let database else { throw SQLiteClipboardLibraryError.openFailed("not open") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT clip_search.id, clip_search.kind, name, body, metadata, "
                + "size_bytes, capture_count, paste_count, is_pinned FROM clip_search "
                + "JOIN clip_search_facets ON clip_search_facets.id = clip_search.id "
                + "AND clip_search_facets.kind = clip_search.kind",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            throw SQLiteClipboardLibraryError.statementFailed(Self.errorMessage(database))
        }
        defer { sqlite3_finalize(statement) }

        var documents: [SearchDocument] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            documents.append(
                SearchDocument(
                    id: Self.columnText(statement, index: 0),
                    kind: sqlite3_column_int64(statement, 1),
                    name: Self.columnText(statement, index: 2),
                    body: Self.columnText(statement, index: 3),
                    metadata: Self.columnText(statement, index: 4),
                    sizeByteCount: sqlite3_column_int64(statement, 5),
                    captureCount: sqlite3_column_int64(statement, 6),
                    pasteCount: sqlite3_column_int64(statement, 7),
                    isPinned: sqlite3_column_int64(statement, 8)
                )
            )
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else {
            throw SQLiteClipboardLibraryError.statementFailed(Self.errorMessage(database))
        }
        return documents
    }

    private func rebuildSearchIndex(with documents: [SearchDocument]) throws {
        guard let database else { throw SQLiteClipboardLibraryError.openFailed("not open") }
        guard sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
            throw SQLiteClipboardLibraryError.transactionFailed(Self.errorMessage(database))
        }
        do {
            try execute("DELETE FROM clip_search", bindings: [])
            try execute("DELETE FROM clip_search_facets", bindings: [])
            for document in documents {
                try insertSearchDocument(document)
            }
            guard sqlite3_exec(database, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                throw SQLiteClipboardLibraryError.transactionFailed(Self.errorMessage(database))
            }
        } catch {
            sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    private func recreateSearchTable() throws {
        guard let database else { throw SQLiteClipboardLibraryError.openFailed("not open") }
        let sql = """
        DROP TABLE IF EXISTS clip_search;
        CREATE VIRTUAL TABLE clip_search USING fts5(
            id UNINDEXED,
            kind UNINDEXED,
            name,
            body,
            metadata,
            tokenize='unicode61 remove_diacritics 2'
        );
        DROP TABLE IF EXISTS clip_search_facets;
        CREATE TABLE clip_search_facets (
            id TEXT NOT NULL,
            kind INTEGER NOT NULL,
            size_bytes INTEGER NOT NULL,
            capture_count INTEGER NOT NULL,
            paste_count INTEGER NOT NULL,
            is_pinned INTEGER NOT NULL CHECK(is_pinned IN (0, 1)),
            PRIMARY KEY(kind, id)
        );
        CREATE INDEX clip_search_facets_size ON clip_search_facets(size_bytes);
        CREATE INDEX clip_search_facets_captures ON clip_search_facets(capture_count);
        CREATE INDEX clip_search_facets_pastes ON clip_search_facets(paste_count);
        CREATE INDEX clip_search_facets_pinned ON clip_search_facets(is_pinned);
        """
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteClipboardLibraryError.schemaFailed(Self.errorMessage(database))
        }
    }

    private static func sortedSearchDocuments(_ documents: [SearchDocument]) -> [SearchDocument] {
        documents.sorted {
            if $0.key != $1.key { return $0.key < $1.key }
            if $0.name != $1.name { return $0.name < $1.name }
            if $0.body != $1.body { return $0.body < $1.body }
            if $0.metadata != $1.metadata { return $0.metadata < $1.metadata }
            if $0.sizeByteCount != $1.sizeByteCount { return $0.sizeByteCount < $1.sizeByteCount }
            if $0.captureCount != $1.captureCount { return $0.captureCount < $1.captureCount }
            if $0.pasteCount != $1.pasteCount { return $0.pasteCount < $1.pasteCount }
            return $0.isPinned < $1.isPinned
        }
    }

    private static func columnText(_ statement: OpaquePointer, index: Int32) -> String {
        sqlite3_column_text(statement, index).map { String(cString: $0) } ?? ""
    }

    private func readSnapshot() throws -> ClipboardLibrarySnapshot {
        guard let database else { throw SQLiteClipboardLibraryError.openFailed("not open") }
        let history: [HistoryItem] = try readObjects(kind: .history)
        let saved: [SavedClip] = try readObjects(kind: .savedClip)
        let folders: [ClipFolder] = try readObjects(kind: .folder)
        let settings = try metadataData(for: "settings").map {
            try decoder.decode(ClipboardLibrarySettings.self, from: $0)
        } ?? ClipboardLibrarySettings()
        let pending = try metadataData(for: "pendingSavedLibraryMutations").map {
            try decoder.decode([PendingSavedLibraryMutation].self, from: $0)
        } ?? []
        let version = try metadataData(for: "schemaVersion").map {
            try decoder.decode(Int.self, from: $0)
        } ?? ClipboardLibrarySnapshot.currentSchemaVersion
        _ = database
        return ClipboardLibrarySnapshot(
            schemaVersion: version,
            history: history,
            savedClips: saved,
            folders: folders,
            settings: settings,
            pendingSavedLibraryMutations: pending
        )
    }

    private func readObjects<T: Decodable>(kind: ObjectKind) throws -> [T] {
        guard let database else { throw SQLiteClipboardLibraryError.openFailed("not open") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT id, payload FROM objects WHERE kind = ?",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            throw SQLiteClipboardLibraryError.statementFailed(Self.errorMessage(database))
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(kind.rawValue))
        var values: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? "unknown"
            guard let bytes = sqlite3_column_blob(statement, 1) else {
                throw SQLiteClipboardLibraryError.corruptObject(id)
            }
            let count = Int(sqlite3_column_bytes(statement, 1))
            let data = Data(bytes: bytes, count: count)
            do {
                values.append(try decoder.decode(T.self, from: data))
            } catch {
                throw SQLiteClipboardLibraryError.corruptObject(id)
            }
        }
        return values
    }

    private func upsertMetadata(key: String, data: Data) throws {
        try execute(
            "INSERT INTO metadata(key, value) VALUES (?, ?) "
                + "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            bindings: [.text(key), .blob(data)]
        )
    }

    private func metadataData(for key: String) throws -> Data? {
        guard let database else { throw SQLiteClipboardLibraryError.openFailed("not open") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT value FROM metadata WHERE key = ?",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            throw SQLiteClipboardLibraryError.statementFailed(Self.errorMessage(database))
        }
        defer { sqlite3_finalize(statement) }
        Self.bindText(key, to: statement, index: 1)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let bytes = sqlite3_column_blob(statement, 0)
        else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
    }

    private func objectCount() throws -> Int {
        guard let database else { throw SQLiteClipboardLibraryError.openFailed("not open") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM objects", -1, &statement, nil) == SQLITE_OK,
              let statement
        else { throw SQLiteClipboardLibraryError.statementFailed(Self.errorMessage(database)) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private enum Binding {
        case integer(Int64)
        case text(String)
        case blob(Data)
    }

    private func execute(_ sql: String, bindings: [Binding]) throws {
        guard let database else { throw SQLiteClipboardLibraryError.openFailed("not open") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else { throw SQLiteClipboardLibraryError.statementFailed(Self.errorMessage(database)) }
        defer { sqlite3_finalize(statement) }
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            switch binding {
            case let .integer(value): sqlite3_bind_int64(statement, index, value)
            case let .text(value): Self.bindText(value, to: statement, index: index)
            case let .blob(value):
                _ = value.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(value.count), Self.sqliteTransient)
                }
            }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLiteClipboardLibraryError.statementFailed(Self.errorMessage(database))
        }
    }

    private static func bindText(_ value: String, to statement: OpaquePointer, index: Int32) {
        sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
    }

    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func errorMessage(_ database: OpaquePointer) -> String {
        sqlite3_errmsg(database).map { String(cString: $0) } ?? "unknown SQLite error"
    }

    private func readSearchResults(for keys: [(id: UUID, kind: ObjectKind)]) throws -> [ClipSearchResult] {
        guard let database else { throw SQLiteClipboardLibraryError.openFailed("not open") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT payload FROM objects WHERE id = ? AND kind = ?",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            throw SQLiteClipboardLibraryError.statementFailed(Self.errorMessage(database))
        }
        defer { sqlite3_finalize(statement) }

        let folders: [ClipFolder] = try readObjects(kind: .folder)
        let foldersByID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0.name) })
        let folderPathsByID = ClipSearchIndex.folderPaths(in: folders)
        var results: [ClipSearchResult] = []
        results.reserveCapacity(keys.count)
        for key in keys {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            Self.bindText(key.id.uuidString.lowercased(), to: statement, index: 1)
            sqlite3_bind_int64(statement, 2, Int64(key.kind.rawValue))
            guard sqlite3_step(statement) == SQLITE_ROW,
                  let bytes = sqlite3_column_blob(statement, 0)
            else { continue }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
            do {
                switch key.kind {
                case .history:
                    results.append(Self.searchResult(for: try decoder.decode(HistoryItem.self, from: data)))
                case .savedClip:
                    let clip = try decoder.decode(SavedClip.self, from: data)
                    results.append(Self.searchResult(
                        for: clip,
                        folderName: clip.folderID.flatMap { foldersByID[$0] },
                        folderPath: clip.folderID.flatMap { folderPathsByID[$0] },
                        sourceHistoryItem: try clip.sourceHistoryItemID.flatMap {
                            try readHistoryItem(id: $0)
                        }
                    ))
                case .folder:
                    continue
                }
            } catch {
                throw SQLiteClipboardLibraryError.corruptObject(key.id.uuidString.lowercased())
            }
        }
        return results
    }

    private func readHistoryItem(id: UUID) throws -> HistoryItem? {
        guard let database else { throw SQLiteClipboardLibraryError.openFailed("not open") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT payload FROM objects WHERE id = ? AND kind = ?",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            throw SQLiteClipboardLibraryError.statementFailed(Self.errorMessage(database))
        }
        defer { sqlite3_finalize(statement) }
        Self.bindText(id.uuidString.lowercased(), to: statement, index: 1)
        sqlite3_bind_int64(statement, 2, Int64(ObjectKind.history.rawValue))
        guard sqlite3_step(statement) == SQLITE_ROW,
              let bytes = sqlite3_column_blob(statement, 0)
        else { return nil }
        let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
        do {
            return try decoder.decode(HistoryItem.self, from: data)
        } catch {
            throw SQLiteClipboardLibraryError.corruptObject(id.uuidString.lowercased())
        }
    }

    private static func searchResult(for item: HistoryItem) -> ClipSearchResult {
        ClipSearchIndex.projection(for: item).result
    }

    private static func searchResult(
        for item: SavedClip,
        folderName: String?,
        folderPath: String? = nil,
        sourceHistoryItem: HistoryItem?
    ) -> ClipSearchResult {
        ClipSearchIndex.projection(
            for: item,
            folderName: folderName,
            folderPath: folderPath,
            sourceHistoryItem: sourceHistoryItem
        ).result
    }

    private static func searchResults(from snapshot: ClipboardLibrarySnapshot) -> [ClipSearchResult] {
        let history = snapshot.history.map(Self.searchResult(for:))
        let foldersByID = Dictionary(uniqueKeysWithValues: snapshot.folders.map { ($0.id, $0.name) })
        let folderPathsByID = ClipSearchIndex.folderPaths(in: snapshot.folders)
        let historyByID = Dictionary(uniqueKeysWithValues: snapshot.history.map { ($0.id, $0) })
        let saved = snapshot.savedClips.map {
            Self.searchResult(
                for: $0,
                folderName: $0.folderID.flatMap { foldersByID[$0] },
                folderPath: $0.folderID.flatMap { folderPathsByID[$0] },
                sourceHistoryItem: $0.sourceHistoryItemID.flatMap { historyByID[$0] }
            )
        }
        return history + saved
    }
}
