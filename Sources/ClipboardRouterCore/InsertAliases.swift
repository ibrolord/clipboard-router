import Foundation

public enum InsertAliasDelivery: String, Codable, CaseIterable, Identifiable, Sendable {
    case copy
    case pasteIntoFrontmostApplication

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .copy: "Copy"
        case .pasteIntoFrontmostApplication: "Paste into previous app"
        }
    }
}

public enum InsertAliasError: Error, Equatable, LocalizedError, Sendable {
    case invalidAbbreviation
    case invalidName

    public var errorDescription: String? {
        switch self {
        case .invalidAbbreviation:
            "Use 2–32 letters, numbers, hyphens, or underscores after the semicolon."
        case .invalidName:
            "Give this insert shortcut a name between 1 and 80 characters."
        }
    }
}

public struct InsertAlias: Identifiable, Codable, Equatable, Sendable {
    public static let maximumAbbreviationLength = 32
    public static let maximumNameUTF8Bytes = 80

    public let id: UUID
    public var name: String
    public var abbreviation: String
    public let savedClipID: UUID
    public var delivery: InsertAliasDelivery

    public init(
        id: UUID = UUID(),
        name: String,
        abbreviation: String,
        savedClipID: UUID,
        delivery: InsertAliasDelivery = .copy
    ) throws {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty,
              normalizedName.utf8.count <= Self.maximumNameUTF8Bytes,
              normalizedName.rangeOfCharacter(from: .controlCharacters) == nil
        else { throw InsertAliasError.invalidName }

        let normalizedAbbreviation = Self.normalize(abbreviation)
        guard (2...Self.maximumAbbreviationLength).contains(normalizedAbbreviation.count),
              normalizedAbbreviation.allSatisfy({
                  $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_"
              })
        else { throw InsertAliasError.invalidAbbreviation }

        self.id = id
        self.name = normalizedName
        self.abbreviation = normalizedAbbreviation
        self.savedClipID = savedClipID
        self.delivery = delivery
    }

    public var trigger: String { ";\(abbreviation)" }

    public static func normalize(_ rawValue: String) -> String {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix(";") { value.removeFirst() }
        return value.precomposedStringWithCanonicalMapping
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, abbreviation, savedClipID, delivery
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            name: container.decode(String.self, forKey: .name),
            abbreviation: container.decode(String.self, forKey: .abbreviation),
            savedClipID: container.decode(UUID.self, forKey: .savedClipID),
            delivery: container.decode(InsertAliasDelivery.self, forKey: .delivery)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(abbreviation, forKey: .abbreviation)
        try container.encode(savedClipID, forKey: .savedClipID)
        try container.encode(delivery, forKey: .delivery)
    }
}
