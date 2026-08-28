import Foundation

public enum DetectedClipEntityKind: String, Codable, CaseIterable, Sendable {
    case webURL
    case emailAddress
    case phoneNumber
    case date

    public var displayName: String {
        switch self {
        case .webURL: "Link"
        case .emailAddress: "Email"
        case .phoneNumber: "Phone"
        case .date: "Date"
        }
    }
}

public struct DetectedClipEntity: Identifiable, Equatable, Sendable {
    public let id: String
    public let kind: DetectedClipEntityKind
    public let displayValue: String
    public let normalizedValue: String
    public let date: Date?
    public let duration: TimeInterval?
    public let timeZoneIdentifier: String?
    public let utf16Range: NSRange

    public init(
        kind: DetectedClipEntityKind,
        displayValue: String,
        normalizedValue: String,
        date: Date? = nil,
        duration: TimeInterval? = nil,
        timeZoneIdentifier: String? = nil,
        utf16Range: NSRange
    ) {
        self.kind = kind
        self.displayValue = displayValue
        self.normalizedValue = normalizedValue
        self.date = date
        self.duration = duration
        self.timeZoneIdentifier = timeZoneIdentifier
        self.utf16Range = utf16Range
        id = "\(kind.rawValue):\(utf16Range.location):\(utf16Range.length):\(normalizedValue)"
    }
}

/// Finds actionable values without changing or persisting the source clip. Data detection is a
/// suggestion surface, not validation; executors must still validate a target before opening it.
public struct ActionableClipDetector: Sendable {
    public static let maximumInputUTF8Bytes = 64 * 1_024
    public static let maximumEntities = 20

    public init() {}

    public func detect(in text: String) -> [DetectedClipEntity] {
        guard !text.isEmpty, text.utf8.count <= Self.maximumInputUTF8Bytes else { return [] }

        let checkingTypes = NSTextCheckingResult.CheckingType.link.rawValue
            | NSTextCheckingResult.CheckingType.phoneNumber.rawValue
            | NSTextCheckingResult.CheckingType.date.rawValue
        guard let detector = try? NSDataDetector(types: checkingTypes) else { return [] }

        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        var seen = Set<String>()
        var entities: [DetectedClipEntity] = []

        detector.enumerateMatches(in: text, range: fullRange) { result, _, stop in
            guard let result,
                  let range = Range(result.range, in: text)
            else { return }
            let displayValue = String(text[range])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !displayValue.isEmpty else { return }

            let entity: DetectedClipEntity?
            switch result.resultType {
            case .link:
                entity = Self.linkEntity(
                    result: result,
                    displayValue: displayValue,
                    range: result.range
                )
            case .phoneNumber:
                entity = Self.phoneEntity(
                    result: result,
                    displayValue: displayValue,
                    range: result.range
                )
            case .date:
                entity = Self.dateEntity(
                    result: result,
                    displayValue: displayValue,
                    range: result.range
                )
            default:
                entity = nil
            }

            guard let entity else { return }
            let deduplicationKey = "\(entity.kind.rawValue):\(entity.normalizedValue)"
            guard seen.insert(deduplicationKey).inserted else { return }
            entities.append(entity)
            if entities.count >= Self.maximumEntities { stop.pointee = true }
        }

        return entities.sorted {
            if $0.utf16Range.location != $1.utf16Range.location {
                return $0.utf16Range.location < $1.utf16Range.location
            }
            return $0.kind.rawValue < $1.kind.rawValue
        }
    }

    private static func linkEntity(
        result: NSTextCheckingResult,
        displayValue: String,
        range: NSRange
    ) -> DetectedClipEntity? {
        guard let url = result.url,
              let scheme = url.scheme?.lowercased()
        else { return nil }

        if scheme == "mailto" {
            let encodedAddress = url.absoluteString
                .dropFirst("mailto:".count)
                .split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
                .first
                .map(String.init) ?? ""
            let address = (encodedAddress.removingPercentEncoding ?? encodedAddress)
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            guard isPlausibleEmail(address) else { return nil }
            let at = address.lastIndex(of: "@")!
            let localPart = address[..<at]
            let domain = address[address.index(after: at)...]
                .lowercased(with: Locale(identifier: "en_US_POSIX"))
            return DetectedClipEntity(
                kind: .emailAddress,
                displayValue: displayValue,
                normalizedValue: "\(localPart)@\(domain)",
                utf16Range: range
            )
        }

        guard ["http", "https"].contains(scheme),
              let host = url.host(),
              !host.isEmpty
        else { return nil }
        return DetectedClipEntity(
            kind: .webURL,
            displayValue: displayValue,
            normalizedValue: url.absoluteString,
            utf16Range: range
        )
    }

    private static func phoneEntity(
        result: NSTextCheckingResult,
        displayValue: String,
        range: NSRange
    ) -> DetectedClipEntity? {
        guard let observed = result.phoneNumber else { return nil }
        let leadingPlus = observed.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("+")
        let digits = observed.unicodeScalars.filter(CharacterSet.decimalDigits.contains).map(String.init)
            .joined()
        guard (7...15).contains(digits.count) else { return nil }
        let normalized = leadingPlus ? "+\(digits)" : digits
        return DetectedClipEntity(
            kind: .phoneNumber,
            displayValue: displayValue,
            normalizedValue: normalized,
            utf16Range: range
        )
    }

    private static func dateEntity(
        result: NSTextCheckingResult,
        displayValue: String,
        range: NSRange
    ) -> DetectedClipEntity? {
        guard let date = result.date else { return nil }
        return DetectedClipEntity(
            kind: .date,
            displayValue: displayValue,
            normalizedValue: ISO8601DateFormatter().string(from: date),
            date: date,
            duration: result.duration > 0 ? result.duration : nil,
            timeZoneIdentifier: result.timeZone?.identifier,
            utf16Range: range
        )
    }

    private static func isPlausibleEmail(_ value: String) -> Bool {
        guard !value.contains(where: \Character.isWhitespace),
              let at = value.lastIndex(of: "@"),
              at != value.startIndex
        else { return false }
        let domain = value[value.index(after: at)...]
        return domain.contains(".") && !domain.hasPrefix(".") && !domain.hasSuffix(".")
    }
}

public enum CustomClipTextMatchMode: String, Codable, CaseIterable, Sendable {
    case wordsOrPhrases
    case regularExpression

    public var displayName: String {
        switch self {
        case .wordsOrPhrases: "Words or phrases"
        case .regularExpression: "Regular expression"
        }
    }
}

/// A bounded, local-only text condition used to decide whether an action is eligible.
/// It never changes the clip and is revalidated whenever a persisted action is decoded.
public struct CustomClipTextMatcher: Codable, Equatable, Hashable, Sendable {
    public static let maximumPatternUTF8Bytes = 256
    public static let maximumInputUTF8Bytes = 8 * 1_024
    public static let maximumLiteralCount = 20
    public static let maximumLiteralUTF8Bytes = 80

    public let mode: CustomClipTextMatchMode
    public let pattern: String
    public let isCaseSensitive: Bool

    public init(
        mode: CustomClipTextMatchMode,
        pattern: String,
        isCaseSensitive: Bool = false
    ) throws {
        let normalized = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.utf8.count <= Self.maximumPatternUTF8Bytes,
              normalized.rangeOfCharacter(from: .controlCharacters) == nil
        else { throw CustomClipTextMatcherError.invalidPattern }

        switch mode {
        case .wordsOrPhrases:
            let literals = Self.literals(in: normalized)
            guard !literals.isEmpty,
                  literals.count <= Self.maximumLiteralCount,
                  literals.allSatisfy({ !$0.isEmpty && $0.utf8.count <= Self.maximumLiteralUTF8Bytes })
            else { throw CustomClipTextMatcherError.invalidPattern }
        case .regularExpression:
            guard !Self.usesUnsupportedRegexFeature(normalized),
                  !Self.hasUnsafeQuantifierStructure(normalized),
                  (try? NSRegularExpression(pattern: normalized)) != nil
            else { throw CustomClipTextMatcherError.unsafeRegularExpression }
        }

        self.mode = mode
        self.pattern = normalized
        self.isCaseSensitive = isCaseSensitive
    }

    public func matches(_ text: String) -> Bool {
        guard !text.isEmpty, text.utf8.count <= Self.maximumInputUTF8Bytes else { return false }
        switch mode {
        case .wordsOrPhrases:
            let options: String.CompareOptions = isCaseSensitive
                ? []
                : [.caseInsensitive, .diacriticInsensitive]
            let locale = Locale(identifier: "en_US_POSIX")
            return Self.literals(in: pattern).contains {
                text.range(of: $0, options: options, range: nil, locale: locale) != nil
            }
        case .regularExpression:
            let options: NSRegularExpression.Options = isCaseSensitive ? [] : [.caseInsensitive]
            guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else {
                return false
            }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            return expression.firstMatch(in: text, range: range) != nil
        }
    }

    public var summary: String {
        switch mode {
        case .wordsOrPhrases: "Contains \(Self.literals(in: pattern).joined(separator: ", "))"
        case .regularExpression: "Matches /\(pattern)/"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case mode, pattern, isCaseSensitive
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            mode: container.decode(CustomClipTextMatchMode.self, forKey: .mode),
            pattern: container.decode(String.self, forKey: .pattern),
            isCaseSensitive: container.decode(Bool.self, forKey: .isCaseSensitive)
        )
    }

    private static func literals(in pattern: String) -> [String] {
        pattern.split(separator: ",", omittingEmptySubsequences: false).map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func usesUnsupportedRegexFeature(_ pattern: String) -> Bool {
        if pattern.contains("(?") { return true }
        return (1...9).contains { pattern.contains("\\\($0)") }
    }

    /// Accept only a conservative repetition subset before handing a user-authored pattern to
    /// ICU. Nested/alternating repeated groups and multiple variable repetitions can create an
    /// exponential number of paths (for example `(a*)(a*)...b`). Fixed-width repetitions remain
    /// useful for IDs and dates without introducing that ambiguity.
    private static func hasUnsafeQuantifierStructure(_ pattern: String) -> Bool {
        let characters = Array(pattern)
        var groupState: [(containsQuantifier: Bool, containsAlternation: Bool)] = []
        var variableQuantifierCount = 0
        var totalQuantifierCount = 0
        var alternationCount = 0
        var escaped = false
        var isInsideCharacterClass = false

        for index in characters.indices {
            let character = characters[index]
            if escaped {
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
                continue
            }
            if isInsideCharacterClass {
                if character == "]" { isInsideCharacterClass = false }
                continue
            }
            if character == "[" {
                isInsideCharacterClass = true
                continue
            }
            if character == "(" {
                groupState.append((false, false))
                continue
            }
            if character == "|" {
                alternationCount += 1
                guard alternationCount <= 8 else { return true }
                if !groupState.isEmpty {
                    groupState[groupState.count - 1].containsAlternation = true
                }
                continue
            }
            if character == ")" {
                let contained = groupState.popLast() ?? (false, false)
                let nextIndex = characters.index(after: index)
                let groupIsQuantified = nextIndex < characters.endIndex
                    && isQuantifierStart(characters[nextIndex])
                if groupIsQuantified,
                   contained.containsQuantifier || contained.containsAlternation
                {
                    return true
                }
                if !groupState.isEmpty,
                   contained.containsQuantifier || contained.containsAlternation || groupIsQuantified
                {
                    groupState[groupState.count - 1].containsQuantifier = true
                }
                continue
            }
            if isQuantifierStart(character) {
                totalQuantifierCount += 1
                guard totalQuantifierCount <= 16 else { return true }

                switch quantifierSafety(startingAt: index, in: characters) {
                case .invalidOrExcessive:
                    return true
                case .variable:
                    variableQuantifierCount += 1
                    guard variableQuantifierCount <= 1 else { return true }
                case .fixed:
                    break
                }

                if !groupState.isEmpty {
                    groupState[groupState.count - 1].containsQuantifier = true
                }
            }
        }
        return false
    }

    private enum QuantifierSafety {
        case fixed
        case variable
        case invalidOrExcessive
    }

    private static func quantifierSafety(
        startingAt index: Int,
        in characters: [Character]
    ) -> QuantifierSafety {
        switch characters[index] {
        case "*", "+", "?":
            return .variable
        case "{":
            guard let closingIndex = characters[index...].firstIndex(of: "}") else {
                return .invalidOrExcessive
            }
            let bodyStart = characters.index(after: index)
            let body = String(characters[bodyStart..<closingIndex])
            let fields = body.split(separator: ",", omittingEmptySubsequences: false)
            guard (1...2).contains(fields.count),
                  let lowerBound = Int(fields[0]),
                  lowerBound >= 0,
                  lowerBound <= 256
            else { return .invalidOrExcessive }

            guard fields.count == 2 else { return .fixed }
            guard !fields[1].isEmpty else { return .variable }
            guard let upperBound = Int(fields[1]),
                  upperBound >= lowerBound,
                  upperBound <= 256
            else { return .invalidOrExcessive }
            return lowerBound == upperBound ? .fixed : .variable
        default:
            return .invalidOrExcessive
        }
    }

    private static func isQuantifierStart(_ character: Character) -> Bool {
        character == "*" || character == "+" || character == "?" || character == "{"
    }
}

public enum CustomClipTextMatcherError: Error, Equatable, LocalizedError, Sendable {
    case invalidPattern
    case unsafeRegularExpression

    public var errorDescription: String? {
        switch self {
        case .invalidPattern:
            "Enter 1–20 comma-separated words or phrases, or a pattern up to 256 bytes."
        case .unsafeRegularExpression:
            "Use a valid bounded regular expression with at most one variable repetition and no lookarounds, backreferences, or nested quantifiers."
        }
    }
}

public enum ClipAutomationEntityFilter: String, Codable, CaseIterable, Sendable {
    case any
    case link
    case email
    case phone
    case date
    case customText

    public var displayName: String {
        switch self {
        case .any: "Any clip"
        case .link: "Clips with a link"
        case .email: "Clips with an email"
        case .phone: "Clips with a phone number"
        case .date: "Clips with a date"
        case .customText: "Custom words or pattern"
        }
    }

    public func matches(_ entities: [DetectedClipEntity]) -> Bool {
        matches(entities, clipText: "", customMatcher: nil)
    }

    public func matches(
        _ entities: [DetectedClipEntity],
        clipText: String,
        customMatcher: CustomClipTextMatcher?
    ) -> Bool {
        switch self {
        case .any: true
        case .link: entities.contains { $0.kind == .webURL }
        case .email: entities.contains { $0.kind == .emailAddress }
        case .phone: entities.contains { $0.kind == .phoneNumber }
        case .date: entities.contains { $0.kind == .date }
        case .customText: customMatcher?.matches(clipText) == true
        }
    }
}

public enum ClipAutomationTarget: Codable, Equatable, Sendable {
    case webURLTemplate(String)
    case application(bookmarkData: Data, displayName: String)
}

public struct ClipAutomation: Codable, Equatable, Identifiable, Sendable {
    public static let maximumNameUTF8Bytes = 80

    public let id: UUID
    public var name: String
    public var isEnabled: Bool
    public var entityFilter: ClipAutomationEntityFilter
    public var customMatcher: CustomClipTextMatcher?
    public var requiredFolderID: UUID?
    public var target: ClipAutomationTarget

    public init(
        id: UUID = UUID(),
        name: String,
        isEnabled: Bool = true,
        entityFilter: ClipAutomationEntityFilter = .any,
        customMatcher: CustomClipTextMatcher? = nil,
        requiredFolderID: UUID? = nil,
        target: ClipAutomationTarget
    ) throws {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty,
              normalizedName.utf8.count <= Self.maximumNameUTF8Bytes,
              normalizedName.rangeOfCharacter(from: .controlCharacters) == nil
        else { throw ClipAutomationError.invalidName }
        let validatedTarget: ClipAutomationTarget
        switch target {
        case let .webURLTemplate(template):
            _ = try AutomationURLTemplate(template)
            validatedTarget = .webURLTemplate(template)
        case let .application(bookmarkData, displayName):
            let normalizedDisplayName = displayName.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !bookmarkData.isEmpty,
                  !normalizedDisplayName.isEmpty,
                  normalizedDisplayName.utf8.count <= Self.maximumNameUTF8Bytes,
                  normalizedDisplayName.rangeOfCharacter(from: .controlCharacters) == nil
            else { throw ClipAutomationError.invalidApplicationTarget }
            validatedTarget = .application(
                bookmarkData: bookmarkData,
                displayName: normalizedDisplayName
            )
        }
        self.id = id
        self.name = normalizedName
        self.isEnabled = isEnabled
        self.entityFilter = entityFilter
        if entityFilter == .customText {
            guard let customMatcher else { throw ClipAutomationError.invalidCustomMatcher }
            self.customMatcher = customMatcher
        } else {
            self.customMatcher = nil
        }
        self.requiredFolderID = requiredFolderID
        self.target = validatedTarget
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, isEnabled, entityFilter, customMatcher, requiredFolderID, target
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            name: container.decode(String.self, forKey: .name),
            isEnabled: container.decode(Bool.self, forKey: .isEnabled),
            entityFilter: container.decode(ClipAutomationEntityFilter.self, forKey: .entityFilter),
            customMatcher: container.decodeIfPresent(CustomClipTextMatcher.self, forKey: .customMatcher),
            requiredFolderID: container.decodeIfPresent(UUID.self, forKey: .requiredFolderID),
            target: container.decode(ClipAutomationTarget.self, forKey: .target)
        )
    }

    public func applies(
        to entities: [DetectedClipEntity],
        clipText: String = "",
        folderID: UUID?
    ) -> Bool {
        isEnabled
            && entityFilter.matches(entities, clipText: clipText, customMatcher: customMatcher)
            && (requiredFolderID == nil || requiredFolderID == folderID)
    }
}

public struct AutomationURLTemplate: Equatable, Sendable {
    public static let supportedPlaceholders = ["{clip}", "{url}", "{email}", "{phone}"]
    public let rawValue: String

    public init(_ rawValue: String) throws {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.utf8.count <= 2_048,
              let components = URLComponents(string: normalized),
              let scheme = components.scheme?.lowercased(),
              scheme == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              Self.supportedPlaceholders.contains(where: normalized.contains)
        else { throw ClipAutomationError.invalidURLTemplate }
        self.rawValue = normalized
    }

    public func render(
        clipText: String,
        entities: [DetectedClipEntity]
    ) throws -> URL {
        let replacements = [
            "{clip}": clipText,
            "{url}": entities.first { $0.kind == .webURL }?.normalizedValue ?? "",
            "{email}": entities.first { $0.kind == .emailAddress }?.normalizedValue ?? "",
            "{phone}": entities.first { $0.kind == .phoneNumber }?.normalizedValue ?? "",
        ]
        var rendered = rawValue
        for (placeholder, value) in replacements {
            rendered = rendered.replacingOccurrences(
                of: placeholder,
                with: Self.queryValue(value)
            )
        }
        guard let url = URL(string: rendered),
              let scheme = url.scheme?.lowercased(),
              scheme == "https",
              url.host()?.isEmpty == false,
              url.user() == nil,
              url.password() == nil
        else { throw ClipAutomationError.invalidRenderedURL }
        return url
    }

    private static func queryValue(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}

public enum ClipAutomationError: Error, Equatable, LocalizedError, Sendable {
    case invalidName
    case invalidURLTemplate
    case invalidRenderedURL
    case invalidApplicationTarget
    case invalidCustomMatcher

    public var errorDescription: String? {
        switch self {
        case .invalidName:
            "Give the automation a name between 1 and 80 bytes."
        case .invalidURLTemplate:
            "Use an HTTPS URL containing {clip}, {url}, {email}, or {phone}."
        case .invalidRenderedURL:
            "This automation could not produce a safe web URL for the selected clip."
        case .invalidApplicationTarget:
            "Choose a valid signed macOS application for this automation."
        case .invalidCustomMatcher:
            "Add a valid custom text condition before saving this automation."
        }
    }
}
