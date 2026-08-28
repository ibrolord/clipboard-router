import Foundation

public struct ContextPackLimits: Codable, Equatable, Sendable {
    public static let `default` = try! ContextPackLimits(
        maximumItemCount: 100,
        maximumItemUTF8Bytes: 256 * 1_024,
        maximumRenderedUTF8Bytes: 1_024 * 1_024
    )

    public let maximumItemCount: Int
    public let maximumItemUTF8Bytes: Int
    public let maximumRenderedUTF8Bytes: Int

    public init(
        maximumItemCount: Int,
        maximumItemUTF8Bytes: Int,
        maximumRenderedUTF8Bytes: Int
    ) throws {
        guard maximumItemCount > 0,
              maximumItemUTF8Bytes > 0,
              maximumRenderedUTF8Bytes > 0
        else {
            throw ContextPackError.invalidLimits
        }

        self.maximumItemCount = maximumItemCount
        self.maximumItemUTF8Bytes = maximumItemUTF8Bytes
        self.maximumRenderedUTF8Bytes = maximumRenderedUTF8Bytes
    }

    private enum CodingKeys: String, CodingKey {
        case maximumItemCount
        case maximumItemUTF8Bytes
        case maximumRenderedUTF8Bytes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            maximumItemCount: container.decode(Int.self, forKey: .maximumItemCount),
            maximumItemUTF8Bytes: container.decode(Int.self, forKey: .maximumItemUTF8Bytes),
            maximumRenderedUTF8Bytes: container.decode(
                Int.self,
                forKey: .maximumRenderedUTF8Bytes
            )
        )
    }
}

/// An immutable snapshot used when composing a text context. The source clip is never edited.
public struct ContextPackItem: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let title: String
    public let textRepresentation: String
    public let capturedAt: Date?
    public let sourceApplication: String?
    public let sourceURL: URL?
    public let metadata: [String: String]

    public init(
        id: UUID,
        title: String,
        textRepresentation: String,
        capturedAt: Date? = nil,
        sourceApplication: String? = nil,
        sourceURL: URL? = nil,
        metadata: [String: String] = [:]
    ) throws {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else {
            throw ContextPackError.emptyItemTitle
        }
        guard !textRepresentation.isEmpty else {
            throw ContextPackError.emptyItemContent
        }

        self.id = id
        self.title = normalizedTitle
        self.textRepresentation = textRepresentation
        self.capturedAt = capturedAt
        self.sourceApplication = sourceApplication
        self.sourceURL = sourceURL
        self.metadata = metadata
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case textRepresentation
        case capturedAt
        case sourceApplication
        case sourceURL
        case metadata
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            title: container.decode(String.self, forKey: .title),
            textRepresentation: container.decode(String.self, forKey: .textRepresentation),
            capturedAt: container.decodeIfPresent(Date.self, forKey: .capturedAt),
            sourceApplication: container.decodeIfPresent(
                String.self,
                forKey: .sourceApplication
            ),
            sourceURL: container.decodeIfPresent(URL.self, forKey: .sourceURL),
            metadata: container.decodeIfPresent(
                [String: String].self,
                forKey: .metadata
            ) ?? [:]
        )
    }
}

/// The authoritative library location that supplied a reviewed combined clip. This expectation is
/// checked inside the library actor immediately before a derived note is committed, so a source
/// cannot be edited, moved, deleted, or reclassified during the review-to-save handoff.
public enum ContextPackSource: Equatable, Sendable {
    case history
    case saved(folderID: UUID?, kind: SavedItemKind)
}

public struct ContextPackSourceExpectation: Equatable, Sendable {
    public let item: ContextPackItem
    public let source: ContextPackSource

    public init(item: ContextPackItem, source: ContextPackSource) {
        self.item = item
        self.source = source
    }
}

/// An ordered, bounded collection of immutable clip snapshots.
public struct ContextPack: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public private(set) var name: String
    public let limits: ContextPackLimits
    public private(set) var items: [ContextPackItem]

    public init(
        id: UUID = UUID(),
        name: String,
        items: [ContextPackItem] = [],
        limits: ContextPackLimits = .default
    ) throws {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            throw ContextPackError.emptyName
        }

        self.id = id
        self.name = normalizedName
        self.limits = limits
        self.items = []

        for item in items {
            try append(item)
        }
        _ = try renderMarkdown()
    }

    public mutating func rename(_ newName: String) throws {
        let normalizedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            throw ContextPackError.emptyName
        }

        let previousName = name
        name = normalizedName
        do {
            _ = try renderMarkdown()
        } catch {
            name = previousName
            throw error
        }
    }

    public mutating func append(_ item: ContextPackItem) throws {
        try insert(item, at: items.endIndex)
    }

    public mutating func insert(_ item: ContextPackItem, at index: Int) throws {
        guard items.indices.contains(index) || index == items.endIndex else {
            throw ContextPackError.invalidIndex(index)
        }
        guard !items.contains(where: { $0.id == item.id }) else {
            throw ContextPackError.duplicateItem(item.id)
        }
        guard items.count < limits.maximumItemCount else {
            throw ContextPackError.itemCountExceedsLimit(limits.maximumItemCount)
        }

        let itemSize = item.textRepresentation.utf8.count
        guard itemSize <= limits.maximumItemUTF8Bytes else {
            throw ContextPackError.itemSizeExceedsLimit(
                itemID: item.id,
                actual: itemSize,
                maximum: limits.maximumItemUTF8Bytes
            )
        }

        items.insert(item, at: index)
        do {
            _ = try renderMarkdown()
        } catch {
            items.remove(at: index)
            throw error
        }
    }

    @discardableResult
    public mutating func remove(itemID: UUID) -> ContextPackItem? {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else {
            return nil
        }
        return items.remove(at: index)
    }

    public mutating func move(from sourceIndex: Int, to destinationIndex: Int) throws {
        guard items.indices.contains(sourceIndex) else {
            throw ContextPackError.invalidIndex(sourceIndex)
        }
        guard items.indices.contains(destinationIndex) else {
            throw ContextPackError.invalidIndex(destinationIndex)
        }
        guard sourceIndex != destinationIndex else {
            return
        }

        let item = items.remove(at: sourceIndex)
        items.insert(item, at: destinationIndex)
    }

    /// Renders stable Markdown using pack order and lexicographically sorted custom metadata.
    public func renderMarkdown() throws -> String {
        var sections = ["# \(markdownHeading(name))"]

        for (offset, item) in items.enumerated() {
            var lines = [
                "## \(offset + 1). \(markdownHeading(item.title))",
                "- Clip ID: `\(item.id.uuidString.lowercased())`",
            ]

            if let capturedAt = item.capturedAt {
                lines.append("- Captured: `\(iso8601String(capturedAt))`")
            }
            if let sourceApplication = item.sourceApplication {
                lines.append("- Source application: \(markdownInline(sourceApplication))")
            }
            if let sourceURL = item.sourceURL {
                lines.append("- Source URL: \(markdownInline(sourceURL.absoluteString))")
            }
            for key in item.metadata.keys.sorted() {
                guard let value = item.metadata[key] else { continue }
                lines.append("- \(markdownInline(key)): \(markdownInline(value))")
            }

            let fence = markdownFence(for: item.textRepresentation)
            lines.append("")
            lines.append("\(fence)text")
            lines.append(item.textRepresentation)
            lines.append(fence)
            sections.append(lines.joined(separator: "\n"))
        }

        let rendered = sections.joined(separator: "\n\n") + "\n"
        let renderedSize = rendered.utf8.count
        guard renderedSize <= limits.maximumRenderedUTF8Bytes else {
            throw ContextPackError.renderedSizeExceedsLimit(
                actual: renderedSize,
                maximum: limits.maximumRenderedUTF8Bytes
            )
        }
        return rendered
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case limits
        case items
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            name: container.decode(String.self, forKey: .name),
            items: container.decode([ContextPackItem].self, forKey: .items),
            limits: container.decode(ContextPackLimits.self, forKey: .limits)
        )
    }
}

public enum ContextPackError: Error, Equatable, LocalizedError, Sendable {
    case invalidLimits
    case emptyName
    case emptyItemTitle
    case emptyItemContent
    case duplicateItem(UUID)
    case invalidIndex(Int)
    case itemCountExceedsLimit(Int)
    case itemSizeExceedsLimit(itemID: UUID, actual: Int, maximum: Int)
    case renderedSizeExceedsLimit(actual: Int, maximum: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidLimits:
            "Combine Clips limits must be greater than zero."
        case .emptyName:
            "A combined collection name cannot be empty."
        case .emptyItemTitle:
            "A combined clip title cannot be empty."
        case .emptyItemContent:
            "A combined clip cannot have empty content."
        case let .duplicateItem(id):
            "Clip \(id) is already in Combine Clips."
        case let .invalidIndex(index):
            "Combine Clips index \(index) is out of range."
        case let .itemCountExceedsLimit(maximum):
            "Combine Clips cannot contain more than \(maximum) items."
        case let .itemSizeExceedsLimit(itemID, actual, maximum):
            "Combined clip \(itemID) is \(actual) bytes; the limit is \(maximum)."
        case let .renderedSizeExceedsLimit(actual, maximum):
            "The combined preview is \(actual) bytes; the limit is \(maximum)."
        }
    }
}

private func iso8601String(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: date)
}

private func markdownHeading(_ value: String) -> String {
    markdownInline(value).replacingOccurrences(of: "#", with: "\\#")
}

private func markdownInline(_ value: String) -> String {
    value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "`", with: "\\`")
        .replacingOccurrences(of: "\r\n", with: " ")
        .replacingOccurrences(of: "\r", with: " ")
        .replacingOccurrences(of: "\n", with: " ")
}

private func markdownFence(for value: String) -> String {
    var maximumRun = 0
    var currentRun = 0
    for character in value {
        if character == "`" {
            currentRun += 1
            maximumRun = max(maximumRun, currentRun)
        } else {
            currentRun = 0
        }
    }
    return String(repeating: "`", count: max(3, maximumRun + 1))
}
