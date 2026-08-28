import AppKit
import ClipboardRouterCore
import SwiftUI

enum ApplicationBrowserAccessibility {
    static let search = "uiAcceptance.appBrowser.search"
    static let cancel = "uiAcceptance.appBrowser.cancel"
    static let commit = "uiAcceptance.appBrowser.commit"
    static let status = "uiAcceptance.appBrowser.status"

    static func root(_ requestID: UUID) -> String {
        "uiAcceptance.appBrowser.root.\(uuid(requestID))"
    }

    static func row(requestID: UUID, application: ApplicationExclusionOption) -> String {
        "uiAcceptance.appBrowser.row.\(uuid(requestID)).\(component(application.bundleIdentifier))"
    }

    static func stateValue(
        resultCount: Int,
        selectedApplicationID: String?,
        isDiscovering: Bool
    ) -> String {
        "results=\(resultCount)|selected=\(component(selectedApplicationID ?? "none"))|discovering=\(isDiscovering)"
    }

    static func component(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private static func uuid(_ id: UUID) -> String { id.uuidString.lowercased() }
}

struct ApplicationBrowserSheet: View {
    @ObservedObject var model: AppModel
    let request: ApplicationBrowserRequest
    let cancel: () -> Void

    @State private var query = ""
    @State private var selectedApplicationID: String?
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Copy & Open in App")
                .font(.title2.weight(.semibold))
            Text("Choose an eligible app. Clipboard Router copies the item and opens that app; it never types, presses Return, or selects a window or chat.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Search installed apps and bundle identifiers", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .accessibilityLabel("Search installed applications")
                .accessibilityIdentifier(ApplicationBrowserAccessibility.search)
                .onMoveCommand(perform: moveApplicationSelection)

            List(filteredApplications, selection: $selectedApplicationID) { application in
                HStack(spacing: 11) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: application.applicationURL.path))
                        .resizable()
                        .frame(width: 30, height: 30)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(application.displayName)
                        Text(application.bundleIdentifier)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if application.isRunning {
                        Text("Running")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let teamIdentifier = application.teamIdentifier {
                        Label("Signed", systemImage: "checkmark.seal.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                            .help("Developer Team: \(teamIdentifier)")
                    } else {
                        Label("Identity checked", systemImage: "checkmark.shield")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 3)
                .tag(application.id)
                .contentShape(Rectangle())
                .accessibilityElement(children: .combine)
                .accessibilityLabel(applicationAccessibilityLabel(application))
                .accessibilityIdentifier(
                    ApplicationBrowserAccessibility.row(
                        requestID: request.id,
                        application: application
                    )
                )
                .accessibilityValue(
                    "selected=\(selectedApplicationID == application.id)|running=\(application.isRunning)|bundle=\(ApplicationBrowserAccessibility.component(application.bundleIdentifier))"
                )
            }
            .overlay {
                if filteredApplications.isEmpty {
                    if model.isDiscoveringApplications {
                        VStack(spacing: 10) {
                            ProgressView()
                            Text("Checking applications…")
                                .font(.headline)
                            Text("Eligible applications appear here as their identity is checked.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ContentUnavailableView(
                            "No eligible app found",
                            systemImage: "app.dashed",
                            description: Text("Try another search. Invalid application bundles are excluded.")
                        )
                    }
                }
            }

            HStack {
                Text("The copied item stays on your clipboard until you replace it. Clipboard Router does not submit it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(ApplicationBrowserAccessibility.status)
                    .accessibilityValue(ApplicationBrowserAccessibility.stateValue(
                        resultCount: filteredApplications.count,
                        selectedApplicationID: selectedApplicationID,
                        isDiscovering: model.isDiscoveringApplications
                    ))
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier(ApplicationBrowserAccessibility.cancel)
                Button("Copy & Open") {
                    guard let selectedApplication else { return }
                    model.copyAndOpen(request.sourceClip, in: selectedApplication)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(selectedApplication == nil)
                .accessibilityIdentifier(ApplicationBrowserAccessibility.commit)
                .accessibilityValue("enabled=\(selectedApplication != nil)")
            }
        }
        .padding(20)
        .frame(
            minWidth: 600,
            idealWidth: 680,
            maxWidth: .infinity,
            minHeight: 460,
            idealHeight: 560,
            maxHeight: .infinity
        )
        .onAppear {
            searchFocused = true
            synchronizeSelection()
        }
        .onChange(of: query) { _, _ in synchronizeSelection() }
        .onChange(of: model.applicationExclusionOptions) { _, _ in synchronizeSelection() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(ApplicationBrowserAccessibility.root(request.id))
        .accessibilityValue(ApplicationBrowserAccessibility.stateValue(
            resultCount: filteredApplications.count,
            selectedApplicationID: selectedApplicationID,
            isDiscovering: model.isDiscoveringApplications
        ))
    }

    private var filteredApplications: [ApplicationExclusionOption] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return Array(model.applicationExclusionOptions.prefix(80)) }
        return model.applicationExclusionOptions.filter {
            $0.displayName.localizedCaseInsensitiveContains(normalized)
                || $0.bundleIdentifier.localizedCaseInsensitiveContains(normalized)
                || $0.applicationURL.path.localizedCaseInsensitiveContains(normalized)
        }.prefix(80).map { $0 }
    }

    private var selectedApplication: ApplicationExclusionOption? {
        guard let selectedApplicationID else { return nil }
        return filteredApplications.first(where: { $0.id == selectedApplicationID })
    }

    private func synchronizeSelection() {
        if !filteredApplications.contains(where: { $0.id == selectedApplicationID }) {
            selectedApplicationID = filteredApplications.first?.id
        }
    }

    private func moveApplicationSelection(_ direction: MoveCommandDirection) {
        let applications = filteredApplications
        guard !applications.isEmpty else { return }
        let currentIndex = applications.firstIndex { $0.id == selectedApplicationID } ?? 0
        switch direction {
        case .down:
            selectedApplicationID = applications[min(currentIndex + 1, applications.count - 1)].id
        case .up:
            selectedApplicationID = applications[max(currentIndex - 1, 0)].id
        default:
            break
        }
    }

    private func applicationAccessibilityLabel(_ application: ApplicationExclusionOption) -> String {
        let running = application.isRunning ? ", running" : ""
        let identity = application.teamIdentifier == nil ? "identity-checked" : "signed"
        return "\(application.displayName), \(identity) application\(running), \(application.bundleIdentifier)"
    }
}

struct InsertPaletteSheet: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var model: AppModel
    let pasteTargetToken: UUID?
    let requestCreateNote: () -> Void
    let cancel: () -> Void

    @State private var query = ""
    @State private var selectedID: UUID?
    @State private var abbreviation = ""
    @State private var delivery: InsertAliasDelivery = .copy
    @State private var isEditingShortcut = false
    @FocusState private var queryFocused: Bool

    private var results: [InsertAliasResult] { model.insertAliasResults(matching: query) }
    private var selected: InsertAliasResult? {
        results.first(where: { $0.id == selectedID }) ?? results.first
    }
    private var hasReusableItems: Bool {
        !model.insertAliasResults(matching: "").isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Quick Paste")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button(action: cancel) {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close Quick Paste")
                .accessibilityLabel("Close Quick Paste")
            }

            TextField("Search saved items or type ;shortcut", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($queryFocused)
                .accessibilityLabel("Search saved clips and notes")
                .onMoveCommand(perform: moveResultSelection)

            if results.isEmpty {
                ContentUnavailableView {
                    Label(
                        hasReusableItems ? "No matches" : "Nothing ready to paste",
                        systemImage: hasReusableItems ? "magnifyingglass" : "text.badge.plus"
                    )
                } description: {
                    Text(
                        hasReusableItems
                            ? "Try another title, phrase, or shortcut."
                            : "Save a text clip or create a note first."
                    )
                } actions: {
                    if hasReusableItems {
                        Button("Clear Search") { query = "" }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button("New Note", systemImage: "square.and.pencil") {
                            requestCreateNote()
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Open Library") { openLibrary() }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    List(results, selection: $selectedID) { result in
                        HStack(spacing: 9) {
                            Image(systemName: result.clip.savedItemKind == .note ? "note.text" : "doc.text")
                                .foregroundStyle(.tint)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.clip.title).lineLimit(1)
                                Text(result.trigger ?? "Saved item")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .tag(result.id)
                        .contentShape(Rectangle())
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(accessibilityLabel(for: result))
                        .accessibilityValue(selected?.id == result.id ? "Selected" : "Not selected")
                        .accessibilityAddTraits(selected?.id == result.id ? .isSelected : [])
                    }
                    .frame(minWidth: 220, idealWidth: 260, maxWidth: 300)

                    if let selected {
                        VStack(alignment: .leading, spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(selected.clip.title)
                                    .font(.headline)
                                    .lineLimit(2)
                                Text(selectedDescription(for: selected))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            ScrollView {
                                Text(selected.clip.content.text)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(10)
                            }
                            .frame(minHeight: 110, idealHeight: 170, maxHeight: 230)
                            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))

                            HStack(spacing: 8) {
                                Button(action: performDefaultAction) {
                                    Label(
                                        defaultActionLabel(for: selected),
                                        systemImage: defaultActionSystemImage(for: selected)
                                    )
                                    .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                                .keyboardShortcut(.defaultAction)
                                .disabled(
                                    selected.alias?.delivery == .pasteIntoFrontmostApplication
                                        && !model.canPasteFromInsertPalette(token: pasteTargetToken)
                                )

                                Menu("Paste Options", systemImage: "ellipsis.circle") {
                                    if selected.alias?.delivery == .pasteIntoFrontmostApplication {
                                        Button("Copy Only", systemImage: "doc.on.doc") {
                                            model.performInsert(selected, delivery: .copy)
                                            cancel()
                                        }
                                    } else {
                                        Button("Paste into Previous App", systemImage: "keyboard") {
                                            model.performInsert(
                                                selected,
                                                delivery: .pasteIntoFrontmostApplication,
                                                pasteTargetToken: pasteTargetToken
                                            )
                                            cancel()
                                        }
                                        .disabled(!model.canPasteFromInsertPalette(token: pasteTargetToken))
                                    }

                                    Divider()

                                    Button(
                                        selected.alias == nil ? "Add Shortcut…" : "Edit Shortcut…",
                                        systemImage: "command"
                                    ) {
                                        syncAliasFields()
                                        isEditingShortcut = true
                                    }
                                }
                                .menuStyle(.borderlessButton)
                                .fixedSize()
                                .help("Choose another paste action or manage this item's shortcut")
                                .accessibilityLabel("Paste options for \(selected.clip.title)")
                                .popover(isPresented: $isEditingShortcut, arrowEdge: .bottom) {
                                    shortcutEditor(for: selected)
                                }
                            }
                        }
                        .padding(14)
                        .frame(minWidth: 300, maxWidth: .infinity, alignment: .topLeading)
                    }
                }
                .frame(minHeight: 280, idealHeight: 340, maxHeight: 400)
            }

        }
        .padding(16)
        .frame(
            minWidth: 620,
            idealWidth: 700,
            maxWidth: .infinity,
            minHeight: 390,
            idealHeight: 460,
            maxHeight: 540
        )
        .onExitCommand(perform: cancel)
        .onAppear {
            selectedID = results.first?.id
            queryFocused = true
            syncAliasFields()
        }
        .onChange(of: selectedID) { _, _ in syncAliasFields() }
        .onChange(of: query) { _, _ in
            if !results.contains(where: { $0.id == selectedID }) {
                selectedID = results.first?.id
            }
        }
    }

    private func shortcutEditor(for selected: InsertAliasResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(selected.alias == nil ? "Add Shortcut" : "Edit Shortcut")
                    .font(.headline)
                Spacer()
                Button {
                    isEditingShortcut = false
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close shortcut editor")
            }

            Text("Available in Quick Paste. If system Text Expansion is enabled, this shortcut also expands as you type.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Text(";")
                    .font(.body.monospaced())
                TextField("pricing", text: $abbreviation)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Shortcut abbreviation")
            }

            Picker("Default action", selection: $delivery) {
                ForEach(InsertAliasDelivery.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }

            HStack {
                if let alias = selected.alias {
                    Button("Remove", role: .destructive) {
                        let clipID = selected.clip.id
                        model.removeInsertAlias(alias)
                        selectedID = clipID
                        abbreviation = ""
                        delivery = .copy
                        isEditingShortcut = false
                    }
                }
                Spacer()
                Button("Cancel") {
                    isEditingShortcut = false
                }
                Button("Save") {
                    if model.saveInsertAlias(
                        for: selected.clip,
                        abbreviation: abbreviation,
                        delivery: delivery
                    ) {
                        query = ";\(InsertAlias.normalize(abbreviation))"
                        isEditingShortcut = false
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 340)
        .onExitCommand { isEditingShortcut = false }
    }

    private func performDefaultAction() {
        guard let selected else { return }
        guard selected.alias?.delivery != .pasteIntoFrontmostApplication
            || model.canPasteFromInsertPalette(token: pasteTargetToken)
        else { return }

        model.performInsert(
            selected,
            pasteTargetToken: pasteTargetToken
        )
        cancel()
    }

    private func defaultActionLabel(for result: InsertAliasResult) -> String {
        switch result.alias?.delivery ?? .copy {
        case .copy: "Copy"
        case .pasteIntoFrontmostApplication: "Paste into Previous App"
        }
    }

    private func defaultActionSystemImage(for result: InsertAliasResult) -> String {
        switch result.alias?.delivery ?? .copy {
        case .copy: "doc.on.doc"
        case .pasteIntoFrontmostApplication: "keyboard"
        }
    }

    private func selectedDescription(for result: InsertAliasResult) -> String {
        let kind = result.clip.savedItemKind == .note ? "Note" : "Saved clip"
        guard let trigger = result.trigger else { return kind }
        return "\(kind) · \(trigger)"
    }

    private func accessibilityLabel(for result: InsertAliasResult) -> String {
        let kind = result.clip.savedItemKind == .note ? "Note" : "Saved clip"
        guard let trigger = result.trigger else {
            return "\(result.clip.title), \(kind)"
        }
        return "\(result.clip.title), \(kind), shortcut \(trigger)"
    }

    private func syncAliasFields() {
        abbreviation = selected?.alias?.abbreviation ?? ""
        delivery = selected?.alias?.delivery ?? .copy
    }

    private func moveResultSelection(_ direction: MoveCommandDirection) {
        let availableResults = results
        guard !availableResults.isEmpty else { return }
        let currentIndex = availableResults.firstIndex { $0.id == selectedID } ?? 0
        switch direction {
        case .down:
            selectedID = availableResults[min(currentIndex + 1, availableResults.count - 1)].id
        case .up:
            selectedID = availableResults[max(currentIndex - 1, 0)].id
        default:
            break
        }
        syncAliasFields()
    }

    private func openLibrary() {
        cancel()
        LibraryWindowPresenter.show(using: openWindow) { message in
            model.errorMessage = message
        }
    }

}
