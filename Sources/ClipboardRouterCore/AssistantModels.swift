import Foundation

public enum AssistantPurpose: String, Codable, CaseIterable, Identifiable, Sendable {
    case quickAnswer
    case enrich
    case rewrite
    case format
    case followUp
    case research

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .quickAnswer: "Quick answer"
        case .enrich: "Enrich"
        case .rewrite: "Rewrite"
        case .format: "Format"
        case .followUp: "Follow up"
        case .research: "Research web"
        }
    }

    public var promptTemplate: String {
        switch self {
        case .quickAnswer: "Answer this question using the attached clip as context: "
        case .enrich: "Enrich this clip with useful, clearly labeled context. Do not invent facts."
        case .rewrite: "Rewrite this clip for clarity while preserving its meaning."
        case .format: "Format this clip into concise, scannable Markdown."
        case .followUp: "Draft the most useful follow-up. Do not send or claim it was sent."
        case .research: "Research this topic on the web. Cite the sources you used and label inference."
        }
    }
}

public enum AssistantMessageRole: String, Codable, Sendable {
    case user
    case assistant
}

public struct AssistantMessage: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let role: AssistantMessageRole
    public let text: String
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        role: AssistantMessageRole,
        text: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
    }
}

public struct AssistantCitation: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let url: URL

    public init(id: UUID = UUID(), title: String, url: URL) {
        self.id = id
        self.title = title
        self.url = url
    }
}

public struct HostedAssistantResponse: Equatable, Sendable {
    public let requestID: String?
    public let model: String
    public let text: String
    public let citations: [AssistantCitation]

    public init(
        requestID: String? = nil,
        model: String,
        text: String,
        citations: [AssistantCitation] = []
    ) {
        self.requestID = requestID
        self.model = model
        self.text = text
        self.citations = citations
    }
}
