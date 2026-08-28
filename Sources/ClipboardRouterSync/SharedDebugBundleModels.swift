import ClipboardRouterCore
import Foundation

public struct SharedDebugBundleItem: Codable, Equatable, Sendable {
    public let title: String
    public let kind: DeveloperContentKind
    public let languageHint: String?
    public let content: String

    public init(
        title: String,
        kind: DeveloperContentKind,
        languageHint: String?,
        content: String
    ) throws {
        self.title = try SharedDebugBundleSanitizer.validatedLabel(title, maximumBytes: 500)
        self.kind = kind
        self.languageHint = try languageHint.map {
            try SharedDebugBundleSanitizer.validatedLabel($0, maximumBytes: 100)
        }
        self.content = try SharedDebugBundleSanitizer.validatedContent(content)
    }

    private enum CodingKeys: String, CodingKey { case title, kind, languageHint, content }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            title: container.decode(String.self, forKey: .title),
            kind: container.decode(DeveloperContentKind.self, forKey: .kind),
            languageHint: container.decodeIfPresent(String.self, forKey: .languageHint),
            content: container.decode(String.self, forKey: .content)
        )
    }
}

/// A deliberately portable, immutable publication. It contains no source IDs, source URLs,
/// application/device/location metadata, root paths, or security-scoped bookmark data. Receiving
/// it only adds a reviewable record to shared state; no flow, paste, process, or external app is
/// invoked.
public struct SharedDebugBundlePublication: Codable, Equatable, Identifiable, Sendable {
    public static let currentSchemaVersion = 1
    /// Leaves headroom for the enclosing 256 KiB shared-folder record and its Lamport metadata.
    public static let maximumEncodedBytes = 240 * 1_024
    public static let maximumItemCount = 100

    public let id: UUID
    public let schemaVersion: Int
    public let publishedAt: Date
    public let projectName: String
    public let branch: String?
    public let problemStatement: String?
    public let items: [SharedDebugBundleItem]

    public init(
        id: UUID = UUID(),
        schemaVersion: Int = currentSchemaVersion,
        publishedAt: Date,
        projectName: String,
        branch: String? = nil,
        problemStatement: String? = nil,
        items: [SharedDebugBundleItem]
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion,
              !items.isEmpty,
              items.count <= Self.maximumItemCount
        else {
            throw SharedDebugBundleError.invalidPublication
        }
        self.id = id
        self.schemaVersion = schemaVersion
        self.publishedAt = publishedAt
        self.projectName = try SharedDebugBundleSanitizer.validatedLabel(
            projectName,
            maximumBytes: 200
        )
        self.branch = try branch.map {
            try SharedDebugBundleSanitizer.validatedLabel($0, maximumBytes: 512)
        }
        self.problemStatement = try problemStatement.map {
            try SharedDebugBundleSanitizer.validatedContent($0, maximumBytes: 2_048)
        }
        self.items = items
        try Self.validateEncodedSize(self)
    }

    public init(
        sanitizing bundle: DebugBundle,
        includeBranch: Bool = false,
        publishedAt: Date = Date()
    ) throws {
        let items = try bundle.items.map { item in
            try SharedDebugBundleItem(
                title: SharedDebugBundleSanitizer.redactingLocalPaths(in: item.source.title),
                kind: item.analysis.kind,
                languageHint: item.analysis.languageHint,
                content: SharedDebugBundleSanitizer.redactingLocalPaths(
                    in: item.source.textRepresentation
                )
            )
        }
        try self.init(
            publishedAt: publishedAt,
            projectName: SharedDebugBundleSanitizer.redactingLocalPaths(
                in: bundle.project.name
            ),
            branch: includeBranch ? bundle.project.branch.map {
                SharedDebugBundleSanitizer.redactingLocalPaths(in: $0)
            } : nil,
            problemStatement: bundle.problemStatement.map {
                SharedDebugBundleSanitizer.redactingLocalPaths(in: $0)
            },
            items: items
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, schemaVersion, publishedAt, projectName, branch, problemStatement, items
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion),
            publishedAt: container.decode(Date.self, forKey: .publishedAt),
            projectName: container.decode(String.self, forKey: .projectName),
            branch: container.decodeIfPresent(String.self, forKey: .branch),
            problemStatement: container.decodeIfPresent(String.self, forKey: .problemStatement),
            items: container.decode([SharedDebugBundleItem].self, forKey: .items)
        )
    }

    private static func validateEncodedSize(_ publication: SharedDebugBundlePublication) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        guard try encoder.encode(publication).count <= Self.maximumEncodedBytes else {
            throw SharedDebugBundleError.publicationTooLarge
        }
    }
}

public enum SharedDebugBundleError: Error, Equatable, LocalizedError, Sendable {
    case invalidPublication
    case invalidText
    case containsLocalPath
    case publicationTooLarge

    public var errorDescription: String? {
        switch self {
        case .invalidPublication: "The shared Debug Bundle is invalid."
        case .invalidText: "The shared Debug Bundle contains invalid text."
        case .containsLocalPath: "Remove local file paths before sharing this Debug Bundle."
        case .publicationTooLarge: "The shared Debug Bundle exceeds the collaboration size limit."
        }
    }
}

enum SharedDebugBundleSanitizer {
    /// Sharing is deliberately privacy-biased: an unquoted local path consumes the remainder of
    /// its line. That can remove nearby diagnostic prose, but it prevents path suffixes containing
    /// spaces from surviving a partial regular-expression match.
    private static let quotedPathExpression = try! NSRegularExpression(
        pattern: #"([\"'`])(?:file://|/|~/|[A-Za-z]:\\|\\\\)[^\r\n]*?\1"#
    )
    private static let labeledPathExpression = try! NSRegularExpression(
        pattern: #"(?im)(\b(?!(?:https?|ftp):)[A-Za-z][A-Za-z0-9_-]{0,40}:[ \t]*)(?:file://|/|~/|[A-Za-z]:\\|\\\\)[^\r\n]*"#
    )
    private static let unquotedPathExpression = try! NSRegularExpression(
        pattern: #"(?m)(^|[\t =\(\[\{,])(?:file://|/|~/|[A-Za-z]:\\|\\\\)[^\r\n]*"#
    )

    static func redactingLocalPaths(in value: String) -> String {
        var result = value
        let quotedRange = NSRange(result.startIndex..<result.endIndex, in: result)
        result = quotedPathExpression.stringByReplacingMatches(
            in: result,
            range: quotedRange,
            withTemplate: "<redacted-local-path>"
        )
        for (expression, replacement) in [
            (labeledPathExpression, "$1<redacted-local-path>"),
            (unquotedPathExpression, "$1<redacted-local-path>"),
        ] {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = expression.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: replacement
            )
        }
        return result
    }

    static func validatedLabel(_ raw: String, maximumBytes: Int) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.utf8.count <= maximumBytes,
              value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { throw SharedDebugBundleError.invalidText }
        guard redactingLocalPaths(in: value) == value else {
            throw SharedDebugBundleError.containsLocalPath
        }
        return value
    }

    static func validatedContent(
        _ raw: String,
        maximumBytes: Int = 128 * 1_024
    ) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= maximumBytes,
              value.unicodeScalars.allSatisfy({ scalar in
                  !CharacterSet.controlCharacters.contains(scalar)
                      || scalar.value == 0x09
                      || scalar.value == 0x0A
              })
        else { throw SharedDebugBundleError.invalidText }
        guard redactingLocalPaths(in: value) == value else {
            throw SharedDebugBundleError.containsLocalPath
        }
        return value
    }
}
