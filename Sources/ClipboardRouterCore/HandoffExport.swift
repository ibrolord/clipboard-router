import Foundation

public enum HandoffFormat: String, Codable, CaseIterable, Sendable {
    case markdown
    case csv
    case json
}

public struct HandoffRecord: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let itemID: UUID
    public let kind: SavedItemKind
    public let title: String
    public let body: String
    public let contentType: SupportedContentType
    public let url: String?
    public let domain: String?
    public let sourceApplicationBundleIdentifier: String?
    public let originallyCapturedAt: Date?
    public let createdAt: Date
    public let modifiedAt: Date
    public let folderPath: String
    public let tags: [String]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        itemID: UUID,
        kind: SavedItemKind,
        title: String,
        body: String,
        contentType: SupportedContentType,
        url: String?,
        domain: String?,
        sourceApplicationBundleIdentifier: String?,
        originallyCapturedAt: Date?,
        createdAt: Date,
        modifiedAt: Date,
        folderPath: String,
        tags: [String]
    ) {
        self.schemaVersion = schemaVersion
        self.itemID = itemID
        self.kind = kind
        self.title = title
        self.body = body
        self.contentType = contentType
        self.url = url
        self.domain = domain
        self.sourceApplicationBundleIdentifier = sourceApplicationBundleIdentifier
        self.originallyCapturedAt = originallyCapturedAt
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.folderPath = folderPath
        self.tags = tags
    }
}

public enum HandoffOmissionReason: String, Codable, CaseIterable, Equatable, Sendable {
    case sensitive
    case locationMetadataNotShareable
    case localFileReference
    case unsupportedBinaryAsset
    case missingFolder
    case corruptItem
}

public struct HandoffOmission: Codable, Equatable, Sendable {
    public let itemID: UUID
    public let title: String
    public let reasonCode: HandoffOmissionReason

    public init(itemID: UUID, title: String, reasonCode: HandoffOmissionReason) {
        self.itemID = itemID
        self.title = title
        self.reasonCode = reasonCode
    }
}

public struct HandoffProjection: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let exportedAt: Date
    public let rootFolderPath: String
    public let records: [HandoffRecord]
    public let omissions: [HandoffOmission]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        exportedAt: Date,
        rootFolderPath: String,
        records: [HandoffRecord],
        omissions: [HandoffOmission]
    ) {
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.rootFolderPath = rootFolderPath
        self.records = records
        self.omissions = omissions
    }
}

public enum HandoffExportError: Error, Equatable, LocalizedError, Sendable {
    case folderNotFound(UUID)
    case invalidFolderHierarchy(UUID)
    case emptySelection
    case destinationExists(URL)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .folderNotFound(id):
            "Folder \(id) was not found."
        case let .invalidFolderHierarchy(id):
            "Folder \(id) belongs to an invalid hierarchy."
        case .emptySelection:
            "There are no eligible items to export."
        case let .destinationExists(url):
            "Export destination already exists: \(url.path)"
        case let .writeFailed(reason):
            "The folder handoff could not be written: \(reason)"
        }
    }
}

public struct FolderHandoffProjector: Sendable {
    public init() {}

    public func project(
        rootFolderID: UUID,
        snapshot: ClipboardLibrarySnapshot,
        at date: Date = Date()
    ) throws -> HandoffProjection {
        let foldersByID = Dictionary(uniqueKeysWithValues: snapshot.folders.map { ($0.id, $0) })
        guard foldersByID[rootFolderID] != nil else {
            throw HandoffExportError.folderNotFound(rootFolderID)
        }
        let selectedFolderIDs = try descendantFolderIDs(
            rootFolderID: rootFolderID,
            foldersByID: foldersByID
        )
        let rootPath = try folderPath(
            for: rootFolderID,
            selectedRootID: rootFolderID,
            foldersByID: foldersByID
        )
        var records: [HandoffRecord] = []
        var omissions: [HandoffOmission] = []

        for item in snapshot.savedClips {
            guard let folderID = item.folderID, selectedFolderIDs.contains(folderID) else {
                continue
            }
            let path: String
            do {
                path = try folderPath(
                    for: folderID,
                    selectedRootID: rootFolderID,
                    foldersByID: foldersByID
                )
            } catch {
                omissions.append(HandoffOmission(
                    itemID: item.id,
                    title: "Excluded item",
                    reasonCode: .missingFolder
                ))
                continue
            }
            if let reason = omissionReason(for: item) {
                omissions.append(HandoffOmission(
                    itemID: item.id,
                    title: "Excluded item",
                    reasonCode: reason
                ))
                continue
            }
            let structuredURL = item.content.representations.url?.originalURL
            records.append(HandoffRecord(
                itemID: item.id,
                kind: item.kind,
                title: item.name,
                body: item.content.text,
                contentType: item.content.type,
                url: structuredURL,
                domain: item.content.representations.url?.host
                    ?? item.captureContext?.sourceDomain,
                sourceApplicationBundleIdentifier: item.sourceApplicationBundleIdentifier,
                originallyCapturedAt: item.originallyCapturedAt,
                createdAt: item.createdAt,
                modifiedAt: item.modifiedAt,
                folderPath: path,
                tags: (item.tags ?? []).sorted {
                    $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
                }
            ))
        }

        records.sort(by: recordOrder)
        omissions.sort { lhs, rhs in
            if lhs.title != rhs.title {
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
            return lhs.itemID.uuidString < rhs.itemID.uuidString
        }
        return HandoffProjection(
            exportedAt: date,
            rootFolderPath: rootPath,
            records: records,
            omissions: omissions
        )
    }

    private func omissionReason(for item: SavedClip) -> HandoffOmissionReason? {
        if item.sensitivity != nil { return .sensitive }
        if item.captureContext?.coarseLocation != nil {
            return .locationMetadataNotShareable
        }
        let originalURL = item.content.representations.url?.originalURL
        let structuredURL = originalURL.flatMap { URL(string: $0) }
        if item.content.type == .fileURLs
            || !item.content.representations.files.isEmpty
            || structuredURL?.isFileURL == true
        {
            return .localFileReference
        }
        if !item.content.representations.referencedAssets.isEmpty
            || item.content.type == .image
            || item.content.type == .richText
        {
            return .unsupportedBinaryAsset
        }
        return nil
    }

    private func descendantFolderIDs(
        rootFolderID: UUID,
        foldersByID: [UUID: ClipFolder]
    ) throws -> Set<UUID> {
        var selected: Set<UUID> = [rootFolderID]
        var queue: [UUID] = [rootFolderID]
        while !queue.isEmpty {
            let parent = queue.removeFirst()
            for child in foldersByID.values where child.parentFolderID == parent {
                guard selected.insert(child.id).inserted else {
                    throw HandoffExportError.invalidFolderHierarchy(child.id)
                }
                queue.append(child.id)
            }
        }
        return selected
    }

    private func folderPath(
        for folderID: UUID,
        selectedRootID: UUID,
        foldersByID: [UUID: ClipFolder]
    ) throws -> String {
        var names: [String] = []
        var cursor: UUID? = folderID
        var visited: Set<UUID> = []
        while let current = cursor {
            guard visited.insert(current).inserted else {
                throw HandoffExportError.invalidFolderHierarchy(current)
            }
            guard let folder = foldersByID[current] else {
                throw HandoffExportError.folderNotFound(current)
            }
            names.append(folder.name)
            if current == selectedRootID { return names.reversed().joined(separator: " / ") }
            cursor = folder.parentFolderID
        }
        throw HandoffExportError.invalidFolderHierarchy(folderID)
    }

    private func recordOrder(_ lhs: HandoffRecord, _ rhs: HandoffRecord) -> Bool {
        if lhs.folderPath != rhs.folderPath { return lhs.folderPath < rhs.folderPath }
        let lhsDate = lhs.originallyCapturedAt ?? lhs.createdAt
        let rhsDate = rhs.originallyCapturedAt ?? rhs.createdAt
        if lhsDate != rhsDate { return lhsDate < rhsDate }
        return lhs.itemID.uuidString < rhs.itemID.uuidString
    }
}

public protocol HandoffRendering: Sendable {
    var format: HandoffFormat { get }
    func render(_ projection: HandoffProjection) throws -> Data
}

public struct MarkdownHandoffRenderer: HandoffRendering {
    public let format = HandoffFormat.markdown

    public init() {}

    public func render(_ projection: HandoffProjection) throws -> Data {
        var lines = [
            "# \(escapedInline(projection.rootFolderPath))",
            "",
            "Exported: \(handoffTimestamp(projection.exportedAt))",
            "Items: \(projection.records.count)",
            "Omitted: \(projection.omissions.count)",
        ]
        var currentPath: String?
        for record in projection.records {
            if currentPath != record.folderPath {
                lines.append(contentsOf: ["", "## \(escapedInline(record.folderPath))"])
                currentPath = record.folderPath
            }
            lines.append(contentsOf: ["", "### \(escapedInline(record.title))", "", record.body])
            lines.append("")
            lines.append("- Kind: \(record.kind.rawValue)")
            lines.append("- Type: \(record.contentType.rawValue)")
            if let url = record.url { lines.append("- URL: \(url)") }
            if let domain = record.domain { lines.append("- Domain: \(escapedInline(domain))") }
            if let source = record.sourceApplicationBundleIdentifier {
                lines.append("- Source: \(escapedInline(source))")
            }
            if let captured = record.originallyCapturedAt {
                lines.append("- Captured: \(handoffTimestamp(captured))")
            }
            if !record.tags.isEmpty {
                lines.append("- Tags: \(record.tags.map(escapedInline).joined(separator: ", "))")
            }
        }
        if !projection.omissions.isEmpty {
            lines.append(contentsOf: ["", "## Omissions", ""])
            for omission in projection.omissions {
                lines.append("- \(escapedInline(omission.title)): \(omission.reasonCode.rawValue)")
            }
        }
        guard let data = (lines.joined(separator: "\n") + "\n").data(using: .utf8) else {
            throw HandoffExportError.writeFailed("Markdown could not be encoded as UTF-8.")
        }
        return data
    }

    private func escapedInline(_ value: String) -> String {
        let oneLine = value.split(whereSeparator: { $0.isNewline }).joined(separator: " ")
        return oneLine.replacingOccurrences(
            of: #"([\\`*_{\[\]<>#])"#,
            with: #"\\$1"#,
            options: .regularExpression
        )
    }
}

public struct CSVHandoffRenderer: HandoffRendering {
    public let format = HandoffFormat.csv

    public init() {}

    public func render(_ projection: HandoffProjection) throws -> Data {
        let header = [
            "schema_version", "item_id", "kind", "title", "body", "content_type",
            "url", "domain", "source_app", "captured_at", "created_at", "modified_at",
            "folder_path", "tags",
        ]
        var rows = [header]
        for record in projection.records {
            rows.append([
                String(record.schemaVersion),
                record.itemID.uuidString.lowercased(),
                record.kind.rawValue,
                record.title,
                record.body,
                record.contentType.rawValue,
                record.url ?? "",
                record.domain ?? "",
                record.sourceApplicationBundleIdentifier ?? "",
                record.originallyCapturedAt.map(handoffTimestamp) ?? "",
                handoffTimestamp(record.createdAt),
                handoffTimestamp(record.modifiedAt),
                record.folderPath,
                record.tags.map {
                    $0.replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "|", with: "\\|")
                }.joined(separator: "|"),
            ])
        }
        let rendered = rows.map { row in row.map(csvCell).joined(separator: ",") }
            .joined(separator: "\r\n") + "\r\n"
        guard let data = rendered.data(using: .utf8) else {
            throw HandoffExportError.writeFailed("CSV could not be encoded as UTF-8.")
        }
        return data
    }

    private func csvCell(_ rawValue: String) -> String {
        let defended = formulaSafe(rawValue)
        guard defended.contains(",") || defended.contains("\"")
            || defended.contains("\r") || defended.contains("\n")
        else { return defended }
        return "\"\(defended.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private func formulaSafe(_ rawValue: String) -> String {
        guard let firstEffective = rawValue.first(where: { !$0.isWhitespace }) else {
            return rawValue
        }
        if ["=", "+", "-", "@"].contains(String(firstEffective))
            || rawValue.first == "\t" || rawValue.first == "\r" || rawValue.first == "\n"
        {
            return "'" + rawValue
        }
        return rawValue
    }
}

public struct JSONHandoffRenderer: HandoffRendering {
    public let format = HandoffFormat.json

    public init() {}

    public func render(_ projection: HandoffProjection) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(projection)
    }
}

public struct HandoffFileWriter: Sendable {
    public init() {}

    public func write(
        _ data: Data,
        to destination: URL,
        replacingExisting: Bool = false
    ) throws {
        let destination = destination.standardizedFileURL
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path), !replacingExisting {
            throw HandoffExportError.destinationExists(destination)
        }
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(
            ".clipboardrouter-handoff-\(UUID().uuidString)",
            isDirectory: false
        )
        do {
            try data.write(to: staging, options: [.atomic])
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: staging)
            } else {
                try fileManager.moveItem(at: staging, to: destination)
            }
        } catch {
            try? fileManager.removeItem(at: staging)
            if let handoffError = error as? HandoffExportError { throw handoffError }
            throw HandoffExportError.writeFailed(error.localizedDescription)
        }
    }
}

private func handoffTimestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}
