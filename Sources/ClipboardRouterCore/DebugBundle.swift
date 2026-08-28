import Foundation

public struct DeveloperProjectContext: Codable, Equatable, Sendable {
    public let name: String
    public let rootLabel: String?
    public let branch: String?
    public let language: String?
    public let runtime: String?

    public init(
        name: String,
        rootLabel: String? = nil,
        branch: String? = nil,
        language: String? = nil,
        runtime: String? = nil
    ) throws {
        self.name = try Self.required(name, field: "project name", maximumBytes: 200)
        self.rootLabel = try Self.optional(rootLabel, field: "project root label", maximumBytes: 500)
        self.branch = try Self.optional(branch, field: "branch", maximumBytes: 200)
        self.language = try Self.optional(language, field: "language", maximumBytes: 100)
        self.runtime = try Self.optional(runtime, field: "runtime", maximumBytes: 100)
    }

    private enum CodingKeys: String, CodingKey {
        case name, rootLabel, branch, language, runtime
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            name: container.decode(String.self, forKey: .name),
            rootLabel: container.decodeIfPresent(String.self, forKey: .rootLabel),
            branch: container.decodeIfPresent(String.self, forKey: .branch),
            language: container.decodeIfPresent(String.self, forKey: .language),
            runtime: container.decodeIfPresent(String.self, forKey: .runtime)
        )
    }

    private static func required(
        _ raw: String,
        field: String,
        maximumBytes: Int
    ) throws -> String {
        guard let value = try optional(raw, field: field, maximumBytes: maximumBytes) else {
            throw DebugBundleError.invalidProjectField(field)
        }
        return value
    }

    private static func optional(
        _ raw: String?,
        field: String,
        maximumBytes: Int
    ) throws -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.utf8.count <= maximumBytes,
              value.rangeOfCharacter(from: .controlCharacters) == nil
        else { throw DebugBundleError.invalidProjectField(field) }
        return value
    }
}

public struct DebugBundleItem: Codable, Equatable, Identifiable, Sendable {
    public let source: ContextPackItem
    public let analysis: DeveloperContentAnalysis

    public var id: UUID { source.id }

    public init(source: ContextPackItem, analysis: DeveloperContentAnalysis) {
        self.source = source
        self.analysis = analysis
    }
}

/// An immutable, local value derived from an already reviewed ContextPack. This type deliberately
/// has no persistence, sync, Vault, pasteboard, process-execution, or network capability. Callers
/// remain responsible for applying the product's sensitivity policy before constructing a bundle.
public struct DebugBundle: Codable, Equatable, Identifiable, Sendable {
    public static let currentSchemaVersion = 1

    public let id: UUID
    public let schemaVersion: Int
    public let generatedAt: Date
    public let project: DeveloperProjectContext
    public let problemStatement: String?
    public let sourceContextPackID: UUID
    public let sourceContextPackName: String
    public let items: [DebugBundleItem]
    public let maximumRenderedUTF8Bytes: Int

    public init(
        id: UUID? = nil,
        schemaVersion: Int = currentSchemaVersion,
        generatedAt: Date,
        project: DeveloperProjectContext,
        problemStatement: String? = nil,
        sourceContextPackID: UUID,
        sourceContextPackName: String,
        items: [DebugBundleItem],
        maximumRenderedUTF8Bytes: Int
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw DebugBundleError.unsupportedSchemaVersion(schemaVersion)
        }
        guard !items.isEmpty else { throw DebugBundleError.emptyBundle }
        guard maximumRenderedUTF8Bytes > 0 else { throw DebugBundleError.invalidRenderLimit }
        let itemIDs = items.map(\.id)
        guard Set(itemIDs).count == itemIDs.count else { throw DebugBundleError.duplicateItem }
        self.id = id ?? sourceContextPackID
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.project = project
        self.problemStatement = try Self.validatedProblemStatement(problemStatement)
        self.sourceContextPackID = sourceContextPackID
        self.sourceContextPackName = sourceContextPackName
        self.items = items
        self.maximumRenderedUTF8Bytes = maximumRenderedUTF8Bytes
    }

    private enum CodingKeys: String, CodingKey {
        case id, schemaVersion, generatedAt, project, problemStatement
        case sourceContextPackID, sourceContextPackName
        case items, maximumRenderedUTF8Bytes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion),
            generatedAt: container.decode(Date.self, forKey: .generatedAt),
            project: container.decode(DeveloperProjectContext.self, forKey: .project),
            problemStatement: container.decodeIfPresent(String.self, forKey: .problemStatement),
            sourceContextPackID: container.decode(UUID.self, forKey: .sourceContextPackID),
            sourceContextPackName: container.decode(String.self, forKey: .sourceContextPackName),
            items: container.decode([DebugBundleItem].self, forKey: .items),
            maximumRenderedUTF8Bytes: container.decode(
                Int.self,
                forKey: .maximumRenderedUTF8Bytes
            )
        )
    }

    private static func validatedProblemStatement(_ raw: String?) throws -> String? {
        guard let raw else { return nil }
        guard raw.unicodeScalars.allSatisfy({ scalar in
            !CharacterSet.controlCharacters.contains(scalar) || scalar.value == 0x0A
        }) else { throw DebugBundleError.invalidProblemStatement }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.utf8.count <= 2_048
        else { throw DebugBundleError.invalidProblemStatement }
        return value
    }
}

public struct DebugBundleBuilder: Sendable {
    private let recognizer: DeveloperContentRecognizer

    public init(recognizer: DeveloperContentRecognizer = DeveloperContentRecognizer()) {
        self.recognizer = recognizer
    }

    public func build(
        project: DeveloperProjectContext,
        from pack: ContextPack,
        problemStatement: String? = nil,
        generatedAt: Date = Date()
    ) throws -> DebugBundle {
        let items = pack.items.map {
            DebugBundleItem(source: $0, analysis: recognizer.analyze($0.textRepresentation))
        }
        return try DebugBundle(
            generatedAt: generatedAt,
            project: project,
            problemStatement: problemStatement,
            sourceContextPackID: pack.id,
            sourceContextPackName: pack.name,
            items: items,
            maximumRenderedUTF8Bytes: pack.limits.maximumRenderedUTF8Bytes
        )
    }
}

public struct DebugBundleRenderer: Sendable {
    public init() {}

    public func renderMarkdown(_ bundle: DebugBundle) throws -> String {
        var lines = [
            "# Debug Bundle: \(heading(bundle.project.name))",
            "",
            "- Generated: `\(Self.timestamp(bundle.generatedAt))`",
            "- Source collection: \(inline(bundle.sourceContextPackName))",
            "- Items: \(bundle.items.count)",
        ]
        append(label: "Project root", value: bundle.project.rootLabel, to: &lines)
        append(label: "Branch", value: bundle.project.branch, to: &lines)
        append(label: "Language", value: bundle.project.language, to: &lines)
        append(label: "Runtime", value: bundle.project.runtime, to: &lines)
        if let problemStatement = bundle.problemStatement {
            let fence = markdownFence(for: problemStatement)
            lines.append(contentsOf: [
                "",
                "## Problem",
                "",
                "\(fence)text",
                problemStatement,
                fence,
            ])
        }

        for (index, item) in bundle.items.enumerated() {
            lines.append(contentsOf: [
                "",
                "## \(index + 1). \(heading(item.source.title))",
                "",
                "- Recognition: `\(item.analysis.kind.rawValue)` (\(item.analysis.confidence)%)",
            ])
            append(label: "Language hint", value: item.analysis.languageHint, to: &lines)
            append(label: "Source application", value: item.source.sourceApplication, to: &lines)
            append(label: "Source URL", value: item.source.sourceURL?.absoluteString, to: &lines)
            if let capturedAt = item.source.capturedAt {
                lines.append("- Captured: `\(Self.timestamp(capturedAt))`")
            }
            for key in item.source.metadata.keys.sorted() {
                guard let value = item.source.metadata[key] else { continue }
                lines.append("- \(inline(key)): \(inline(value))")
            }
            let fence = markdownFence(for: item.source.textRepresentation)
            let language = item.analysis.languageHint ?? "text"
            lines.append(contentsOf: [
                "",
                "\(fence)\(language)",
                item.source.textRepresentation,
                fence,
            ])
        }

        let rendered = lines.joined(separator: "\n") + "\n"
        guard rendered.utf8.count <= bundle.maximumRenderedUTF8Bytes else {
            throw DebugBundleError.renderedSizeExceedsLimit(
                actual: rendered.utf8.count,
                maximum: bundle.maximumRenderedUTF8Bytes
            )
        }
        return rendered
    }

    public func renderJSON(_ bundle: DebugBundle) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(bundle)
        guard data.count <= bundle.maximumRenderedUTF8Bytes else {
            throw DebugBundleError.renderedSizeExceedsLimit(
                actual: data.count,
                maximum: bundle.maximumRenderedUTF8Bytes
            )
        }
        return data
    }

    private func append(label: String, value: String?, to lines: inout [String]) {
        guard let value else { return }
        lines.append("- \(label): \(inline(value))")
    }

    private func heading(_ value: String) -> String {
        inline(value)
    }

    private func inline(_ value: String) -> String {
        let flattened = value
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\u{000B}", with: " ")
            .replacingOccurrences(of: "\u{000C}", with: " ")
            .replacingOccurrences(of: "\u{0085}", with: " ")
            .replacingOccurrences(of: "\u{2028}", with: " ")
            .replacingOccurrences(of: "\u{2029}", with: " ")
        let markdownMetacharacters = CharacterSet(charactersIn: "\\`*_{}[]()<>#+-.!|>~")
        var escaped = String.UnicodeScalarView()
        for scalar in flattened.unicodeScalars {
            if markdownMetacharacters.contains(scalar) {
                escaped.append("\\")
            }
            escaped.append(scalar)
        }
        return String(escaped)
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

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}

public enum DebugBundleError: Error, Equatable, LocalizedError, Sendable {
    case invalidProjectField(String)
    case invalidProblemStatement
    case emptyBundle
    case duplicateItem
    case invalidRenderLimit
    case unsupportedSchemaVersion(Int)
    case renderedSizeExceedsLimit(actual: Int, maximum: Int)

    public var errorDescription: String? {
        switch self {
        case let .invalidProjectField(field):
            "The \(field) is empty, too long, or contains control characters."
        case .invalidProblemStatement:
            "The problem statement is empty, too long, or contains unsupported control characters."
        case .emptyBundle:
            "A Debug Bundle needs at least one reviewed item."
        case .duplicateItem:
            "A Debug Bundle cannot contain the same item more than once."
        case .invalidRenderLimit:
            "The Debug Bundle render limit must be positive."
        case let .unsupportedSchemaVersion(version):
            "Debug Bundle schema version \(version) is not supported."
        case let .renderedSizeExceedsLimit(actual, maximum):
            "The Debug Bundle is \(actual) bytes; the limit is \(maximum) bytes."
        }
    }
}
