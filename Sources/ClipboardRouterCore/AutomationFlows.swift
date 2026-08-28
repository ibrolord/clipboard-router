import CryptoKit
import Foundation

public enum ClipFlowTrigger: Codable, Equatable, Sendable {
    case manual
    /// Folder-entry triggers are evaluated only for a committed local user mutation. A sync
    /// refresh, launch restore, or mutation made by the same flow is never a trigger source.
    case folderEntry(folderID: UUID, includeDescendants: Bool)

    public var isAutomatic: Bool {
        if case .folderEntry = self { return true }
        return false
    }
}

public enum ClipFlowStep: Codable, Equatable, Identifiable, Sendable {
    case addTags(id: UUID, tags: [String])
    case moveToFolder(id: UUID, folderID: UUID?)
    case openWeb(id: UUID, template: String, label: String)
    case openApplication(id: UUID, bookmarkData: Data, displayName: String)
    case createTaskDraft(id: UUID, titleTemplate: String, dueInDays: Int)
    case enrichWithOnDeviceAI(id: UUID, instruction: String)

    public var id: UUID {
        switch self {
        case let .addTags(id, _),
             let .moveToFolder(id, _),
             let .openWeb(id, _, _),
             let .openApplication(id, _, _),
             let .createTaskDraft(id, _, _),
             let .enrichWithOnDeviceAI(id, _):
            id
        }
    }

    public var isExternal: Bool {
        switch self {
        case .openWeb, .openApplication: true
        case .addTags, .moveToFolder, .createTaskDraft, .enrichWithOnDeviceAI: false
        }
    }

    public var isPortable: Bool {
        if case .openApplication = self { return false }
        return true
    }

    public var displayName: String {
        switch self {
        case .addTags: "Add tags"
        case .moveToFolder: "Move to folder"
        case let .openWeb(_, _, label): "Open \(label)"
        case let .openApplication(_, _, displayName): "Open \(displayName)"
        case .createTaskDraft: "Create follow-up note"
        case .enrichWithOnDeviceAI: "Enrich with on-device AI"
        }
    }
}

public struct ClipFlow: Codable, Equatable, Identifiable, Sendable {
    public static let currentSchemaVersion = 1
    public static let maximumSteps = 12
    public static let maximumInstructionUTF8Bytes = 2_000

    public let schemaVersion: Int
    public let id: UUID
    public var name: String
    public var isEnabled: Bool
    public var trigger: ClipFlowTrigger
    public var entityFilter: ClipAutomationEntityFilter
    public var customMatcher: CustomClipTextMatcher?
    public var steps: [ClipFlowStep]
    /// A shared scope carries only a portable recipe. Credentials, app bookmarks, clip bodies,
    /// local enablement, and run receipts are deliberately never part of this value.
    public var sharedFolderID: UUID?

    public init(
        id: UUID = UUID(),
        name: String,
        isEnabled: Bool = true,
        trigger: ClipFlowTrigger = .manual,
        entityFilter: ClipAutomationEntityFilter = .any,
        customMatcher: CustomClipTextMatcher? = nil,
        steps: [ClipFlowStep],
        sharedFolderID: UUID? = nil
    ) throws {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty,
              normalizedName.utf8.count <= ClipAutomation.maximumNameUTF8Bytes,
              normalizedName.rangeOfCharacter(from: .controlCharacters) == nil
        else { throw ClipFlowError.invalidName }
        guard !steps.isEmpty, steps.count <= Self.maximumSteps,
              Set(steps.map(\.id)).count == steps.count
        else { throw ClipFlowError.invalidSteps }

        for step in steps {
            try Self.validate(step)
        }
        // Organization is one atomic local transaction. Keeping it as a leading block makes the
        // reviewed order truthful and prevents a later move from being hoisted ahead of an
        // external action during execution.
        var reachedSideEffect = false
        var moveCount = 0
        for step in steps {
            switch step {
            case .addTags:
                guard !reachedSideEffect else { throw ClipFlowError.invalidSteps }
            case .moveToFolder:
                guard !reachedSideEffect else { throw ClipFlowError.invalidSteps }
                moveCount += 1
                guard moveCount <= 1 else { throw ClipFlowError.invalidSteps }
            case .openWeb, .openApplication, .createTaskDraft, .enrichWithOnDeviceAI:
                reachedSideEffect = true
            }
        }
        if sharedFolderID != nil, steps.contains(where: { !$0.isPortable }) {
            throw ClipFlowError.nonPortableSharedStep
        }
        if case let .folderEntry(folderID, _) = trigger,
           let sharedFolderID,
           folderID != sharedFolderID
        {
            // Descendant validation is performed with the live folder graph at execution time.
            // The record itself must at least remain rooted in the same declared workspace.
            throw ClipFlowError.invalidSharedScope
        }

        schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.name = normalizedName
        self.isEnabled = isEnabled
        self.trigger = trigger
        self.entityFilter = entityFilter
        if entityFilter == .customText {
            guard let customMatcher else { throw ClipFlowError.invalidCustomMatcher }
            self.customMatcher = customMatcher
        } else {
            self.customMatcher = nil
        }
        self.steps = steps
        self.sharedFolderID = sharedFolderID
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, name, isEnabled, trigger, entityFilter, customMatcher, steps, sharedFolderID
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        guard version == Self.currentSchemaVersion else { throw ClipFlowError.unsupportedVersion }
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            name: container.decode(String.self, forKey: .name),
            isEnabled: container.decode(Bool.self, forKey: .isEnabled),
            trigger: container.decode(ClipFlowTrigger.self, forKey: .trigger),
            entityFilter: container.decode(ClipAutomationEntityFilter.self, forKey: .entityFilter),
            customMatcher: container.decodeIfPresent(CustomClipTextMatcher.self, forKey: .customMatcher),
            steps: container.decode([ClipFlowStep].self, forKey: .steps),
            sharedFolderID: container.decodeIfPresent(UUID.self, forKey: .sharedFolderID)
        )
    }

    public var requiresReviewWhenTriggered: Bool {
        trigger.isAutomatic && steps.contains { $0.isExternal || Self.requiresHumanReview($0) }
    }

    public func matches(entities: [DetectedClipEntity], clipText: String) -> Bool {
        entityFilter.matches(entities, clipText: clipText, customMatcher: customMatcher)
    }

    public var mutatesLibrary: Bool {
        steps.contains { step in
            switch step {
            case .addTags, .moveToFolder, .createTaskDraft, .enrichWithOnDeviceAI: true
            case .openWeb, .openApplication: false
            }
        }
    }

    private static func requiresHumanReview(_ step: ClipFlowStep) -> Bool {
        switch step {
        case .createTaskDraft, .enrichWithOnDeviceAI: true
        case .addTags, .moveToFolder, .openWeb, .openApplication: false
        }
    }

    private static func validate(_ step: ClipFlowStep) throws {
        switch step {
        case let .addTags(_, tags):
            _ = try ClipTag.normalize(tags)
        case .moveToFolder:
            break
        case let .openWeb(_, template, label):
            _ = try AutomationURLTemplate(template)
            let normalized = label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty,
                  normalized.utf8.count <= ClipAutomation.maximumNameUTF8Bytes,
                  normalized.rangeOfCharacter(from: .controlCharacters) == nil
            else { throw ClipFlowError.invalidStep }
        case let .openApplication(_, bookmarkData, displayName):
            guard !bookmarkData.isEmpty,
                  !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw ClipFlowError.invalidStep }
        case let .createTaskDraft(_, titleTemplate, dueInDays):
            guard !titleTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  titleTemplate.utf8.count <= 500,
                  (0...365).contains(dueInDays)
            else { throw ClipFlowError.invalidStep }
        case let .enrichWithOnDeviceAI(_, instruction):
            let normalized = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty,
                  normalized.utf8.count <= maximumInstructionUTF8Bytes,
                  normalized.rangeOfCharacter(from: .controlCharacters) == nil
            else { throw ClipFlowError.invalidStep }
        }
    }
}

public struct ClipFlowRunPlan: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let flowID: UUID
    public let flowVersionFingerprint: String
    public let clipID: UUID
    public let clipFingerprint: String
    public let createdAt: Date
    public let steps: [ClipFlowStep]

    public init(
        id: UUID = UUID(),
        flow: ClipFlow,
        clipID: UUID,
        clipFingerprint: String,
        createdAt: Date = Date()
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let flowData = try encoder.encode(flow)
        self.id = id
        flowID = flow.id
        flowVersionFingerprint = SHA256.hash(data: flowData)
            .map { String(format: "%02x", $0) }
            .joined()
        self.clipID = clipID
        self.clipFingerprint = clipFingerprint
        self.createdAt = createdAt
        steps = flow.steps
    }
}

public struct AutomationTriggerEvent: Equatable, Sendable {
    public let clipID: UUID
    public let clipFingerprint: String
    public let sourceFolderID: UUID?
    public let destinationFolderID: UUID
    public let occurredAt: Date
    public let correlationID: UUID

    public init(
        clipID: UUID,
        clipFingerprint: String,
        sourceFolderID: UUID?,
        destinationFolderID: UUID,
        occurredAt: Date = Date(),
        correlationID: UUID = UUID()
    ) {
        self.clipID = clipID
        self.clipFingerprint = clipFingerprint
        self.sourceFolderID = sourceFolderID
        self.destinationFolderID = destinationFolderID
        self.occurredAt = occurredAt
        self.correlationID = correlationID
    }
}

public enum ClipFlowError: Error, Equatable, LocalizedError, Sendable {
    case invalidName
    case invalidSteps
    case invalidStep
    case invalidCustomMatcher
    case unsupportedVersion
    case nonPortableSharedStep
    case invalidSharedScope
    case ineligibleClip
    case staleRun
    case triggerLoop

    public var errorDescription: String? {
        switch self {
        case .invalidName: "Give the flow a name between 1 and 80 bytes."
        case .invalidSteps: "A flow needs between 1 and 12 unique steps."
        case .invalidStep: "One of the flow steps is incomplete or unsafe."
        case .invalidCustomMatcher: "Add a valid custom text condition before saving this flow."
        case .unsupportedVersion: "This automation was created by an unsupported version of Clipboard Router."
        case .nonPortableSharedStep: "Application-specific actions cannot be shared with a team."
        case .invalidSharedScope: "The automation trigger must stay inside its shared workspace."
        case .ineligibleClip: "This clip cannot run automations."
        case .staleRun: "The clip or automation changed. Review the automation again."
        case .triggerLoop: "Clipboard Router stopped an automation loop."
        }
    }
}
