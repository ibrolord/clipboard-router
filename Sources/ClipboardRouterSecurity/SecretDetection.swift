import ClipboardRouterCore
import Foundation

public enum SecretCategory: String, Codable, CaseIterable, Hashable, Sendable {
    case privateKey
    case awsAccessKey
    case openAIAPIKey
    case githubToken
    case slackToken
    case jsonWebToken
    case credentialURL
    case environmentAssignment
    case connectionString
    case paymentCard
}

public enum SecretConfidence: String, Codable, Hashable, Sendable {
    case medium
    case high

    fileprivate var rank: Int {
        switch self {
        case .medium: 0
        case .high: 1
        }
    }
}

/// A privacy-safe detection. The matched text and its location are deliberately omitted.
public struct SecretDetection: Codable, Equatable, Hashable, Sendable {
    public let category: SecretCategory
    public let confidence: SecretConfidence

    public init(category: SecretCategory, confidence: SecretConfidence) {
        self.category = category
        self.confidence = confidence
    }
}

/// Safe to pass to UI and analytics-free health reporting: it contains no source text.
public struct SecretScanResult: Codable, Equatable, Sendable {
    public let detections: [SecretDetection]

    public init(detections: [SecretDetection]) {
        var strongestByCategory: [SecretCategory: SecretConfidence] = [:]
        for detection in detections {
            if let current = strongestByCategory[detection.category],
               current.rank >= detection.confidence.rank
            {
                continue
            }
            strongestByCategory[detection.category] = detection.confidence
        }
        self.detections = strongestByCategory
            .map { SecretDetection(category: $0.key, confidence: $0.value) }
            .sorted { $0.category.rawValue < $1.category.rawValue }
    }

    public var containsSecret: Bool { !detections.isEmpty }

    public func contains(_ category: SecretCategory) -> Bool {
        detections.contains { $0.category == category }
    }

    public static let clear = SecretScanResult(detections: [])
}

/// A deterministic, local-only detector. It performs no logging, persistence, or networking.
public struct SecretDetector: Sendable {
    public init() {}

    /// Scans every in-memory searchable representation. Optional rich/HTML values must already
    /// be decoded to text by the caller; this detector never follows asset paths or reads files.
    public func scan(
        _ content: ClipContent,
        extractedRichText: String? = nil,
        extractedHTMLText: String? = nil
    ) -> SecretScanResult {
        let texts = [content.searchableText, extractedRichText, extractedHTMLText]
            .compactMap { value -> String? in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
        return SecretScanResult(
            detections: texts.flatMap { scan(text: $0).detections }
        )
    }

    public func scan(text: String) -> SecretScanResult {
        var detections: [SecretDetection] = []

        for rule in Self.tokenRules where containsNonPlaceholderMatch(rule.pattern, in: text) {
            detections.append(
                SecretDetection(category: rule.category, confidence: rule.confidence)
            )
        }

        if containsValidJWT(in: text) {
            detections.append(SecretDetection(category: .jsonWebToken, confidence: .high))
        }
        if containsCredentialURL(in: text) {
            detections.append(SecretDetection(category: .credentialURL, confidence: .high))
        }
        if containsSecretEnvironmentAssignment(in: text) {
            detections.append(
                SecretDetection(category: .environmentAssignment, confidence: .medium)
            )
        }
        if containsConnectionStringWithPassword(in: text) {
            detections.append(SecretDetection(category: .connectionString, confidence: .high))
        }
        if containsLuhnValidPaymentCard(in: text) {
            detections.append(SecretDetection(category: .paymentCard, confidence: .medium))
        }

        return SecretScanResult(detections: detections)
    }
}

private extension SecretDetector {
    struct TokenRule {
        let category: SecretCategory
        let confidence: SecretConfidence
        let pattern: String
    }

    static let tokenRules: [TokenRule] = [
        TokenRule(
            category: .privateKey,
            confidence: .high,
            pattern: #"-----BEGIN (?:RSA |EC |DSA |OPENSSH |ENCRYPTED )?PRIVATE KEY-----"#
        ),
        TokenRule(
            category: .awsAccessKey,
            confidence: .high,
            pattern: #"(?<![A-Z0-9])(?:AKIA|ASIA)[A-Z0-9]{16}(?![A-Z0-9])"#
        ),
        TokenRule(
            category: .openAIAPIKey,
            confidence: .high,
            pattern: #"(?<![A-Za-z0-9_-])sk-(?:(?:proj|svcacct)-)?[A-Za-z0-9_-]{20,}(?![A-Za-z0-9_-])"#
        ),
        TokenRule(
            category: .githubToken,
            confidence: .high,
            pattern: #"(?<![A-Za-z0-9_])(?:gh[pousr]_[A-Za-z0-9]{36,255}|github_pat_[A-Za-z0-9_]{22,255})(?![A-Za-z0-9_])"#
        ),
        TokenRule(
            category: .slackToken,
            confidence: .high,
            pattern: #"(?<![A-Za-z0-9-])(?:xox[a-z]-[A-Za-z0-9-]{16,255}|xapp-[A-Za-z0-9-]{16,255})(?![A-Za-z0-9-])"#
        ),
    ]

    func containsNonPlaceholderMatch(_ pattern: String, in text: String) -> Bool {
        matches(pattern, in: text).contains { match in
            guard let range = Range(match.range, in: text) else { return false }
            return !Self.isPlaceholder(String(text[range]))
        }
    }

    func containsValidJWT(in text: String) -> Bool {
        let pattern = #"(?<![A-Za-z0-9_-])([A-Za-z0-9_-]{8,})\.([A-Za-z0-9_-]{8,})\.([A-Za-z0-9_-]{8,})(?![A-Za-z0-9_-])"#
        for match in matches(pattern, in: text) {
            guard match.numberOfRanges == 4,
                  let headerRange = Range(match.range(at: 1), in: text),
                  let payloadRange = Range(match.range(at: 2), in: text),
                  let header = decodeJSONObject(String(text[headerRange])),
                  decodeJSONObject(String(text[payloadRange])) != nil,
                  header["alg"] is String
            else {
                continue
            }
            return true
        }
        return false
    }

    func containsCredentialURL(in text: String) -> Bool {
        let pattern = #"(?i)(?:https?|ftp|ssh)://([^\s/:@]+):([^\s/@]+)@[^\s/]+"#
        return matches(pattern, in: text).contains { match in
            guard match.numberOfRanges == 3,
                  let passwordRange = Range(match.range(at: 2), in: text)
            else {
                return false
            }
            return !Self.isPlaceholder(String(text[passwordRange]))
        }
    }

    func containsSecretEnvironmentAssignment(in text: String) -> Bool {
        let pattern = #"(?mi)^[ \t]*(?:export[ \t]+)?([A-Z_][A-Z0-9_]*)[ \t]*=[ \t]*(?:\"([^\"\r\n]*)\"|'([^'\r\n]*)'|([^\s#\r\n]+))"#

        for match in matches(pattern, in: text) {
            guard match.numberOfRanges == 5,
                  let keyRange = Range(match.range(at: 1), in: text)
            else {
                continue
            }
            let key = String(text[keyRange]).uppercased()
            if key.hasPrefix("PUBLIC_") || key.hasPrefix("NEXT_PUBLIC_") {
                continue
            }
            let sensitiveKeyNames = [
                "PASSWORD", "PASSWD", "PWD", "SECRET", "TOKEN", "API_KEY", "ACCESS_KEY",
                "PRIVATE_KEY", "CLIENT_SECRET", "AUTH_TOKEN", "CREDENTIAL", "CREDENTIALS",
            ]
            guard sensitiveKeyNames.contains(where: { key == $0 || key.hasSuffix("_\($0)") })
            else {
                continue
            }

            let value = (2...4).compactMap { index -> String? in
                guard match.range(at: index).location != NSNotFound,
                      let range = Range(match.range(at: index), in: text)
                else {
                    return nil
                }
                return String(text[range])
            }.first ?? ""

            if value.count >= 6, !Self.isPlaceholder(value) {
                return true
            }
        }
        return false
    }

    func containsConnectionStringWithPassword(in text: String) -> Bool {
        let URIpattern = #"(?i)(?:postgres(?:ql)?|mysql|mongodb(?:\+srv)?|rediss?|amqps?)://([^:\s/@]+):([^@\s/]+)@[^\s]+"#
        if matches(URIpattern, in: text).contains(where: { match in
            guard match.numberOfRanges == 3,
                  let passwordRange = Range(match.range(at: 2), in: text)
            else {
                return false
            }
            return !Self.isPlaceholder(String(text[passwordRange]))
        }) {
            return true
        }

        let serverPattern = #"(?i)(?:^|;)\s*(?:server|host|data source)\s*="#
        let passwordPattern = #"(?i)(?:^|;)\s*(?:password|pwd)\s*=\s*([^;\r\n]+)"#
        for line in text.components(separatedBy: .newlines) {
            guard !matches(serverPattern, in: line).isEmpty else { continue }
            for match in matches(passwordPattern, in: line) {
                guard match.numberOfRanges == 2,
                      let passwordRange = Range(match.range(at: 1), in: line)
                else {
                    continue
                }
                if !Self.isPlaceholder(String(line[passwordRange])) {
                    return true
                }
            }
        }
        return false
    }

    func containsLuhnValidPaymentCard(in text: String) -> Bool {
        let pattern = #"(?<![A-Za-z0-9])(?:[0-9][ -]?){12,18}[0-9](?![A-Za-z0-9])"#
        for match in matches(pattern, in: text) {
            guard let range = Range(match.range, in: text) else { continue }
            let digits = text[range].compactMap { $0.wholeNumberValue }
            guard (13...19).contains(digits.count), Set(digits).count > 1 else { continue }
            if Self.isLuhnValid(digits) {
                return true
            }
        }
        return false
    }

    func matches(_ pattern: String, in text: String) -> [NSTextCheckingResult] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        return expression.matches(
            in: text,
            range: NSRange(text.startIndex..<text.endIndex, in: text)
        )
    }

    func decodeJSONObject(_ base64URL: String) -> [String: Any]? {
        var encoded = base64URL.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = encoded.count % 4
        if remainder != 0 {
            encoded += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: encoded),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any]
        else {
            return nil
        }
        return dictionary
    }

    static func isPlaceholder(_ candidate: String) -> Bool {
        let normalized = candidate
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n\"'"))
            .uppercased()
        guard !normalized.isEmpty else { return true }

        let markers = [
            "EXAMPLE", "PLACEHOLDER", "REPLACE_ME", "REPLACEME", "CHANGE_ME",
            "CHANGEME", "REDACTED", "YOUR_", "<YOUR", "${", "{{", "DUMMY",
        ]
        if markers.contains(where: normalized.contains) {
            return true
        }
        return ["PASSWORD", "SECRET", "TOKEN", "API_KEY", "KEY", "TEST"].contains(normalized)
    }

    static func isLuhnValid(_ digits: [Int]) -> Bool {
        var sum = 0
        let parity = digits.count % 2
        for (index, digit) in digits.enumerated() {
            var value = digit
            if index % 2 == parity {
                value *= 2
                if value > 9 { value -= 9 }
            }
            sum += value
        }
        return sum % 10 == 0
    }
}
