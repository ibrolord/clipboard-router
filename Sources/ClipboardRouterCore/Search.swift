import Foundation
import SQLite3

public enum ClipSearchResultKind: Int, Codable, Hashable, Sendable {
    case savedClip
    case historyItem
}

public struct ClipSearchResult: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let kind: ClipSearchResultKind
    public let name: String?
    public let content: ClipContent
    public let recency: Date
    /// The time the content entered the clipboard. This differs from `recency` for saved clips,
    /// whose modification time is used for ranking but not for date-based retrieval.
    public let capturedAt: Date
    public let sourceApplicationBundleIdentifier: String?
    public let captureContext: ClipCaptureContext?
    public let sensitivity: ClipSensitivityMetadata?
    public let folderID: UUID?
    public let folderName: String?
    public let folderPath: String?
    public let savedItemKind: SavedItemKind?
    public let tags: [String]
    public let originatingDeviceIdentifier: String?
    public let pasteboardTypeIdentifiers: [String]
    public let captureCount: Int
    public let pasteCount: Int
    public let isPinned: Bool
    public let sizeByteCount: Int

    public init(
        id: UUID,
        kind: ClipSearchResultKind,
        name: String?,
        content: ClipContent,
        recency: Date,
        capturedAt: Date? = nil,
        sourceApplicationBundleIdentifier: String? = nil,
        captureContext: ClipCaptureContext? = nil,
        sensitivity: ClipSensitivityMetadata? = nil,
        folderID: UUID? = nil,
        folderName: String? = nil,
        folderPath: String? = nil,
        savedItemKind: SavedItemKind? = nil,
        tags: [String] = [],
        originatingDeviceIdentifier: String? = nil,
        pasteboardTypeIdentifiers: [String] = [],
        captureCount: Int = 1,
        pasteCount: Int = 0,
        isPinned: Bool = false,
        sizeByteCount: Int? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.content = content
        self.recency = recency
        self.capturedAt = capturedAt ?? recency
        self.sourceApplicationBundleIdentifier = sourceApplicationBundleIdentifier
        self.captureContext = captureContext
        self.sensitivity = sensitivity
        self.folderID = folderID
        self.folderName = folderName
        self.folderPath = folderPath
        self.savedItemKind = savedItemKind
        self.tags = tags
        self.originatingDeviceIdentifier = originatingDeviceIdentifier
        self.pasteboardTypeIdentifiers = pasteboardTypeIdentifiers
        self.captureCount = captureCount
        self.pasteCount = pasteCount
        self.isPinned = isPinned
        self.sizeByteCount = sizeByteCount ?? content.estimatedStorageByteCount
    }
}

/// SQLite FTS5-backed search. The index is derived and contains ordinary clips only; Vault,
/// quarantine, and private-session values never reach this type.
final class ClipSearchIndex: @unchecked Sendable {
    struct Projection: Sendable {
        let result: ClipSearchResult
        let name: String
        let body: String
        let metadata: String

        var normalizedName: String { ClipSearchIndex.normalize(name) }
        var normalizedContent: String { ClipSearchIndex.normalize(body) }
        var normalizedMetadata: String { ClipSearchIndex.normalize(metadata) }
    }

    private struct Document: Sendable {
        let result: ClipSearchResult
        let normalizedName: String
        let normalizedContent: String
        let normalizedMetadata: String
    }

    private var database: OpaquePointer?
    private let documents: [UUID: Document]
    private let orderedDocuments: [Document]

    init(snapshot: ClipboardLibrarySnapshot) {
        let foldersByID = Dictionary(uniqueKeysWithValues: snapshot.folders.map { ($0.id, $0.name) })
        let folderPathsByID = Self.folderPaths(in: snapshot.folders)
        let historyByID = Dictionary(uniqueKeysWithValues: snapshot.history.map { ($0.id, $0) })
        let savedDocuments = snapshot.savedClips.map { clip in
            Self.document(from: Self.projection(
                for: clip,
                folderName: clip.folderID.flatMap { foldersByID[$0] },
                folderPath: clip.folderID.flatMap { folderPathsByID[$0] },
                sourceHistoryItem: clip.sourceHistoryItemID.flatMap { historyByID[$0] }
            ))
        }
        let historyDocuments = snapshot.history.map { item in
            Self.document(from: Self.projection(for: item))
        }
        let all = savedDocuments + historyDocuments
        orderedDocuments = all.sorted(by: Self.recencyOrder)
        documents = Dictionary(uniqueKeysWithValues: all.map { ($0.result.id, $0) })
        buildSQLiteIndex(from: all)
    }

    private static func document(from projection: Projection) -> Document {
        Document(
            result: projection.result,
            normalizedName: projection.normalizedName,
            normalizedContent: projection.normalizedContent,
            normalizedMetadata: projection.normalizedMetadata
        )
    }

    static func projection(for item: HistoryItem) -> Projection {
        let result = ClipSearchResult(
            id: item.id,
            kind: .historyItem,
            name: nil,
            content: item.content,
            recency: item.lastCapturedAt,
            capturedAt: item.lastCapturedAt,
            sourceApplicationBundleIdentifier: item.sourceApplicationBundleIdentifier,
            captureContext: item.captureContext,
            sensitivity: item.sensitivity,
            originatingDeviceIdentifier: item.originatingDeviceIdentifier,
            pasteboardTypeIdentifiers: item.pasteboardTypeIdentifiers ?? [],
            captureCount: item.captureCount,
            pasteCount: item.pasteCount ?? 0
        )
        return projection(for: result)
    }

    static func projection(
        for item: SavedClip,
        folderName: String?,
        folderPath: String? = nil,
        sourceHistoryItem: HistoryItem? = nil
    ) -> Projection {
        let result = ClipSearchResult(
            id: item.id,
            kind: .savedClip,
            name: item.name,
            content: item.content,
            recency: item.modifiedAt,
            capturedAt: item.originallyCapturedAt ?? item.createdAt,
            sourceApplicationBundleIdentifier: item.sourceApplicationBundleIdentifier,
            captureContext: item.captureContext,
            sensitivity: item.sensitivity,
            folderID: item.folderID,
            folderName: folderName,
            folderPath: folderPath,
            savedItemKind: item.kind,
            tags: item.tags ?? [],
            originatingDeviceIdentifier: item.originatingDeviceIdentifier,
            pasteboardTypeIdentifiers: item.pasteboardTypeIdentifiers ?? [],
            captureCount: sourceHistoryItem?.captureCount ?? 1,
            pasteCount: sourceHistoryItem?.pasteCount ?? 0,
            isPinned: item.isPinned
        )
        return projection(for: result)
    }

    static func projection(for result: ClipSearchResult) -> Projection {
        let context = result.captureContext
        let origin = result.kind == .savedClip ? "saved" : "history"
        var metadataParts = typeSearchValues(for: result.content).map { "type \($0)" } + [
            "date \(dateToken(result.capturedAt))",
            "origin \(origin)",
            "pinned \(result.isPinned)",
            "size \(result.sizeByteCount)",
            "captures \(result.captureCount)",
            "pastes \(result.pasteCount)",
        ]
        func append(_ key: String, _ values: [String]) {
            for value in values where !value.isEmpty { metadataParts.append("\(key) \(value)") }
        }
        append("source", [result.sourceApplicationBundleIdentifier, context?.sourceApplicationName].compactMap { $0 })
        append("app", [result.sourceApplicationBundleIdentifier, context?.sourceApplicationName].compactMap { $0 })
        append("domain", [context?.sourceDomain].compactMap { $0 })
        append("sourceurl", [context?.sourceURL].compactMap { $0 })
        append("device", [result.originatingDeviceIdentifier, context?.deviceLabel].compactMap { $0 })
        append("os", [context?.operatingSystem].compactMap { $0 })
        append("location", [context?.coarseLocation?.label].compactMap { $0 })
        append("geohash", [context?.coarseLocation?.geohash].compactMap { $0 })
        append("secret", [result.sensitivity?.category].compactMap { $0 })
        append("sensitivity", [result.sensitivity?.category].compactMap { $0 })
        let searchableFolderName = result.folderName
            ?? (result.kind == .savedClip && result.folderID == nil ? "unfiled" : nil)
        append("folder", [searchableFolderName].compactMap { $0 })
        append("folder", [result.folderPath].compactMap { $0 })
        append("folderpath", [result.folderPath].compactMap { $0 })
        append("folderid", [result.folderID?.uuidString].compactMap { $0 })
        append("kind", [result.savedItemKind?.rawValue].compactMap { $0 })
        append("tag", result.tags)
        append("tags", result.tags)
        append("uti", utiSearchValues(for: result))
        let representations = result.content.representations
        append("url", [
            representations.url?.originalURL,
            representations.url?.host,
            representations.url?.title,
        ].compactMap { $0 })
        append("file", representations.files.flatMap { [$0.displayName, $0.url.absoluteString] })
        if let image = representations.imageMetadata {
            append("image", [image.format, "\(image.pixelWidth)", "\(image.pixelHeight)"])
        }
        return Projection(
            result: result,
            name: result.name ?? "",
            body: result.content.searchableText,
            metadata: metadataParts.joined(separator: " ")
        )
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    static func folderPaths(in folders: [ClipFolder]) -> [UUID: String] {
        let byID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        var result: [UUID: String] = [:]
        func path(for id: UUID, visiting: inout Set<UUID>) -> String? {
            if let cached = result[id] { return cached }
            guard visiting.insert(id).inserted, let folder = byID[id] else { return nil }
            defer { visiting.remove(id) }
            let value: String
            if let parentID = folder.parentFolderID,
               let parentPath = path(for: parentID, visiting: &visiting)
            {
                value = "\(parentPath) / \(folder.name)"
            } else {
                value = folder.name
            }
            result[id] = value
            return value
        }
        for folder in folders {
            var visiting = Set<UUID>()
            _ = path(for: folder.id, visiting: &visiting)
        }
        return result
    }

    struct DatePredicate: Sendable {
        let start: Date?
        let end: Date?
        let indexedDateTokens: [String]

        func contains(_ date: Date) -> Bool {
            guard let start, let end else { return false }
            return date >= start && date < end
        }
    }

    struct NumericPredicate: Sendable {
        enum Comparison: Sendable { case equal, greaterThan, greaterThanOrEqual, lessThan, lessThanOrEqual }
        let comparison: Comparison
        let value: Int

        func contains(_ candidate: Int) -> Bool {
            switch comparison {
            case .equal: candidate == value
            case .greaterThan: candidate > value
            case .greaterThanOrEqual: candidate >= value
            case .lessThan: candidate < value
            case .lessThanOrEqual: candidate <= value
            }
        }

        var sqlOperator: String {
            switch comparison {
            case .equal: "="
            case .greaterThan: ">"
            case .greaterThanOrEqual: ">="
            case .lessThan: "<"
            case .lessThanOrEqual: "<="
            }
        }
    }

    struct ParsedQuery: Sendable {
        let normalizedInput: String
        let isInvalid: Bool
        let generalTerms: [String]
        let contentTerms: [String]
        let sources: [String]
        /// Exact source facets generated by Smart Views. Values are decoded from `+`-escaped
        /// tokens so application names containing spaces remain a single query token.
        let exactSources: [String]
        let domains: [String]
        let exactDomains: [String]
        let types: [String]
        let devices: [String]
        let locations: [String]
        /// `*` means any sensitivity category.
        let secrets: [String]
        let dates: [DatePredicate]
        let folders: [String]
        let tags: [String]
        let utis: [String]
        let origins: [String]
        let savedItemKinds: [SavedItemKind]
        let pinned: [Bool]
        let sizes: [NumericPredicate]
        let captures: [NumericPredicate]
        let pastes: [NumericPredicate]

        var isEmpty: Bool {
            !isInvalid
                && generalTerms.isEmpty
                && contentTerms.isEmpty
                && sources.isEmpty
                && exactSources.isEmpty
                && domains.isEmpty
                && exactDomains.isEmpty
                && types.isEmpty
                && devices.isEmpty
                && locations.isEmpty
                && secrets.isEmpty
                && dates.isEmpty
                && folders.isEmpty
                && tags.isEmpty
                && utis.isEmpty
                && origins.isEmpty
                && savedItemKinds.isEmpty
                && pinned.isEmpty
                && sizes.isEmpty
                && captures.isEmpty
                && pastes.isEmpty
        }

        var hasNumericPredicates: Bool {
            !sizes.isEmpty || !captures.isEmpty || !pastes.isEmpty || !pinned.isEmpty
        }

        var rankingText: String {
            (generalTerms + contentTerms).joined(separator: " ")
        }
    }

    func search(query: String, limit: Int, now: Date = Date()) -> [ClipSearchResult] {
        guard limit > 0 else { return [] }
        let parsed = Self.parse(query: query, now: now)
        guard !parsed.isInvalid else { return [] }
        guard !parsed.isEmpty else {
            return Array(orderedDocuments.prefix(limit).map(\.result))
        }

        let candidateDocuments: [Document]
        if let database,
           let matchExpression = Self.ftsMatchExpression(for: parsed),
           let ids = queryIDs(database: database, matchExpression: matchExpression)
        {
            candidateDocuments = ids.compactMap { documents[$0] }
        } else {
            candidateDocuments = orderedDocuments
        }

        return candidateDocuments
            .compactMap { document -> (ClipSearchResult, Int)? in
                guard Self.matches(
                    parsed,
                    result: document.result,
                    normalizedName: document.normalizedName,
                    normalizedContent: document.normalizedContent,
                    normalizedMetadata: document.normalizedMetadata
                ) else { return nil }

                let score = Self.score(
                    parsed,
                    normalizedName: document.normalizedName,
                    normalizedContent: document.normalizedContent,
                    normalizedMetadata: document.normalizedMetadata
                )
                return (document.result, score)
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return Self.resultOrder(lhs.0, rhs.0)
            }
            .prefix(limit)
            .map(\.0)
    }

    private func buildSQLiteIndex(from documents: [Document]) {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(
            ":memory:",
            &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX,
            nil
        ) == SQLITE_OK, let handle else { return }

        let schema = """
        CREATE VIRTUAL TABLE clip_search USING fts5(
            id UNINDEXED,
            name,
            body,
            metadata,
            tokenize='unicode61 remove_diacritics 2'
        );
        """
        guard sqlite3_exec(handle, schema, nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return
        }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            handle,
            "INSERT INTO clip_search(id, name, body, metadata) VALUES (?, ?, ?, ?)",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            sqlite3_close(handle)
            return
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_exec(handle, "BEGIN", nil, nil, nil)
        for document in documents {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            Self.bind(document.result.id.uuidString.lowercased(), to: statement, index: 1)
            Self.bind(document.normalizedName, to: statement, index: 2)
            Self.bind(document.normalizedContent, to: statement, index: 3)
            Self.bind(document.normalizedMetadata, to: statement, index: 4)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
                sqlite3_close(handle)
                return
            }
        }
        guard sqlite3_exec(handle, "COMMIT", nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return
        }
        database = handle
    }

    private func queryIDs(
        database: OpaquePointer,
        matchExpression: String
    ) -> [UUID]? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT id FROM clip_search WHERE clip_search MATCH ?",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        Self.bind(matchExpression, to: statement, index: 1)

        var ids: [UUID] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let value = sqlite3_column_text(statement, 0),
                  let id = UUID(uuidString: String(cString: value))
            else { continue }
            ids.append(id)
        }
        return ids
    }

    static func parse(query: String, now: Date = Date()) -> ParsedQuery {
        let normalizedInput = normalize(query).trimmingCharacters(in: .whitespacesAndNewlines)
        let edgePunctuation = CharacterSet(charactersIn: ",.!?;()[]{}")
        let tokens = normalizedInput.split(whereSeparator: \Character.isWhitespace).map {
            String($0).trimmingCharacters(in: edgePunctuation)
        }
        var consumed = Array(repeating: false, count: tokens.count)
        var generalTerms: [String] = []
        var contentTerms: [String] = []
        var sources: [String] = []
        var exactSources: [String] = []
        var domains: [String] = []
        var exactDomains: [String] = []
        var types: [String] = []
        var devices: [String] = []
        var locations: [String] = []
        var secrets: [String] = []
        var dates: [DatePredicate] = []
        var folders: [String] = []
        var tags: [String] = []
        var utis: [String] = []
        var origins: [String] = []
        var savedItemKinds: [SavedItemKind] = []
        var pinned: [Bool] = []
        var sizes: [NumericPredicate] = []
        var captures: [NumericPredicate] = []
        var pastes: [NumericPredicate] = []
        var isInvalid = false

        // Exact field:value syntax is parsed first and retains its original AND semantics.
        for index in tokens.indices {
            let token = tokens[index]
            guard let separator = token.firstIndex(of: ":") else { continue }
            let key = String(token[..<separator])
            let value = String(token[token.index(after: separator)...])
            let exactKeys: Set<String> = [
                "source", "app", "sourceexact", "domain", "domainexact", "type", "device", "location", "secret",
                "sensitivity", "date", "folder", "folderpath", "tag", "tags", "uti", "origin", "kind",
                "pinned", "size", "captures", "pastes",
            ]
            guard !value.isEmpty else {
                if exactKeys.contains(key) {
                    isInvalid = true
                    consumed[index] = true
                }
                continue
            }
            switch key {
            case "source", "app": sources.append(value)
            case "sourceexact": exactSources.append(decodeExactFacetValue(value))
            case "domain": domains.append(value)
            case "domainexact": exactDomains.append(decodeExactFacetValue(value))
            case "type": types.append(typeAlias(for: value))
            case "device": devices.append(value)
            case "location": locations.append(value)
            case "secret", "sensitivity": secrets.append(value)
            case "date": dates.append(exactDatePredicate(value))
            case "folder", "folderpath": folders.append(value)
            case "tag", "tags": tags.append(value)
            case "uti": utis.append(value)
            case "origin": origins.append(originAlias(for: value))
            case "kind":
                if let kind = SavedItemKind(rawValue: value) { savedItemKinds.append(kind) }
                else { isInvalid = true }
            case "pinned":
                if let value = parseBoolean(value) { pinned.append(value) }
                else { isInvalid = true }
            case "size":
                if let value = parseNumericPredicate(value, permitsByteUnits: true) { sizes.append(value) }
                else { isInvalid = true }
            case "captures":
                if let value = parseNumericPredicate(value, permitsByteUnits: false) { captures.append(value) }
                else { isInvalid = true }
            case "pastes":
                if let value = parseNumericPredicate(value, permitsByteUnits: false) { pastes.append(value) }
                else { isInvalid = true }
            default: continue
            }
            consumed[index] = true
        }

        for index in tokens.indices where !consumed[index] {
            switch tokens[index] {
            case "image", "images":
                types.append("image")
                consumed[index] = true
            case "link", "links", "url", "urls":
                types.append("url")
                consumed[index] = true
            case "pdf", "pdfs":
                types.append("pdf")
                consumed[index] = true
            case "secret", "secrets":
                secrets.append("*")
                consumed[index] = true
            case "today":
                dates.append(relativeDatePredicate(.today, now: now))
                consumed[index] = true
            case "yesterday":
                dates.append(relativeDatePredicate(.yesterday, now: now))
                consumed[index] = true
            case "last" where index + 1 < tokens.count && tokens[index + 1] == "week":
                dates.append(relativeDatePredicate(.lastWeek, now: now))
                consumed[index] = true
                consumed[index + 1] = true
            default:
                continue
            }
        }

        func isPhraseBoundary(_ index: Int) -> Bool {
            guard index < tokens.count else { return true }
            if consumed[index] { return true }
            return ["from", "containing", "copied"].contains(tokens[index])
        }

        func phrase(after start: Int) -> (value: String, range: Range<Int>)? {
            var end = start
            while end < tokens.count, !isPhraseBoundary(end) { end += 1 }
            guard end > start else { return nil }
            return (tokens[start..<end].joined(separator: " "), start..<end)
        }

        var index = 0
        while index < tokens.count {
            guard !consumed[index] else {
                index += 1
                continue
            }
            if tokens[index] == "from", let found = phrase(after: index + 1) {
                sources.append(found.value)
                consumed[index] = true
                for position in found.range { consumed[position] = true }
                index = found.range.upperBound
                continue
            }
            if tokens[index] == "containing", let found = phrase(after: index + 1) {
                contentTerms.append(contentsOf: found.value.split(separator: " ").map(String.init))
                consumed[index] = true
                for position in found.range { consumed[position] = true }
                index = found.range.upperBound
                continue
            }
            if tokens[index] == "copied", index + 1 < tokens.count,
               ["in", "on"].contains(tokens[index + 1]),
               let found = phrase(after: index + 2)
            {
                if tokens[index + 1] == "in" { locations.append(found.value) }
                else { devices.append(found.value) }
                consumed[index] = true
                consumed[index + 1] = true
                for position in found.range { consumed[position] = true }
                index = found.range.upperBound
                continue
            }
            index += 1
        }

        let naturalGlueWords: Set<String> = ["clip", "clips", "thing", "things", "copied"]
        for index in tokens.indices where !consumed[index] && !tokens[index].isEmpty {
            if naturalGlueWords.contains(tokens[index]) { continue }
            generalTerms.append(tokens[index])
        }

        return ParsedQuery(
            normalizedInput: normalizedInput,
            isInvalid: isInvalid,
            generalTerms: generalTerms,
            contentTerms: contentTerms,
            sources: sources,
            exactSources: exactSources,
            domains: domains,
            exactDomains: exactDomains,
            types: types,
            devices: devices,
            locations: locations,
            secrets: secrets,
            dates: dates,
            folders: folders,
            tags: tags,
            utis: utis,
            origins: origins,
            savedItemKinds: savedItemKinds,
            pinned: pinned,
            sizes: sizes,
            captures: captures,
            pastes: pastes
        )
    }

    static func ftsMatchExpression(for query: String) -> String? {
        ftsMatchExpression(for: parse(query: query))
    }

    static func ftsMatchExpression(for query: ParsedQuery) -> String? {
        let components = (query.generalTerms + query.contentTerms).map {
            "\"\(escapedFTS($0))\"*"
        }
        guard !components.isEmpty else { return nil }
        return components.joined(separator: " AND ")
    }

    /// Candidate-only substring selectors for structured fields. Values intentionally omit their
    /// field labels, making each candidate set a superset; canonical post-filtering enforces that
    /// the value occurred in the requested field. Each outer entry is ANDed, inner values are ORed.
    static func metadataCandidateGroups(for query: ParsedQuery) -> [[String]] {
        var groups = (
            query.sources + query.exactSources + query.domains + query.exactDomains
                + query.types + query.devices + query.locations
                + query.folders + query.tags + query.utis + query.origins
                + query.savedItemKinds.map(\.rawValue)
        ).map { [normalize($0)] }
        groups.append(contentsOf: query.secrets.map { [$0 == "*" ? "secret" : normalize($0)] })
        groups.append(contentsOf: query.dates.map { $0.indexedDateTokens.map(normalize) })
        return groups.filter { !$0.isEmpty }
    }

    static func plainTerms(from query: String) -> [String] {
        let parsed = parse(query: query)
        return parsed.generalTerms + parsed.contentTerms
    }

    static func matchesStructuredPredicates(_ query: ParsedQuery, result: ClipSearchResult) -> Bool {
        let source = normalize([
            result.sourceApplicationBundleIdentifier,
            result.captureContext?.sourceApplicationName,
        ].compactMap { $0 }.joined(separator: " "))
        let exactSourceValues = [
            result.sourceApplicationBundleIdentifier,
            result.captureContext?.sourceApplicationName,
        ].compactMap { $0 }.map(normalize)
        let domain = normalize(result.captureContext?.sourceDomain ?? "")
        let device = normalize([
            result.originatingDeviceIdentifier,
            result.captureContext?.deviceLabel,
        ].compactMap { $0 }.joined(separator: " "))
        let location = normalize(result.captureContext?.coarseLocation?.label ?? "")
        let category = normalize(result.sensitivity?.category ?? "")
        let folder = normalize(
            result.folderPath
                ?? result.folderName
                ?? (result.kind == .savedClip && result.folderID == nil ? "unfiled" : "")
        )
        let tags = result.tags.map(normalize)
        let utis = utiSearchValues(for: result).map(normalize)
        let origin = result.kind == .savedClip ? "saved" : "history"
        guard query.sources.allSatisfy({ contains(source, $0) }),
              query.exactSources.allSatisfy({ exactSourceValues.contains(normalize($0)) }),
              query.domains.allSatisfy({ contains(domain, $0) }),
              query.exactDomains.allSatisfy({ domain == normalize($0) }),
              query.devices.allSatisfy({ contains(device, $0) }),
              query.locations.allSatisfy({ contains(location, $0) }),
              query.types.allSatisfy({ typeSearchValues(for: result.content).contains($0) }),
              query.secrets.allSatisfy({ $0 == "*" ? result.sensitivity != nil : contains(category, $0) }),
              query.dates.allSatisfy({ $0.contains(result.capturedAt) }),
              query.folders.allSatisfy({ contains(folder, $0) }),
              query.tags.allSatisfy({ term in tags.contains(where: { contains($0, term) }) }),
              query.utis.allSatisfy({ term in utis.contains(where: { contains($0, term) }) }),
              query.origins.allSatisfy({ $0 == origin }),
              query.savedItemKinds.allSatisfy({
                  $0 == (result.savedItemKind ?? .clip)
              }),
              query.pinned.allSatisfy({ $0 == result.isPinned }),
              query.sizes.allSatisfy({ $0.contains(result.sizeByteCount) }),
              query.captures.allSatisfy({ $0.contains(result.captureCount) }),
              query.pastes.allSatisfy({ $0.contains(result.pasteCount) })
        else { return false }
        return true
    }

    static func matches(
        _ query: ParsedQuery,
        result: ClipSearchResult,
        normalizedName: String,
        normalizedContent: String,
        normalizedMetadata: String
    ) -> Bool {
        guard matchesStructuredPredicates(query, result: result),
              query.generalTerms.allSatisfy({ term in
                  contains(normalizedName, term)
                      || contains(normalizedContent, term)
                      || contains(normalizedMetadata, term)
              }),
              query.contentTerms.allSatisfy({ contains(normalizedContent, $0) })
        else { return false }
        return true
    }

    static func score(
        _ query: ParsedQuery,
        normalizedName: String,
        normalizedContent: String,
        normalizedMetadata: String = ""
    ) -> Int {
        let rankingText = query.rankingText
        var score = 0
        if !rankingText.isEmpty {
            if normalizedName == rankingText { score += 1_000 }
            else if normalizedName.hasPrefix(rankingText) { score += 500 }
            if normalizedContent == rankingText { score += 400 }
            else if normalizedContent.hasPrefix(rankingText) { score += 200 }
        }
        for term in query.generalTerms + query.contentTerms {
            if contains(normalizedName, term) { score += 25 }
            if contains(normalizedContent, term) { score += 10 }
            if contains(normalizedMetadata, term) { score += 8 }
        }
        return score
    }

    private enum RelativeDate {
        case today
        case yesterday
        case lastWeek
    }

    private static func relativeDatePredicate(_ relativeDate: RelativeDate, now: Date) -> DatePredicate {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let start: Date
        let end: Date
        switch relativeDate {
        case .today:
            start = today
            end = calendar.date(byAdding: .day, value: 1, to: today)!
        case .yesterday:
            start = calendar.date(byAdding: .day, value: -1, to: today)!
            end = today
        case .lastWeek:
            let currentWeekStart = calendar.dateInterval(of: .weekOfYear, for: now)!.start
            start = calendar.date(byAdding: .day, value: -7, to: currentWeekStart)!
            end = currentWeekStart
        }
        return DatePredicate(
            start: start,
            end: end,
            indexedDateTokens: utcDateTokensIntersecting(start: start, end: end)
        )
    }

    private static func exactDatePredicate(_ token: String) -> DatePredicate {
        let calendar = Calendar.current
        let parts = token.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let start = calendar.date(from: DateComponents(
                  timeZone: calendar.timeZone,
                  year: parts[0],
                  month: parts[1],
                  day: parts[2]
              )),
              calendar.component(.year, from: start) == parts[0],
              calendar.component(.month, from: start) == parts[1],
              calendar.component(.day, from: start) == parts[2],
              let end = calendar.date(byAdding: .day, value: 1, to: start)
        else {
            return DatePredicate(start: nil, end: nil, indexedDateTokens: [token])
        }
        return DatePredicate(
            start: start,
            end: end,
            indexedDateTokens: utcDateTokensIntersecting(start: start, end: end)
        )
    }

    private static func utcDateTokensIntersecting(start: Date, end: Date) -> [String] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var tokens: [String] = []
        var cursor = calendar.startOfDay(for: start)
        while cursor < end {
            tokens.append(dateToken(cursor))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return tokens
    }

    private static func typeAlias(for value: String) -> String {
        switch value {
        case "link", "links", "urls": "url"
        case "images": "image"
        case "pdfs": "pdf"
        case "text": "plaintext"
        case "file", "files": "fileurls"
        default: value
        }
    }

    private static func originAlias(for value: String) -> String {
        switch value {
        case "savedclip", "savedclips", "library": "saved"
        case "historyitem", "historyitems", "recent": "history"
        default: value
        }
    }

    private static func parseBoolean(_ value: String) -> Bool? {
        switch value {
        case "true", "yes", "1": true
        case "false", "no", "0": false
        default: nil
        }
    }

    private static func decodeExactFacetValue(_ value: String) -> String {
        value.replacingOccurrences(of: "+", with: " ")
    }

    private static func parseNumericPredicate(
        _ input: String,
        permitsByteUnits: Bool
    ) -> NumericPredicate? {
        let operators: [(String, NumericPredicate.Comparison)] = [
            (">=", .greaterThanOrEqual), ("<=", .lessThanOrEqual),
            (">", .greaterThan), ("<", .lessThan), ("=", .equal),
        ]
        let found = operators.first { input.hasPrefix($0.0) }
        let comparison = found?.1 ?? .equal
        var valueText = found.map { String(input.dropFirst($0.0.count)) } ?? input
        var multiplier = 1.0
        if permitsByteUnits {
            let units: [(String, Double)] = [
                ("gb", 1_073_741_824), ("mb", 1_048_576), ("kb", 1_024), ("b", 1),
            ]
            if let unit = units.first(where: { valueText.hasSuffix($0.0) }) {
                multiplier = unit.1
                valueText.removeLast(unit.0.count)
            }
        }
        guard !valueText.isEmpty,
              let number = Double(valueText), number >= 0,
              number.isFinite,
              number * multiplier <= Double(Int.max),
              permitsByteUnits || number.rounded(.towardZero) == number
        else { return nil }
        return NumericPredicate(comparison: comparison, value: Int(number * multiplier))
    }

    static func typeSearchValues(for content: ClipContent) -> [String] {
        var values = [normalize(content.type.rawValue)]
        switch content.type {
        case .plainText: values.append("text")
        case .url: values.append("link")
        case .richText: values.append("richtext")
        case .image: break
        case .fileURLs: values.append("file")
        }
        let hasPDF = content.representations.files.contains {
            $0.url.pathExtension.caseInsensitiveCompare("pdf") == .orderedSame
        } || content.representations.referencedAssets.contains { $0.kind == .pdf }
        if hasPDF { values.append("pdf") }
        return values.reduce(into: []) { unique, value in
            if !unique.contains(value) { unique.append(value) }
        }
    }

    private static func utiSearchValues(for result: ClipSearchResult) -> [String] {
        let representationUTIs = result.content.representations.referencedAssets.map(\.uniformTypeIdentifier)
        return Array(Set(result.pasteboardTypeIdentifiers + representationUTIs)).sorted()
    }

    private static func escapedFTS(_ token: String) -> String {
        token.replacingOccurrences(of: "\"", with: "\"\"")
    }

    private static func bind(_ value: String, to statement: OpaquePointer, index: Int32) {
        sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
    }

    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static func normalize(_ value: String) -> String {
        value
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    static func contains(_ haystack: String, _ needle: String) -> Bool {
        haystack.range(of: needle, options: [.literal]) != nil
    }

    static func dateToken(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    private static func recencyOrder(_ lhs: Document, _ rhs: Document) -> Bool {
        resultOrder(lhs.result, rhs.result)
    }

    static func resultOrder(_ lhs: ClipSearchResult, _ rhs: ClipSearchResult) -> Bool {
        if lhs.recency != rhs.recency { return lhs.recency > rhs.recency }
        if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
