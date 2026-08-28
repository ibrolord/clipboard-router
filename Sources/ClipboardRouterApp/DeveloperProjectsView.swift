import ClipboardRouterCore
import ClipboardRouterSync
import SwiftUI

enum DeveloperProjectsAccessibility {
    static let root = "uiAcceptance.projects.root"
    static let newProject = "uiAcceptance.projects.newProject"
    static let projectTab = "uiAcceptance.projects.tab"
    static let activeState = "uiAcceptance.projects.activeState"
    static let makeActive = "uiAcceptance.projects.makeActive"
    static let debugBundles = "uiAcceptance.projects.debugBundles"

    static func projectRow(_ id: UUID) -> String {
        "uiAcceptance.projects.row.\(id.uuidString.lowercased())"
    }

    static func debugBundleRow(_ id: UUID) -> String {
        "uiAcceptance.projects.debugBundleRow.\(id.uuidString.lowercased())"
    }
}

struct DeveloperProjectsView: View {
    @ObservedObject var model: AppModel
    @State private var isCreatingProject = false
    @State private var projectForIDE: DeveloperProject?
    @State private var projectForSourceApps: DeveloperProject?
    @State private var projectToRename: DeveloperProject?
    @State private var renamedProjectName = ""
    @State private var projectToArchive: DeveloperProject?
    @State private var selectedTab: ProjectTab = .timeline

    private enum ProjectTab: String, CaseIterable, Identifiable {
        case timeline = "Timeline"
        case bundles = "Debug Bundles"
        case team = "All Team Bundles"
        var id: String { rawValue }
    }

    var body: some View {
        Group {
            if model.developerProjects.isEmpty {
                VStack(spacing: 0) {
                    ContentUnavailableView {
                        Label("No Projects", systemImage: "hammer")
                    } description: {
                        Text("Create a local project to keep related developer clips and reviewed Debug Bundles together.")
                    } actions: {
                        Button("New Project…", systemImage: "plus") {
                            isCreatingProject = true
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier(DeveloperProjectsAccessibility.newProject)
                        if model.canExportBundledCommandLineTool {
                            Button("Export cr Command…", systemImage: "terminal") {
                                model.exportBundledCommandLineTool()
                            }
                        }
                    }
                    if hasTeamDebugBundles {
                        Divider()
                        teamBundles()
                    }
                }
            } else {
                HSplitView {
                    projectList
                        .frame(minWidth: 220, idealWidth: 250, maxWidth: 290)
                    projectDetail
                        .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .sheet(isPresented: $isCreatingProject) {
            DeveloperProjectEditorView(model: model) { isCreatingProject = false }
        }
        .sheet(item: $projectForIDE) { project in
            DeveloperIDEPickerView(model: model, project: project) { projectForIDE = nil }
        }
        .sheet(item: $projectForSourceApps) { project in
            DeveloperSourceAppsPickerView(model: model, project: project) {
                projectForSourceApps = nil
            }
        }
        .alert("Rename Project", isPresented: Binding(
            get: { projectToRename != nil },
            set: { if !$0 { projectToRename = nil } }
        )) {
            TextField("Project name", text: $renamedProjectName)
            Button("Cancel", role: .cancel) { projectToRename = nil }
            Button("Rename") {
                guard let project = projectToRename else { return }
                Task { @MainActor in
                    if await model.renameDeveloperProject(id: project.id, name: renamedProjectName) {
                        projectToRename = nil
                    }
                }
            }
            .disabled(renamedProjectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .confirmationDialog(
            "Archive this project?",
            isPresented: Binding(
                get: { projectToArchive != nil },
                set: { if !$0 { projectToArchive = nil } }
            ),
            presenting: projectToArchive
        ) { project in
            Button("Archive \(project.name)", role: .destructive) {
                model.archiveDeveloperProject(id: project.id)
                projectToArchive = nil
            }
        } message: { _ in
            Text("The ordinary clips remain in History or Saved. The archived project stops receiving clips.")
        }
    }

    private var projectList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Projects").font(.headline)
                Spacer()
                Button("New Project", systemImage: "plus") { isCreatingProject = true }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier(DeveloperProjectsAccessibility.newProject)
            }
            .padding(12)
            Divider()
            List(selection: Binding(
                get: { model.selectedDeveloperProjectID },
                set: { model.selectDeveloperProject($0) }
            )) {
                ForEach(model.developerProjects) { project in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(project.name).lineLimit(1)
                            if project.id == model.activeDeveloperProject?.id {
                                Text("ACTIVE")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.green)
                            }
                        }
                        HStack(spacing: 4) {
                            if let branch = project.repository?.branch {
                                Image(systemName: "arrow.triangle.branch")
                                Text(branch).lineLimit(1)
                            } else {
                                Text(project.repository?.displayName ?? "Local project")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .tag(project.id)
                    .padding(.vertical, 3)
                    .accessibilityIdentifier(DeveloperProjectsAccessibility.projectRow(project.id))
                    .accessibilityValue(
                        project.id == model.activeDeveloperProject?.id ? "Active" : "Inactive"
                    )
                }
            }
            Divider()
            if model.canExportBundledCommandLineTool {
                VStack(alignment: .leading, spacing: 5) {
                    Button("Export cr Command…", systemImage: "terminal") {
                        model.exportBundledCommandLineTool()
                    }
                    .buttonStyle(.borderless)
                    Text(model.bundledCommandLineToolVersion.map { "Bundled \($0) · PATH is never changed" }
                        ?? "Available in the packaged desktop app")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
            }
        }
        .onAppear {
            if model.selectedDeveloperProjectID == nil {
                model.selectDeveloperProject(model.activeDeveloperProject?.id ?? model.developerProjects.first?.id)
            }
        }
    }

    @ViewBuilder
    private var projectDetail: some View {
        if let project = model.selectedDeveloperProject {
            VStack(spacing: 0) {
                projectHeader(project)
                Divider()
                Picker("Project view", selection: $selectedTab) {
                    ForEach(ProjectTab.allCases) { tab in Text(tab.rawValue).tag(tab) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 360)
                .padding(12)
                .accessibilityIdentifier(DeveloperProjectsAccessibility.projectTab)
                .accessibilityValue(selectedTab.rawValue)
                Divider()
                switch selectedTab {
                case .timeline: timeline(project)
                case .bundles: bundles(project)
                case .team: teamBundles()
                }
            }
        } else {
            ContentUnavailableView("Select a Project", systemImage: "hammer")
        }
    }

    private func projectHeader(_ project: DeveloperProject) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(project.name).font(.title2.weight(.semibold))
                    Label(
                        project.repository?.branch ?? project.repository?.displayName ?? "Local-only",
                        systemImage: project.repository?.branch == nil ? "folder" : "arrow.triangle.branch"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button("Rename…", systemImage: "pencil") {
                        renamedProjectName = project.name
                        projectToRename = project
                    }
                    Button("Archive…", systemImage: "archivebox", role: .destructive) {
                        projectToArchive = project
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
            }

            HStack(spacing: 8) {
                if project.id == model.activeDeveloperProject?.id {
                    HStack(spacing: 8) {
                        Label("Active", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .accessibilityIdentifier(DeveloperProjectsAccessibility.activeState)
                            .accessibilityValue(project.name)
                        Button("Stop Using", systemImage: "stop.circle") {
                            model.setActiveDeveloperProject(nil)
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.isBusy)
                        .help("Stop automatically assigning new developer clips to this project")
                    }
                } else {
                    Button("Make Active") { model.setActiveDeveloperProject(project.id) }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isBusy)
                        .accessibilityIdentifier(DeveloperProjectsAccessibility.makeActive)
                }
                Spacer(minLength: 8)
                Button("Open in IDE…", systemImage: "arrow.up.forward.app") {
                    projectForIDE = project
                }
                .disabled(project.repository == nil)
                .accessibilityIdentifier("developerProjects.openInIDE")
            }

            HStack(spacing: 14) {
                Toggle("Auto-add when active", isOn: Binding(
                    get: { model.selectedDeveloperProject?.autoAddDeveloperClips == true },
                    set: { model.setDeveloperAutoCapture($0, for: project.id) }
                ))
                .toggleStyle(.switch)
                .disabled(project.allowedSourceBundleIdentifiers.isEmpty)
                .accessibilityIdentifier("developerProjects.autoCapture")
                if project.allowedSourceBundleIdentifiers.isEmpty {
                    Button("Choose Capture Apps…", systemImage: "app.badge.checkmark") {
                        projectForSourceApps = project
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("developerProjects.captureApps")
                } else {
                    Button("Capture Apps…", systemImage: "app.badge.checkmark") {
                        projectForSourceApps = project
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("developerProjects.captureApps")
                }
                Text(autoCaptureStatus(for: project))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .help("Off by default. Automatic capture requires an approved app and accepts only ordinary non-sensitive code, commands, logs, errors, and stack traces.")
        }
        .padding(16)
    }

    private func timeline(_ project: DeveloperProject) -> some View {
        List(model.developerTimeline) { entry in
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: timelineSymbol(entry.kind))
                    .foregroundStyle(.tint)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(timelineTitle(entry.kind, project: project))
                    if case let .clipAdded(reference) = entry.kind {
                        if let clip = model.developerClip(for: reference) {
                            Text(clip.title).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        } else {
                            Text("Source clip is no longer in the ordinary library")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
                Text(entry.occurredAt, format: .relative(presentation: .named))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
        .overlay {
            if model.developerTimeline.isEmpty {
                ContentUnavailableView(
                    "No Project Activity",
                    systemImage: "clock",
                    description: Text("Add a clip manually, or enable automatic developer capture.")
                )
            }
        }
    }

    private func bundles(_ project: DeveloperProject) -> some View {
        let saved = model.developerWorkspaceSnapshot.debugBundles
            .filter { $0.projectID == project.id }
            .sorted { $0.savedAt > $1.savedAt }
        return VStack(spacing: 0) {
            HStack {
                Text("Reviewed bundles are durable local snapshots.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Build Bundle…", systemImage: "ladybug") {
                    model.openActionsWorkspace(.pasteTools)
                }
            }
            .padding(12)
            Divider()
            if saved.isEmpty {
                ContentUnavailableView(
                    "No Saved Debug Bundles",
                    systemImage: "ladybug",
                    description: Text("Build one in Actions, review its exact Markdown, then choose a project to save it to.")
                )
            } else {
                List(saved) { snapshot in
                    DisclosureGroup {
                        Text((try? DebugBundleRenderer().renderMarkdown(snapshot.bundle)) ?? "Preview unavailable")
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .padding(.vertical, 8)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(snapshot.bundle.problemStatement ?? "Debug Bundle")
                                    .lineLimit(1)
                                Text("\(snapshot.bundle.items.count) items")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(snapshot.savedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier(
                        DeveloperProjectsAccessibility.debugBundleRow(snapshot.id)
                    )
                    .accessibilityValue(
                        "\(snapshot.bundle.items.count) item\(snapshot.bundle.items.count == 1 ? "" : "s")"
                    )
                }
            }
        }
        .accessibilityIdentifier(DeveloperProjectsAccessibility.debugBundles)
        .accessibilityValue("\(saved.count) saved bundle\(saved.count == 1 ? "" : "s")")
    }

    private var teamDebugBundleNotes: [SavedClip] {
        model.sharedFolderSnapshots.values
            .flatMap(\.savedClips)
            .filter {
                $0.kind == .note
                    && $0.tags?.contains(AppModel.sharedDebugBundleTag) == true
                    && $0.content.text.hasPrefix("Debug Bundle\n\nProject: ")
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private var hasTeamDebugBundles: Bool { !teamDebugBundleNotes.isEmpty }

    private func teamBundles() -> some View {
        let notes = teamDebugBundleNotes
        return VStack(spacing: 0) {
            HStack {
                Text("Team Debug Bundles across your shared folders")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(12)
            Divider()
            if notes.isEmpty {
                ContentUnavailableView(
                    "No Team Debug Bundles",
                    systemImage: "person.2",
                    description: Text("Publish a reviewed bundle to an editable shared folder to make it visible here.")
                )
            } else {
                List(notes) { note in
                    DisclosureGroup {
                        Text(note.content.text)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .padding(.vertical, 6)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(note.name)
                                Text(
                                    note.folderID.map(model.folderPath(for:))
                                        ?? "Shared folder unavailable"
                                )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(note.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func autoCaptureStatus(for project: DeveloperProject) -> String {
        guard !project.allowedSourceBundleIdentifiers.isEmpty else {
            return "Choose at least one app before enabling automatic capture."
        }
        let count = project.allowedSourceBundleIdentifiers.count
        guard project.autoAddDeveloperClips else {
            return "\(count) approved · auto-add is off"
        }
        if project.id == model.activeDeveloperProject?.id {
            return "\(count) approved · auto-add is on"
        }
        return "\(count) approved · activates when this project is Active"
    }

    private func timelineSymbol(_ kind: DeveloperTimelineEntry.Kind) -> String {
        switch kind {
        case .projectCreated: "hammer"
        case .clipAdded: "doc.badge.plus"
        case .debugBundleSaved: "ladybug"
        }
    }

    private func timelineTitle(_ kind: DeveloperTimelineEntry.Kind, project: DeveloperProject) -> String {
        switch kind {
        case .projectCreated: "Created \(project.name)"
        case .clipAdded: "Added a clip"
        case let .debugBundleSaved(_, itemCount):
            "Saved a Debug Bundle with \(itemCount) item\(itemCount == 1 ? "" : "s")"
        }
    }
}
