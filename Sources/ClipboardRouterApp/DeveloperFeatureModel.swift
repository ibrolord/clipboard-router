import ClipboardRouterCore
import Foundation

struct DeveloperDebugBundleReviewRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let pack: ContextPack
    let generatedAt: Date

    init(id: UUID = UUID(), pack: ContextPack, generatedAt: Date = Date()) {
        self.id = id
        self.pack = pack
        self.generatedAt = generatedAt
    }
}

struct DeveloperDebugBundleReview: Equatable, Sendable {
    let bundle: DebugBundle
    let markdown: String

    var itemCount: Int { bundle.items.count }
    var utf8ByteCount: Int { markdown.utf8.count }
}

enum DeveloperFeatureModel {
    static func review(
        request: DeveloperDebugBundleReviewRequest,
        projectDisplayName: String,
        problemStatement: String
    ) throws -> DeveloperDebugBundleReview {
        let project = try DeveloperProjectContext(name: projectDisplayName)
        let bundle = try DebugBundleBuilder().build(
            project: project,
            from: request.pack,
            problemStatement: problemStatement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : problemStatement,
            generatedAt: request.generatedAt
        )
        let markdown = try DebugBundleRenderer().renderMarkdown(bundle)
        return DeveloperDebugBundleReview(bundle: bundle, markdown: markdown)
    }

    static func badgeLabel(for analysis: DeveloperContentAnalysis) -> String {
        switch analysis.kind.rawValue {
        case "sourceCode": "Code"
        case "error", "stackTrace": "Error"
        case "log": "Log"
        case "command": "Command"
        default: "Text"
        }
    }
}
