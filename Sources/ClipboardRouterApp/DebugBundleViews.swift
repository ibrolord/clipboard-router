import ClipboardRouterCore
import SwiftUI

enum DebugBundleAccessibility {
    static let workspace = "uiAcceptance.debugBundle.workspace"
    static let review = "uiAcceptance.debugBundle.review"
    static let reviewSheet = "uiAcceptance.debugBundle.reviewSheet"
    static let close = "uiAcceptance.debugBundle.close"
    static let projectName = "uiAcceptance.debugBundle.projectName"
    static let destination = "uiAcceptance.debugBundle.destination"
    static let problem = "uiAcceptance.debugBundle.problem"
    static let validation = "uiAcceptance.debugBundle.validation"
    static let preview = "uiAcceptance.debugBundle.preview"
    static let saveProject = "uiAcceptance.debugBundle.saveProject"
    static let copy = "uiAcceptance.debugBundle.copy"
    static let clear = "uiAcceptance.debugBundle.clear"

    static func item(_ id: UUID) -> String {
        "uiAcceptance.debugBundle.item.\(id.uuidString.lowercased())"
    }

    static func moveEarlier(_ id: UUID) -> String {
        "uiAcceptance.debugBundle.moveEarlier.\(id.uuidString.lowercased())"
    }

    static func moveLater(_ id: UUID) -> String {
        "uiAcceptance.debugBundle.moveLater.\(id.uuidString.lowercased())"
    }
}

struct DebugBundleReviewSheet: View {
    @ObservedObject var model: AppModel
    let request: DeveloperDebugBundleReviewRequest
    @State private var projectDisplayName: String
    @State private var targetProjectID: UUID?
    @State private var problemStatement = ""
    @State private var review: DeveloperDebugBundleReview?
    @State private var validationMessage: String?
    @State private var isShowingAssistant = false
    @State private var isSavingNote = false
    @State private var isPersistingBundle = false
    @State private var savedProjectID: UUID?
    @State private var savedMarkdown: String?

    init(model: AppModel, request: DeveloperDebugBundleReviewRequest) {
        self.model = model
        self.request = request
        _projectDisplayName = State(
            initialValue: model.activeDeveloperProject?.name ?? request.pack.name
        )
        _targetProjectID = State(initialValue: model.activeDeveloperProject?.id)
    }

    var body: some View {
        Group {
            if isShowingAssistant, review != nil {
                AIClipAssistantSheet(
                    availability: model.onDeviceAIAvailability,
                    cloudConfigured: model.isHostedAssistantConfigured,
                    cloudConsentGranted: model.isHostedAssistantConsentGranted,
                    cloudModel: model.hostedAssistantModel,
                    cloudSourceEligible: model.canUseCloudAssistant(forDebugBundle: request),
                    cloudSourceUnavailableReason: model.cloudAssistantUnavailableReason(forDebugBundle: request),
                    sourceTitle: "Debug Bundle for \(projectDisplayName)",
                    ask: { prompt, messages, purpose, engine in
                        await model.askDebugBundleAssistant(
                            prompt: prompt,
                            messages: messages,
                            purpose: purpose,
                            engine: engine,
                            request: request,
                            projectDisplayName: projectDisplayName,
                            problemStatement: problemStatement
                        )
                    },
                    saveResult: { result, provenance in
                        await model.saveDebugBundleAIDraft(
                            result,
                            request: request,
                            modelProvenance: provenance
                        )
                    },
                    copyResult: { result in
                        model.copyDebugBundleAssistantResponse(result, request: request)
                    },
                    errorMessage: Binding(
                        get: { model.errorMessage },
                        set: { model.errorMessage = $0 }
                    ),
                    cancel: { isShowingAssistant = false }
                )
            } else {
                reviewContent
            }
        }
        .onAppear(perform: refreshReview)
        .onChange(of: targetProjectID) { _, projectID in
            guard let projectID,
                  let project = model.developerProjects.first(where: { $0.id == projectID })
            else { return }
            projectDisplayName = project.name
        }
        .onChange(of: projectDisplayName) { _, _ in refreshReview() }
        .onChange(of: problemStatement) { _, _ in refreshReview() }
    }

    private var reviewContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "ladybug.fill").foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Debug Bundle").font(.title2.weight(.semibold))
                    Text("Review the exact Markdown before it leaves Clipboard Router.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    model.dismissDebugBundleReview()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close Debug Bundle")
                .accessibilityIdentifier(DebugBundleAccessibility.close)
            }
            .padding(16)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                TextField("Project display name", text: $projectDisplayName)
                    .accessibilityLabel("Debug Bundle project display name")
                    .accessibilityIdentifier(DebugBundleAccessibility.projectName)
                Picker("Save to Project", selection: $targetProjectID) {
                    Text("Choose a Project").tag(UUID?.none)
                    ForEach(model.developerProjects) { project in
                        Text(project.name).tag(Optional(project.id))
                    }
                }
                .accessibilityLabel("Debug Bundle destination project")
                .accessibilityIdentifier(DebugBundleAccessibility.destination)
                .accessibilityValue(targetProjectName)
                TextField("Problem statement", text: $problemStatement, axis: .vertical)
                    .lineLimit(2...4)
                    .accessibilityLabel("Debug Bundle problem statement")
                    .accessibilityIdentifier(DebugBundleAccessibility.problem)
                if let validationMessage {
                    Label(validationMessage, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                        .accessibilityIdentifier(DebugBundleAccessibility.validation)
                }
            }
            .padding(16)

            Divider()

            HSplitView {
                List {
                    ForEach(Array((review?.bundle.items ?? []).enumerated()), id: \.element.id) { index, item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(String(index + 1))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 18, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.source.title).lineLimit(2)
                                Text(DeveloperFeatureModel.badgeLabel(for: item.analysis))
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(.quaternary, in: Capsule())
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Item \(index + 1), \(item.source.title), \(DeveloperFeatureModel.badgeLabel(for: item.analysis))")
                    }
                }
                .listStyle(.inset)
                .frame(minWidth: 210, idealWidth: 240, maxWidth: 280)

                ScrollView {
                    Text(review?.markdown ?? "Complete the project details to preview the bundle.")
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(16)
                }
                .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Debug Bundle Markdown preview")
                .accessibilityValue(review?.markdown ?? "Preview unavailable")
                .accessibilityIdentifier(DebugBundleAccessibility.preview)
            }

            Divider()

            HStack(spacing: 10) {
                if let review {
                    Text("\(review.itemCount) item\(review.itemCount == 1 ? "" : "s") · \(ByteCountFormatter.string(fromByteCount: Int64(review.utf8ByteCount), countStyle: .file))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Menu("More", systemImage: "ellipsis.circle") {
                    Button("Save as Note", systemImage: "note.text.badge.plus") {
                        guard review != nil, !isSavingNote else { return }
                        isSavingNote = true
                        Task {
                            _ = await model.saveDebugBundleAsNote(
                                request,
                                projectDisplayName: projectDisplayName,
                                problemStatement: problemStatement
                            )
                            isSavingNote = false
                        }
                    }
                    Button("Share…", systemImage: "square.and.arrow.up") {
                        guard review != nil else { return }
                        model.shareDebugBundle(
                            request,
                            projectDisplayName: projectDisplayName,
                            problemStatement: problemStatement
                        )
                    }
                    Divider()
                    Menu("Publish to Team", systemImage: "person.2") {
                        if model.developerTeamDestinations.isEmpty {
                            Text("No editable shared folders")
                            Divider()
                            Button("Open Saved Folders…", systemImage: "folder") {
                                model.dismissDebugBundleReview()
                                model.selectLibrarySection(.allSaved)
                            }
                        } else {
                            ForEach(model.developerTeamDestinations) { destination in
                                Button(destination.path) {
                                    Task {
                                        _ = await model.publishDebugBundleToTeam(
                                            request,
                                            projectDisplayName: projectDisplayName,
                                            problemStatement: problemStatement,
                                            folderID: destination.id
                                        )
                                    }
                                }
                            }
                        }
                    }
                    Divider()
                    Button("Ask Assistant", systemImage: "sparkles") {
                        isShowingAssistant = true
                    }
                    .disabled(!model.canPresentAssistant(forDebugBundle: request))
                }
                .help("Save a note, publish to a team, share, or ask the Assistant")
                Button(
                    isCurrentReviewSaved ? "Saved" : "Save to Project",
                    systemImage: isCurrentReviewSaved ? "checkmark.circle.fill" : "hammer"
                ) {
                    guard let review,
                          let targetProjectID,
                          !isPersistingBundle,
                          !isCurrentReviewSaved
                    else { return }
                    let savedTargetProjectID = targetProjectID
                    let savedProjectDisplayName = projectDisplayName
                    let savedProblemStatement = problemStatement
                    let savedReviewMarkdown = review.markdown
                    isPersistingBundle = true
                    Task {
                        let didSave = await model.persistDebugBundle(
                            request,
                            projectID: savedTargetProjectID,
                            projectDisplayName: savedProjectDisplayName,
                            problemStatement: savedProblemStatement
                        )
                        if didSave {
                            savedProjectID = savedTargetProjectID
                            savedMarkdown = savedReviewMarkdown
                        }
                        isPersistingBundle = false
                    }
                }
                .disabled(targetProjectID == nil || isCurrentReviewSaved)
                .accessibilityIdentifier(DebugBundleAccessibility.saveProject)
                .accessibilityValue(isCurrentReviewSaved ? "Saved" : "Not saved")
                .help(targetProjectID == nil
                    ? "Choose a destination project above"
                    : "Save this reviewed snapshot to the selected project")
                Button("Copy", systemImage: "doc.on.doc") {
                    guard review != nil else { return }
                    model.copyDebugBundle(
                        request,
                        projectDisplayName: projectDisplayName,
                        problemStatement: problemStatement
                    )
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [.command])
                .accessibilityIdentifier(DebugBundleAccessibility.copy)
            }
            .disabled(review == nil || isSavingNote || isPersistingBundle || model.isBusy)
            .padding(14)
        }
        .frame(minWidth: 700, idealWidth: 760, minHeight: 560, idealHeight: 620)
        .accessibilityIdentifier(DebugBundleAccessibility.reviewSheet)
    }

    private func refreshReview() {
        do {
            review = try DeveloperFeatureModel.review(
                request: request,
                projectDisplayName: projectDisplayName,
                problemStatement: problemStatement
            )
            validationMessage = nil
        } catch {
            review = nil
            validationMessage = error.localizedDescription
        }
    }

    private var isCurrentReviewSaved: Bool {
        guard let targetProjectID, let markdown = review?.markdown else { return false }
        return savedProjectID == targetProjectID && savedMarkdown == markdown
    }

    private var targetProjectName: String {
        guard let targetProjectID,
              let project = model.developerProjects.first(where: { $0.id == targetProjectID })
        else { return "No project selected" }
        return project.name
    }
}
