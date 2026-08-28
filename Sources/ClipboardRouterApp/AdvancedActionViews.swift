import AppKit
import ClipboardRouterCore
import ClipboardRouterPlatform
import SwiftUI

enum AssistantAcceptanceAccessibility {
    static let sheet = "uiAcceptance.assistant.sheet"
    static let engine = "uiAcceptance.assistant.engine"
    static let send = "uiAcceptance.assistant.send"
    static let close = "uiAcceptance.assistant.close"
    static let response = "uiAcceptance.assistant.response"
    static let copy = "uiAcceptance.assistant.copy"
    static let save = "uiAcceptance.assistant.save"
    static let error = "uiAcceptance.assistant.error"

    static func sheet(_ requestID: UUID?) -> String {
        requestID.map { "\(sheet).\(uuid($0))" } ?? sheet
    }

    static func preset(_ purpose: AssistantPurpose) -> String {
        "uiAcceptance.assistant.preset.\(purpose.rawValue)"
    }

    static func message(_ id: UUID) -> String {
        "uiAcceptance.assistant.message.\(uuid(id))"
    }

    static func stateValue(
        purpose: AssistantPurpose,
        engine: AssistantEngine,
        isWorking: Bool,
        isSaving: Bool,
        responseCount: Int,
        hasError: Bool
    ) -> String {
        "purpose=\(purpose.rawValue)|engine=\(engine.rawValue)|working=\(isWorking)|saving=\(isSaving)|responses=\(responseCount)|error=\(hasError)"
    }

    static func responseValue(_ response: HostedAssistantResponse) -> String {
        "model=\(component(response.model))|request=\(component(response.requestID ?? "none"))|citations=\(response.citations.count)|characters=\(response.text.count)"
    }

    static func component(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private static func uuid(_ id: UUID) -> String { id.uuidString.lowercased() }
}

enum AssistantPromptTemplatePolicy {
    struct Selection: Equatable {
        let prompt: String
        let lastAppliedTemplate: String?
    }

    static func selecting(
        template: String,
        currentPrompt: String,
        lastAppliedTemplate: String?
    ) -> Selection {
        let isBlank = currentPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard isBlank || currentPrompt == lastAppliedTemplate else {
            return Selection(prompt: currentPrompt, lastAppliedTemplate: nil)
        }
        return Selection(prompt: template, lastAppliedTemplate: template)
    }
}

struct ContactDraftSheet: View {
    @State private var draft: ContactDraft
    @State private var duplicates: [ContactDuplicate] = []
    @State private var isCheckingDuplicates = false
    @State private var isSaving = false
    @State private var allowsPossibleDuplicate = false
    let checkDuplicates: (ContactDraft) async -> [ContactDuplicate]
    let save: (ContactDraft, Bool) async -> Bool
    let cancel: () -> Void

    init(
        draft: ContactDraft,
        checkDuplicates: @escaping (ContactDraft) async -> [ContactDuplicate],
        save: @escaping (ContactDraft, Bool) async -> Bool,
        cancel: @escaping () -> Void
    ) {
        _draft = State(initialValue: draft)
        self.checkDuplicates = checkDuplicates
        self.save = save
        self.cancel = cancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Save to Contacts")
                .font(.title2.weight(.semibold))
            Text("Review every field. Clipboard Router requests Contacts access only after you press Save Contact.")
                .foregroundStyle(.secondary)

            Form {
                TextField("First name", text: $draft.givenName)
                TextField("Last name", text: $draft.familyName)
                TextField("Company", text: $draft.organizationName)
                TextField("Phone", text: firstPhone)
                TextField("Email", text: firstEmail)

                if isCheckingDuplicates {
                    ProgressView("Checking for possible duplicates…")
                } else if !duplicates.isEmpty {
                    Section("Possible duplicates") {
                        ForEach(duplicates) { duplicate in
                            Label(duplicate.displayName, systemImage: "person.crop.circle.badge.exclamationmark")
                        }
                        Text("Clipboard Router will create a new contact. Cancel and review Contacts if you prefer to update an existing person.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Toggle("I reviewed these matches and want a separate contact", isOn: $allowsPossibleDuplicate)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                Button(duplicates.isEmpty ? "Save Contact" : "Create Anyway") {
                    Task {
                        isSaving = true
                        let saved = await save(draft, allowsPossibleDuplicate)
                        if !saved {
                            duplicates = await checkDuplicates(draft)
                        }
                        isSaving = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving || isCheckingDuplicates || (!duplicates.isEmpty && !allowsPossibleDuplicate))
            }
        }
        .padding(20)
        .frame(width: 520, height: 500)
        .task(id: duplicateFingerprint) {
            allowsPossibleDuplicate = false
            isCheckingDuplicates = true
            duplicates = await checkDuplicates(draft)
            isCheckingDuplicates = false
        }
    }

    private var firstPhone: Binding<String> {
        Binding(
            get: { draft.phoneNumbers.first ?? "" },
            set: { draft.phoneNumbers = $0.isEmpty ? [] : [$0] }
        )
    }

    private var firstEmail: Binding<String> {
        Binding(
            get: { draft.emailAddresses.first ?? "" },
            set: { draft.emailAddresses = $0.isEmpty ? [] : [$0] }
        )
    }

    private var duplicateFingerprint: String {
        (draft.phoneNumbers + draft.emailAddresses).joined(separator: "|")
    }
}

struct AIClipAssistantSheet: View {
    @Environment(\.openSettings) private var openSettings
    let availability: OnDeviceAIAvailability
    let cloudConfigured: Bool
    let cloudConsentGranted: Bool
    let cloudModel: String
    let cloudSourceEligible: Bool
    let cloudSourceUnavailableReason: String
    let sourceTitle: String
    let acceptanceID: UUID?
    let ask: (
        String,
        [AssistantMessage],
        AssistantPurpose,
        AssistantEngine
    ) async -> HostedAssistantResponse?
    let saveResult: (String, String) async -> Bool
    let copyResult: (String) -> Void
    let cancel: () -> Void
    @Binding private var errorMessage: String?

    @State private var prompt = ""
    @State private var messages: [AssistantMessage] = []
    @State private var citations: [AssistantCitation] = []
    @State private var purpose: AssistantPurpose = .quickAnswer
    @State private var engine: AssistantEngine
    @State private var isWorking = false
    @State private var isSavingResult = false
    @State private var latestResponse: HostedAssistantResponse?
    @State private var inlineError: String?
    @State private var requestTask: Task<Void, Never>?
    @State private var lastAppliedPromptTemplate: String?
    @FocusState private var promptFocused: Bool

    init(
        availability: OnDeviceAIAvailability,
        cloudConfigured: Bool,
        cloudConsentGranted: Bool,
        cloudModel: String,
        cloudSourceEligible: Bool,
        cloudSourceUnavailableReason: String,
        sourceTitle: String,
        acceptanceID: UUID? = nil,
        ask: @escaping (
            String,
            [AssistantMessage],
            AssistantPurpose,
            AssistantEngine
        ) async -> HostedAssistantResponse?,
        saveResult: @escaping (String, String) async -> Bool,
        copyResult: @escaping (String) -> Void,
        errorMessage: Binding<String?>,
        cancel: @escaping () -> Void
    ) {
        self.availability = availability
        self.cloudConfigured = cloudConfigured
        self.cloudConsentGranted = cloudConsentGranted
        self.cloudModel = cloudModel
        self.cloudSourceEligible = cloudSourceEligible
        self.cloudSourceUnavailableReason = cloudSourceUnavailableReason
        self.sourceTitle = sourceTitle
        self.acceptanceID = acceptanceID
        self.ask = ask
        self.saveResult = saveResult
        self.copyResult = copyResult
        _errorMessage = errorMessage
        self.cancel = cancel
        let cloudReady = cloudSourceEligible
            && cloudConfigured
            && cloudConsentGranted
            && Self.isValidCloudModel(cloudModel)
        _engine = State(initialValue: availability == .available || !cloudReady ? .onDevice : .fastCloud)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            assistantHeader
            purposeBar
            promptComposer

            if !messages.isEmpty || isWorking {
                conversationPanel
            }

            if !citations.isEmpty {
                citationBar
            }

            if let inlineError {
                inlineErrorPanel(inlineError)
            }

        }
        .padding(14)
        .frame(minWidth: 560, idealWidth: 600, maxWidth: 640)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AssistantAcceptanceAccessibility.sheet(acceptanceID))
        .accessibilityValue(AssistantAcceptanceAccessibility.stateValue(
            purpose: purpose,
            engine: engine,
            isWorking: isWorking,
            isSaving: isSavingResult,
            responseCount: messages.lazy.filter { $0.role == .assistant }.count,
            hasError: inlineError != nil
        ))
        .onAppear { promptFocused = true }
        .onDisappear {
            requestTask?.cancel()
            requestTask = nil
        }
    }

    private var assistantHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Use AI")
                    .font(.headline)
                Label(sourceTitle, systemImage: "paperclip")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(sourceTitle)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Picker("Processing mode", selection: $engine) {
                    Text("On this Mac").tag(AssistantEngine.onDevice)
                        .disabled(availability != .available)
                    Text("Cloud").tag(AssistantEngine.fastCloud)
                        .disabled(!cloudSourceEligible || !cloudConfigured || !cloudConsentGranted || !isCloudModelValid)
                }
                .labelsHidden()
                .accessibilityLabel("Processing mode")
                .accessibilityIdentifier(AssistantAcceptanceAccessibility.engine)
                .accessibilityValue("engine=\(engine.rawValue)|available=\(engineAvailable)")
                .pickerStyle(.segmented)
                .frame(width: 176)

                if !engineAvailable {
                    HStack(spacing: 5) {
                        Label(engineStatus, systemImage: engine == .onDevice ? "laptopcomputer" : "icloud")
                            .lineLimit(1)
                        if cloudSourceEligible {
                            Button("Set Up…") { openAssistantSettings() }
                                .buttonStyle(.link)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }
            Button(action: closeAssistant) {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Close Assistant")
            .accessibilityIdentifier(AssistantAcceptanceAccessibility.close)
        }
    }

    private var purposeBar: some View {
        ViewThatFits(in: .horizontal) {
            purposeButtons
            ScrollView(.horizontal, showsIndicators: true) {
                purposeButtons
                    .padding(.bottom, 2)
            }
        }
    }

    private var purposeButtons: some View {
        HStack(spacing: 6) {
            ForEach(AssistantPurpose.allCases) { option in
                purposeButton(option)
            }
        }
    }

    @ViewBuilder
    private func purposeButton(_ option: AssistantPurpose) -> some View {
        Group {
            if purpose == option {
                Button(purposeLabel(option)) { selectPurpose(option) }
                    .buttonStyle(.borderedProminent)
            } else {
                Button(purposeLabel(option)) { selectPurpose(option) }
                    .buttonStyle(.bordered)
            }
        }
        .controlSize(.small)
        .accessibilityIdentifier(AssistantAcceptanceAccessibility.preset(option))
        .accessibilityValue(purpose == option ? "Selected" : "Not selected")
        .accessibilityAddTraits(purpose == option ? .isSelected : [])
    }

    private var promptComposer: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                if prompt.isEmpty {
                    Text("Ask a question or describe the result you want…")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 9)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $prompt)
                    .font(.body)
                    .focused($promptFocused)
                    .scrollContentBackground(.hidden)
                    .padding(3)
                    .accessibilityLabel("Question or instruction")
                    .accessibilityIdentifier("uiAcceptance.assistant.prompt")
            }
            .frame(
                minHeight: messages.isEmpty ? 52 : 44,
                idealHeight: messages.isEmpty ? 64 : 52,
                maxHeight: messages.isEmpty ? 96 : 72
            )

            Divider()

            HStack(spacing: 10) {
                Label(disclosureSummary, systemImage: engine == .fastCloud ? "icloud.and.arrow.up" : "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(disclosureText)
                Spacer(minLength: 10)
                Button(messages.isEmpty ? "Send" : "Send Follow-up") {
                    sendPrompt()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(!engineAvailable || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isWorking)
                .accessibilityIdentifier(AssistantAcceptanceAccessibility.send)
                .accessibilityValue(
                    "enabled=\(engineAvailable && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isWorking)|followUp=\(!messages.isEmpty)"
                )
            }
            .padding(8)
        }
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator))
    }

    private var conversationPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(latestResponse == nil ? "Working…" : "Response")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let latestResponse {
                    Button {
                        copyResult(latestResponse.text)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .controlSize(.small)
                    .accessibilityIdentifier(AssistantAcceptanceAccessibility.copy)
                    .accessibilityValue(AssistantAcceptanceAccessibility.responseValue(latestResponse))

                    Button {
                        saveLatestResponse(latestResponse)
                    } label: {
                        Label("Save to Notes", systemImage: "note.text.badge.plus")
                    }
                    .controlSize(.small)
                    .help("Creates an unfiled note after secret scanning. It never inherits a team-shared source folder.")
                    .disabled(isWorking || isSavingResult)
                    .accessibilityIdentifier(AssistantAcceptanceAccessibility.save)
                    .accessibilityValue("saving=\(isSavingResult)|enabled=\(!isWorking && !isSavingResult)")
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(messages) { message in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(message.role == .user ? "You" : "Assistant")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(message.text)
                                .textSelection(.enabled)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            message.role == .user
                                ? Color.accentColor.opacity(0.11)
                                : Color.secondary.opacity(0.09),
                            in: RoundedRectangle(cornerRadius: 9)
                        )
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier(AssistantAcceptanceAccessibility.message(message.id))
                        .accessibilityValue(
                            "role=\(message.role.rawValue)|characters=\(message.text.count)"
                        )
                    }
                    if isWorking {
                        ProgressView(engine == .onDevice ? "Thinking on this Mac…" : "Sending reviewed request…")
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                .padding(1)
            }
        }
        .padding(8)
        .frame(minHeight: 120, idealHeight: 190, maxHeight: 280)
        .background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier(AssistantAcceptanceAccessibility.response)
        .accessibilityValue(
            latestResponse.map(AssistantAcceptanceAccessibility.responseValue)
                ?? "working=\(isWorking)|response=none"
        )
    }

    private var citationBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(citations) { citation in
                    Link(destination: citation.url) {
                        Label(citation.title, systemImage: "arrow.up.right.square")
                            .lineLimit(1)
                    }
                    .help(citation.url.absoluteString)
                }
            }
        }
    }

    private func inlineErrorPanel(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if engine == .fastCloud {
                Button("Assistant Settings…", action: openAssistantSettings)
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AssistantAcceptanceAccessibility.error)
        .accessibilityValue("message=\(AssistantAcceptanceAccessibility.component(message))")
    }

    private var engineAvailable: Bool {
        switch engine {
        case .onDevice: availability == .available
        case .fastCloud:
            cloudSourceEligible && cloudConfigured && cloudConsentGranted && isCloudModelValid
        }
    }

    private var engineStatus: String {
        switch engine {
        case .onDevice:
            switch availability {
            case .available: "Ready on this Mac"
            case .requiresMacOS26: "Requires macOS 26"
            case .appleIntelligenceUnavailable: "Unavailable on this Mac"
            }
        case .fastCloud:
            if !cloudSourceEligible {
                cloudSourceUnavailableReason
            } else if !cloudConfigured || !cloudConsentGranted {
                "Configure Cloud in Settings"
            } else if !isCloudModelValid {
                "Choose a valid model in Settings"
            } else {
                cloudModel
            }
        }
    }

    private var disclosureText: String {
        if engine == .fastCloud {
            return "Sent to OpenAI only when you press Send. The response is an unverified draft and cannot run actions."
        }
        return "Stays on this Mac. The response is an unverified draft and cannot run actions."
    }

    private var disclosureSummary: String {
        engine == .fastCloud ? "Sent to OpenAI on Send" : "Stays on this Mac"
    }

    private func purposeLabel(_ option: AssistantPurpose) -> String {
        switch option {
        case .quickAnswer: "Ask"
        case .enrich: "Extract details"
        case .rewrite: "Rewrite"
        case .format: "Format"
        case .followUp: "Draft follow-up"
        case .research: "Research"
        }
    }

    private func sendPrompt() {
        guard !isWorking, engineAvailable else { return }
        let outgoing = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !outgoing.isEmpty else { return }

        inlineError = nil
        errorMessage = nil
        requestTask?.cancel()
        isWorking = true
        let prior = messages
        let outgoingMessage = AssistantMessage(role: .user, text: outgoing)
        messages.append(outgoingMessage)
        prompt = ""
        lastAppliedPromptTemplate = nil

        requestTask = Task {
            defer {
                isWorking = false
                requestTask = nil
            }
            if let response = await ask(outgoing, prior, purpose, engine) {
                guard !Task.isCancelled else { return }
                messages.append(AssistantMessage(role: .assistant, text: response.text))
                citations = response.citations
                latestResponse = response
            } else {
                guard !Task.isCancelled else {
                    errorMessage = nil
                    return
                }
                messages.removeAll { $0.id == outgoingMessage.id }
                if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    prompt = outgoing
                }
                promptFocused = true
                inlineError = errorMessage ?? "Assistant could not complete the request. Review the setup and try again."
                errorMessage = nil
            }
        }
    }

    private var isCloudModelValid: Bool {
        Self.isValidCloudModel(cloudModel)
    }

    private static func isValidCloudModel(_ model: String) -> Bool {
        let value = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return !value.isEmpty
            && value.utf8.count <= 120
            && value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
            && value.rangeOfCharacter(from: .controlCharacters) == nil
    }

    private func openAssistantSettings() {
        UserDefaults.standard.set(SettingsTab.assistant.rawValue, forKey: "settings.selectedTab")
        openSettings()
    }

    private func selectPurpose(_ option: AssistantPurpose) {
        purpose = option
        let selection = AssistantPromptTemplatePolicy.selecting(
            template: option.promptTemplate,
            currentPrompt: prompt,
            lastAppliedTemplate: lastAppliedPromptTemplate
        )
        prompt = selection.prompt
        lastAppliedPromptTemplate = selection.lastAppliedTemplate
        promptFocused = true
    }

    private func saveLatestResponse(_ response: HostedAssistantResponse) {
        guard !isSavingResult else { return }
        isSavingResult = true
        Task {
            defer { isSavingResult = false }
            if await saveResult(response.text, response.model) {
                closeAssistant()
            }
        }
    }

    private func closeAssistant() {
        requestTask?.cancel()
        requestTask = nil
        cancel()
    }

}

struct ClipFlowReviewSheet: View {
    let request: ClipFlowRunReviewRequest
    let folderName: (UUID?) -> String
    let run: () async -> Bool
    let cancel: () -> Void
    @State private var isRunning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(request.triggeredAutomatically ? "Automation ready for review" : "Run custom action?")
                .font(.title2.weight(.semibold))
            Text("Leading tag and folder changes commit together, then remaining steps run top to bottom. It stops on the first failure; completed steps are not rolled back.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Label(
                "Progress is saved without clip contents. After a relaunch, completed steps are not replayed and unknown external outcomes require reconciliation.",
                systemImage: "checkmark.shield"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            List(Array(request.flow.steps.enumerated()), id: \.element.id) { index, step in
                HStack(alignment: .top, spacing: 12) {
                    Text("\(index + 1)")
                        .font(.caption.monospacedDigit())
                        .frame(width: 22, height: 22)
                        .background(.quaternary, in: Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        Text(step.displayName)
                        Text(stepDetail(step))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(ActionFlowAccessibility.reviewStep(step.id))
                .accessibilityValue("Step \(index + 1) of \(request.flow.steps.count): \(step.displayName), \(stepDetail(step))")
            }
            .frame(minHeight: 130, idealHeight: 180, maxHeight: 220)

            HStack {
                Button("Cancel", action: cancel)
                    .accessibilityIdentifier(ActionFlowAccessibility.reviewCancel(request.id))
                Spacer()
                Button("Run \(request.flow.name)") {
                    Task {
                        isRunning = true
                        _ = await run()
                        isRunning = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRunning)
                .accessibilityIdentifier(ActionFlowAccessibility.reviewRun(request.id))
                .accessibilityValue(isRunning ? "Running" : "Ready")
            }
        }
        .padding(20)
        .frame(width: 560, height: 430)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(ActionFlowAccessibility.review(request.id))
        .accessibilityValue(ActionFlowAccessibility.reviewValue(
            flowName: request.flow.name,
            stepCount: request.flow.steps.count,
            triggeredAutomatically: request.triggeredAutomatically,
            isRunning: isRunning
        ))
    }

    private func stepDetail(_ step: ClipFlowStep) -> String {
        switch step {
        case let .addTags(_, tags): tags.joined(separator: ", ")
        case let .moveToFolder(_, folderID): folderName(folderID)
        case let .openWeb(_, template, _): URLComponents(string: template)?.host ?? "HTTPS destination"
        case let .openApplication(_, _, displayName): displayName
        case let .createTaskDraft(_, title, dueInDays): "\(title) · due in \(dueInDays) days"
        case let .enrichWithOnDeviceAI(_, instruction): instruction
        }
    }
}

struct FlowEditorSheet: View {
    enum OpenTargetChoice: String, CaseIterable, Identifiable {
        case website = "Website or CRM"
        case application = "Application"
        var id: Self { self }
    }

    let folders: [FolderDestination]
    let aiAvailability: OnDeviceAIAvailability
    let applications: [ApplicationExclusionOption]
    let isDiscoveringApplications: Bool
    let refreshApplications: () -> Void
    let makeApplicationStep: (UUID, URL) -> ClipFlowStep?
    let save: (String, ClipFlowTrigger, ClipAutomationEntityFilter, CustomClipTextMatcher?, [ClipFlowStep]) -> Bool
    let cancel: () -> Void
    let existingFlow: ClipFlow?

    @State private var name = "Sales follow-up"
    @State private var filter: ClipAutomationEntityFilter = .any
    @State private var customMatchMode: CustomClipTextMatchMode = .wordsOrPhrases
    @State private var customPattern = ""
    @State private var customMatchIsCaseSensitive = false
    @State private var triggerAutomatically = false
    @State private var triggerFolderID: UUID?
    @State private var includeDescendantFolders = false
    @State private var tags = ""
    @State private var shouldMove = false
    @State private var moveFolderID: UUID?
    @State private var shouldOpenCRM = false
    @State private var openTargetChoice: OpenTargetChoice = .website
    @State private var crmName = "HubSpot"
    @State private var crmTemplate = "https://app.hubspot.com/search?q={email}"
    @State private var applicationSearch = ""
    @State private var applicationURL: URL?
    @State private var applicationStep: ClipFlowStep?
    @State private var shouldCreateTask = false
    @State private var taskTitle = "Follow up: {title}"
    @State private var dueInDays = 2
    @State private var shouldEnrich = false
    @State private var enrichmentPrompt = "Summarize the account context and suggest the next action."
    @State private var tagStepID = UUID()
    @State private var moveStepID = UUID()
    @State private var crmStepID = UUID()
    @State private var taskStepID = UUID()
    @State private var enrichmentStepID = UUID()

    init(
        existingFlow: ClipFlow? = nil,
        folders: [FolderDestination],
        aiAvailability: OnDeviceAIAvailability,
        applications: [ApplicationExclusionOption],
        isDiscoveringApplications: Bool,
        refreshApplications: @escaping () -> Void,
        makeApplicationStep: @escaping (UUID, URL) -> ClipFlowStep?,
        save: @escaping (String, ClipFlowTrigger, ClipAutomationEntityFilter, CustomClipTextMatcher?, [ClipFlowStep]) -> Bool,
        cancel: @escaping () -> Void
    ) {
        self.existingFlow = existingFlow
        self.folders = folders
        self.aiAvailability = aiAvailability
        self.applications = applications
        self.isDiscoveringApplications = isDiscoveringApplications
        self.refreshApplications = refreshApplications
        self.makeApplicationStep = makeApplicationStep
        self.save = save
        self.cancel = cancel
        guard let flow = existingFlow else { return }
        _name = State(initialValue: flow.name)
        _filter = State(initialValue: flow.entityFilter)
        if let matcher = flow.customMatcher {
            _customMatchMode = State(initialValue: matcher.mode)
            _customPattern = State(initialValue: matcher.pattern)
            _customMatchIsCaseSensitive = State(initialValue: matcher.isCaseSensitive)
        }
        if case let .folderEntry(folderID, includeDescendants) = flow.trigger {
            _triggerAutomatically = State(initialValue: true)
            _triggerFolderID = State(initialValue: folderID)
            _includeDescendantFolders = State(initialValue: includeDescendants)
        }
        for step in flow.steps {
            switch step {
            case let .addTags(id, values):
                _tagStepID = State(initialValue: id)
                _tags = State(initialValue: values.joined(separator: ", "))
            case let .moveToFolder(id, folderID):
                _moveStepID = State(initialValue: id)
                _shouldMove = State(initialValue: true)
                _moveFolderID = State(initialValue: folderID)
            case let .openWeb(id, template, label):
                _crmStepID = State(initialValue: id)
                _shouldOpenCRM = State(initialValue: true)
                _openTargetChoice = State(initialValue: .website)
                _crmName = State(initialValue: label)
                _crmTemplate = State(initialValue: template)
            case let .openApplication(id, _, displayName):
                _crmStepID = State(initialValue: id)
                _shouldOpenCRM = State(initialValue: true)
                _openTargetChoice = State(initialValue: .application)
                _applicationSearch = State(initialValue: displayName)
                _applicationStep = State(initialValue: step)
            case let .createTaskDraft(id, title, due):
                _taskStepID = State(initialValue: id)
                _shouldCreateTask = State(initialValue: true)
                _taskTitle = State(initialValue: title)
                _dueInDays = State(initialValue: due)
            case let .enrichWithOnDeviceAI(id, instruction):
                _enrichmentStepID = State(initialValue: id)
                _shouldEnrich = State(initialValue: true)
                _enrichmentPrompt = State(initialValue: instruction)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(existingFlow == nil ? "Create Custom Action" : "Edit Custom Action")
                .font(.title2.weight(.semibold))
            Text("Build a reviewed flow from safe, typed steps. Clipboard Router does not support scripts, automatic sends, or arbitrary webhooks.")
                .foregroundStyle(.secondary)

            Form {
                Section("Basics") {
                    TextField("Action name", text: $name)
                        .accessibilityIdentifier("uiAcceptance.flow.name")
                    Picker("Show for", selection: $filter) {
                        ForEach(ClipAutomationEntityFilter.allCases, id: \.self) {
                            Text($0.displayName).tag($0)
                        }
                    }
                    .accessibilityIdentifier(ActionFlowAccessibility.flowFilter)
                    .accessibilityValue(filter.displayName)
                    if filter == .customText {
                        CustomClipMatcherEditor(
                            mode: $customMatchMode,
                            pattern: $customPattern,
                            isCaseSensitive: $customMatchIsCaseSensitive
                        )
                    }
                }
                Section("Trigger") {
                    Toggle("When a clip enters a folder", isOn: $triggerAutomatically)
                        .accessibilityIdentifier(ActionFlowAccessibility.flowTrigger)
                        .accessibilityValue("automatic=\(triggerAutomatically)")
                    if triggerAutomatically {
                        folderPicker(
                            "Watch folder",
                            selection: $triggerFolderID,
                            identifier: ActionFlowAccessibility.flowTriggerFolder
                        )
                        Toggle("Include descendant folders", isOn: $includeDescendantFolders)
                            .accessibilityIdentifier(ActionFlowAccessibility.flowIncludeDescendants)
                            .accessibilityValue("included=\(includeDescendantFolders)")
                        Text("Local reversible steps can start after a user move. CRM, app, follow-up note, and AI steps wait in Ready for Review. Sync changes never trigger a flow.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Steps — run top to bottom") {
                    TextField("1. Add tags (comma separated)", text: $tags)
                        .accessibilityIdentifier("uiAcceptance.flow.tags")
                    Toggle("2. Move to folder", isOn: $shouldMove)
                        .accessibilityIdentifier(ActionFlowAccessibility.flowMove)
                        .accessibilityValue("enabled=\(shouldMove)")
                    if shouldMove {
                        folderPicker(
                            "Destination",
                            selection: $moveFolderID,
                            identifier: ActionFlowAccessibility.flowMoveFolder
                        )
                    }
                    Toggle("3. Open a website, CRM, or app", isOn: $shouldOpenCRM)
                        .accessibilityIdentifier(ActionFlowAccessibility.flowOpen)
                        .accessibilityValue("enabled=\(shouldOpenCRM)")
                    if shouldOpenCRM {
                        Picker("Destination type", selection: $openTargetChoice) {
                            ForEach(OpenTargetChoice.allCases) { choice in
                                Text(choice.rawValue).tag(choice)
                            }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier(ActionFlowAccessibility.flowOpenType)
                        .accessibilityValue("kind=\(openTargetChoice == .website ? "website" : "application")")
                        if openTargetChoice == .website {
                            TextField("Destination name", text: $crmName)
                                .accessibilityIdentifier(ActionFlowAccessibility.flowOpenName)
                            TextField("HTTPS template", text: $crmTemplate)
                                .accessibilityIdentifier(ActionFlowAccessibility.flowOpenTemplate)
                            Text("Placeholders: {clip}, {url}, {email}, {phone}. This opens a reviewed browser destination; it does not claim an API write.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            VerifiedApplicationSelectionList(
                                applications: filteredApplications,
                                isDiscovering: isDiscoveringApplications,
                                search: $applicationSearch,
                                selection: $applicationURL,
                                existingSelectionLabel: existingApplicationLabel,
                                accessibilityScopeID: ActionFlowAccessibility.openApplicationScope(crmStepID)
                            )
                            Text("The clip is copied, then the selected signed app is opened. Clipboard Router never types or submits it.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Toggle("4. Create a follow-up note", isOn: $shouldCreateTask)
                        .accessibilityIdentifier(ActionFlowAccessibility.flowCreateTask)
                        .accessibilityValue(shouldCreateTask ? "On" : "Off")
                    if shouldCreateTask {
                        TextField("Note title", text: $taskTitle)
                            .accessibilityIdentifier(ActionFlowAccessibility.flowTaskTitle)
                        Stepper("Due in \(dueInDays) days", value: $dueInDays, in: 0...365)
                            .accessibilityIdentifier(ActionFlowAccessibility.flowTaskDueDays)
                            .accessibilityValue("\(dueInDays)")
                    }
                    Toggle("5. Add on-device AI enrichment", isOn: $shouldEnrich)
                        .accessibilityIdentifier(ActionFlowAccessibility.flowEnrich)
                        .accessibilityValue("enabled=\(shouldEnrich)")
                    if shouldEnrich {
                        TextField("Instruction", text: $enrichmentPrompt, axis: .vertical)
                            .lineLimit(2...5)
                            .accessibilityIdentifier(ActionFlowAccessibility.flowEnrichmentInstruction)
                        Label(onDeviceAIStatus, systemImage: aiAvailability == .available ? "checkmark.circle" : "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(aiAvailability == .available ? Color.secondary : Color.orange)
                    }
                }
            }
            .formStyle(.grouped)

            if builtSteps.isEmpty {
                Label("Add at least one step before saving this action.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Cancel", action: cancel)
                    .accessibilityIdentifier(ActionFlowAccessibility.flowCancel)
                Spacer()
                Button(existingFlow == nil ? "Save Custom Action" : "Save Changes") {
                    if save(name, trigger, filter, selectedCustomMatcher, builtSteps) { cancel() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(cannotCommit)
                .accessibilityIdentifier(ActionFlowAccessibility.flowCommit)
                .accessibilityValue(cannotCommit ? "Unavailable" : "Ready")
            }
        }
        .padding(20)
        .frame(width: 640, height: 720)
        .onAppear(perform: refreshApplications)
        .onChange(of: applicationURL) { _, newValue in
            applicationStep = newValue.flatMap { makeApplicationStep(crmStepID, $0) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(ActionFlowAccessibility.flowEditor)
        .accessibilityValue(ActionFlowAccessibility.editorValue(
            editingID: existingFlow?.id,
            matcherState: matcherAccessibilityState,
            stepCount: builtSteps.count,
            canCommit: !cannotCommit
        ))
        .accessibilityHint(ActionFlowAccessibility.structuredEditorState(
            triggerFolderID: triggerAutomatically ? triggerFolderID : nil,
            includesDescendants: triggerAutomatically && includeDescendantFolders,
            moveFolderID: shouldMove ? moveFolderID : nil,
            openKind: shouldOpenCRM ? (openTargetChoice == .website ? "website" : "application") : "none",
            stepCount: builtSteps.count,
            canCommit: !cannotCommit
        ))
    }

    private var trigger: ClipFlowTrigger {
        if triggerAutomatically, let triggerFolderID {
            return .folderEntry(
                folderID: triggerFolderID,
                includeDescendants: includeDescendantFolders
            )
        }
        return .manual
    }

    private var selectedCustomMatcher: CustomClipTextMatcher? {
        guard filter == .customText else { return nil }
        return try? CustomClipTextMatcher(
            mode: customMatchMode,
            pattern: customPattern,
            isCaseSensitive: customMatchIsCaseSensitive
        )
    }

    private var matcherAccessibilityState: String {
        guard filter == .customText else { return "Any eligible clip" }
        let trimmed = customPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Custom match required" }
        guard let selectedCustomMatcher else { return "Custom match invalid" }
        return selectedCustomMatcher.summary
    }

    private var cannotCommit: Bool {
        builtSteps.isEmpty
            || (filter == .customText && selectedCustomMatcher == nil)
            || (triggerAutomatically && triggerFolderID == nil)
            || hasInvalidOpenTarget
            || (shouldEnrich && aiAvailability != .available)
    }

    private var onDeviceAIStatus: String {
        switch aiAvailability {
        case .available:
            "Apple Intelligence is ready on this Mac."
        case .requiresMacOS26:
            "This step requires macOS 26 or later."
        case .appleIntelligenceUnavailable:
            "Turn on Apple Intelligence before using this step."
        }
    }

    private var builtSteps: [ClipFlowStep] {
        var steps: [ClipFlowStep] = []
        let parsedTags = tags.split(separator: ",").map(String.init)
        if !parsedTags.isEmpty { steps.append(.addTags(id: tagStepID, tags: parsedTags)) }
        if shouldMove { steps.append(.moveToFolder(id: moveStepID, folderID: moveFolderID)) }
        if shouldOpenCRM {
            switch openTargetChoice {
            case .website:
                steps.append(.openWeb(id: crmStepID, template: crmTemplate, label: crmName))
            case .application:
                if let applicationStep { steps.append(applicationStep) }
            }
        }
        if shouldCreateTask {
            steps.append(.createTaskDraft(id: taskStepID, titleTemplate: taskTitle, dueInDays: dueInDays))
        }
        if shouldEnrich {
            steps.append(.enrichWithOnDeviceAI(id: enrichmentStepID, instruction: enrichmentPrompt))
        }
        return steps
    }

    private var hasInvalidOpenTarget: Bool {
        shouldOpenCRM && openTargetChoice == .application && applicationStep == nil
    }

    private var existingApplicationLabel: String? {
        guard applicationURL == nil,
              case let .openApplication(_, _, displayName)? = applicationStep
        else { return nil }
        return displayName
    }

    private var filteredApplications: [ApplicationExclusionOption] {
        let query = applicationSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return Array(applications.prefix(80)) }
        return applications.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
                || $0.bundleIdentifier.localizedCaseInsensitiveContains(query)
        }.prefix(80).map { $0 }
    }

    private func folderPicker(
        _ title: String,
        selection: Binding<UUID?>,
        identifier: String
    ) -> some View {
        Picker(title, selection: selection) {
            Text("Saved").tag(UUID?.none)
            ForEach(folders) { folder in
                Text(folder.path).tag(UUID?.some(folder.id))
            }
        }
        .accessibilityIdentifier(identifier)
        .accessibilityValue("folder=\(selection.wrappedValue?.uuidString.lowercased() ?? "saved")")
    }
}
