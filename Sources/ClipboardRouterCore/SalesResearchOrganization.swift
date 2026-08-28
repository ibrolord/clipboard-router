import Foundation

public struct ClipTag: Codable, Hashable, Sendable {
    public static let maximumCountPerItem = 20
    public static let maximumUTF8Bytes = 64

    public let displayName: String
    public let comparisonKey: String

    public init(_ rawValue: String) throws {
        let collapsed = rawValue
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !collapsed.isEmpty else {
            throw ClipTagValidationError.empty
        }
        guard collapsed.utf8.count <= Self.maximumUTF8Bytes else {
            throw ClipTagValidationError.tooLong(maximumUTF8Bytes: Self.maximumUTF8Bytes)
        }
        guard collapsed.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw ClipTagValidationError.containsControlCharacter
        }

        displayName = collapsed
        comparisonKey = collapsed.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    public static func normalize(_ candidates: [String]) throws -> [String] {
        guard candidates.count <= maximumCountPerItem else {
            throw ClipTagValidationError.tooMany(maximum: maximumCountPerItem)
        }
        var acceptedByKey: [String: ClipTag] = [:]
        for candidate in candidates {
            let tag = try ClipTag(candidate)
            if acceptedByKey[tag.comparisonKey] == nil {
                acceptedByKey[tag.comparisonKey] = tag
            }
        }
        guard acceptedByKey.count <= maximumCountPerItem else {
            throw ClipTagValidationError.tooMany(maximum: maximumCountPerItem)
        }
        return acceptedByKey.values
            .sorted { lhs, rhs in
                if lhs.comparisonKey != rhs.comparisonKey {
                    return lhs.comparisonKey < rhs.comparisonKey
                }
                return lhs.displayName < rhs.displayName
            }
            .map(\.displayName)
    }
}

public enum ClipTagValidationError: Error, Equatable, LocalizedError, Sendable {
    case empty
    case tooLong(maximumUTF8Bytes: Int)
    case containsControlCharacter
    case tooMany(maximum: Int)

    public var errorDescription: String? {
        switch self {
        case .empty:
            "Tags cannot be empty."
        case let .tooLong(maximum):
            "A tag cannot exceed \(maximum) UTF-8 bytes."
        case .containsControlCharacter:
            "Tags cannot contain control characters."
        case let .tooMany(maximum):
            "A saved item can have at most \(maximum) tags."
        }
    }
}

public struct FolderRecipe: Equatable, Sendable {
    public let rootName: String
    public let childNames: [String]

    public init(rootName: String, childNames: [String]) {
        self.rootName = rootName
        self.childNames = childNames
    }

    public static func salesWorkspace(named name: String) -> FolderRecipe {
        FolderRecipe(
            rootName: name,
            childNames: ["Accounts", "Messaging", "Competitors", "Unsorted"]
        )
    }
}

public struct CreatedFolderRecipe: Equatable, Sendable {
    public let root: ClipFolder
    public let children: [ClipFolder]

    public init(root: ClipFolder, children: [ClipFolder]) {
        self.root = root
        self.children = children
    }
}
