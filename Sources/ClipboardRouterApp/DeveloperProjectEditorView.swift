import AppKit
import ClipboardRouterCore
import SwiftUI
import UniformTypeIdentifiers

enum DeveloperProjectPickerAccessibility {
    static func ideRoot(_ projectID: UUID) -> String {
        "uiAcceptance.projects.ide.root.\(uuid(projectID))"
    }

    static func ideSearch(_ projectID: UUID) -> String {
        "uiAcceptance.projects.ide.search.\(uuid(projectID))"
    }

    static func ideRow(projectID: UUID, bundleIdentifier: String) -> String {
        "uiAcceptance.projects.ide.row.\(uuid(projectID)).\(component(bundleIdentifier))"
    }

    static func ideClose(_ projectID: UUID) -> String {
        "uiAcceptance.projects.ide.close.\(uuid(projectID))"
    }

    static func captureRoot(_ projectID: UUID) -> String {
        "uiAcceptance.projects.captureApps.root.\(uuid(projectID))"
    }

    static func captureRow(projectID: UUID, bundleIdentifier: String) -> String {
        "uiAcceptance.projects.captureApps.row.\(uuid(projectID)).\(component(bundleIdentifier))"
    }

    static func captureDone(_ projectID: UUID) -> String {
        "uiAcceptance.projects.captureApps.done.\(uuid(projectID))"
    }

    static func stateValue(results: Int, selected: Int, discovering: Bool) -> String {
        "results=\(results)|selected=\(selected)|discovering=\(discovering)"
    }

    static func component(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private static func uuid(_ id: UUID) -> String { id.uuidString.lowercased() }
}

struct DeveloperProjectEditorView: View {
    @ObservedObject var model: AppModel
    let clipToAdd: PresentedClip?
    let dismiss: () -> Void

    @State private var name = ""
    @State private var repositoryURL: URL?
    @State private var isSaving = false

    init(
        model: AppModel,
        clipToAdd: PresentedClip? = nil,
        dismiss: @escaping () -> Void
    ) {
        self.model = model
        self.clipToAdd = clipToAdd
        self.dismiss = dismiss
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("New Project")
                    .font(.title2.weight(.semibold))
                Text(clipToAdd == nil
                    ? "Choose the repository yourself. Clipboard Router stores read-only local access, not its path in sync."
                    : "Choose the repository, then this clip will be added to the new project. The project stays local unless you explicitly share a reviewed Debug Bundle.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Form {
                TextField("Project name", text: $name)
                    .accessibilityLabel("Project name")
                    .accessibilityIdentifier("uiAcceptance.projects.name")
                LabeledContent("Repository") {
                    HStack(spacing: 8) {
                        Text(repositoryURL?.lastPathComponent ?? "Not selected")
                            .foregroundStyle(repositoryURL == nil ? .secondary : .primary)
                            .lineLimit(1)
                        Button("Choose…") { chooseRepository() }
                            .accessibilityIdentifier("uiAcceptance.projects.chooseRepository")
                    }
                }
            }
            .formStyle(.grouped)

            Label(
                "Git inspection reads only .git/HEAD. It does not run Git, inspect source files, hooks, remotes, or worktrees.",
                systemImage: "lock.shield"
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel", action: dismiss)
                    .keyboardShortcut(.cancelAction)
                Button("Create Project") { createProject() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave || isSaving)
                    .accessibilityIdentifier("uiAcceptance.projects.create")
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && repositoryURL != nil
    }

    private func chooseRepository() {
        let panel = NSOpenPanel()
        panel.title = "Choose Repository Folder"
        panel.prompt = "Choose Repository"
        panel.allowedContentTypes = [.folder]
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK else { return }
        repositoryURL = panel.url
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            name = panel.url?.lastPathComponent ?? ""
        }
    }

    private func createProject() {
        guard let repositoryURL else { return }
        isSaving = true
        Task { @MainActor in
            if await model.createDeveloperProject(name: name, repositoryRootURL: repositoryURL) {
                if let clipToAdd, let project = model.selectedDeveloperProject {
                    model.addToDeveloperProject(clipToAdd, projectID: project.id)
                }
                dismiss()
            }
            isSaving = false
        }
    }
}

struct DeveloperIDEPickerView: View {
    @ObservedObject var model: AppModel
    let project: DeveloperProject
    let dismiss: () -> Void

    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Open \(project.name) in…")
                .font(.title3.weight(.semibold))
            HStack {
                TextField("Search installed apps", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier(DeveloperProjectPickerAccessibility.ideSearch(project.id))
                Button("Refresh Installed Apps", systemImage: "arrow.clockwise") {
                    model.refreshApplicationExclusionOptions(force: true)
                }
                .labelStyle(.iconOnly)
                .help("Refresh Installed Apps")
                .disabled(model.isDiscoveringApplications)
            }
            List(filteredApplications) { application in
                Button {
                    model.openDeveloperProjectInIDE(project, application: application)
                    dismiss()
                } label: {
                    HStack {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: application.applicationURL.path))
                            .resizable()
                            .frame(width: 24, height: 24)
                        Text(application.displayName)
                        Spacer()
                        if application.bundleIdentifier == project.preferredIDEBundleIdentifier {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(DeveloperProjectPickerAccessibility.ideRow(
                    projectID: project.id,
                    bundleIdentifier: application.bundleIdentifier
                ))
                .accessibilityValue(
                    "preferred=\(application.bundleIdentifier == project.preferredIDEBundleIdentifier)|bundle=\(DeveloperProjectPickerAccessibility.component(application.bundleIdentifier))"
                )
            }
            .overlay {
                if model.isDiscoveringApplications {
                    ProgressView("Finding installed apps…")
                } else if filteredApplications.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            HStack {
                Text("The selected app opens the folder. Clipboard content is not copied or pasted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Close", action: dismiss)
                    .accessibilityIdentifier(DeveloperProjectPickerAccessibility.ideClose(project.id))
            }
        }
        .padding(18)
        .frame(width: 480, height: 440)
        .onAppear { model.refreshApplicationExclusionOptions(force: false) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(DeveloperProjectPickerAccessibility.ideRoot(project.id))
        .accessibilityValue(DeveloperProjectPickerAccessibility.stateValue(
            results: filteredApplications.count,
            selected: 0,
            discovering: model.isDiscoveringApplications
        ))
    }

    private var filteredApplications: [ApplicationExclusionOption] {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let options = value.isEmpty
            ? model.applicationExclusionOptions
            : model.applicationExclusionOptions.filter {
                $0.displayName.localizedCaseInsensitiveContains(value)
                    || $0.bundleIdentifier.localizedCaseInsensitiveContains(value)
            }
        return options.sorted { lhs, rhs in
            let lhsPreferred = lhs.bundleIdentifier == project.preferredIDEBundleIdentifier
            let rhsPreferred = rhs.bundleIdentifier == project.preferredIDEBundleIdentifier
            if lhsPreferred != rhsPreferred { return lhsPreferred }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }
}

struct DeveloperSourceAppsPickerView: View {
    @ObservedObject var model: AppModel
    let project: DeveloperProject
    let dismiss: () -> Void
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Approved Capture Apps")
                    .font(.title3.weight(.semibold))
                Text("Automatic project capture accepts developer clips only from apps you choose here.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                TextField("Search installed apps", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("developerSourceApps.search")
                    .accessibilityValue("project=\(project.id.uuidString.lowercased())")
                Button("Refresh Installed Apps", systemImage: "arrow.clockwise") {
                    model.refreshApplicationExclusionOptions(force: true)
                }
                .labelStyle(.iconOnly)
                .help("Refresh Installed Apps")
                .disabled(model.isDiscoveringApplications)
            }
            List(filteredApplications) { application in
                Toggle(isOn: Binding(
                    get: {
                        model.developerWorkspaceSnapshot.projects
                            .first(where: { $0.id == project.id })?
                            .allowedSourceBundleIdentifiers
                            .contains(application.bundleIdentifier) == true
                    },
                    set: {
                        model.setDeveloperSourceApplication(
                            application.bundleIdentifier,
                            allowed: $0,
                            for: project.id
                        )
                    }
                )) {
                    HStack {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: application.applicationURL.path))
                            .resizable().frame(width: 24, height: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(application.displayName)
                            Text(application.bundleIdentifier)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .toggleStyle(.checkbox)
                .accessibilityIdentifier(DeveloperProjectPickerAccessibility.captureRow(
                    projectID: project.id,
                    bundleIdentifier: application.bundleIdentifier
                ))
                .accessibilityValue(
                    "allowed=\(allowedSourceBundleIdentifiers.contains(application.bundleIdentifier))|bundle=\(DeveloperProjectPickerAccessibility.component(application.bundleIdentifier))"
                )
            }
            .overlay {
                if model.isDiscoveringApplications {
                    ProgressView("Finding installed apps…")
                } else if filteredApplications.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            HStack {
                Text("No selection means automatic capture stays inert.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done", action: dismiss)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier(DeveloperProjectPickerAccessibility.captureDone(project.id))
            }
        }
        .padding(18)
        .frame(width: 520, height: 480)
        .onAppear { model.refreshApplicationExclusionOptions(force: false) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(DeveloperProjectPickerAccessibility.captureRoot(project.id))
        .accessibilityValue(DeveloperProjectPickerAccessibility.stateValue(
            results: filteredApplications.count,
            selected: allowedSourceBundleIdentifiers.count,
            discovering: model.isDiscoveringApplications
        ))
    }

    private var filteredApplications: [ApplicationExclusionOption] {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return model.applicationExclusionOptions }
        return model.applicationExclusionOptions.filter {
            $0.displayName.localizedCaseInsensitiveContains(value)
                || $0.bundleIdentifier.localizedCaseInsensitiveContains(value)
        }
    }

    private var allowedSourceBundleIdentifiers: Set<String> {
        Set(model.developerWorkspaceSnapshot.projects
            .first(where: { $0.id == project.id })?
            .allowedSourceBundleIdentifiers ?? [])
    }
}
