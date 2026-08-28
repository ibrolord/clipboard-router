import Foundation

public enum AutomaticOrganizationRuleBehavior: String, Codable, CaseIterable, Sendable {
    case suggest
    case alwaysApply
}

public enum AutomaticOrganizationInputOrigin: String, Codable, CaseIterable, Sendable {
    case localUser
    case sync
    case vault
    case quarantine
    case privateSession
}

public struct AutomaticOrganizationEvaluationContext: Equatable, Sendable {
    public let origin: AutomaticOrganizationInputOrigin
    public let isCommittedOrdinarySavedItem: Bool
    public let isSensitive: Bool

    public init(
        origin: AutomaticOrganizationInputOrigin,
        isCommittedOrdinarySavedItem: Bool,
        isSensitive: Bool
    ) {
        self.origin = origin
        self.isCommittedOrdinarySavedItem = isCommittedOrdinarySavedItem
        self.isSensitive = isSensitive
    }

    public static let committedLocalOrdinary = AutomaticOrganizationEvaluationContext(
        origin: .localUser,
        isCommittedOrdinarySavedItem: true,
        isSensitive: false
    )

    public var permitsOrganization: Bool {
        origin == .localUser && isCommittedOrdinarySavedItem && !isSensitive
    }
}

public enum AutomaticOrganizationMatcher: Codable, Equatable, Sendable {
    case contentType(SupportedContentType)
    case domain(String)
    case sourceApplication(String)
    case entity(DetectedClipEntityKind)
    case customText(CustomClipTextMatcher)
}

public struct AutomaticOrganizationAction: Codable, Equatable, Sendable {
    /// Distinguishes "do not move" from an intentional move to the unfiled Saved root.
    public let movesToFolder: Bool
    public let destinationFolderID: UUID?
    public let addedTags: [String]

    public init(
        movesToFolder: Bool = false,
        destinationFolderID: UUID? = nil,
        addedTags: [String] = []
    ) throws {
        let tags = try ClipTag.normalize(addedTags)
        guard movesToFolder || !tags.isEmpty else {
            throw AutomaticOrganizationError.emptyAction
        }
        self.movesToFolder = movesToFolder
        self.destinationFolderID = movesToFolder ? destinationFolderID : nil
        self.addedTags = tags
    }

    private enum CodingKeys: String, CodingKey {
        case movesToFolder, destinationFolderID, addedTags
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            movesToFolder: container.decode(Bool.self, forKey: .movesToFolder),
            destinationFolderID: container.decodeIfPresent(UUID.self, forKey: .destinationFolderID),
            addedTags: container.decode([String].self, forKey: .addedTags)
        )
    }
}

public struct AutomaticOrganizationRule: Codable, Equatable, Identifiable, Sendable {
    public static let maximumNameUTF8Bytes = 80

    public let id: UUID
    public var name: String
    public var isEnabled: Bool
    public var priority: Int
    public var behavior: AutomaticOrganizationRuleBehavior
    public var matcher: AutomaticOrganizationMatcher
    public var action: AutomaticOrganizationAction

    public init(
        id: UUID = UUID(),
        name: String,
        isEnabled: Bool = true,
        priority: Int,
        behavior: AutomaticOrganizationRuleBehavior = .suggest,
        matcher: AutomaticOrganizationMatcher,
        action: AutomaticOrganizationAction
    ) throws {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty,
              normalizedName.utf8.count <= Self.maximumNameUTF8Bytes,
              normalizedName.rangeOfCharacter(from: .controlCharacters) == nil,
              priority >= 0
        else { throw AutomaticOrganizationError.invalidRule }

        switch matcher {
        case .contentType, .entity, .customText:
            break
        case let .domain(value):
            guard Self.normalizedDomain(value) != nil else {
                throw AutomaticOrganizationError.invalidMatcher
            }
        case let .sourceApplication(value):
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty,
                  normalized.utf8.count <= 255,
                  normalized.rangeOfCharacter(from: .controlCharacters) == nil
            else { throw AutomaticOrganizationError.invalidMatcher }
        }

        self.id = id
        self.name = normalizedName
        self.isEnabled = isEnabled
        self.priority = priority
        self.behavior = behavior
        self.matcher = matcher
        self.action = action
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, isEnabled, priority, behavior, matcher, action
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            name: container.decode(String.self, forKey: .name),
            isEnabled: container.decode(Bool.self, forKey: .isEnabled),
            priority: container.decode(Int.self, forKey: .priority),
            behavior: container.decode(AutomaticOrganizationRuleBehavior.self, forKey: .behavior),
            matcher: container.decode(AutomaticOrganizationMatcher.self, forKey: .matcher),
            action: container.decode(AutomaticOrganizationAction.self, forKey: .action)
        )
    }

    static func normalizedDomain(_ rawValue: String) -> String? {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
        while value.hasPrefix(".") { value.removeFirst() }
        while value.hasSuffix(".") { value.removeLast() }
        guard !value.isEmpty,
              value.utf8.count <= 253,
              !value.contains("://"),
              value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              value.split(separator: ".").allSatisfy({ label in
                  !label.isEmpty
                      && label.utf8.count <= 63
                      && label.first != "-"
                      && label.last != "-"
                      && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
              })
        else { return nil }
        return value
    }
}

public struct AutomaticOrganizationSuggestion: Equatable, Identifiable, Sendable {
    public var id: UUID { rule.id }
    public let rule: AutomaticOrganizationRule
    public let reason: String
    public let confidence: Int

    public init(rule: AutomaticOrganizationRule, reason: String, confidence: Int) {
        self.rule = rule
        self.reason = reason
        self.confidence = confidence
    }
}

public struct SavedClipOrganizationExpectation: Codable, Equatable, Sendable {
    public let modifiedAt: Date
    public let folderID: UUID?
    public let tags: [String]
    public let contentFingerprint: String

    public init(savedClip: SavedClip) {
        modifiedAt = savedClip.modifiedAt
        folderID = savedClip.folderID
        tags = savedClip.tags ?? []
        contentFingerprint = savedClip.content.deduplicationFingerprint
    }
}

public struct AutomaticOrganizationItemState: Codable, Equatable, Sendable {
    public let folderID: UUID?
    public let tags: [String]
    public let modifiedAt: Date
    public let contentFingerprint: String

    public init(savedClip: SavedClip) {
        folderID = savedClip.folderID
        tags = savedClip.tags ?? []
        modifiedAt = savedClip.modifiedAt
        contentFingerprint = savedClip.content.deduplicationFingerprint
    }

    public var expectation: SavedClipOrganizationExpectation {
        SavedClipOrganizationExpectation(
            modifiedAt: modifiedAt,
            folderID: folderID,
            tags: tags,
            contentFingerprint: contentFingerprint
        )
    }
}

public extension SavedClipOrganizationExpectation {
    init(
        modifiedAt: Date,
        folderID: UUID?,
        tags: [String],
        contentFingerprint: String
    ) {
        self.modifiedAt = modifiedAt
        self.folderID = folderID
        self.tags = tags
        self.contentFingerprint = contentFingerprint
    }
}

public struct AutomaticOrganizationReceipt: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let savedClipID: UUID
    public let ruleID: UUID
    public let appliedAt: Date
    public let before: AutomaticOrganizationItemState
    public let after: AutomaticOrganizationItemState

    public init(
        id: UUID = UUID(),
        savedClipID: UUID,
        ruleID: UUID,
        appliedAt: Date,
        before: AutomaticOrganizationItemState,
        after: AutomaticOrganizationItemState
    ) {
        self.id = id
        self.savedClipID = savedClipID
        self.ruleID = ruleID
        self.appliedAt = appliedAt
        self.before = before
        self.after = after
    }
}

public struct AutomaticOrganizationSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let maximumRules = 100
    public static let maximumReceipts = 100
    public static let maximumTrackedLocalItems = 20_000

    public let schemaVersion: Int
    public var rules: [AutomaticOrganizationRule]
    public var suppressedRuleIDs: Set<UUID>
    public var receipts: [AutomaticOrganizationReceipt]
    /// Local-only provenance. An ID enters this set only through a committed local save path;
    /// sync/shared hydration never populates it.
    public var locallyCreatedSavedItemIDs: Set<UUID>

    public init(
        schemaVersion: Int = currentSchemaVersion,
        rules: [AutomaticOrganizationRule] = [],
        suppressedRuleIDs: Set<UUID> = [],
        receipts: [AutomaticOrganizationReceipt] = [],
        locallyCreatedSavedItemIDs: Set<UUID> = []
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw AutomaticOrganizationError.unsupportedSchemaVersion(schemaVersion)
        }
        // Rules are mutable value types after construction. Re-run every initializer
        // invariant before a complete snapshot can be accepted or persisted.
        let validatedRules = try rules.map { rule in
            try AutomaticOrganizationRule(
                id: rule.id,
                name: rule.name,
                isEnabled: rule.isEnabled,
                priority: rule.priority,
                behavior: rule.behavior,
                matcher: rule.matcher,
                action: rule.action
            )
        }
        guard validatedRules.count <= Self.maximumRules,
              Set(validatedRules.map(\.id)).count == validatedRules.count,
              receipts.count <= Self.maximumReceipts,
              Set(receipts.map(\.id)).count == receipts.count,
              locallyCreatedSavedItemIDs.count <= Self.maximumTrackedLocalItems
        else { throw AutomaticOrganizationError.invalidSnapshot }
        self.schemaVersion = schemaVersion
        self.rules = validatedRules
        self.suppressedRuleIDs = suppressedRuleIDs
        self.receipts = receipts
        self.locallyCreatedSavedItemIDs = locallyCreatedSavedItemIDs
    }

    public static var empty: AutomaticOrganizationSnapshot {
        try! AutomaticOrganizationSnapshot()
    }

    /// Replaces one rule only when the editor is still based on the persisted version.
    /// Identity, ordering, enablement, and behavior are deliberately immutable in this
    /// operation; those properties have their own explicit controls in the rules list.
    public func replacingRule(
        _ replacement: AutomaticOrganizationRule,
        expecting expected: AutomaticOrganizationRule
    ) throws -> AutomaticOrganizationSnapshot {
        guard replacement.id == expected.id,
              replacement.priority == expected.priority,
              replacement.isEnabled == expected.isEnabled,
              replacement.behavior == expected.behavior
        else { throw AutomaticOrganizationError.invalidRule }
        guard let index = rules.firstIndex(where: { $0.id == expected.id }) else {
            throw AutomaticOrganizationError.ruleNotFound
        }
        guard rules[index] == expected else {
            throw AutomaticOrganizationError.staleRule
        }

        var updatedRules = rules
        updatedRules[index] = replacement
        return try AutomaticOrganizationSnapshot(
            schemaVersion: schemaVersion,
            rules: updatedRules,
            suppressedRuleIDs: suppressedRuleIDs,
            receipts: receipts,
            locallyCreatedSavedItemIDs: locallyCreatedSavedItemIDs
        )
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, rules, suppressedRuleIDs, receipts, locallyCreatedSavedItemIDs
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion),
            rules: container.decode([AutomaticOrganizationRule].self, forKey: .rules),
            suppressedRuleIDs: Set(container.decode([UUID].self, forKey: .suppressedRuleIDs)),
            receipts: container.decode([AutomaticOrganizationReceipt].self, forKey: .receipts),
            locallyCreatedSavedItemIDs: Set(
                container.decodeIfPresent([UUID].self, forKey: .locallyCreatedSavedItemIDs) ?? []
            )
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(rules, forKey: .rules)
        try container.encode(suppressedRuleIDs.sorted { $0.uuidString < $1.uuidString }, forKey: .suppressedRuleIDs)
        try container.encode(receipts, forKey: .receipts)
        try container.encode(
            locallyCreatedSavedItemIDs.sorted { $0.uuidString < $1.uuidString },
            forKey: .locallyCreatedSavedItemIDs
        )
    }
}

public struct AutomaticOrganizationEngine: Sendable {
    public static let maximumRuleEvaluations = 100
    public static let maximumAutomaticApplications = 8

    private let entityDetector: ActionableClipDetector

    public init(entityDetector: ActionableClipDetector = ActionableClipDetector()) {
        self.entityDetector = entityDetector
    }

    public func suggestions(
        for savedClip: SavedClip,
        snapshot: AutomaticOrganizationSnapshot,
        context: AutomaticOrganizationEvaluationContext
    ) -> [AutomaticOrganizationSuggestion] {
        guard context.permitsOrganization else { return [] }
        return orderedEligibleRules(snapshot: snapshot, behavior: .suggest)
            .prefix(Self.maximumRuleEvaluations)
            .compactMap { suggestion(for: savedClip, rule: $0) }
            .prefix(Self.maximumAutomaticApplications)
            .map { $0 }
    }

    public func automaticRules(
        for savedClip: SavedClip,
        snapshot: AutomaticOrganizationSnapshot,
        context: AutomaticOrganizationEvaluationContext
    ) -> [AutomaticOrganizationSuggestion] {
        guard context.permitsOrganization else { return [] }
        return orderedEligibleRules(snapshot: snapshot, behavior: .alwaysApply)
            .prefix(Self.maximumRuleEvaluations)
            .compactMap { suggestion(for: savedClip, rule: $0) }
            .prefix(Self.maximumAutomaticApplications)
            .map { $0 }
    }

    private func orderedEligibleRules(
        snapshot: AutomaticOrganizationSnapshot,
        behavior: AutomaticOrganizationRuleBehavior
    ) -> [AutomaticOrganizationRule] {
        snapshot.rules
            .filter {
                $0.isEnabled
                    && $0.behavior == behavior
                    && !snapshot.suppressedRuleIDs.contains($0.id)
            }
            .sorted {
                if $0.priority != $1.priority { return $0.priority < $1.priority }
                return $0.id.uuidString < $1.id.uuidString
            }
    }

    private func suggestion(
        for savedClip: SavedClip,
        rule: AutomaticOrganizationRule
    ) -> AutomaticOrganizationSuggestion? {
        switch rule.matcher {
        case let .contentType(type):
            guard savedClip.content.type == type else { return nil }
            return AutomaticOrganizationSuggestion(
                rule: rule,
                reason: "Content type is \(type.rawValue)",
                confidence: 100
            )
        case let .domain(rawDomain):
            guard let domain = AutomaticOrganizationRule.normalizedDomain(rawDomain),
                  let host = normalizedHost(for: savedClip),
                  host == domain || host.hasSuffix(".\(domain)")
            else { return nil }
            return AutomaticOrganizationSuggestion(
                rule: rule,
                reason: "Link domain matches \(domain)",
                confidence: 95
            )
        case let .sourceApplication(rawApplication):
            let application = normalized(rawApplication)
            let bundleID = savedClip.sourceApplicationBundleIdentifier.map(normalized)
            let appName = savedClip.captureContext?.sourceApplicationName.map(normalized)
            guard bundleID == application || appName == application else { return nil }
            return AutomaticOrganizationSuggestion(
                rule: rule,
                reason: "Source application matches \(rawApplication)",
                confidence: 90
            )
        case let .entity(kind):
            guard entityDetector.detect(in: savedClip.content.searchableText)
                .contains(where: { $0.kind == kind })
            else { return nil }
            return AutomaticOrganizationSuggestion(
                rule: rule,
                reason: "Contains a detected \(kind.displayName.lowercased())",
                confidence: 85
            )
        case let .customText(matcher):
            guard matcher.matches(savedClip.content.searchableText) else { return nil }
            return AutomaticOrganizationSuggestion(
                rule: rule,
                reason: matcher.summary,
                confidence: 75
            )
        }
    }

    private func normalizedHost(for savedClip: SavedClip) -> String? {
        let candidates = [
            savedClip.captureContext?.sourceDomain,
            savedClip.content.representations.url?.host,
            URLComponents(
                string: savedClip.content.text.trimmingCharacters(in: .whitespacesAndNewlines)
            )?.host,
        ]
        return candidates.compactMap { $0 }
            .compactMap(AutomaticOrganizationRule.normalizedDomain)
            .first
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
    }
}

public enum AutomaticOrganizationError: Error, Equatable, LocalizedError, Sendable {
    case invalidRule
    case invalidMatcher
    case emptyAction
    case invalidSnapshot
    case unsupportedSchemaVersion(Int)
    case protectedItem
    case authorizationChanged
    case staleReceipt
    case ruleNotFound
    case staleRule
    case ineligibleDestination

    public var errorDescription: String? {
        switch self {
        case .invalidRule: "Enter a rule name and a non-negative priority."
        case .invalidMatcher: "Choose a valid content, domain, application, entity, or bounded text condition."
        case .emptyAction: "Choose a destination folder or add at least one tag."
        case .invalidSnapshot: "Automatic Organization data is invalid or exceeds its safety limits."
        case let .unsupportedSchemaVersion(version): "Automatic Organization schema \(version) is unsupported."
        case .protectedItem: "Automatic Organization only works on committed, ordinary, non-sensitive saved items."
        case .authorizationChanged: "Folder access changed before the organization update could be committed."
        case .staleReceipt: "This item changed after Automatic Organization ran, so Undo was not applied."
        case .ruleNotFound: "This organization rule no longer exists. Refresh the rules list and try again."
        case .staleRule: "This organization rule changed while you were editing it. Reopen it to review the latest version."
        case .ineligibleDestination: "The selected folder no longer exists or cannot accept items. Choose another destination."
        }
    }
}
