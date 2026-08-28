import Foundation

public struct TextExpansionDefinition: Equatable, Sendable {
    public let aliasID: UUID
    public let trigger: String
    public let replacement: String

    public init(aliasID: UUID, trigger: String, replacement: String) {
        self.aliasID = aliasID
        self.trigger = trigger.precomposedStringWithCanonicalMapping.lowercased()
        self.replacement = replacement
    }
}

public struct TextExpansionMatch: Equatable, Sendable {
    public let definition: TextExpansionDefinition
    public let delimiter: Character
    public init(definition: TextExpansionDefinition, delimiter: Character) {
        self.definition = definition
        self.delimiter = delimiter
    }
    /// AX text ranges are expressed in UTF-16 code units, not Swift grapheme clusters.
    public var replacedUTF16Length: Int {
        definition.trigger.utf16.count + String(delimiter).utf16.count
    }
}

public struct TextExpansionMatcher: Sendable {
    public static let maximumTokenCharacters = InsertAlias.maximumAbbreviationLength + 1
    public static let tokenTimeout: TimeInterval = 3

    private var token = ""
    private var lastInputAt: Date?
    private var contextID: String?
    private var mayStartTrigger = true

    public init() {}

    public mutating func consume(
        _ character: Character,
        at date: Date,
        contextID newContextID: String,
        mayStartAtContextChange: Bool = true,
        definitions: [TextExpansionDefinition]
    ) -> TextExpansionMatch? {
        if contextID != newContextID {
            reset(contextID: newContextID, mayStartTrigger: mayStartAtContextChange)
        } else if lastInputAt.map({ date.timeIntervalSince($0) > Self.tokenTimeout }) == true {
            reset(contextID: newContextID, mayStartTrigger: token.isEmpty && mayStartTrigger)
        }
        contextID = newContextID
        lastInputAt = date

        if Self.delimiters.contains(character) {
            defer { reset(contextID: newContextID, mayStartTrigger: true) }
            guard token.hasPrefix(";") else { return nil }
            return definitions
                .filter { $0.trigger == token.lowercased() }
                .sorted {
                    if $0.trigger.count != $1.trigger.count {
                        return $0.trigger.count > $1.trigger.count
                    }
                    return $0.aliasID.uuidString < $1.aliasID.uuidString
                }
                .first
                .map { TextExpansionMatch(definition: $0, delimiter: character) }
        }

        guard character != "\u{1b}" else {
            reset(contextID: newContextID, mayStartTrigger: false)
            return nil
        }
        if character.isWhitespace || character.isPunctuation && character != ";" {
            reset(contextID: newContextID, mayStartTrigger: true)
            return nil
        }
        if character == ";", token.isEmpty, !mayStartTrigger { return nil }
        if token.isEmpty, character != ";" {
            mayStartTrigger = false
            return nil
        }
        token.append(character)
        if token.count > Self.maximumTokenCharacters {
            reset(contextID: newContextID, mayStartTrigger: false)
        }
        return nil
    }

    public mutating func reset(
        contextID: String? = nil,
        mayStartTrigger: Bool = true
    ) {
        token.removeAll(keepingCapacity: true)
        lastInputAt = nil
        self.contextID = contextID
        self.mayStartTrigger = mayStartTrigger
    }

    private static let delimiters: Set<Character> = [" ", "\t", "\n"]
}
