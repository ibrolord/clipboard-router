import Foundation

public enum DeveloperContentKind: String, Codable, CaseIterable, Sendable {
    case sourceCode
    case log
    case error
    case stackTrace
    case command
    case plainText
}

public enum DeveloperContentSignal: String, Codable, CaseIterable, Sendable {
    case fencedCodeBlock
    case sourceSyntax
    case logTimestamp
    case logLevel
    case errorDiagnostic
    case stackFrame
    case tracebackHeader
    case shebang
    case shellPrompt
}

/// A bounded, deterministic hint about developer-oriented text. Recognition never changes the
/// source clip and is not a security, sensitivity, or correctness decision.
public struct DeveloperContentAnalysis: Codable, Equatable, Sendable {
    public let kind: DeveloperContentKind
    public let confidence: Int
    public let languageHint: String?
    public let signals: [DeveloperContentSignal]
    public let analyzedLineCount: Int
    public let inputWasTruncated: Bool

    public init(
        kind: DeveloperContentKind,
        confidence: Int,
        languageHint: String? = nil,
        signals: [DeveloperContentSignal] = [],
        analyzedLineCount: Int,
        inputWasTruncated: Bool
    ) {
        self.kind = kind
        self.confidence = min(100, max(0, confidence))
        self.languageHint = languageHint
        self.signals = Array(Set(signals)).sorted { $0.rawValue < $1.rawValue }
        self.analyzedLineCount = max(0, analyzedLineCount)
        self.inputWasTruncated = inputWasTruncated
    }
}

public struct DeveloperContentRecognizer: Sendable {
    public static let maximumInputUTF8Bytes = 256 * 1_024
    public static let maximumAnalyzedLines = 4_000

    public init() {}

    public func analyze(_ text: String) -> DeveloperContentAnalysis {
        let bounded = Self.boundedSample(text)
        let allLines = bounded.value.components(separatedBy: .newlines)
        let lines = Array(allLines.prefix(Self.maximumAnalyzedLines))
        let wasTruncated = bounded.wasTruncated || allLines.count > lines.count

        guard !bounded.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return DeveloperContentAnalysis(
                kind: .plainText,
                confidence: 100,
                analyzedLineCount: lines.count,
                inputWasTruncated: wasTruncated
            )
        }

        var signals = Set<DeveloperContentSignal>()
        var stackFrameCount = 0
        var timestampCount = 0
        var logLevelCount = 0
        var errorCount = 0
        var syntaxCount = 0
        var languageScores: [String: Int] = [:]
        let firstNonemptyLine = lines.first {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }?.trimmingCharacters(in: .whitespaces)
        let isShebangCommand = firstNonemptyLine?.hasPrefix("#!") == true
        let isPromptCommand = firstNonemptyLine.map(Self.hasShellPrompt) ?? false
        if isShebangCommand {
            signals.insert(.shebang)
            if let firstNonemptyLine {
                languageScores[Self.shebangLanguage(firstNonemptyLine), default: 0] += 5
            }
        }
        if isPromptCommand {
            signals.insert(.shellPrompt)
            languageScores["shell", default: 0] += 5
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lower = trimmed.lowercased(with: Locale(identifier: "en_US_POSIX"))

            if Self.isCodeFence(trimmed) {
                signals.insert(.fencedCodeBlock)
                if let fencedLanguage = Self.fencedLanguage(in: trimmed) {
                    languageScores[fencedLanguage, default: 0] += 4
                }
            }
            if Self.looksLikeTracebackHeader(lower) {
                signals.insert(.tracebackHeader)
                errorCount += 1
                languageScores["python", default: 0] += 2
            }
            if Self.looksLikeStackFrame(trimmed, lower: lower) {
                signals.insert(.stackFrame)
                stackFrameCount += 1
                Self.incrementStackLanguageScore(for: lower, scores: &languageScores)
            }
            if Self.startsWithTimestamp(trimmed) {
                signals.insert(.logTimestamp)
                timestampCount += 1
            }
            if Self.containsLogLevel(lower) {
                signals.insert(.logLevel)
                logLevelCount += 1
            }
            if Self.containsErrorDiagnostic(lower) {
                signals.insert(.errorDiagnostic)
                errorCount += 1
            }
            if let language = Self.sourceLanguageHint(for: trimmed, lower: lower) {
                signals.insert(.sourceSyntax)
                syntaxCount += 1
                languageScores[language, default: 0] += 1
            }
        }

        let kind: DeveloperContentKind
        let confidence: Int
        if isShebangCommand || isPromptCommand {
            kind = .command
            confidence = isShebangCommand ? 96 : 92
        } else if signals.contains(.tracebackHeader) || stackFrameCount >= 2 {
            kind = .stackTrace
            confidence = min(98, 78 + stackFrameCount * 4)
        } else if errorCount > 0 {
            kind = .error
            confidence = min(95, 68 + errorCount * 6 + stackFrameCount * 3)
        } else if timestampCount > 0, logLevelCount > 0 {
            kind = .log
            confidence = min(94, 65 + min(timestampCount, logLevelCount) * 5)
        } else if signals.contains(.fencedCodeBlock) || syntaxCount >= 2 {
            kind = .sourceCode
            confidence = signals.contains(.fencedCodeBlock)
                ? min(96, 82 + syntaxCount * 2)
                : min(90, 60 + syntaxCount * 5)
        } else {
            kind = .plainText
            confidence = 70
        }

        return DeveloperContentAnalysis(
            kind: kind,
            confidence: confidence,
            languageHint: Self.leadingLanguage(in: languageScores),
            signals: Array(signals),
            analyzedLineCount: lines.count,
            inputWasTruncated: wasTruncated
        )
    }

    private static func boundedSample(_ text: String) -> (value: String, wasTruncated: Bool) {
        guard text.utf8.count > maximumInputUTF8Bytes else { return (text, false) }
        var scalars = String.UnicodeScalarView()
        var byteCount = 0
        for scalar in text.unicodeScalars {
            let scalarBytes = scalar.utf8.count
            guard byteCount <= maximumInputUTF8Bytes - scalarBytes else { break }
            scalars.append(scalar)
            byteCount += scalarBytes
        }
        return (String(scalars), true)
    }

    private static func fencedLanguage(in line: String) -> String? {
        guard isCodeFence(line) else { return nil }
        let value = String(line.dropFirst(3))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
        guard !value.isEmpty,
              value.utf8.count <= 32,
              value.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_+-#")).contains($0)
              })
        else { return nil }
        return normalizedLanguage(value)
    }

    private static func isCodeFence(_ line: String) -> Bool {
        line.hasPrefix("```") || line.hasPrefix("~~~")
    }

    private static func hasShellPrompt(_ line: String) -> Bool {
        line.hasPrefix("$ ") || line.hasPrefix("% ") || line.hasPrefix("❯ ")
    }

    private static func shebangLanguage(_ line: String) -> String {
        let lower = line.lowercased(with: Locale(identifier: "en_US_POSIX"))
        if lower.contains("python") { return "python" }
        if lower.contains("node") || lower.contains("deno") || lower.contains("bun") {
            return "javascript"
        }
        if lower.contains("ruby") { return "ruby" }
        if lower.contains("perl") { return "perl" }
        return "shell"
    }

    private static func looksLikeTracebackHeader(_ lower: String) -> Bool {
        lower == "traceback (most recent call last):"
            || lower.hasPrefix("thread '") && lower.contains(" panicked at ")
    }

    private static func looksLikeStackFrame(_ line: String, lower: String) -> Bool {
        if lower.hasPrefix("at "), lower.contains(":"), lower.contains(")") { return true }
        if lower.hasPrefix("file \"") && lower.contains("\", line ") { return true }
        if lower.hasPrefix("#"), lower.contains(" 0x"), lower.contains(" in ") { return true }
        if lower.contains(".swift:"), lower.contains(": error:") { return true }
        if lower.contains(".java:"), lower.hasPrefix("at ") { return true }
        return line.hasPrefix("\t") && lower.trimmingCharacters(in: .whitespaces).hasPrefix("at ")
    }

    private static func startsWithTimestamp(_ line: String) -> Bool {
        let characters = Array(line.prefix(24))
        guard characters.count >= 8 else { return false }
        if characters.count >= 10,
           characters[0...3].allSatisfy(\.isNumber),
           characters[4] == "-",
           characters[5...6].allSatisfy(\.isNumber),
           characters[7] == "-",
           characters[8...9].allSatisfy(\.isNumber)
        {
            return true
        }
        return characters.count >= 8
            && characters[0...1].allSatisfy(\.isNumber)
            && characters[2] == ":"
            && characters[3...4].allSatisfy(\.isNumber)
            && characters[5] == ":"
            && characters[6...7].allSatisfy(\.isNumber)
    }

    private static func containsLogLevel(_ lower: String) -> Bool {
        let normalized = lower.map { $0.isLetter ? $0 : " " }
        let words = Set(String(normalized).split(separator: " ").map(String.init))
        return !words.isDisjoint(with: ["trace", "debug", "info", "warn", "warning", "error", "fatal"])
    }

    private static func containsErrorDiagnostic(_ lower: String) -> Bool {
        [
            "error:", "fatal:", "fatal error", "exception:", "unhandled exception",
            "panic:", "assertion failed", "failed with exit code", "segmentation fault",
        ].contains { lower.contains($0) }
    }

    private static func sourceLanguageHint(for line: String, lower: String) -> String? {
        if lower.hasPrefix("import "), lower.hasSuffix(";") { return "java" }
        if lower.hasPrefix("import ") || lower.hasPrefix("func ")
            || lower.hasPrefix("let ") || lower.hasPrefix("var ")
            || lower.hasPrefix("struct ") || lower.hasPrefix("protocol ")
        {
            return "swift"
        }
        if lower.hasPrefix("def ") || lower.hasPrefix("from ") && lower.contains(" import ") {
            return "python"
        }
        if lower.hasPrefix("const ") || lower.hasPrefix("function ")
            || lower.hasPrefix("export ") || lower.hasPrefix("interface ")
        {
            return lower.contains(": ") || lower.hasPrefix("interface ") ? "typescript" : "javascript"
        }
        if lower.hasPrefix("#include ") { return "c" }
        if lower.hasPrefix("package main") || lower.hasPrefix("func main(") { return "go" }
        if lower.hasPrefix("fn ") || lower.hasPrefix("pub fn ") || lower.hasPrefix("use ") {
            return "rust"
        }
        if line.hasSuffix(";"), line.contains("=") { return "code" }
        return nil
    }

    private static func incrementStackLanguageScore(
        for lower: String,
        scores: inout [String: Int]
    ) {
        if lower.contains(".swift:") { scores["swift", default: 0] += 2 }
        if lower.contains(".js:") || lower.contains(".mjs:") { scores["javascript", default: 0] += 2 }
        if lower.contains(".ts:") { scores["typescript", default: 0] += 2 }
        if lower.contains(".py\"") || lower.hasPrefix("file \"") { scores["python", default: 0] += 2 }
        if lower.contains(".java:") { scores["java", default: 0] += 2 }
    }

    private static func normalizedLanguage(_ raw: String) -> String {
        switch raw {
        case "js", "jsx": "javascript"
        case "ts", "tsx": "typescript"
        case "py": "python"
        case "rs": "rust"
        case "golang": "go"
        default: raw
        }
    }

    private static func leadingLanguage(in scores: [String: Int]) -> String? {
        scores.sorted {
            if $0.value != $1.value { return $0.value > $1.value }
            return $0.key < $1.key
        }.first?.key
    }
}
