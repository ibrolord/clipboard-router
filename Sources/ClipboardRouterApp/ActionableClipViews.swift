import AppKit
import ClipboardRouterCore
import ClipboardRouterPlatform
import SwiftUI

enum ActionFlowAccessibility {
    static let settings = "uiAcceptance.actions.settings"
    static let newFlow = "uiAcceptance.actions.newFlow"
    static let flowEditor = "uiAcceptance.flow.editor"
    static let flowName = "uiAcceptance.flow.name"
    static let flowFilter = "uiAcceptance.flow.filter"
    static let flowTags = "uiAcceptance.flow.tags"
    static let flowCreateTask = "uiAcceptance.flow.createTask"
    static let flowTaskTitle = "uiAcceptance.flow.taskTitle"
    static let flowTaskDueDays = "uiAcceptance.flow.taskDueDays"
    static let flowTrigger = "uiAcceptance.flow.trigger"
    static let flowTriggerFolder = "uiAcceptance.flow.triggerFolder"
    static let flowIncludeDescendants = "uiAcceptance.flow.includeDescendants"
    static let flowMove = "uiAcceptance.flow.move"
    static let flowMoveFolder = "uiAcceptance.flow.moveFolder"
    static let flowOpen = "uiAcceptance.flow.open"
    static let flowOpenType = "uiAcceptance.flow.openType"
    static let flowOpenName = "uiAcceptance.flow.openName"
    static let flowOpenTemplate = "uiAcceptance.flow.openTemplate"
    static let flowEnrich = "uiAcceptance.flow.enrich"
    static let flowEnrichmentInstruction = "uiAcceptance.flow.enrichmentInstruction"
    static let flowCancel = "uiAcceptance.flow.cancel"
    static let flowCommit = "uiAcceptance.flow.commit"
    static let matcherMode = "uiAcceptance.customMatcher.mode"
    static let matcherPattern = "uiAcceptance.customMatcher.pattern"
    static let matcherCaseSensitive = "uiAcceptance.customMatcher.caseSensitive"
    static let matcherError = "uiAcceptance.customMatcher.error"
    static let deletionCancel = "uiAcceptance.actions.deleteCancel"

    static func flowRow(_ id: UUID) -> String {
        "uiAcceptance.actions.flowRow.\(identifierComponent(id))"
    }

    static func flowEdit(_ id: UUID) -> String {
        "uiAcceptance.actions.flowEdit.\(identifierComponent(id))"
    }

    static func flowDelete(_ id: UUID) -> String {
        "uiAcceptance.actions.flowDelete.\(identifierComponent(id))"
    }

    static func confirmFlowDelete(_ id: UUID) -> String {
        "uiAcceptance.actions.confirmFlowDelete.\(identifierComponent(id))"
    }

    static func review(_ id: UUID) -> String {
        "uiAcceptance.flow.review.\(identifierComponent(id))"
    }

    static func reviewStep(_ id: UUID) -> String {
        "uiAcceptance.flow.reviewStep.\(identifierComponent(id))"
    }

    static func reviewRun(_ id: UUID) -> String {
        "uiAcceptance.flow.reviewRun.\(identifierComponent(id))"
    }

    static func reviewCancel(_ id: UUID) -> String {
        "uiAcceptance.flow.reviewCancel.\(identifierComponent(id))"
    }

    static func openApplicationScope(_ stepID: UUID) -> String {
        "uiAcceptance.flow.openApplication.\(identifierComponent(stepID))"
    }

    static func structuredEditorState(
        triggerFolderID: UUID?,
        includesDescendants: Bool,
        moveFolderID: UUID?,
        openKind: String,
        stepCount: Int,
        canCommit: Bool
    ) -> String {
        [
            "triggerFolder=\(triggerFolderID.map(identifierComponent) ?? "none")",
            "descendants=\(includesDescendants)",
            "moveFolder=\(moveFolderID.map(identifierComponent) ?? "none")",
            "open=\(component(openKind))",
            "steps=\(stepCount)",
            "canCommit=\(canCommit)",
        ].joined(separator: "|")
    }

    static func flowRowValue(
        matcherSummary: String,
        stepCount: Int,
        isAutomatic: Bool,
        isEnabled: Bool
    ) -> String {
        let stepLabel = stepCount == 1 ? "1 step" : "\(stepCount) steps"
        return [
            isEnabled ? "Enabled" : "Disabled",
            matcherSummary,
            stepLabel,
            isAutomatic ? "folder trigger" : "manual",
        ].joined(separator: ", ")
    }

    static func editorValue(
        editingID: UUID?,
        matcherState: String,
        stepCount: Int,
        canCommit: Bool
    ) -> String {
        let mode = editingID.map { "Editing \(identifierComponent($0))" } ?? "Creating"
        let stepLabel = stepCount == 1 ? "1 step" : "\(stepCount) steps"
        return "\(mode), \(matcherState), \(stepLabel), \(canCommit ? "ready to save" : "cannot save")"
    }

    static func reviewValue(
        flowName: String,
        stepCount: Int,
        triggeredAutomatically: Bool,
        isRunning: Bool
    ) -> String {
        let stepLabel = stepCount == 1 ? "1 step" : "\(stepCount) steps"
        let trigger = triggeredAutomatically ? "automatic trigger" : "manual run"
        return "\(flowName), \(stepLabel), \(trigger), \(isRunning ? "running" : "ready for review")"
    }

    private static func identifierComponent(_ id: UUID) -> String {
        id.uuidString.lowercased()
    }

    static func component(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}

enum ClipActionAcceptanceAccessibility {
    static func action(
        _ descriptor: ClipActionDescriptor,
        clipID: UUID,
        surface: ClipActionSurface
    ) -> String {
        "uiAcceptance.clipAction.\(surface.rawValue).\(uuid(clipID)).\(descriptor.id.rawValue)"
    }

    static func surface(_ surface: ClipActionSurface, clipID: UUID) -> String {
        "uiAcceptance.clipActions.\(surface.rawValue).\(uuid(clipID))"
    }

    static func descriptorValue(
        _ descriptor: ClipActionDescriptor,
        index: Int
    ) -> String {
        [
            "index=\(index)",
            "id=\(descriptor.id.rawValue)",
            "group=\(descriptor.group.rawValue)",
            "order=\(descriptor.order)",
            "enabled=\(descriptor.isEnabled)",
            "reason=\(component(descriptor.disabledReason ?? "none"))",
            "presentation=\(presentation(descriptor.presentation))",
        ].joined(separator: "|")
    }

    static func inventoryValue(_ inventory: ClipActionInventory) -> String {
        inventory.descriptors.enumerated().map { index, descriptor in
            descriptorValue(descriptor, index: index)
        }.joined(separator: ";")
    }

    static func index(of descriptor: ClipActionDescriptor, in inventory: ClipActionInventory) -> Int {
        inventory.descriptors.firstIndex(where: { $0.id == descriptor.id }) ?? -1
    }

    static func component(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private static func presentation(_ value: ClipActionPresentation) -> String {
        switch value {
        case .immediate: "immediate"
        case .submenu: "submenu"
        case .persistentContinuation: "persistentContinuation"
        case .libraryRoute: "libraryRoute"
        case .systemPanel: "systemPanel"
        case .destructive: "destructive"
        }
    }

    private static func uuid(_ id: UUID) -> String { id.uuidString.lowercased() }
}

struct SuggestedClipAction: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable {
        case openLink
        case composeEmail
        case openCallingApp
        case saveContact
        case createCalendarEvent
        case findRelated
        case askAI
    }

    let kind: Kind
    let entity: DetectedClipEntity?

    var id: String { "\(kind.rawValue):\(entity?.id ?? "clip")" }

    var title: String {
        switch kind {
        case .openLink: "Open Link"
        case .composeEmail: "Compose Email"
        case .openCallingApp: "Open Calling App"
        case .saveContact: "Save to Contacts…"
        case .createCalendarEvent: "Add to Calendar…"
        case .findRelated: "Find Related"
        case .askAI: "Use AI…"
        }
    }

    var symbolName: String {
        switch kind {
        case .openLink: "safari"
        case .composeEmail: "envelope"
        case .openCallingApp: "phone"
        case .saveContact: "person.crop.circle.badge.plus"
        case .createCalendarEvent: "calendar.badge.plus"
        case .findRelated: "magnifyingglass"
        case .askAI: "sparkles"
        }
    }

    var valuePreview: String {
        if kind == .createCalendarEvent, let date = entity?.date {
            return date.formatted(date: .abbreviated, time: .shortened)
        }
        return entity?.normalizedValue ?? "Review the clip and choose on-device or Fast cloud processing"
    }
}

struct ActionableClipMenuContent: View {
    let suggestions: [SuggestedClipAction]
    let automations: [ClipAutomation]
    let flows: [ClipFlow]
    let runSuggestion: (SuggestedClipAction) -> Void
    let runAutomation: (ClipAutomation) -> Void
    let runFlow: (ClipFlow) -> Void
    let canCreateCustomAction: Bool
    let createCustomAction: () -> Void

    var body: some View {
        let quickSuggestions = suggestions.filter { $0.kind != .askAI }
        let assistantAction = suggestions.first { $0.kind == .askAI }

        if !quickSuggestions.isEmpty {
            Menu("Quick Actions", systemImage: "bolt") {
                ForEach(quickSuggestions) { suggestion in
                    Button {
                        runSuggestion(suggestion)
                    } label: {
                        Label(suggestion.title, systemImage: suggestion.symbolName)
                    }
                    .help(suggestion.valuePreview)
                }
            }
        }

        if !automations.isEmpty {
            Menu("One-click Destinations", systemImage: "play.square.stack") {
                ForEach(automations) { automation in
                    Button(automation.name) { runAutomation(automation) }
                }
            }
        }

        if !flows.isEmpty {
            Menu("Run Custom Action", systemImage: "bolt.square") {
                ForEach(flows) { flow in
                    Button(flow.name) { runFlow(flow) }
                }
            }
        }

        if let assistantAction {
            Button("Use AI…", systemImage: "sparkles") {
                runSuggestion(assistantAction)
            }
            .help("Rewrite, extract details, research, or ask. Nothing is sent until you press Send.")
        }

        if canCreateCustomAction {
            Button("Create Custom Action…", systemImage: "plus.circle", action: createCustomAction)
        }
    }
}

struct SuggestedActionsSection: View {
    let suggestions: [SuggestedClipAction]
    let automations: [ClipAutomation]
    let flows: [ClipFlow]
    let runSuggestion: (SuggestedClipAction) -> Void
    let runAutomation: (ClipAutomation) -> Void
    let runFlow: (ClipFlow) -> Void
    let canCreateCustomAction: Bool
    let createCustomAction: () -> Void

    var body: some View {
        if !suggestions.isEmpty || !automations.isEmpty || !flows.isEmpty || canCreateCustomAction {
            VStack(alignment: .leading, spacing: 9) {
                Text("Actions")
                    .font(.headline)
                if !suggestions.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(suggestions.prefix(3)) { suggestion in
                            Button(suggestion.title, systemImage: suggestion.symbolName) {
                                runSuggestion(suggestion)
                            }
                            .help(suggestion.valuePreview)
                        }
                    }
                }
                if !automations.isEmpty {
                    Menu("One-click Destinations", systemImage: "play.square.stack") {
                        ForEach(automations) { automation in
                            Button(automation.name) { runAutomation(automation) }
                        }
                    }
                }
                if !flows.isEmpty {
                    Menu("Run Custom Action", systemImage: "bolt.square") {
                        ForEach(flows) { flow in
                            Button(flow.name) { runFlow(flow) }
                        }
                    }
                }
                if canCreateCustomAction {
                    Button("Create Custom Action…", systemImage: "plus.circle", action: createCustomAction)
                }
                Text("Detected locally. Nothing is sent, called, or scheduled until you choose an action.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
        }
    }
}

struct CalendarEventDraftSheet: View {
    @State private var draft: CalendarEventDraft
    let save: (CalendarEventDraft) async -> Bool
    let cancel: () -> Void

    init(
        draft: CalendarEventDraft,
        save: @escaping (CalendarEventDraft) async -> Bool,
        cancel: @escaping () -> Void
    ) {
        _draft = State(initialValue: draft)
        self.save = save
        self.cancel = cancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add to Calendar")
                .font(.title2.weight(.semibold))
            Text("Review the event before Clipboard Router requests Calendar access or saves anything.")
                .foregroundStyle(.secondary)

            Form {
                TextField("Title", text: $draft.title)
                DatePicker("Starts", selection: $draft.startDate)
                DatePicker(
                    "Ends",
                    selection: $draft.endDate,
                    in: draft.startDate.addingTimeInterval(60)...
                )
                TextField("Notes", text: $draft.notes, axis: .vertical)
                    .lineLimit(3...8)
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                Button("Add Event") {
                    Task { _ = await save(draft) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || draft.endDate <= draft.startDate
                )
            }
        }
        .padding(20)
        .frame(width: 520, height: 390)
    }
}

struct CustomClipMatcherEditor: View {
    @Binding var mode: CustomClipTextMatchMode
    @Binding var pattern: String
    @Binding var isCaseSensitive: Bool

    var body: some View {
        Picker("Match type", selection: $mode) {
            ForEach(CustomClipTextMatchMode.allCases, id: \.self) { option in
                Text(option.displayName).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier(ActionFlowAccessibility.matcherMode)
        .accessibilityValue(mode.displayName)

        TextField(
            mode == .wordsOrPhrases
                ? "Words or phrases, separated by commas"
                : "Regular expression",
            text: $pattern,
            axis: .vertical
        )
        .lineLimit(1...3)
        .accessibilityIdentifier(ActionFlowAccessibility.matcherPattern)

        Toggle("Case sensitive", isOn: $isCaseSensitive)
            .accessibilityIdentifier(ActionFlowAccessibility.matcherCaseSensitive)
            .accessibilityValue(isCaseSensitive ? "On" : "Off")

        if let validationMessage {
            Label(validationMessage, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .accessibilityLabel("Custom match error: \(validationMessage)")
                .accessibilityValue(validationMessage)
                .accessibilityIdentifier(ActionFlowAccessibility.matcherError)
        } else {
            Text(helpText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var validationMessage: String? {
        guard !pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        do {
            _ = try CustomClipTextMatcher(
                mode: mode,
                pattern: pattern,
                isCaseSensitive: isCaseSensitive
            )
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private var helpText: String {
        switch mode {
        case .wordsOrPhrases:
            "The action appears when the clip contains any listed word or phrase. Matching stays on this Mac."
        case .regularExpression:
            "The pattern is checked locally against text clips up to 8 KB. Lookarounds, backreferences, and nested quantifiers are blocked."
        }
    }
}

struct AutomationEditorSheet: View {
    enum TargetChoice: String, CaseIterable, Identifiable {
        case web = "Web URL"
        case application = "Application"
        var id: Self { self }
    }

    let folders: [FolderDestination]
    let applications: [ApplicationExclusionOption]
    let isDiscoveringApplications: Bool
    let refreshApplications: () -> Void
    let saveWeb: (String, ClipAutomationEntityFilter, CustomClipTextMatcher?, UUID?, String) -> Bool
    let saveApplication: (String, ClipAutomationEntityFilter, CustomClipTextMatcher?, UUID?, URL) -> Bool
    let cancel: () -> Void
    let existingAutomation: ClipAutomation?

    @State private var name = ""
    @State private var filter: ClipAutomationEntityFilter = .any
    @State private var customMatchMode: CustomClipTextMatchMode = .wordsOrPhrases
    @State private var customPattern = ""
    @State private var customMatchIsCaseSensitive = false
    @State private var folderID: UUID?
    @State private var targetChoice: TargetChoice = .web
    @State private var template = "https://www.google.com/search?q={clip}"
    @State private var applicationURL: URL?
    @State private var applicationSearch = ""

    init(
        existingAutomation: ClipAutomation? = nil,
        folders: [FolderDestination],
        applications: [ApplicationExclusionOption],
        isDiscoveringApplications: Bool,
        refreshApplications: @escaping () -> Void,
        saveWeb: @escaping (String, ClipAutomationEntityFilter, CustomClipTextMatcher?, UUID?, String) -> Bool,
        saveApplication: @escaping (String, ClipAutomationEntityFilter, CustomClipTextMatcher?, UUID?, URL) -> Bool,
        cancel: @escaping () -> Void
    ) {
        self.existingAutomation = existingAutomation
        self.folders = folders
        self.applications = applications
        self.isDiscoveringApplications = isDiscoveringApplications
        self.refreshApplications = refreshApplications
        self.saveWeb = saveWeb
        self.saveApplication = saveApplication
        self.cancel = cancel
        _name = State(initialValue: existingAutomation?.name ?? "")
        _filter = State(initialValue: existingAutomation?.entityFilter ?? .any)
        if let matcher = existingAutomation?.customMatcher {
            _customMatchMode = State(initialValue: matcher.mode)
            _customPattern = State(initialValue: matcher.pattern)
            _customMatchIsCaseSensitive = State(initialValue: matcher.isCaseSensitive)
        }
        _folderID = State(initialValue: existingAutomation?.requiredFolderID)
        if case let .webURLTemplate(template)? = existingAutomation?.target {
            _targetChoice = State(initialValue: .web)
            _template = State(initialValue: template)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(existingAutomation == nil ? "New One-click Destination" : "Edit One-click Destination")
                .font(.title2.weight(.semibold))
            Text("One-click destinations run only when you choose them on a clip. They never run during capture or sync.")
                .foregroundStyle(.secondary)

            Form {
                TextField("Name", text: $name)
                    .accessibilityIdentifier("uiAcceptance.automation.name")
                Picker("Show for", selection: $filter) {
                    ForEach(ClipAutomationEntityFilter.allCases, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                .accessibilityIdentifier("uiAcceptance.automation.filter")
                if filter == .customText {
                    CustomClipMatcherEditor(
                        mode: $customMatchMode,
                        pattern: $customPattern,
                        isCaseSensitive: $customMatchIsCaseSensitive
                    )
                }
                Picker("Folder condition", selection: $folderID) {
                    Text("Any folder").tag(UUID?.none)
                    ForEach(folders) { folder in
                        Text(folder.path).tag(UUID?.some(folder.id))
                    }
                }
                Picker("Target", selection: $targetChoice) {
                    ForEach(TargetChoice.allCases) { Text($0.rawValue).tag($0) }
                }
                .disabled(existingAutomation != nil)
                if targetChoice == .web {
                    TextField("HTTPS URL template", text: $template)
                        .accessibilityIdentifier("uiAcceptance.automation.template")
                    Text("Use {clip}, {url}, {email}, or {phone}. Choosing this action opens the rendered URL in your browser.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VerifiedApplicationSelectionList(
                        applications: filteredApplications,
                        isDiscovering: isDiscoveringApplications,
                        search: $applicationSearch,
                        selection: $applicationURL
                    )
                    Button("Choose Application…", systemImage: "folder") {
                        chooseApplication()
                    }
                    Text("The selected clip is copied, then the signed app is opened. Clipboard Router never types or submits it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                Button(existingAutomation == nil ? "Save Destination" : "Save Changes") {
                    switch targetChoice {
                    case .web:
                        if saveWeb(name, filter, selectedCustomMatcher, folderID, template) { cancel() }
                    case .application:
                        if let applicationURL,
                           saveApplication(name, filter, selectedCustomMatcher, folderID, applicationURL)
                        { cancel() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || (filter == .customText && selectedCustomMatcher == nil)
                        || (targetChoice == .application && applicationURL == nil)
                )
                .accessibilityIdentifier("uiAcceptance.automation.commit")
            }
        }
        .padding(20)
        .frame(width: 600, height: 560)
        .onAppear(perform: refreshApplications)
    }

    private var filteredApplications: [ApplicationExclusionOption] {
        let query = applicationSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return Array(applications.prefix(80)) }
        return applications.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
                || $0.bundleIdentifier.localizedCaseInsensitiveContains(query)
        }.prefix(80).map { $0 }
    }

    private var selectedCustomMatcher: CustomClipTextMatcher? {
        guard filter == .customText else { return nil }
        return try? CustomClipTextMatcher(
            mode: customMatchMode,
            pattern: customPattern,
            isCaseSensitive: customMatchIsCaseSensitive
        )
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.title = "Choose Destination Application"
        panel.prompt = "Choose Application"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        if panel.runModal() == .OK { applicationURL = panel.url }
    }
}

/// A single, consistent app chooser shared by one-click destinations and custom actions.
/// Discovery and code-signature verification remain owned by `AppModel`; this view only
/// filters and selects from that verified catalog.
struct VerifiedApplicationSelectionList: View {
    let applications: [ApplicationExclusionOption]
    let isDiscovering: Bool
    @Binding var search: String
    @Binding var selection: URL?
    var existingSelectionLabel: String? = nil
    var accessibilityScopeID: String? = nil

    var body: some View {
        TextField("Search installed apps", text: $search)
            .textFieldStyle(.roundedBorder)
            .verifiedApplicationAcceptanceIdentifier(accessibilityScopeID.map { "\($0).search" })

        if isDiscovering, applications.isEmpty {
            HStack(spacing: 8) {
                ProgressView()
                Text("Checking installed applications…")
                    .foregroundStyle(.secondary)
            }
        } else if applications.isEmpty {
            Label("No matching signed application", systemImage: "app.dashed")
                .foregroundStyle(.secondary)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(applications.prefix(12).enumerated()), id: \.element.id) { index, application in
                    Button {
                        selection = application.applicationURL
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "app")
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(application.displayName)
                                    .foregroundStyle(.primary)
                                Text(application.bundleIdentifier)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if selection == application.applicationURL {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.tint)
                            }
                        }
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Select \(application.displayName)")
                    .accessibilityValue(selection == application.applicationURL ? "Selected" : "Not selected")
                    .verifiedApplicationAcceptanceIdentifier(
                        accessibilityScopeID.map {
                            "\($0).row.\(ActionFlowAccessibility.component(application.bundleIdentifier))"
                        }
                    )

                    if index < min(applications.count, 12) - 1 { Divider() }
                }
            }
            .padding(.horizontal, 10)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 9))

            if let selected = applications.first(where: { $0.applicationURL == selection }) {
                Label("Selected: \(selected.displayName)", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let existingSelectionLabel {
                Label("Current: \(existingSelectionLabel)", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Label("Choose one application to continue.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private extension View {
    @ViewBuilder
    func verifiedApplicationAcceptanceIdentifier(_ identifier: String?) -> some View {
        if let identifier {
            accessibilityIdentifier(identifier)
        } else {
            self
        }
    }
}

private struct ApplicationAutomationMetadataEditorSheet: View {
    let automation: ClipAutomation
    let folders: [FolderDestination]
    let save: (String, ClipAutomationEntityFilter, CustomClipTextMatcher?, UUID?) -> Bool
    let cancel: () -> Void
    @State private var name: String
    @State private var filter: ClipAutomationEntityFilter
    @State private var customMatchMode: CustomClipTextMatchMode
    @State private var customPattern: String
    @State private var customMatchIsCaseSensitive: Bool
    @State private var folderID: UUID?

    init(
        automation: ClipAutomation,
        folders: [FolderDestination],
        save: @escaping (String, ClipAutomationEntityFilter, CustomClipTextMatcher?, UUID?) -> Bool,
        cancel: @escaping () -> Void
    ) {
        self.automation = automation
        self.folders = folders
        self.save = save
        self.cancel = cancel
        _name = State(initialValue: automation.name)
        _filter = State(initialValue: automation.entityFilter)
        _customMatchMode = State(initialValue: automation.customMatcher?.mode ?? .wordsOrPhrases)
        _customPattern = State(initialValue: automation.customMatcher?.pattern ?? "")
        _customMatchIsCaseSensitive = State(initialValue: automation.customMatcher?.isCaseSensitive ?? false)
        _folderID = State(initialValue: automation.requiredFolderID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit One-click Destination")
                .font(.title2.weight(.semibold))
            Form {
                TextField("Name", text: $name)
                Picker("Show for", selection: $filter) {
                    ForEach(ClipAutomationEntityFilter.allCases, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                if filter == .customText {
                    CustomClipMatcherEditor(
                        mode: $customMatchMode,
                        pattern: $customPattern,
                        isCaseSensitive: $customMatchIsCaseSensitive
                    )
                }
                Picker("Folder condition", selection: $folderID) {
                    Text("Any folder").tag(UUID?.none)
                    ForEach(folders) { folder in
                        Text(folder.path).tag(UUID?.some(folder.id))
                    }
                }
                if case let .application(_, displayName) = automation.target {
                    LabeledContent("Application", value: displayName)
                    Text("The verified application target is preserved. Create a new destination to choose a different app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                Button("Cancel", action: cancel)
                Spacer()
                Button("Save Changes") {
                    if save(name, filter, selectedCustomMatcher, folderID) { cancel() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || (filter == .customText && selectedCustomMatcher == nil)
                )
            }
        }
        .padding(20)
        .frame(width: 520, height: 390)
    }

    private var selectedCustomMatcher: CustomClipTextMatcher? {
        guard filter == .customText else { return nil }
        return try? CustomClipTextMatcher(
            mode: customMatchMode,
            pattern: customPattern,
            isCaseSensitive: customMatchIsCaseSensitive
        )
    }
}

struct AutomationSettings: View {
    private enum DeletionTarget: Identifiable {
        case automation(ClipAutomation)
        case flow(ClipFlow)
        var id: String {
            switch self {
            case let .automation(item): "automation-\(item.id.uuidString)"
            case let .flow(item): "flow-\(item.id.uuidString)"
            }
        }
        var name: String {
            switch self {
            case let .automation(item): item.name
            case let .flow(item): item.name
            }
        }
        var entityID: UUID {
            switch self {
            case let .automation(item): item.id
            case let .flow(item): item.id
            }
        }
        var isFlow: Bool {
            if case .flow = self { return true }
            return false
        }
    }

    @ObservedObject var model: AppModel
    @State private var isAddingAutomation = false
    @State private var isAddingFlow = false
    @State private var pendingPublishFlowID: UUID?
    @State private var pendingPublishWorkspace: FolderDestination?
    @State private var pendingUnpublishFlow: ClipFlow?
    @State private var editingAutomation: ClipAutomation?
    @State private var editingFlow: ClipFlow?
    @State private var deletionTarget: DeletionTarget?

    var body: some View {
        editingSheets
    }

    private var settingsForm: some View {
        Form {
            Section {
                Text("Turn a saved clip into a reviewed next step. Actions can run manually or react to a local folder move; shared templates arrive disabled and sync never executes them.")
                    .foregroundStyle(.secondary)
            }

            Section("Custom actions") {
                if model.clipFlows.isEmpty {
                    HStack(alignment: .center, spacing: 14) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("No custom actions yet")
                                .font(.headline)
                            Text("Create a reviewed flow for tagging, filing, app or CRM handoff, follow-up notes, or on-device enrichment.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Create Custom Action…", systemImage: "plus.circle") {
                            isAddingFlow = true
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier(ActionFlowAccessibility.newFlow)
                    }
                } else {
                    ForEach(model.clipFlows) { flow in
                        flowRow(flow)
                    }
                    Button("Create Custom Action…", systemImage: "plus.circle") {
                        isAddingFlow = true
                    }
                    .accessibilityIdentifier(ActionFlowAccessibility.newFlow)
                }
            }

            Section("One-click destinations") {
                if model.clipAutomations.isEmpty {
                    Text("No one-click destinations yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.clipAutomations) { automation in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(automation.name)
                                Text(automationSummary(automation))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle(
                                "Enabled",
                                isOn: Binding(
                                    get: { automation.isEnabled },
                                    set: { model.setAutomationEnabled(automation.id, enabled: $0) }
                                )
                            )
                            .labelsHidden()
                            Button("Edit", systemImage: "pencil") {
                                editingAutomation = automation
                            }
                            .labelStyle(.iconOnly)
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                deletionTarget = .automation(automation)
                            }
                            .labelStyle(.iconOnly)
                        }
                    }
                }
                Button("New One-click Destination…", systemImage: "plus") {
                    isAddingAutomation = true
                }
                .accessibilityIdentifier("uiAcceptance.actions.newAutomation")
            }

            AutomationRunLedgerSection(model: model)

            Section("Safety") {
                Label("No scripts, arbitrary webhooks, or automatic sends", systemImage: "checkmark.shield")
                Label("Folder triggers never run from sync and queue external steps for review", systemImage: "person.badge.clock")
                Label("Sensitive, Vault, quarantine, and Private Session content cannot run actions", systemImage: "lock")
            }
        }
        .formStyle(.grouped)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(ActionFlowAccessibility.settings)
        .accessibilityValue(
            "\(model.clipFlows.count) custom actions, \(model.clipAutomations.count) one-click destinations"
        )
    }

    private var confirmationDialogs: some View {
        settingsForm
        .confirmationDialog(
            "Publish team template?",
            isPresented: Binding(
                get: { pendingPublishFlowID != nil && pendingPublishWorkspace != nil },
                set: { showing in
                    if !showing {
                        pendingPublishFlowID = nil
                        pendingPublishWorkspace = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            if let flowID = pendingPublishFlowID, let workspace = pendingPublishWorkspace {
                Button("Publish to \(workspace.path)") {
                    model.publishFlowToTeam(flowID, workspaceID: workspace.id)
                    pendingPublishFlowID = nil
                    pendingPublishWorkspace = nil
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only portable steps are shared. Credentials and app bookmarks stay on this Mac, and teammates receive the template disabled until they review and enable it.")
        }
        .confirmationDialog(
            "Unpublish team template?",
            isPresented: Binding(
                get: { pendingUnpublishFlow != nil },
                set: { if !$0 { pendingUnpublishFlow = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let flow = pendingUnpublishFlow {
                Button("Unpublish \(flow.name)", role: .destructive) {
                    model.unpublishFlowFromTeam(flow.id)
                    pendingUnpublishFlow = nil
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the template from the team workspace. A local copy remains on this Mac.")
        }
        .confirmationDialog(
            "Delete \(deletionTarget?.name ?? "this action")?",
            isPresented: Binding(
                get: { deletionTarget != nil },
                set: { if !$0 { deletionTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let target = deletionTarget {
                Button("Delete", role: .destructive) {
                    switch target {
                    case let .automation(item): model.deleteAutomation(item.id)
                    case let .flow(item): model.deleteFlow(item.id)
                    }
                    deletionTarget = nil
                }
                .accessibilityIdentifier(
                    target.isFlow
                        ? ActionFlowAccessibility.confirmFlowDelete(target.entityID)
                        : "uiAcceptance.actions.confirmAutomationDelete.\(target.entityID.uuidString.lowercased())"
                )
            }
            Button("Cancel", role: .cancel) { deletionTarget = nil }
                .accessibilityIdentifier(ActionFlowAccessibility.deletionCancel)
        } message: {
            Text("The action definition is removed from this Mac. This cannot be undone.")
        }
    }

    private var creationSheets: some View {
        confirmationDialogs
        .sheet(isPresented: $isAddingAutomation) {
            AutomationEditorSheet(
                folders: model.folderDestinations,
                applications: model.applicationExclusionOptions,
                isDiscoveringApplications: model.isDiscoveringApplications,
                refreshApplications: { model.refreshApplicationExclusionOptions(force: true) },
                saveWeb: model.addWebAutomation,
                saveApplication: model.addApplicationAutomation,
                cancel: { isAddingAutomation = false }
            )
        }
        .sheet(isPresented: $isAddingFlow) {
            FlowEditorSheet(
                folders: model.folderDestinations,
                aiAvailability: model.onDeviceAIAvailability,
                applications: model.applicationExclusionOptions,
                isDiscoveringApplications: model.isDiscoveringApplications,
                refreshApplications: { model.refreshApplicationExclusionOptions(force: true) },
                makeApplicationStep: model.makeApplicationFlowStep,
                save: model.addFlow,
                cancel: { isAddingFlow = false }
            )
        }
    }

    private var editingSheets: some View {
        creationSheets
        .sheet(item: $editingAutomation) { automation in
            Group {
                switch automation.target {
                case .webURLTemplate:
                    AutomationEditorSheet(
                        existingAutomation: automation,
                        folders: model.folderDestinations,
                        applications: model.applicationExclusionOptions,
                        isDiscoveringApplications: model.isDiscoveringApplications,
                        refreshApplications: { model.refreshApplicationExclusionOptions(force: true) },
                        saveWeb: { name, filter, customMatcher, folderID, template in
                            model.updateWebAutomation(
                                id: automation.id,
                                name: name,
                                filter: filter,
                                customMatcher: customMatcher,
                                folderID: folderID,
                                template: template
                            )
                        },
                        saveApplication: { _, _, _, _, _ in false },
                        cancel: { editingAutomation = nil }
                    )
                case .application:
                    ApplicationAutomationMetadataEditorSheet(
                        automation: automation,
                        folders: model.folderDestinations,
                        save: { name, filter, customMatcher, folderID in
                            model.updateAutomationMetadata(
                                id: automation.id,
                                name: name,
                                filter: filter,
                                customMatcher: customMatcher,
                                folderID: folderID
                            )
                        },
                        cancel: { editingAutomation = nil }
                    )
                }
            }
        }
        .sheet(item: $editingFlow) { flow in
            FlowEditorSheet(
                existingFlow: flow,
                folders: model.folderDestinations,
                aiAvailability: model.onDeviceAIAvailability,
                applications: model.applicationExclusionOptions,
                isDiscoveringApplications: model.isDiscoveringApplications,
                refreshApplications: { model.refreshApplicationExclusionOptions(force: true) },
                makeApplicationStep: model.makeApplicationFlowStep,
                save: { name, trigger, filter, customMatcher, steps in
                    model.updateFlow(
                        id: flow.id,
                        name: name,
                        trigger: trigger,
                        filter: filter,
                        customMatcher: customMatcher,
                        steps: steps
                    )
                },
                cancel: { editingFlow = nil }
            )
        }
    }

    private func flowRow(_ flow: ClipFlow) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(flow.name)
                Text(flowSummary(flow))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Toggle("Enabled", isOn: enabledBinding(for: flow))
                .labelsHidden()
            if canEditFlow(flow) {
                Button("Edit", systemImage: "pencil") {
                    editingFlow = flow
                }
                .labelStyle(.iconOnly)
                .accessibilityIdentifier(ActionFlowAccessibility.flowEdit(flow.id))
            }
            publishMenu(for: flow)
            removalButton(for: flow)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(ActionFlowAccessibility.flowRow(flow.id))
        .accessibilityValue(ActionFlowAccessibility.flowRowValue(
            matcherSummary: flow.customMatcher?.summary ?? flow.entityFilter.displayName,
            stepCount: flow.steps.count,
            isAutomatic: flow.trigger.isAutomatic,
            isEnabled: flow.isEnabled
        ))
    }

    private func flowSummary(_ flow: ClipFlow) -> String {
        let filter = flow.customMatcher?.summary ?? flow.entityFilter.displayName
        let trigger = flow.trigger.isAutomatic ? "folder trigger" : "manual"
        return "\(filter) · \(flow.steps.count) steps · \(trigger)"
    }

    private func enabledBinding(for flow: ClipFlow) -> Binding<Bool> {
        Binding(
            get: { flow.isEnabled },
            set: { model.setFlowEnabled(flow.id, enabled: $0) }
        )
    }

    @ViewBuilder
    private func publishMenu(for flow: ClipFlow) -> some View {
        let destinations = model.teamAutomationDestinations
        if !destinations.isEmpty {
            Menu("Publish to Team", systemImage: "person.2") {
                ForEach(destinations) { workspace in
                    Button(workspace.path) {
                        pendingPublishFlowID = flow.id
                        pendingPublishWorkspace = workspace
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    @ViewBuilder
    private func removalButton(for flow: ClipFlow) -> some View {
        if model.canUnpublishFlow(flow) {
            Button("Unpublish from Team", systemImage: "person.2.slash", role: .destructive) {
                pendingUnpublishFlow = flow
            }
            .labelStyle(.iconOnly)
        } else {
            Button(
                flow.sharedFolderID == nil ? "Delete" : "Remove from This Mac",
                systemImage: "trash",
                role: .destructive
            ) {
                deletionTarget = .flow(flow)
            }
            .labelStyle(.iconOnly)
            .accessibilityIdentifier(ActionFlowAccessibility.flowDelete(flow.id))
        }
    }

    private func automationSummary(_ automation: ClipAutomation) -> String {
        let target: String
        switch automation.target {
        case let .webURLTemplate(template):
            target = URLComponents(string: template)?.host ?? "Web URL"
        case let .application(_, displayName):
            target = displayName
        }
        let condition = automation.customMatcher?.summary ?? automation.entityFilter.displayName
        return "\(condition) → \(target)"
    }

    private func canEditFlow(_ flow: ClipFlow) -> Bool {
        guard flow.sharedFolderID == nil else { return false }
        var kinds: Set<String> = []
        var previousRank = -1
        for step in flow.steps {
            let (kind, rank): (String, Int) = switch step {
            case .addTags: ("tags", 0)
            case .moveToFolder: ("move", 1)
            case .openWeb, .openApplication: ("open", 2)
            case .createTaskDraft: ("task", 3)
            case .enrichWithOnDeviceAI: ("enrich", 4)
            }
            guard kinds.insert(kind).inserted, rank > previousRank else { return false }
            previousRank = rank
        }
        return true
    }
}
