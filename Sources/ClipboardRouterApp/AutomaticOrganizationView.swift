import ClipboardRouterCore
import SwiftUI

struct AutomaticOrganizationDashboardView: View {
    @ObservedObject var model: AppModel
    @State private var isCreatingRule = false
    @State private var editingRule: AutomaticOrganizationRule?
    @State private var previewClipID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Auto Organize")
                        .font(.title2.weight(.semibold))
                    Text("File saved clips with local, deterministic rules you can preview and undo.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("New Rule", systemImage: "plus") { isCreatingRule = true }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("uiAcceptance.autoOrganize.newRule")
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    previewSection
                    rulesSection
                    safetySection
                }
                .padding(20)
            }
        }
        .sheet(isPresented: $isCreatingRule) {
            AutomaticOrganizationRuleEditorSheet(model: model) {
                isCreatingRule = false
            }
        }
        .sheet(item: $editingRule) { rule in
            AutomaticOrganizationRuleEditorSheet(model: model, editingRule: rule) {
                editingRule = nil
            }
        }
        .onAppear {
            if previewClipID == nil {
                previewClipID = model.automaticOrganizationPreviewClips.first?.id
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AutomaticOrganizationAccessibility.dashboard)
        .accessibilityValue(AutomaticOrganizationAccessibility.dashboardValue(
            previewClipID: previewClipID,
            ruleCount: model.automaticOrganizationSnapshot.rules.count,
            receiptCount: model.automaticOrganizationSnapshot.receipts.count,
            status: model.statusMessage,
            error: model.errorMessage
        ))
    }

    private var selectedPreviewClip: PresentedClip? {
        model.automaticOrganizationPreviewClips.first { $0.id == previewClipID }
    }

    @ViewBuilder
    private var previewSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                if model.automaticOrganizationPreviewClips.isEmpty {
                    ContentUnavailableView(
                        "Save a clip to preview rules",
                        systemImage: "tray.and.arrow.down",
                        description: Text("History, Vault, quarantine, and Private Session items are never evaluated.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    Picker("Saved item", selection: $previewClipID) {
                        ForEach(model.automaticOrganizationPreviewClips) { clip in
                            Text(clip.title).tag(Optional(clip.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("uiAcceptance.autoOrganize.previewClip")

                    if let clip = selectedPreviewClip {
                        let suggestions = model.automaticOrganizationSuggestions(for: clip)
                        if let suggestion = suggestions.first {
                            OrganizationSuggestionCard(
                                model: model,
                                clip: clip,
                                suggestion: suggestion
                            )
                        } else {
                            Label(
                                model.automaticOrganizationSnapshot.rules.isEmpty
                                    ? "Create a rule to see its result here."
                                    : "No enabled suggestion rule matches this saved item.",
                                systemImage: "checkmark.circle"
                            )
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(4)
        } label: {
            Label("Preview", systemImage: "eye")
        }
    }

    @ViewBuilder
    private var rulesSection: some View {
        GroupBox {
            if model.automaticOrganizationSnapshot.rules.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "wand.and.stars")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text("No organization rules")
                        .font(.headline)
                    Text("Start with one narrow rule, preview it, then choose whether future matches should ask or apply automatically.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Create First Rule") { isCreatingRule = true }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("uiAcceptance.autoOrganize.createFirstRule")
                }
                .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                VStack(spacing: 0) {
                    let ordered = model.automaticOrganizationSnapshot.rules.sorted {
                        if $0.priority != $1.priority { return $0.priority < $1.priority }
                        return $0.id.uuidString < $1.id.uuidString
                    }
                    ForEach(Array(ordered.enumerated()), id: \.element.id) { index, rule in
                        if index > 0 { Divider() }
                        ruleRow(rule, index: index, count: ordered.count)
                    }
                }
            }
        } label: {
            Label("Ordered rules", systemImage: "list.number")
        }
    }

    private func ruleRow(
        _ rule: AutomaticOrganizationRule,
        index: Int,
        count: Int
    ) -> some View {
        let isSuppressed = model.automaticOrganizationSnapshot.suppressedRuleIDs.contains(rule.id)
        let destinationName = rule.action.destinationFolderID.map {
            model.folderPath(for: $0)
        }
        let actionSummary = actionDescription(rule.action, destinationName: destinationName)
        return HStack(alignment: .top, spacing: 12) {
            Toggle(
                "",
                isOn: Binding(
                    get: { rule.isEnabled && !isSuppressed },
                    set: { model.setAutomaticOrganizationRuleEnabled(rule.id, enabled: $0) }
                )
            )
            .labelsHidden()
            .accessibilityLabel("Enable \(rule.name)")
            .accessibilityIdentifier(AutomaticOrganizationAccessibility.ruleControl(
                "enable",
                ruleID: rule.id
            ))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(rule.name).font(.headline)
                    if isSuppressed {
                        Text("Never suggest")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(.secondary.opacity(0.15), in: Capsule())
                    }
                }
                Text("When \(matcherDescription(rule.matcher)), \(actionSummary).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Picker(
                "Behavior",
                selection: Binding(
                    get: { rule.behavior },
                    set: { model.setAutomaticOrganizationRuleBehavior(rule.id, behavior: $0) }
                )
            ) {
                Text("Suggest").tag(AutomaticOrganizationRuleBehavior.suggest)
                Text("Always Apply").tag(AutomaticOrganizationRuleBehavior.alwaysApply)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 150)
            .accessibilityIdentifier(AutomaticOrganizationAccessibility.ruleControl(
                "behavior",
                ruleID: rule.id
            ))
            .accessibilityAction(named: "Select Suggest") {
                model.setAutomaticOrganizationRuleBehavior(rule.id, behavior: .suggest)
            }
            .accessibilityAction(named: "Select Always Apply") {
                model.setAutomaticOrganizationRuleBehavior(rule.id, behavior: .alwaysApply)
            }

            HStack(spacing: 4) {
                Button {
                    editingRule = rule
                } label: { Image(systemName: "pencil") }
                    .accessibilityLabel("Edit \(rule.name)")
                    .accessibilityIdentifier(AutomaticOrganizationAccessibility.ruleControl(
                        "edit",
                        ruleID: rule.id
                    ))
                Button {
                    model.moveAutomaticOrganizationRule(rule.id, offset: -1)
                } label: { Image(systemName: "chevron.up") }
                    .disabled(index == 0)
                    .accessibilityLabel("Move \(rule.name) earlier")
                    .accessibilityIdentifier(AutomaticOrganizationAccessibility.ruleControl(
                        "moveUp",
                        ruleID: rule.id
                    ))
                Button {
                    model.moveAutomaticOrganizationRule(rule.id, offset: 1)
                } label: { Image(systemName: "chevron.down") }
                    .disabled(index == count - 1)
                    .accessibilityLabel("Move \(rule.name) later")
                    .accessibilityIdentifier(AutomaticOrganizationAccessibility.ruleControl(
                        "moveDown",
                        ruleID: rule.id
                    ))
                Button(role: .destructive) {
                    model.deleteAutomaticOrganizationRule(rule.id)
                } label: { Image(systemName: "trash") }
                    .accessibilityLabel("Delete \(rule.name)")
                    .accessibilityIdentifier(AutomaticOrganizationAccessibility.ruleControl(
                        "delete",
                        ruleID: rule.id
                    ))
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AutomaticOrganizationAccessibility.ruleRow(rule.id))
        .accessibilityValue(AutomaticOrganizationAccessibility.ruleValue(
            rule,
            order: index,
            isSuppressed: isSuppressed
        ))
    }

    private var safetySection: some View {
        Label(
            "Rules run only after a local save commits. Synced imports, Vault, sensitive review, quarantine, and Private Session never trigger them.",
            systemImage: "lock.shield"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

struct OrganizationSuggestionCard: View {
    @ObservedObject var model: AppModel
    let clip: PresentedClip
    let suggestion: AutomaticOrganizationSuggestion

    private var actionSummary: String {
        actionDescription(
            suggestion.rule.action,
            destinationName: suggestion.rule.action.destinationFolderID.map {
                model.folderPath(for: $0)
            }
        )
    }

    var body: some View {
        // The organization mutation refreshes the library snapshot asynchronously. Resolve the
        // current presented clip for the accessibility receipt so its tags describe the committed
        // item, rather than the pre-mutation value captured when this card was first rendered.
        let accessibilityClip = model.automaticOrganizationPreviewClips.first {
            $0.id == clip.id
        } ?? clip
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(suggestion.rule.name, systemImage: "wand.and.stars")
                    .font(.headline)
                Spacer()
                Text("\(suggestion.confidence)% match")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Text(suggestion.reason)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(actionSummary.capitalized + ".")
                .font(.callout)
            Text(accessibilityClip.tags.isEmpty
                ? "Tags: none"
                : "Tags: " + accessibilityClip.tags.sorted().map { "#\($0)" }.joined(separator: ", "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(
                    AutomaticOrganizationAccessibility.suggestionTags(accessibilityClip.id)
                )
                .accessibilityValue(
                    AutomaticOrganizationAccessibility.suggestionTagsValue(accessibilityClip)
                )
            HStack {
                Button("Apply Once") {
                    model.applyAutomaticOrganizationOnce(suggestion, to: clip)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("uiAcceptance.autoOrganize.applyOnce")
                Button("Always Apply") {
                    model.alwaysApplyAutomaticOrganization(suggestion, to: clip)
                }
                .accessibilityIdentifier("uiAcceptance.autoOrganize.alwaysApply")
                Button("Never Suggest") {
                    model.neverSuggestAutomaticOrganization(suggestion)
                }
                .accessibilityIdentifier("uiAcceptance.autoOrganize.neverSuggest")
                Spacer()
                if let receipt = model.latestAutomaticOrganizationReceipt(for: clip.id) {
                    Button("Undo", systemImage: "arrow.uturn.backward") {
                        model.undoAutomaticOrganization(receipt)
                    }
                    .accessibilityIdentifier("uiAcceptance.autoOrganize.undo")
                }
            }
            .disabled(model.isBusy)
        }
        .padding(12)
        .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AutomaticOrganizationAccessibility.suggestion)
        .accessibilityValue(AutomaticOrganizationAccessibility.suggestionValue(
            suggestion,
            clip: accessibilityClip,
            hasUndoReceipt: model.latestAutomaticOrganizationReceipt(for: clip.id) != nil,
            status: model.statusMessage,
            error: model.errorMessage
        ))
    }
}

enum AutomaticOrganizationMatchKind: String, CaseIterable, Identifiable {
    case contentType = "Content type"
    case domain = "Link domain"
    case sourceApplication = "Source app"
    case entity = "Detected entity"
    case wordsOrPhrases = "Words or phrases"
    case safeRegex = "Safe regex"
    var id: Self { self }
}

struct AutomaticOrganizationMatcherDraft: Equatable {
    var kind = AutomaticOrganizationMatchKind.contentType
    var contentType = SupportedContentType.url
    var entity = DetectedClipEntityKind.webURL
    var value = ""
    var isCaseSensitive = false

    init(
        kind: AutomaticOrganizationMatchKind = .contentType,
        contentType: SupportedContentType = .url,
        entity: DetectedClipEntityKind = .webURL,
        value: String = "",
        isCaseSensitive: Bool = false
    ) {
        self.kind = kind
        self.contentType = contentType
        self.entity = entity
        self.value = value
        self.isCaseSensitive = isCaseSensitive
    }

    init(matcher: AutomaticOrganizationMatcher? = nil) {
        guard let matcher else { return }
        switch matcher {
        case let .contentType(type):
            kind = .contentType
            contentType = type
        case let .domain(domain):
            kind = .domain
            value = domain
        case let .sourceApplication(application):
            kind = .sourceApplication
            value = application
        case let .entity(detectedEntity):
            kind = .entity
            entity = detectedEntity
        case let .customText(matcher):
            kind = matcher.mode == .wordsOrPhrases ? .wordsOrPhrases : .safeRegex
            value = matcher.pattern
            isCaseSensitive = matcher.isCaseSensitive
        }
    }

    func validatedMatcher() throws -> AutomaticOrganizationMatcher {
        switch kind {
        case .contentType: .contentType(contentType)
        case .domain: .domain(value)
        case .sourceApplication: .sourceApplication(value)
        case .entity: .entity(entity)
        case .wordsOrPhrases:
            .customText(try CustomClipTextMatcher(
                mode: .wordsOrPhrases,
                pattern: value,
                isCaseSensitive: isCaseSensitive
            ))
        case .safeRegex:
            .customText(try CustomClipTextMatcher(
                mode: .regularExpression,
                pattern: value,
                isCaseSensitive: isCaseSensitive
            ))
        }
    }
}

struct AutomaticOrganizationRuleEditorSheet: View {
    @ObservedObject var model: AppModel
    let editingRule: AutomaticOrganizationRule?
    let dismiss: () -> Void
    @State private var name = ""
    @State private var matchKind = AutomaticOrganizationMatchKind.contentType
    @State private var contentType = SupportedContentType.url
    @State private var entity = DetectedClipEntityKind.webURL
    @State private var matchValue = ""
    @State private var matchIsCaseSensitive = false
    @State private var movesToFolder = false
    @State private var destinationFolderID: UUID?
    @State private var tags = ""
    @State private var errorMessage: String?

    init(
        model: AppModel,
        editingRule: AutomaticOrganizationRule? = nil,
        dismiss: @escaping () -> Void
    ) {
        self.model = model
        self.editingRule = editingRule
        self.dismiss = dismiss

        _name = State(initialValue: editingRule?.name ?? "")
        _movesToFolder = State(initialValue: editingRule?.action.movesToFolder ?? false)
        _destinationFolderID = State(initialValue: editingRule?.action.destinationFolderID)
        _tags = State(initialValue: editingRule?.action.addedTags.joined(separator: ", ") ?? "")

        let matcherDraft = AutomaticOrganizationMatcherDraft(matcher: editingRule?.matcher)
        _matchKind = State(initialValue: matcherDraft.kind)
        _contentType = State(initialValue: matcherDraft.contentType)
        _entity = State(initialValue: matcherDraft.entity)
        _matchValue = State(initialValue: matcherDraft.value)
        _matchIsCaseSensitive = State(initialValue: matcherDraft.isCaseSensitive)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(editingRule == nil ? "New Organization Rule" : "Edit Organization Rule")
                .font(.title2.weight(.semibold))
            Form {
                TextField("Rule name", text: $name)
                    .accessibilityIdentifier("uiAcceptance.autoOrganize.ruleName")
                Picker("Match", selection: $matchKind) {
                    ForEach(AutomaticOrganizationMatchKind.allCases) { Text($0.rawValue).tag($0) }
                }
                .accessibilityIdentifier("uiAcceptance.autoOrganize.matchKind")
                .accessibilityAction(named: "Select Safe regex") {
                    matchKind = .safeRegex
                }
                matchValueEditor
                Toggle("Move to a folder", isOn: $movesToFolder)
                    .accessibilityIdentifier("uiAcceptance.autoOrganize.movesToFolder")
                if movesToFolder {
                    Picker("Destination", selection: $destinationFolderID) {
                        Text("Saved (no folder)").tag(UUID?.none)
                        if let destinationFolderID,
                           !eligibleDestinationIDs.contains(destinationFolderID) {
                            Text("Unavailable folder")
                                .tag(Optional(destinationFolderID))
                                .disabled(true)
                        }
                        ForEach(model.folderDestinations.filter(\.canAcceptItems)) { folder in
                            Text(folder.path).tag(Optional(folder.id))
                        }
                    }
                    .accessibilityIdentifier("uiAcceptance.autoOrganize.destination")
                    if destinationFolderID != nil && !isSelectedDestinationEligible {
                        Text("This folder no longer exists or you no longer have permission to add items. Choose another destination.")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("uiAcceptance.autoOrganize.destinationError")
                    }
                }
                TextField("Add tags (comma separated)", text: $tags)
                    .accessibilityIdentifier("uiAcceptance.autoOrganize.tags")
            }
            .formStyle(.grouped)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("uiAcceptance.autoOrganize.error")
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .accessibilityIdentifier("uiAcceptance.autoOrganize.cancel")
                Button(editingRule == nil ? "Create Rule" : "Save Changes") { saveRule() }
                    .buttonStyle(.borderedProminent)
                    .disabled(movesToFolder && !isSelectedDestinationEligible)
                    .accessibilityIdentifier("uiAcceptance.autoOrganize.saveRule")
            }
        }
        .padding(22)
        .frame(width: 520)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("uiAcceptance.autoOrganize.editor")
        .accessibilityValue(AutomaticOrganizationAccessibility.editorValue(
            editingRuleID: editingRule?.id,
            matchKind: matchKind,
            isDestinationEligible: isSelectedDestinationEligible,
            error: errorMessage
        ))
    }

    @ViewBuilder
    private var matchValueEditor: some View {
        switch matchKind {
        case .contentType:
            Picker("Type", selection: $contentType) {
                ForEach(SupportedContentType.allCases, id: \.self) {
                    Text(contentTypeLabel($0)).tag($0)
                }
            }
            .accessibilityIdentifier("uiAcceptance.autoOrganize.contentType")
        case .entity:
            Picker("Entity", selection: $entity) {
                ForEach(DetectedClipEntityKind.allCases, id: \.self) {
                    Text($0.displayName).tag($0)
                }
            }
            .accessibilityIdentifier("uiAcceptance.autoOrganize.entity")
        case .domain:
            TextField("Domain, such as example.com", text: $matchValue)
                .accessibilityIdentifier("uiAcceptance.autoOrganize.matchValue")
        case .sourceApplication:
            TextField("App name or bundle ID", text: $matchValue)
                .accessibilityIdentifier("uiAcceptance.autoOrganize.matchValue")
        case .wordsOrPhrases:
            TextField("Comma-separated words or phrases", text: $matchValue)
                .accessibilityIdentifier("uiAcceptance.autoOrganize.matchValue")
            Toggle("Match capitalization exactly", isOn: $matchIsCaseSensitive)
                .accessibilityIdentifier("uiAcceptance.autoOrganize.caseSensitive")
        case .safeRegex:
            TextField(#"Pattern, such as \bACME-\d{3}\b"#, text: $matchValue)
                .accessibilityIdentifier("uiAcceptance.autoOrganize.matchValue")
            Toggle("Match capitalization exactly", isOn: $matchIsCaseSensitive)
                .accessibilityIdentifier("uiAcceptance.autoOrganize.caseSensitive")
            Text("Lookarounds, backreferences, nested quantifiers, and inputs over 8 KB are rejected.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var eligibleDestinationIDs: Set<UUID> {
        Set(model.folderDestinations.filter(\.canAcceptItems).map(\.id))
    }

    private var isSelectedDestinationEligible: Bool {
        guard movesToFolder, let destinationFolderID else { return true }
        return eligibleDestinationIDs.contains(destinationFolderID)
    }

    private func saveRule() {
        do {
            let matcher = try AutomaticOrganizationMatcherDraft(
                kind: matchKind,
                contentType: contentType,
                entity: entity,
                value: matchValue,
                isCaseSensitive: matchIsCaseSensitive
            ).validatedMatcher()
            let original = editingRule
            let rule = try AutomaticOrganizationRule(
                id: original?.id ?? UUID(),
                name: name,
                isEnabled: original?.isEnabled ?? true,
                priority: original?.priority
                    ?? (model.automaticOrganizationSnapshot.rules.map(\.priority).max() ?? -1) + 1,
                behavior: original?.behavior ?? .suggest,
                matcher: matcher,
                action: AutomaticOrganizationAction(
                    movesToFolder: movesToFolder,
                    destinationFolderID: destinationFolderID,
                    addedTags: tags.split(separator: ",").map(String.init)
                )
            )
            Task {
                let didSave: Bool
                if let original {
                    didSave = await model.updateAutomaticOrganizationRule(
                        rule,
                        expecting: original
                    )
                } else {
                    didSave = await model.addAutomaticOrganizationRule(rule)
                }
                if didSave {
                    dismiss()
                } else {
                    errorMessage = model.errorMessage ?? "The organization rule could not be saved."
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

enum AutomaticOrganizationAccessibility {
    static let dashboard = "uiAcceptance.autoOrganize.dashboard"
    static let suggestion = "uiAcceptance.autoOrganize.suggestion"

    static func ruleRow(_ ruleID: UUID) -> String {
        "uiAcceptance.autoOrganize.row.\(uuid(ruleID))"
    }

    static func ruleControl(_ control: String, ruleID: UUID) -> String {
        "uiAcceptance.autoOrganize.\(control).\(uuid(ruleID))"
    }

    static func suggestionTags(_ clipID: UUID) -> String {
        "uiAcceptance.autoOrganize.suggestion.tags.\(uuid(clipID))"
    }

    static func ruleValue(
        _ rule: AutomaticOrganizationRule,
        order: Int,
        isSuppressed: Bool
    ) -> String {
        "name=\(component(rule.name))|enabled=\(rule.isEnabled && !isSuppressed)|behavior=\(rule.behavior.rawValue)|order=\(order)|suppressed=\(isSuppressed)"
    }

    static func dashboardValue(
        previewClipID: UUID?,
        ruleCount: Int,
        receiptCount: Int,
        status: String?,
        error: String?
    ) -> String {
        "previewClip=\(previewClipID.map(uuid) ?? "none")|rules=\(ruleCount)|receipts=\(receiptCount)|status=\(component(status ?? "none"))|error=\(component(error ?? "none"))"
    }

    static func suggestionValue(
        _ suggestion: AutomaticOrganizationSuggestion,
        clip: PresentedClip,
        hasUndoReceipt: Bool,
        status: String?,
        error: String?
    ) -> String {
        "rule=\(uuid(suggestion.rule.id))|clip=\(uuid(clip.id))|confidence=\(suggestion.confidence)|undo=\(hasUndoReceipt)|tags=\(tagList(clip.tags.sorted()))|status=\(component(status ?? "none"))|error=\(component(error ?? "none"))"
    }

    static func suggestionTagsValue(_ clip: PresentedClip) -> String {
        "clip=\(uuid(clip.id))|tags=\(tagList(clip.tags.sorted()))"
    }

    static func editorValue(
        editingRuleID: UUID?,
        matchKind: AutomaticOrganizationMatchKind,
        isDestinationEligible: Bool,
        error: String?
    ) -> String {
        "mode=\(editingRuleID == nil ? "create" : "edit")|rule=\(editingRuleID.map(uuid) ?? "none")|match=\(matchKind.rawValue)|destinationValid=\(isDestinationEligible)|error=\(component(error ?? "none"))"
    }

    private static func uuid(_ id: UUID) -> String {
        id.uuidString.lowercased()
    }

    private static func component(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    /// Tags share the `tags=` field with a comma-delimited list, so beyond the pipe-delimited
    /// escaping applied by `component()`, a literal comma inside a tag must also be escaped —
    /// otherwise it is indistinguishable from the separator between tags.
    private static func tagList(_ tags: [String]) -> String {
        tags.map(tagComponent).joined(separator: ",")
    }

    private static func tagComponent(_ value: String) -> String {
        component(value).replacingOccurrences(of: ",", with: "\\,")
    }
}

private func matcherDescription(_ matcher: AutomaticOrganizationMatcher) -> String {
    switch matcher {
    case let .contentType(type): "the content type is \(contentTypeLabel(type))"
    case let .domain(domain): "the link domain matches \(domain)"
    case let .sourceApplication(application): "the source app is \(application)"
    case let .entity(entity): "a \(entity.displayName.lowercased()) is detected"
    case let .customText(matcher): matcher.summary.lowercased()
    }
}

private func actionDescription(
    _ action: AutomaticOrganizationAction,
    destinationName: String? = nil
) -> String {
    var parts: [String] = []
    if action.movesToFolder {
        parts.append(action.destinationFolderID == nil
            ? "move to Saved"
            : "move to \(destinationName ?? "the chosen folder")")
    }
    if !action.addedTags.isEmpty {
        parts.append("add \(action.addedTags.map { "#\($0)" }.joined(separator: ", "))")
    }
    return parts.joined(separator: " and ")
}

private func contentTypeLabel(_ type: SupportedContentType) -> String {
    switch type {
    case .plainText: "Plain text"
    case .url: "Link"
    case .richText: "Rich text"
    case .image: "Image"
    case .fileURLs: "Files"
    }
}
