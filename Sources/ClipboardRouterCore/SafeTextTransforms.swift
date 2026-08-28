import Foundation

public enum LineEndingStyle: String, Codable, Equatable, Sendable {
    case lineFeed
    case carriageReturnLineFeed
    case carriageReturn

    fileprivate var separator: String {
        switch self {
        case .lineFeed: "\n"
        case .carriageReturnLineFeed: "\r\n"
        case .carriageReturn: "\r"
        }
    }
}

/// Character-based offsets avoid splitting an extended Unicode grapheme cluster.
public struct TextRedactionRange: Equatable, Sendable {
    public let location: Int
    public let length: Int

    public init(location: Int, length: Int) throws {
        guard location >= 0, length > 0 else {
            throw SafeTextTransformError.invalidRedactionRange(location: location, length: length)
        }
        self.location = location
        self.length = length
    }
}

public enum SafeTextTransform: Equatable, Sendable {
    case plainText
    case trim
    case lineEndings(LineEndingStyle)
    case uppercase
    case lowercase
    case titleCase
    case quote
    case codeBlock(language: String?)
    case redact(ranges: [TextRedactionRange], replacement: String)
    case prettyJSON
    case stripANSI
    case urlDecode
}

/// Pure, deterministic, local-only transformations. Inputs are values and are never mutated.
public enum SafeTextTransformer {
    public static let maximumDeveloperTransformUTF8Bytes = 1 * 1_024 * 1_024

    public static func apply(_ transform: SafeTextTransform, to original: String) throws -> String {
        switch transform {
        case .plainText:
            return original
        case .trim:
            return original.trimmingCharacters(in: .whitespacesAndNewlines)
        case let .lineEndings(style):
            return normalizedLineFeeds(original).replacingOccurrences(
                of: "\n",
                with: style.separator
            )
        case .uppercase:
            return original.uppercased(with: stableLocale)
        case .lowercase:
            return original.lowercased(with: stableLocale)
        case .titleCase:
            return original.capitalized(with: stableLocale)
        case .quote:
            return normalizedLineFeeds(original)
                .components(separatedBy: "\n")
                .map { $0.isEmpty ? ">" : "> \($0)" }
                .joined(separator: "\n")
        case let .codeBlock(language):
            let language = try validatedLanguage(language)
            let fence = markdownFence(for: original)
            return "\(fence)\(language ?? "")\n\(original)\n\(fence)"
        case let .redact(ranges, replacement):
            return try redact(original, ranges: ranges, replacement: replacement)
        case .prettyJSON:
            try validateDeveloperTransformInput(original)
            return try validateDeveloperTransformOutput(prettyJSON(original))
        case .stripANSI:
            try validateDeveloperTransformInput(original)
            return try validateDeveloperTransformOutput(stripANSI(original))
        case .urlDecode:
            try validateDeveloperTransformInput(original)
            guard let decoded = original.removingPercentEncoding else {
                throw SafeTextTransformError.invalidPercentEncoding
            }
            return try validateDeveloperTransformOutput(decoded)
        }
    }

    public static func apply(
        _ transforms: [SafeTextTransform],
        to original: String
    ) throws -> String {
        try transforms.reduce(original) { value, transform in
            try apply(transform, to: value)
        }
    }
}

public enum SafeTextTransformError: Error, Equatable, LocalizedError, Sendable {
    case invalidRedactionRange(location: Int, length: Int)
    case redactionRangeOutOfBounds(location: Int, length: Int, characterCount: Int)
    case invalidCodeBlockLanguage(String)
    case invalidJSON
    case invalidPercentEncoding
    case developerTransformInputTooLarge(actual: Int, maximum: Int)
    case developerTransformOutputTooLarge(actual: Int, maximum: Int)

    public var errorDescription: String? {
        switch self {
        case let .invalidRedactionRange(location, length):
            "Redaction range (\(location), \(length)) must have a nonnegative location and positive length."
        case let .redactionRangeOutOfBounds(location, length, characterCount):
            "Redaction range (\(location), \(length)) exceeds \(characterCount) characters."
        case let .invalidCodeBlockLanguage(language):
            "Code-block language \(language) contains unsupported characters."
        case .invalidJSON:
            "The text is not valid JSON."
        case .invalidPercentEncoding:
            "The text contains invalid URL percent encoding."
        case let .developerTransformInputTooLarge(actual, maximum):
            "The transform input is \(actual) bytes; the limit is \(maximum) bytes."
        case let .developerTransformOutputTooLarge(actual, maximum):
            "The transform output is \(actual) bytes; the limit is \(maximum) bytes."
        }
    }
}

private let stableLocale = Locale(identifier: "en_US_POSIX")

private func normalizedLineFeeds(_ value: String) -> String {
    value
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
}

private func validatedLanguage(_ language: String?) throws -> String? {
    guard let language else { return nil }
    let normalized = language.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return nil }

    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_+-"))
    guard normalized.unicodeScalars.allSatisfy(allowed.contains) else {
        throw SafeTextTransformError.invalidCodeBlockLanguage(language)
    }
    return normalized
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

private func redact(
    _ original: String,
    ranges: [TextRedactionRange],
    replacement: String
) throws -> String {
    guard !ranges.isEmpty else { return original }

    let characters = Array(original)
    let sortedRanges = ranges.sorted {
        ($0.location, $0.length) < ($1.location, $1.length)
    }

    var mergedRanges: [Range<Int>] = []
    for range in sortedRanges {
        guard range.location <= characters.count,
              range.length <= characters.count - range.location
        else {
            throw SafeTextTransformError.redactionRangeOutOfBounds(
                location: range.location,
                length: range.length,
                characterCount: characters.count
            )
        }
        let upperBound = range.location + range.length

        let candidate = range.location ..< upperBound
        if let last = mergedRanges.last, candidate.lowerBound <= last.upperBound {
            mergedRanges[mergedRanges.count - 1] = last.lowerBound ..< max(
                last.upperBound,
                candidate.upperBound
            )
        } else {
            mergedRanges.append(candidate)
        }
    }

    var output = ""
    var cursor = 0
    for range in mergedRanges {
        output.append(contentsOf: characters[cursor ..< range.lowerBound])
        output.append(replacement)
        cursor = range.upperBound
    }
    output.append(contentsOf: characters[cursor...])
    return output
}

private func prettyJSON(_ original: String) throws -> String {
    guard let data = original.data(using: .utf8) else {
        throw SafeTextTransformError.invalidJSON
    }
    let value: Any
    do {
        value = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    } catch {
        throw SafeTextTransformError.invalidJSON
    }
    guard JSONSerialization.isValidJSONObject(value) else {
        // JSONSerialization can parse top-level fragments but cannot serialize them with stable
        // pretty-printing. Reject rather than silently changing their representation.
        throw SafeTextTransformError.invalidJSON
    }
    do {
        let rendered = try JSONSerialization.data(
            withJSONObject: value,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        guard let text = String(data: rendered, encoding: .utf8) else {
            throw SafeTextTransformError.invalidJSON
        }
        return text
    } catch let error as SafeTextTransformError {
        throw error
    } catch {
        throw SafeTextTransformError.invalidJSON
    }
}

private func validateDeveloperTransformInput(_ value: String) throws {
    let count = value.utf8.count
    let maximum = SafeTextTransformer.maximumDeveloperTransformUTF8Bytes
    guard count <= maximum else {
        throw SafeTextTransformError.developerTransformInputTooLarge(
            actual: count,
            maximum: maximum
        )
    }
}

private func validateDeveloperTransformOutput(_ value: String) throws -> String {
    let count = value.utf8.count
    let maximum = SafeTextTransformer.maximumDeveloperTransformUTF8Bytes
    guard count <= maximum else {
        throw SafeTextTransformError.developerTransformOutputTooLarge(
            actual: count,
            maximum: maximum
        )
    }
    return value
}

/// Removes common ANSI CSI/OSC control sequences with a bounded scalar state machine. Unknown
/// escape sequences consume only their introducer and one following scalar, preserving ordinary
/// text without invoking a regular-expression engine on untrusted logs.
private func stripANSI(_ original: String) -> String {
    enum State {
        case text
        case escape
        case controlSequence
        case operatingSystemCommand
        case operatingSystemCommandEscape
    }

    var state = State.text
    var output = String.UnicodeScalarView()
    for scalar in original.unicodeScalars {
        switch state {
        case .text:
            if scalar.value == 0x1B {
                state = .escape
            } else if scalar.value == 0x9B {
                state = .controlSequence
            } else {
                output.append(scalar)
            }
        case .escape:
            if scalar == "[" {
                state = .controlSequence
            } else if scalar == "]" {
                state = .operatingSystemCommand
            } else {
                state = .text
            }
        case .controlSequence:
            if (0x40...0x7E).contains(scalar.value) {
                state = .text
            }
        case .operatingSystemCommand:
            if scalar.value == 0x07 {
                state = .text
            } else if scalar.value == 0x1B {
                state = .operatingSystemCommandEscape
            }
        case .operatingSystemCommandEscape:
            state = scalar == "\\" ? .text : .operatingSystemCommand
        }
    }
    return String(output)
}
