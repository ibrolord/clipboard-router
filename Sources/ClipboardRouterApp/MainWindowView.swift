import ClipboardRouterCore
import ClipboardRouterPlatform
import SwiftUI

enum ClipTablePresentation {
    static func sectionIdentity(_ section: LibrarySection) -> LibrarySection { section }

    /// Native AppKit-backed tables can retain the old row tree when a small Saved collection is
    /// mutated in place. Include the visible item identities and presentation versions so a local
    /// create/edit replaces the table data source, while ordinary selection/search changes within
    /// the same rows keep native keyboard and pointer semantics.
    static func dataIdentity(_ section: LibrarySection, clips: [PresentedClip]) -> String {
        let rows = clips.map {
            "\($0.id.uuidString.lowercased()):\($0.title):\($0.date.timeIntervalSinceReferenceDate)"
        }.joined(separator: "|")
        return "\(section):\(rows)"
    }
}

private extension View {
    @ViewBuilder
    func clipActionAcceptance(
        _ descriptor: ClipActionDescriptor?,
        clipID: UUID,
        inventory: ClipActionInventory
    ) -> some View {
        if let descriptor {
            accessibilityIdentifier(ClipActionAcceptanceAccessibility.action(
                descriptor,
                clipID: clipID,
                surface: inventory.surface
            ))
            .accessibilityHint(ClipActionAcceptanceAccessibility.descriptorValue(
                descriptor,
                index: ClipActionAcceptanceAccessibility.index(of: descriptor, in: inventory)
            ))
        } else {
            self
        }
    }
}

struct MainWindowView: View {
    @ObservedObject var model: AppModel
    @State private var isCreatingFolder = false
    @State private var isCreatingSalesWorkspace = false
    @State private var isShowingSearchHelp = false
    @State private var noteEditorRequest: NoteEditorRequest?
    @State private var isShowingInsertPalette = false
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        Group {
            if model.isReady {
                HStack(spacing: 0) {
                    librarySidebar
                        // Keep the existing sidebar tree for accessibility and packaged UI
                        // automation, while allowing the content pane to breathe on wide windows
                        // and yielding space on smaller displays.
                        .frame(minWidth: 220, idealWidth: 240, maxWidth: 280)
                    Divider()
                    libraryContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .layoutPriority(1)
                    }
            } else {
                ProgressView("Opening Clipboard Router…")
            }
        }
        .navigationTitle("Clipboard Router")
        .toolbar {
            if model.isOrdinarySearchAvailable {
                ToolbarItemGroup(placement: .automatic) {
                    TextField("Search content or metadata", text: $model.searchText)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 220, idealWidth: 280, maxWidth: 340)
                        .focused($isSearchFocused)
                        .accessibilityIdentifier("uiAcceptance.library.search")
                        .accessibilityLabel("Search content or metadata across History and Saved Clips")
                    Button("Search filters", systemImage: "line.3.horizontal.decrease.circle") {
                        isShowingSearchHelp.toggle()
                    }
                    .help("Search fields and filter examples")
                    .popover(isPresented: $isShowingSearchHelp, arrowEdge: .bottom) {
                        SearchHelpView { query in
                            model.applySearchExample(query)
                            isShowingSearchHelp = false
                        }
                    }
                }
            }
            ToolbarItem(placement: .automatic) {
                Button("Quick Paste", systemImage: "text.badge.plus") {
                    model.requestInsertPalette()
                }
                .help("Find and insert a saved clip or note (\(model.insertPaletteHotKeyChoice.displayName))")
            }
        }
        .onChange(of: model.searchFocusRequestID) { _, _ in
            isSearchFocused = true
        }
        .onChange(of: model.noteCreationRequestID) { _, _ in
            guard model.noteCreationPresentationSurface == .library else { return }
            noteEditorRequest = NoteEditorRequest(mode: .create)
        }
        .onChange(of: model.insertPaletteRequestID) { _, _ in
            guard model.insertPalettePresentationSurface == .library else { return }
            isShowingInsertPalette = true
        }
        .onChange(of: model.searchText) { _, _ in model.updateSearch() }
        .safeAreaInset(edge: .bottom, spacing: 12) {
            Group {
                if let status = model.statusMessage {
                    StatusToast(message: status) { model.dismissStatus() }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: model.statusMessage)
        }
        .sheet(
            isPresented: Binding(
                get: { model.pendingEncryptedShareRequest != nil },
                set: { presented in
                    if !presented { model.dismissEncryptedShare() }
                }
            )
        ) {
            if let request = model.pendingEncryptedShareRequest {
                EncryptedShareComposerSheet(
                    model: model,
                    request: request,
                    dismiss: model.dismissEncryptedShare
                )
            }
        }
        .sheet(
            isPresented: Binding(
                get: { model.decryptedSharePreview != nil },
                set: { presented in
                    if !presented { model.clearDecryptedSharePreview() }
                }
            )
        ) {
            if let content = model.decryptedSharePreview {
                EncryptedSharePreviewSheet(
                    content: content,
                    copy: model.copyDecryptedSharePreview,
                    dismiss: model.clearDecryptedSharePreview
                )
            }
        }
        .sheet(isPresented: $isCreatingFolder) {
            NewFolderSheet { name in
                model.createFolder(named: name)
                isCreatingFolder = false
            }
        }
        .sheet(isPresented: $isCreatingSalesWorkspace) {
            NewSalesWorkspaceSheet { name in
                model.createSalesWorkspace(named: name)
                isCreatingSalesWorkspace = false
            }
        }
        .sheet(item: pendingHandoffBinding) { request in
            HandoffReviewSheet(
                request: request,
                copyMarkdown: model.copyFolderBrief,
                export: model.exportFolderHandoff,
                cancel: model.dismissHandoffReview
            )
        }
        .sheet(item: $noteEditorRequest) { request in
            NoteEditorSheet(request: request, folders: model.folderDestinations) { title, body, folderID in
                await model.createNoteFromEditor(title: title, body: body, folderID: folderID)
            }
        }
        .sheet(isPresented: $isShowingInsertPalette) {
            InsertPaletteSheet(
                model: model,
                pasteTargetToken: model.insertPalettePasteTargetToken,
                requestCreateNote: {
                    isShowingInsertPalette = false
                    noteEditorRequest = NoteEditorRequest(mode: .create)
                }
            ) { isShowingInsertPalette = false }
        }
        .sheet(item: pendingCRMReviewBinding) { request in
            CRMWriteReviewSheet(model: model, draft: request)
        }
        .sheet(item: pendingContactBinding) { request in
            ContactDraftSheet(
                draft: request.draft,
                checkDuplicates: model.contactDuplicates,
                save: { draft, allowDuplicate in
                    await model.createContact(
                        draft,
                        sourceClip: request.sourceClip,
                        allowingPossibleDuplicate: allowDuplicate
                    )
                },
                cancel: model.dismissContactDraft
            )
        }
        .sheet(item: pendingCombinedClipsBinding) { request in
            CombinedClipsReviewSheet(model: model, request: request)
        }
        .sheet(item: pendingDebugBundleBinding) { request in
            DebugBundleReviewSheet(model: model, request: request)
        }
        .sheet(item: pendingAssistantBinding) { request in
            AIClipAssistantSheet(
                availability: model.onDeviceAIAvailability,
                cloudConfigured: model.isHostedAssistantConfigured,
                cloudConsentGranted: model.isHostedAssistantConsentGranted,
                cloudModel: model.hostedAssistantModel,
                cloudSourceEligible: model.canUseCloudAssistant(for: request.sourceClip),
                cloudSourceUnavailableReason: model.cloudAssistantUnavailableReason(for: request.sourceClip),
                sourceTitle: request.sourceClip.title,
                acceptanceID: request.id,
                ask: { prompt, messages, purpose, engine in
                    await model.askAssistant(
                        prompt: prompt,
                        messages: messages,
                        purpose: purpose,
                        engine: engine,
                        sourceClip: request.sourceClip
                    )
                },
                saveResult: {
                    await model.saveAIDraft(
                        $0,
                        sourceClip: request.sourceClip,
                        modelProvenance: $1
                    )
                },
                copyResult: model.copyAssistantResponse,
                errorMessage: Binding(
                    get: { model.errorMessage },
                    set: { model.errorMessage = $0 }
                ),
                cancel: model.dismissAIAssistant
            )
        }
        .sheet(item: pendingApplicationBrowserBinding) { request in
            ApplicationBrowserSheet(
                model: model,
                request: request,
                cancel: model.dismissApplicationBrowser
            )
        }
        .sheet(item: pendingFlowBinding) { request in
            ClipFlowReviewSheet(
                request: request,
                folderName: { $0.map(model.folderPath(for:)) ?? "Saved" },
                run: { await model.executeFlow(request) },
                cancel: model.dismissFlowReview
            )
        }
        .sheet(
            isPresented: Binding(
                get: { model.isReady && !model.hasCompletedOnboarding },
                set: { _ in }
            )
        ) {
            OnboardingView(
                isEngineeringBuild: model.isDirectLicenseEngineeringBuild
                    && !model.isMacAppStoreDistribution
            ) {
                model.completeOnboarding()
            }
                .interactiveDismissDisabled()
        }
        .alert(
            "Clipboard Router",
            isPresented: errorAlertPresented
        ) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "An unknown error occurred.")
        }
    }

    private var librarySidebar: some View {
        LibrarySidebar(
            model: model,
            isCreatingFolder: $isCreatingFolder,
            isCreatingSalesWorkspace: $isCreatingSalesWorkspace
        )
    }

    private var libraryContent: some View {
        ZStack {
            HSplitView {
                ClipListView(model: model)
                    .frame(minWidth: 240, idealWidth: 320, maxWidth: 420)
                ClipDetailView(model: model)
                    .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
            }
            .opacity(showsOrdinaryLibrary ? 1 : 0)
            .allowsHitTesting(showsOrdinaryLibrary)
            .accessibilityHidden(!showsOrdinaryLibrary)

            HSplitView {
                VaultListView(model: model)
                    .frame(minWidth: 240, idealWidth: 320, maxWidth: 420)
                VaultDetailView(model: model)
                    .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
            }
            .opacity(showsVault ? 1 : 0)
            .allowsHitTesting(showsVault)
            .accessibilityHidden(!showsVault)

            dashboardDetail
                .opacity(showsDashboard ? 1 : 0)
                .allowsHitTesting(showsDashboard)
                .accessibilityHidden(!showsDashboard)
        }
    }

    private var showsDashboard: Bool {
        switch model.selectedSection {
        case .clipboardHealth, .workflows, .sync, .developerProjects, .automaticOrganization: true
        default: false
        }
    }

    private var showsVault: Bool {
        model.selectedSection == .vault
    }

    private var showsOrdinaryLibrary: Bool {
        !showsDashboard && !showsVault
    }

    @ViewBuilder
    private var dashboardDetail: some View {
        switch model.selectedSection {
        case .clipboardHealth:
            ClipboardHealthDashboardView(model: model)
        case .workflows:
            WorkflowDashboardView(model: model)
        case .sync:
            SyncDashboardView(model: model)
        case .developerProjects:
            DeveloperProjectsView(model: model)
        case .automaticOrganization:
            AutomaticOrganizationDashboardView(model: model)
        default:
            ClipDetailView(model: model)
        }
    }

    private var errorAlertPresented: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { presented in
                if !presented { model.errorMessage = nil }
            }
        )
    }

    private var pendingHandoffBinding: Binding<HandoffReviewRequest?> {
        Binding(
            get: { model.pendingHandoffReview },
            set: { value in if value == nil { model.dismissHandoffReview() } }
        )
    }

    private var pendingCRMReviewBinding: Binding<CRMReviewDraft?> {
        Binding(
            get: { model.pendingCRMReview },
            set: { if $0 == nil { model.dismissCRMReview() } }
        )
    }

    private var pendingContactBinding: Binding<ContactDraftRequest?> {
        Binding(
            get: {
                model.contactDraftPresentationSurface == .library ? model.pendingContactDraft : nil
            },
            set: { value in
                if value == nil, model.contactDraftPresentationSurface == .library {
                    model.dismissContactDraft()
                }
            }
        )
    }

    private var pendingAssistantBinding: Binding<AIClipAssistantRequest?> {
        Binding(
            get: {
                model.assistantPresentationSurface == .library ? model.pendingAIAssistant : nil
            },
            set: { value in
                if value == nil, model.assistantPresentationSurface == .library {
                    model.dismissAIAssistant()
                }
            }
        )
    }

    private var pendingCombinedClipsBinding: Binding<CombinedClipsReviewRequest?> {
        Binding(
            get: { model.pendingCombinedClipsReview },
            set: { value in
                if value == nil { model.dismissCombinedClipsReview() }
            }
        )
    }

    private var pendingDebugBundleBinding: Binding<DeveloperDebugBundleReviewRequest?> {
        Binding(
            get: { model.pendingDebugBundleReview },
            set: { value in
                if value == nil { model.dismissDebugBundleReview() }
            }
        )
    }

    private var pendingApplicationBrowserBinding: Binding<ApplicationBrowserRequest?> {
        Binding(
            get: {
                model.applicationBrowserPresentationSurface == .library
                    ? model.pendingApplicationBrowser : nil
            },
            set: { value in
                if value == nil, model.applicationBrowserPresentationSurface == .library {
                    model.dismissApplicationBrowser()
                }
            }
        )
    }

    private var pendingFlowBinding: Binding<ClipFlowRunReviewRequest?> {
        Binding(
            get: {
                model.flowReviewPresentationSurface == .library ? model.pendingFlowReview : nil
            },
            set: { value in
                if value == nil, model.flowReviewPresentationSurface == .library {
                    model.dismissFlowReview()
                }
            }
        )
    }

}

private struct LibrarySidebar: View {
    @Environment(\.openSettings) private var openSettings
    @ObservedObject var model: AppModel
    @Binding var isCreatingFolder: Bool
    @Binding var isCreatingSalesWorkspace: Bool
    @State private var folderBeingRenamed: ClipFolder?
    @State private var renamedFolderName = ""
    @State private var subfolderParent: ClipFolder?
    @State private var subfolderName = ""
    @State private var isBrowseExpanded = false
    @State private var areApplicationSourcesExpanded = false
    @State private var areDomainSourcesExpanded = false
    @State private var smartViewBeingEdited: UserSmartView?
    @State private var isSavingSmartView = false

    var body: some View {
        VStack(spacing: 0) {
            List(selection: Binding(
                get: { model.selectedSection },
                set: { model.selectLibrarySection($0) }
            )) {
                Section("Find") {
                    Label("History", systemImage: "clock.arrow.circlepath")
                        .badge(model.snapshot.history.count)
                        .tag(LibrarySection.history)
                        .accessibilityIdentifier("uiAcceptance.library.history")
                    DisclosureGroup(
                        isExpanded: $isBrowseExpanded,
                        content: {
                            ForEach(browseSmartViews) { smartView in
                                smartViewRow(smartView)
                            }
                            if !model.applicationSmartViews.isEmpty {
                                DisclosureGroup(
                                    isExpanded: $areApplicationSourcesExpanded,
                                    content: {
                                        ForEach(model.applicationSmartViews) { smartView in
                                            smartViewRow(smartView)
                                        }
                                    },
                                    label: {
                                        Label("Apps", systemImage: "app.dashed")
                                    }
                                )
                            }
                            if !model.domainSmartViews.isEmpty {
                                DisclosureGroup(
                                    isExpanded: $areDomainSourcesExpanded,
                                    content: {
                                        ForEach(model.domainSmartViews) { smartView in
                                            smartViewRow(smartView)
                                        }
                                    },
                                    label: {
                                        Label("Domains", systemImage: "globe")
                                    }
                                )
                            }
                        },
                        label: {
                            Label("Browse", systemImage: "line.3.horizontal.decrease.circle")
                        }
                    )
                }

                Section {
                    ForEach(Array(model.userSmartViews.enumerated()), id: \.element.id) { index, view in
                        if let definition = model.smartViewDefinition(for: .user(view.id)) {
                            smartViewRow(definition)
                                .accessibilityIdentifier(SmartViewBulkAccessibility.smartViewRow(view.id))
                                .accessibilityValue(SmartViewBulkAccessibility.smartViewValue(
                                    view,
                                    order: index
                                ))
                                .contextMenu {
                                    Button("Edit…", systemImage: "pencil") {
                                        smartViewBeingEdited = view
                                    }
                                    .accessibilityIdentifier(SmartViewBulkAccessibility.smartViewControl(
                                        "edit",
                                        id: view.id
                                    ))
                                    Button(
                                        view.isPinned ? "Unpin Smart View" : "Pin Smart View",
                                        systemImage: view.isPinned ? "pin.slash" : "pin"
                                    ) {
                                        model.setUserSmartViewPinned(id: view.id, pinned: !view.isPinned)
                                    }
                                    .accessibilityIdentifier(SmartViewBulkAccessibility.smartViewControl(
                                        "pin",
                                        id: view.id
                                    ))
                                    Divider()
                                    Button("Move Up", systemImage: "arrow.up") {
                                        model.moveUserSmartView(id: view.id, offset: -1)
                                    }
                                    .disabled(!model.canMoveUserSmartView(id: view.id, offset: -1))
                                    .accessibilityIdentifier(SmartViewBulkAccessibility.smartViewControl(
                                        "moveUp",
                                        id: view.id
                                    ))
                                    Button("Move Down", systemImage: "arrow.down") {
                                        model.moveUserSmartView(id: view.id, offset: 1)
                                    }
                                    .disabled(!model.canMoveUserSmartView(id: view.id, offset: 1))
                                    .accessibilityIdentifier(SmartViewBulkAccessibility.smartViewControl(
                                        "moveDown",
                                        id: view.id
                                    ))
                                    Divider()
                                    Button("Delete Smart View", systemImage: "trash", role: .destructive) {
                                        model.deleteUserSmartView(id: view.id)
                                    }
                                    .accessibilityIdentifier(SmartViewBulkAccessibility.smartViewControl(
                                        "delete",
                                        id: view.id
                                    ))
                                }
                        }
                    }
                    Button("Save Current Search…", systemImage: "plus") {
                        isSavingSmartView = true
                    }
                    .buttonStyle(.plain)
                    .disabled((try? ClipSearchQuery.validate(model.searchText)) == nil)
                    .accessibilityIdentifier("uiAcceptance.smartViews.saveCurrentSearch")
                    .accessibilityHint("Save the active content and metadata query as a local Smart View")
                } header: {
                    HStack {
                        Text("Smart Views")
                        Spacer()
                        Text("On this Mac")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Label("Saved", systemImage: "bookmark")
                        .badge(model.snapshot.savedClips.count)
                        .tag(LibrarySection.allSaved)
                        .accessibilityIdentifier("uiAcceptance.library.saved")
                        .dropDestination(for: LibraryItemTransfer.self) { items, _ in
                            items.reduce(false) { handled, item in
                                model.organizeTransferredItem(item, to: nil) || handled
                            }
                        }
                    if let notes = model.smartViewDefinition(for: .notes) {
                        smartViewRow(notes)
                    }
                    if let pinned = model.smartViewDefinition(for: .pinnedSaved) {
                        smartViewRow(pinned)
                    }
                    FolderTreeRows(
                        model: model,
                        parentFolderID: nil,
                        createSubfolder: { folder in
                            subfolderName = ""
                            subfolderParent = folder
                        },
                        rename: { folder in
                            renamedFolderName = folder.name
                            folderBeingRenamed = folder
                        }
                    )
                    Label(
                        "iCloud Sync",
                        systemImage: model.isSavedLibrarySyncEnabled ? "icloud" : "icloud.slash"
                    )
                    .tag(LibrarySection.sync)
                    Label("Projects", systemImage: "hammer")
                        .badge(model.developerProjects.count)
                        .tag(LibrarySection.developerProjects)
                        .accessibilityIdentifier("uiAcceptance.library.projects")
                    Button("Export Saved Library…", systemImage: "square.and.arrow.up") {
                        model.exportSavedLibrary()
                    }
                    .buttonStyle(.plain)
                    .disabled(model.snapshot.savedClips.isEmpty)
                } header: {
                    HStack {
                        Text("Keep")
                        Spacer()
                        Menu {
                            Button("New Folder…", systemImage: "folder.badge.plus") {
                                isCreatingFolder = true
                            }
                            Button("New Sales Workspace…", systemImage: "briefcase") {
                                isCreatingSalesWorkspace = true
                            }
                            .accessibilityIdentifier("uiAcceptance.library.newSalesWorkspace")
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.plain)
                        .menuStyle(.borderlessButton)
                        .accessibilityLabel("Create folder or sales workspace")
                        .accessibilityIdentifier("uiAcceptance.library.createMenu")
                        .accessibilityAction(named: "New Sales Workspace") {
                            isCreatingSalesWorkspace = true
                        }
                    }
                }

                Section("Use") {
                    Label("Actions", systemImage: "bolt.square")
                        .badge(model.unresolvedAutomationRunCount)
                        .tag(LibrarySection.workflows)
                        .accessibilityIdentifier("uiAcceptance.library.actions")
                    Label("Auto Organize", systemImage: "wand.and.stars")
                        .badge(model.automaticOrganizationSnapshot.rules.count)
                        .tag(LibrarySection.automaticOrganization)
                        .accessibilityIdentifier("uiAcceptance.library.autoOrganize")
                }

                Section("Protect") {
                    Label("Clipboard Health", systemImage: "checkmark.shield")
                        .badge(model.clipboardHealth.quarantinedClipCount)
                        .tag(LibrarySection.clipboardHealth)
                    if let sensitive = model.smartViewDefinition(for: .sensitiveReview),
                       sensitive.count > 0
                    {
                        smartViewRow(sensitive)
                    }
                    Label("Vault", systemImage: model.isVaultUnlocked ? "lock.open" : "lock")
                        .badge(model.vaultEncryptedItemCount)
                        .tag(LibrarySection.vault)
                        .accessibilityHint("Vault items are excluded from ordinary history and search")
                    if model.isPrivateSessionActive {
                        Label("Private Session", systemImage: "eye.slash.fill")
                            .tag(LibrarySection.privateSession)
                        Button("End Private Session", systemImage: "stop.circle", role: .destructive) {
                            model.endPrivateSession()
                        }
                        .buttonStyle(.plain)
                        .sidebarActionRow(tint: .red)
                    } else if model.isStartingPrivateSession {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Starting Private Session…")
                                .font(.callout.weight(.semibold))
                            Spacer()
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .accessibilityLabel("Starting Private Session")
                    } else {
                        Button("Start Private Session", systemImage: "eye.slash") {
                            model.startPrivateSession()
                        }
                        .buttonStyle(.plain)
                        .sidebarActionRow(tint: .indigo)
                        .accessibilityHint("Keep new clips in memory until you end the session")
                    }
                }
            }
            .listStyle(.sidebar)
            // Outside a NavigationSplitView a sidebar list keeps the ordinary opaque list
            // background, so it reads flat against the content pane. Hiding it lets the sidebar
            // material through and restores the separation macOS sidebars normally have.
            .scrollContentBackground(.hidden)
            .background(.regularMaterial)

            Divider()

            VStack(spacing: 10) {
                CaptureStatusButton(model: model)
                Button {
                    openSettings()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "gearshape")
                        Text("Settings")
                            .font(.callout.weight(.semibold))
                        Spacer()
                        Text("⌘,")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open Clipboard Router Settings")
                .accessibilityLabel("Open Settings")
                .accessibilityIdentifier("uiAcceptance.library.openSettings")
            }
            .padding(10)
            .background(.bar)
        }
        .alert(
            "Rename Folder",
            isPresented: Binding(
                get: { folderBeingRenamed != nil },
                set: { if !$0 { folderBeingRenamed = nil } }
            )
        ) {
            TextField("Folder name", text: $renamedFolderName)
            Button("Cancel", role: .cancel) { folderBeingRenamed = nil }
            Button("Rename") {
                guard let folder = folderBeingRenamed else { return }
                model.renameFolder(id: folder.id, name: renamedFolderName)
                folderBeingRenamed = nil
            }
            .disabled(renamedFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert(
            "New Subfolder",
            isPresented: Binding(
                get: { subfolderParent != nil },
                set: { if !$0 { subfolderParent = nil } }
            )
        ) {
            TextField("Subfolder name", text: $subfolderName)
            Button("Cancel", role: .cancel) { subfolderParent = nil }
            Button("Create") {
                guard let parent = subfolderParent else { return }
                model.createFolder(named: subfolderName, parentFolderID: parent.id)
                subfolderParent = nil
            }
            .disabled(subfolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Create inside \(subfolderParent?.name ?? "this folder").")
        }
        .sheet(isPresented: $isSavingSmartView) {
            SaveSmartViewSheet(model: model)
        }
        .sheet(item: $smartViewBeingEdited) { view in
            SaveSmartViewSheet(model: model, editing: view)
        }
    }

    private var browseSmartViews: [SmartViewDefinition] {
        model.staticSmartViews.filter { smartView in
            switch smartView.id {
            case .notes, .pinnedSaved, .sensitiveReview:
                return false
            default:
                return true
            }
        }
    }

    @ViewBuilder
    private func smartViewRow(
        _ smartView: SmartViewDefinition,
        title: String? = nil
    ) -> some View {
        Label(title ?? smartView.title, systemImage: smartView.systemImage)
            .badge(smartView.count)
            .tag(LibrarySection.smartView(smartView.id))
            .accessibilityIdentifier("uiAcceptance.smartViews.row.\(title ?? smartView.title)")
            .accessibilityHint("Read-only filter: \(smartView.query)")
    }

}

private struct FolderTreeRows: View {
    @ObservedObject var model: AppModel
    let parentFolderID: UUID?
    let createSubfolder: (ClipFolder) -> Void
    let rename: (ClipFolder) -> Void
    @State private var folderPendingDeletion: ClipFolder?

    var body: some View {
        ForEach(children) { folder in
            DisclosureGroup {
                FolderTreeRows(
                    model: model,
                    parentFolderID: folder.id,
                    createSubfolder: createSubfolder,
                    rename: rename
                )
            } label: {
                Label(folder.name, systemImage: "folder")
                    .badge(model.snapshot.savedClips.filter { $0.folderID == folder.id }.count)
                    .tag(LibrarySection.folder(folder.id))
                    .accessibilityIdentifier("uiAcceptance.folder.\(folder.name)")
                    .accessibilityAction(named: "Create Research Handoff") {
                        model.prepareFolderHandoff(folderID: folder.id)
                    }
                    .draggable(FolderTransfer(id: folder.id))
                    .dropDestination(for: LibraryItemTransfer.self) { items, _ in
                        items.reduce(false) { handled, item in
                            model.organizeTransferredItem(item, to: folder.id) || handled
                        }
                    }
                    .dropDestination(for: FolderTransfer.self) { items, _ in
                        guard let item = items.first,
                              model.canMoveFolder(id: item.id, to: folder.id)
                        else { return false }
                        model.moveFolder(id: item.id, to: folder.id)
                        return true
                    }
                    .contextMenu { folderContextMenu(folder) }
            }
        }
        .confirmationDialog(
            "Delete this folder?",
            isPresented: Binding(
                get: { folderPendingDeletion != nil },
                set: { if !$0 { folderPendingDeletion = nil } }
            ),
            presenting: folderPendingDeletion
        ) { folder in
            Button("Delete \(folder.name)", role: .destructive) {
                model.deleteFolder(id: folder.id)
                folderPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { folderPendingDeletion = nil }
        } message: { folder in
            let itemCount = model.snapshot.savedClips.filter { $0.folderID == folder.id }.count
            let childCount = model.snapshot.folders.filter { $0.parentFolderID == folder.id }.count
            Text("\(itemCount) saved item\(itemCount == 1 ? "" : "s") will become unfiled. \(childCount) subfolder\(childCount == 1 ? "" : "s") will move up one level.")
        }
    }

    private var children: [ClipFolder] {
        model.snapshot.folders
            .filter { $0.parentFolderID == parentFolderID }
            .sorted { lhs, rhs in
                lhs.sortOrder == rhs.sortOrder
                    ? lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                    : lhs.sortOrder < rhs.sortOrder
            }
    }

    @ViewBuilder
    private func folderContextMenu(_ folder: ClipFolder) -> some View {
        Button("New Subfolder…") {
            createSubfolder(folder)
        }
        .disabled(!model.canManageSharedFolder(folder.id))
        Button("Rename Folder") { rename(folder) }
            .disabled(!model.canManageSharedFolder(folder.id))
        Button("Move to Top Level") { model.moveFolder(id: folder.id, to: nil) }
            .disabled(folder.parentFolderID == nil || !model.canMoveFolder(id: folder.id, to: nil))
        Divider()
        Button("Create Research Handoff…") {
            model.prepareFolderHandoff(folderID: folder.id)
        }
        Divider()
        if model.sharedFolderSnapshot(for: folder.id) == nil {
            Button("Share Folder…") { model.shareFolder(id: folder.id) }
                .disabled(
                    !model.canManageFolderSharing(folder.id)
                        || !model.canStartFolderSharing
                )
                .help(model.sharedFolderMessage ?? "Share this folder with iCloud")
        } else {
            Button("Manage Sharing…") {
                model.presentSharedFolderInvitationSurface(folderID: folder.id)
            }
            .disabled(!model.canManageFolderSharing(folder.id))
            Button("Refresh Shared Folder") { model.refreshSharedFolder(id: folder.id) }
                .disabled(!model.canManageFolderSharing(folder.id))
        }
        Button("Delete Folder…", role: .destructive) { folderPendingDeletion = folder }
            .disabled(!model.canManageSharedFolder(folder.id))
    }
}

private struct CaptureStatusButton: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Button(action: model.toggleCapture) {
            HStack(spacing: 8) {
                Circle()
                    .fill(model.isCaptureActive ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(model.captureStatusTitle)
                    .font(.callout.weight(.semibold))
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(model.captureStatusDetail)
        .accessibilityLabel(model.isCaptureActive ? "Pause clipboard capture" : "Resume clipboard capture")
    }
}

private struct ClipListView: View {
    @ObservedObject var model: AppModel
    @State private var newFolderClip: PresentedClip?
    @State private var vaultMoveClip: PresentedClip?
    @State private var confirmedVaultMoveSummary: VaultMoveSummary?
    @State private var sensitiveExportClip: PresentedClip?
    @State private var noteEditorRequest: NoteEditorRequest?
    @State private var clipEditorRequest: ClipEditorRequest?
    @State private var newProjectClip: PresentedClip?
    @State private var calendarDraft: CalendarEventDraftRequest?
    @State private var isBulkMovePresented = false
    @State private var isBulkTagPresented = false

    private var isNotesSection: Bool {
        model.selectedSection == .smartView(.notes)
    }

    private var isSavedCollectionSection: Bool {
        switch model.selectedSection {
        case .allSaved, .smartView(.notes), .smartView(.pinnedSaved):
            true
        default:
            false
        }
    }

    private var savedModeSelection: Binding<LibrarySection> {
        Binding(
            get: {
                switch model.selectedSection {
                case .smartView(.notes): .smartView(.notes)
                case .smartView(.pinnedSaved): .smartView(.pinnedSaved)
                default: .allSaved
                }
            },
            set: { model.selectLibrarySection($0) }
        )
    }

    var sectionTitle: String {
        switch model.selectedSection {
        case .history: "History"
        case .allSaved: "Saved"
        case let .folder(id): model.snapshot.folders.first(where: { $0.id == id })?.name ?? "Folder"
        case .searchResults: "Search Results"
        case let .smartView(id): model.smartViewDefinition(for: id)?.title ?? "Smart View"
        case .vault: "Vault"
        case .privateSession: "Private Session"
        case .clipboardHealth: "Clipboard Health"
        case .workflows: "Actions"
        case .sync: "iCloud Sync"
        case .developerProjects: "Projects"
        case .automaticOrganization: "Auto Organize"
        }
    }

    var body: some View {
        let clips = model.clipsForSelectedSection

        VStack(spacing: 0) {
            VStack(spacing: isSavedCollectionSection ? 8 : 0) {
                HStack {
                    Text(sectionTitle)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                    if isNotesSection {
                        Button("New Note", systemImage: "square.and.pencil") {
                            noteEditorRequest = NoteEditorRequest(mode: .create)
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Create a note (⌘⇧N)")
                        .accessibilityLabel("Create a note")
                    }
                    if model.isBusy { ProgressView().controlSize(.small) }
                }

                if !model.selectedClipIDs.isEmpty {
                    bulkActionBar
                }

                if isSavedCollectionSection {
                    Picker("Saved view", selection: savedModeSelection) {
                        Text("All").tag(LibrarySection.allSaved)
                        Text("Notes").tag(LibrarySection.smartView(.notes))
                        Text("Pinned").tag(LibrarySection.smartView(.pinnedSaved))
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityLabel("Saved item type")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            if model.isOrdinarySearchActive {
                SearchExplanationBar(model: model)
                Divider()
            }

            if clips.isEmpty {
                EmptyStateCard(
                    title: emptyTitle,
                    message: emptyDescription,
                    systemImage: model.searchText.isEmpty
                        ? (isNotesSection ? "note.text" : "clipboard")
                        : "magnifyingglass"
                ) {
                    if isNotesSection && model.searchText.isEmpty {
                        Button("New Note", systemImage: "square.and.pencil") {
                            noteEditorRequest = NoteEditorRequest(mode: .create)
                        }
                        .buttonStyle(.borderedProminent)
                        Text("or press ⌘⇧N")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Table(clips, selection: Binding(
                    get: { model.selectedClipIDs },
                    set: { model.setSelectedClipIDs($0) }
                )) {
                    TableColumn("") { clip in
                        clipListRow(clip)
                    }
                }
                .tableColumnHeaders(.hidden)
                // A section change can replace a tiny Saved data set with thousands of History
                // rows. Recreate the native table for that navigation boundary instead of asking
                // AppKit to accessibility-diff the two unrelated collections in place.
                .id(ClipTablePresentation.dataIdentity(
                    model.selectedSection,
                    clips: clips
                ))
                .accessibilityLabel("Clip list. Use Command-click or Shift-click to select multiple items.")
            }
        }
        .sheet(item: $newFolderClip) { clip in
            FolderPickerSheet(
                folders: model.snapshot.folders,
                initiallyAddingFolder: true,
                onSelect: { folderID in
                    model.saveHistoryClip(clip, folderID: folderID)
                    newFolderClip = nil
                },
                onCreateFolder: { name in
                    try await model.saveHistoryClipInNewFolder(clip, named: name)
                }
            )
            .onDisappear {
                if newFolderClip?.id == clip.id { newFolderClip = nil }
            }
        }
        .sheet(item: $noteEditorRequest) { request in
            NoteEditorSheet(request: request, folders: model.folderDestinations) { title, body, folderID in
                switch request.mode {
                case .create, .makeFromClip:
                    return await model.createNoteFromEditor(
                        title: title, body: body, folderID: folderID
                    )
                case let .edit(clip):
                    return await model.updateNoteFromEditor(
                        clip, title: title, body: body, folderID: folderID
                    )
                }
            }
        }
        .sheet(item: $clipEditorRequest) { request in
            ClipEditorSheet(request: request, folders: model.folderDestinations) { title, body, folderID in
                await model.saveEditedClipFromEditor(
                    request.clip, title: title, body: body, folderID: folderID
                )
            }
        }
        .sheet(isPresented: $isBulkMovePresented) {
            BulkMoveSheet(folders: model.folderDestinations) { folderID in
                model.performBulkLibraryMutation(.moveSaved(folderID: folderID))
            }
        }
        .sheet(isPresented: $isBulkTagPresented) {
            BulkTagSheet { tags in model.performBulkLibraryMutation(.addTags(tags)) }
        }
        .sheet(item: Binding(
            get: { model.pendingBulkLibraryResult },
            set: { if $0 == nil { model.dismissBulkLibraryResult() } }
        )) { result in
            BulkLibraryResultSheet(result: result, dismiss: model.dismissBulkLibraryResult)
        }
        .sheet(item: $newProjectClip) { clip in
            DeveloperProjectEditorView(model: model, clipToAdd: clip) {
                newProjectClip = nil
            }
        }
        .sheet(item: $calendarDraft) { request in
            CalendarEventDraftSheet(
                draft: request.draft,
                save: { reviewed in
                    let saved = await model.createCalendarEvent(
                        reviewed,
                        sourceClip: request.sourceClip
                    )
                    if saved { calendarDraft = nil }
                    return saved
                },
                cancel: { calendarDraft = nil }
            )
        }
        .confirmationDialog(
            "Move this clip to Vault?",
            isPresented: Binding(
                get: { vaultMoveClip != nil },
                set: {
                    if !$0 {
                        vaultMoveClip = nil
                        confirmedVaultMoveSummary = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            if let clip = vaultMoveClip, let summary = confirmedVaultMoveSummary {
                Button("Move to Vault") {
                    model.moveClipToVault(clip, confirmedSummary: summary)
                    vaultMoveClip = nil
                    confirmedVaultMoveSummary = nil
                }
                .disabled(model.isBusy || !model.canMoveClipToVault(clip))
                Button("Cancel", role: .cancel) {
                    vaultMoveClip = nil
                    confirmedVaultMoveSummary = nil
                }
            }
        } message: {
            if let summary = confirmedVaultMoveSummary {
                Text(summary.confirmationMessage)
            }
        }
        .confirmationDialog(
            "Export flagged sensitive clip?",
            isPresented: Binding(
                get: { sensitiveExportClip != nil },
                set: { if !$0 { sensitiveExportClip = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let clip = sensitiveExportClip {
                Button("Export Anyway", role: .destructive) {
                    model.exportOrdinaryClip(clip, sensitiveContentConfirmed: true)
                    sensitiveExportClip = nil
                }
                Button("Cancel", role: .cancel) { sensitiveExportClip = nil }
            }
        } message: {
            if let clip = sensitiveExportClip,
               case let .requiresSensitiveConfirmation(category) = model.clipExportDecision(clip)
            {
                Text("Clipboard Router detected \(category). The portable archive will contain the clip's original content.")
            }
        }
    }

    @ViewBuilder
    private var bulkActionBar: some View {
        HStack(spacing: 8) {
            Text("\(model.selectedClipIDs.count) selected")
                .font(.caption.weight(.semibold))
                .accessibilityLabel("\(model.selectedClipIDs.count) items selected")
                .accessibilityIdentifier("uiAcceptance.bulk.selectedCount")
                .accessibilityValue("\(model.selectedClipIDs.count)")
            Spacer()
            Menu("Selected Items", systemImage: "ellipsis.circle") {
                if model.selectedClipsForBulkAction.contains(where: { $0.origin == .history }) {
                    Menu("Save History to…", systemImage: "bookmark") {
                        Button("Saved (no folder)") {
                            model.performBulkLibraryMutation(.saveHistory(folderID: nil))
                        }
                        .accessibilityIdentifier(SmartViewBulkAccessibility.bulkDestination(nil))
                        .accessibilityValue("eligible=true|path=Saved")
                        ForEach(model.folderDestinations) { folder in
                            Button(folder.path) {
                                model.performBulkLibraryMutation(.saveHistory(folderID: folder.id))
                            }
                            .disabled(!folder.canAcceptItems)
                            .accessibilityIdentifier(SmartViewBulkAccessibility.bulkDestination(folder.id))
                            .accessibilityValue(
                                "eligible=\(folder.canAcceptItems)|path=\(SmartViewBulkAccessibility.component(folder.path))"
                            )
                        }
                    }
                    .accessibilityIdentifier(SmartViewBulkAccessibility.bulkSave)
                }
                Button("Move Saved Items…", systemImage: "folder") {
                    isBulkMovePresented = true
                }
                .accessibilityIdentifier(SmartViewBulkAccessibility.bulkMove)
                Button("Add Tags…", systemImage: "tag") { isBulkTagPresented = true }
                    .accessibilityIdentifier("uiAcceptance.bulk.addTags")
                Menu("Pin", systemImage: "pin") {
                    Button("Pin Eligible") { model.performBulkLibraryMutation(.setPinned(true)) }
                        .accessibilityIdentifier(SmartViewBulkAccessibility.bulkPin)
                    Button("Unpin Eligible") { model.performBulkLibraryMutation(.setPinned(false)) }
                        .accessibilityIdentifier(SmartViewBulkAccessibility.bulkUnpin)
                }
                Divider()
                Button("Export Eligible…", systemImage: "square.and.arrow.up") {
                    model.exportBulkLibrarySelection()
                }
                .accessibilityIdentifier(SmartViewBulkAccessibility.bulkExport)
                Button("Clear Selection", systemImage: "xmark.circle") {
                    model.setSelectedClipIDs([])
                }
                .accessibilityIdentifier(SmartViewBulkAccessibility.bulkClear)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Actions for selected items")
            .accessibilityIdentifier("uiAcceptance.bulk.menu")
        }
        .controlSize(.small)
    }

    @ViewBuilder
    private func clipListRow(_ clip: PresentedClip) -> some View {
        let row = ClipRow(
            clip: clip,
            isSensitive: model.isSensitiveForPresentation(clip),
            thumbnailLoader: model.thumbnailLoader,
            originContext: model.clipOriginContext(clip),
            sourceContext: model.clipSourceContext(clip)
        ) {
            model.copy(clip)
        }
        .tag(clip.id)
        .contentShape(Rectangle())
        .accessibilityIdentifier("uiAcceptance.library.clip.\(clip.id.uuidString.lowercased())")
        .accessibilityValue("tags=\(clip.tags.sorted().joined(separator: ","))")
        .accessibilityAddTraits(
            model.selectedClipIDs.contains(clip.id) ? .isSelected : []
        )
        .contextMenu {
            DeferredContextMenuContent {
                clipContextMenu(for: clip)
            }
        }

        switch clip.origin {
        case .history:
            row.draggable(LibraryItemTransfer(id: clip.id, origin: .history))
        case .saved:
            row.draggable(LibraryItemTransfer(id: clip.id, origin: .saved))
        case .privateSession:
            row
        }
    }

    @ViewBuilder
    private func clipContextMenu(for clip: PresentedClip) -> some View {
        let policy = model.clipContextMenuPolicy(for: clip)
        let inventory = ClipActionCatalog.inventory(for: clip, model: model, surface: .libraryContext)
        let exportDecision = model.clipExportDecision(clip)
        let suggestions = model.suggestedActions(for: clip)
        let assistantAction = suggestions.first { $0.kind == .askAI }
        let quickSuggestions = suggestions.filter { $0.kind != .askAI }
        let automations = model.applicableAutomations(for: clip)
        let flows = model.applicableFlows(for: clip)

        Button("Copy", systemImage: "doc.on.doc") { model.copy(clip) }
            .disabled(model.isSensitiveForPresentation(clip))
            .accessibilityIdentifier(ClipActionAcceptanceAccessibility.surface(
                .libraryContext,
                clipID: clip.id
            ))
            .accessibilityValue(ClipActionAcceptanceAccessibility.inventoryValue(inventory))

        if model.isEncryptedShare(clip) {
            Button("Decrypt Encrypted Share…", systemImage: "lock.open") {
                Task { _ = await model.decryptEncryptedShare(clip) }
            }
            .help("Authenticate and show the decrypted payload in an ephemeral preview")
            .accessibilityIdentifier("uiAcceptance.decryptShare.\(clip.id.uuidString.lowercased())")
        }

        if let action = inventory[.useAI], let assistantAction {
            Button(action.title, systemImage: action.symbolName) {
                calendarDraft = model.performSuggestedAction(assistantAction, for: clip)
            }
            .help("Rewrite, extract details, research, or ask. Nothing is sent until you press Send.")
            .clipActionAcceptance(action, clipID: clip.id, inventory: inventory)
        }

        switch policy.organization {
        case .saveToFolder:
            Menu("Save to Folder", systemImage: "folder.badge.plus") {
                Button("Saved") { model.saveHistoryClip(clip, folderID: nil) }
                Divider()
                ForEach(model.folderDestinations) { folder in
                    Button(folder.path) { model.saveHistoryClip(clip, folderID: folder.id) }
                        .disabled(!folder.canAcceptItems)
                }
                Divider()
                Button("New Folder…", systemImage: "folder.badge.plus") {
                    newFolderClip = clip
                }
            }
            .clipActionAcceptance(inventory[.saveToFolder], clipID: clip.id, inventory: inventory)
        case .moveToFolder:
            if case let .saved(currentFolderID) = clip.origin {
                Menu("Move to Folder", systemImage: "folder") {
                    Button("Saved") { model.moveSavedClip(id: clip.id, to: nil) }
                        .disabled(currentFolderID == nil)
                    Divider()
                    ForEach(model.folderDestinations) { folder in
                        Button(folder.path) { model.moveSavedClip(id: clip.id, to: folder.id) }
                            .disabled(
                                folder.id == currentFolderID
                                    || !folder.canAcceptItems
                            )
                    }
                }
                .disabled(!(inventory[.moveToFolder]?.isEnabled ?? false))
                .clipActionAcceptance(inventory[.moveToFolder], clipID: clip.id, inventory: inventory)
            }
        case .none:
            EmptyView()
        }

        if let action = inventory[.pin] {
            Button(
                action.title,
                systemImage: action.symbolName
            ) {
                model.togglePinOrSave(clip)
            }
            .disabled(model.isBusy || !action.isEnabled)
            .help(action.disabledReason ?? "Keep this item at the top of your saved clips")
            .clipActionAcceptance(action, clipID: clip.id, inventory: inventory)
        }

        if inventory.contains(.editNote) {
            Button("Edit Note…", systemImage: "square.and.pencil") {
                noteEditorRequest = NoteEditorRequest(mode: .edit(clip))
            }
            .clipActionAcceptance(inventory[.editNote], clipID: clip.id, inventory: inventory)
        } else {
            if inventory.contains(.editClip) {
                Button(
                    clip.origin == .history ? "Edit a Saved Copy…" : "Edit Clip…",
                    systemImage: "pencil"
                ) {
                    clipEditorRequest = ClipEditorRequest(mode: clip.origin == .history
                        ? .editHistoryCopy(clip)
                        : .editSaved(clip))
                }
                .clipActionAcceptance(inventory[.editClip], clipID: clip.id, inventory: inventory)
            }
            if inventory.contains(.makeNote) {
                Button("Make Note…", systemImage: "note.text.badge.plus") {
                    noteEditorRequest = NoteEditorRequest(mode: .makeFromClip(clip))
                }
                .clipActionAcceptance(inventory[.makeNote], clipID: clip.id, inventory: inventory)
            }
        }

        if inventory.contains(.setShortcut) {
            Button("Set Shortcut…", systemImage: "character.textbox") {
                model.presentMenuBarContinuation(.shortcutEditor(clip))
            }
            .help("Create an abbreviation for this saved item in Quick Paste")
            .clipActionAcceptance(inventory[.setShortcut], clipID: clip.id, inventory: inventory)
        }

        if let action = inventory[.moveToVault] {
            Button(action.title, systemImage: action.symbolName) {
                confirmedVaultMoveSummary = model.vaultMoveSummary(for: clip)
                if confirmedVaultMoveSummary != nil { vaultMoveClip = clip }
            }
            .disabled(model.isBusy || !action.isEnabled)
            .help(action.disabledReason ?? "Encrypt and remove ordinary copies")
            .clipActionAcceptance(action, clipID: clip.id, inventory: inventory)
        }

        if clip.origin != .privateSession {
            Button("Copy Encrypted Share", systemImage: "lock.shield") {
                model.presentEncryptedShare(clip)
            }
            .help("Copy an authenticated Clipboard Router envelope. The recipient key must already be trusted.")
            .accessibilityIdentifier("uiAcceptance.encryptedShare.\(clip.id.uuidString.lowercased())")
        }

        if inventory.contains(.share) || inventory.contains(.export) {
            Divider()
            if inventory.contains(.share) {
                Button("Share Clip…", systemImage: "square.and.arrow.up") {
                    model.shareOrdinaryClip(clip)
                }
                .clipActionAcceptance(inventory[.share], clipID: clip.id, inventory: inventory)
            }
            if let folderID = policy.folderID {
                if model.sharedFolderSnapshot(for: folderID) == nil {
                    Button("Share Folder…", systemImage: "person.2") {
                        model.shareFolder(id: folderID)
                    }
                    .disabled(
                        !policy.canManageFolderSharing
                            || !model.canStartFolderSharing
                    )
                    .help(model.sharedFolderMessage ?? "Share this folder with iCloud")
                } else {
                    Button("Manage Folder Sharing…", systemImage: "person.2") {
                        model.presentSharedFolderInvitationSurface(folderID: folderID)
                    }
                    .disabled(!policy.canManageFolderSharing)
                }
            }
            if let action = inventory[.export] {
                Button("Export Clip…", systemImage: "square.and.arrow.down") {
                    switch exportDecision {
                    case .available:
                        model.exportOrdinaryClip(clip)
                    case .requiresSensitiveConfirmation:
                        sensitiveExportClip = clip
                    case .unavailable:
                        break
                    }
                }
                .disabled(!action.isEnabled)
                .help(
                    action.disabledReason
                        ?? "Export this clip as a portable archive"
                )
                .clipActionAcceptance(action, clipID: clip.id, inventory: inventory)
            }
        }

        if inventory.contains(.quickActions) || inventory.contains(.actions) {
            Divider()
            ActionableClipMenuContent(
                suggestions: quickSuggestions,
                automations: automations,
                flows: flows,
                runSuggestion: { action in
                    calendarDraft = model.performSuggestedAction(action, for: clip)
                },
                runAutomation: { model.runAutomation($0, for: clip) },
                runFlow: { model.requestFlowRun($0, for: clip) },
                canCreateCustomAction: clip.origin.isSaved,
                createCustomAction: openAutomationSettings
            )
        }

        if inventory.contains(.copyAndOpen) {
            Button("Copy & Open…", systemImage: "arrow.up.forward.app") {
                model.presentApplicationBrowser(for: clip)
            }
            .help("Search eligible installed apps, then copy and open one explicitly")
            .clipActionAcceptance(inventory[.copyAndOpen], clipID: clip.id, inventory: inventory)
        }

        if inventory.contains(.sendToCRM) {
            Button("Send to CRM…", systemImage: "building.2") {
                model.presentCRMReview(for: clip)
            }
            .help("Review allowlisted fields before explicitly creating or updating a CRM record")
            .clipActionAcceptance(inventory[.sendToCRM], clipID: clip.id, inventory: inventory)
        }

        if inventory.contains(.clipTools) {
            Menu("Clip Tools", systemImage: "square.stack.3d.up") {
                Button("Copy as Base64", systemImage: "number") {
                    model.copyAsBase64(clip)
                }
                .disabled(!clip.content.representations.referencedAssets.isEmpty || !clip.content.representations.files.isEmpty)
                .help("Copy portable text or URL content as reversible Base64. Rich, image, and file clips stay local; Base64 is not encryption.")
                Divider()
                Button("Add to Combine Clips") { model.addToCombinedClips(clip) }
                Button("Add to Debug Bundle") { model.addToDebugBundle(clip) }
                Menu("Add to Project", systemImage: "hammer") {
                    ForEach(model.developerProjects) { project in
                        Button(project.name) {
                            model.addToDeveloperProject(clip, projectID: project.id)
                        }
                    }
                    if !model.developerProjects.isEmpty { Divider() }
                    Button("New Project…", systemImage: "plus") {
                        newProjectClip = clip
                    }
                }
                .disabled(!model.canAddToDeveloperProject(clip))
                Button("Add to Paste Stack") { model.addToPasteStack(clip) }
                Divider()
                Menu("Transform") {
                    Button("Trim whitespace") {
                        model.previewTransform(.trim, title: "Trim whitespace", for: clip)
                    }
                    Button("Plain text") {
                        model.previewTransform(.plainText, title: "Plain text", for: clip)
                    }
                    Button("UPPERCASE") {
                        model.previewTransform(.uppercase, title: "UPPERCASE", for: clip)
                    }
                    Button("Code block") {
                        model.previewTransform(
                            .codeBlock(language: nil),
                            title: "Code block",
                            for: clip
                        )
                    }
                    Divider()
                    Button("Pretty JSON") {
                        model.previewTransform(.prettyJSON, title: "Pretty JSON", for: clip)
                    }
                    Button("Strip ANSI") {
                        model.previewTransform(.stripANSI, title: "Strip ANSI", for: clip)
                    }
                    Button("URL Decode") {
                        model.previewTransform(.urlDecode, title: "URL Decode", for: clip)
                    }
                }
            }
            .clipActionAcceptance(inventory[.clipTools], clipID: clip.id, inventory: inventory)
        }

        if let action = inventory[.delete] {
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) { model.delete(clip) }
                .disabled(!action.isEnabled)
                .help(action.disabledReason ?? "Delete this item")
                .clipActionAcceptance(action, clipID: clip.id, inventory: inventory)
        }
    }

    private func openAutomationSettings() {
        model.openActionsWorkspace(.automations)
    }

    private var emptyDescription: String {
        if !model.searchText.isEmpty { return "Try a different word or phrase." }
        switch model.selectedSection {
        case .history: return "Copy text in any app and it will appear here."
        case .allSaved, .folder: return "Save useful history items to keep them here."
        case .smartView where isNotesSection: return "Write something directly, without copying it first."
        case .searchResults, .smartView: return "Remove a filter or try a different metadata field."
        case .vault: return "Vault items never appear in ordinary search."
        case .privateSession:
            return model.isPrivateSessionActive
                ? "New clips copied now will stay only in memory."
                : "Start a Private Session to keep new clips only in memory."
        case .clipboardHealth, .workflows, .sync, .developerProjects, .automaticOrganization:
            return "Choose an action in this section."
        }
    }

    private var emptyTitle: String {
        if !model.searchText.isEmpty { return "No matching clips" }
        return isNotesSection ? "No notes yet" : "No clips yet"
    }
}

/// Keeps SwiftUI's eager `contextMenu` builder pass cheap for large lists.
///
/// `contextMenu` may ask for its root content while installing each row. Returning this small
/// wrapper records only the real menu builder at that point; resolving action policy, suggested
/// actions, automations, and secret-sensitive inventory is deferred until SwiftUI renders the
/// menu's content. Do not inline `clipContextMenu(for:)` back into the row modifier: doing so makes
/// opening a 1,000-item Library perform the complete menu inventory for every row.
struct DeferredContextMenuContent<Content: View>: View {
    private let build: () -> Content

    init(@ViewBuilder build: @escaping () -> Content) {
        self.build = build
    }

    var body: some View {
        build()
    }
}

private struct ClipRow: View {
    let clip: PresentedClip
    let isSensitive: Bool
    let thumbnailLoader: ClipThumbnailLoader
    let originContext: String
    let sourceContext: String?
    let onCopy: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            if !isSensitive, clip.content.representations.thumbnail != nil {
                ClipThumbnailView(
                    reference: clip.content.representations.thumbnail,
                    loader: thumbnailLoader,
                    accessibilityLabel: "Thumbnail for \(safeTitle)"
                )
                .frame(width: 54, height: 42)
                .accessibilityHidden(true)
            } else {
                Image(systemName: !isSensitive
                    ? (clip.savedItemKind == .note ? "note.text" : clipSymbol(for: clip.content.type))
                    : "exclamationmark.shield.fill")
                    .foregroundStyle(!isSensitive ? Color.accentColor : Color.orange)
                    .frame(width: 22, height: 22)
                    .background(.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(safeTitle)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                HStack(spacing: 5) {
                    MinuteRelativeTimestamp(date: clip.date)
                    Text("•")
                    Text(originContext)
                    if let sourceContext {
                        Text("•")
                        Text(sourceContext)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(safeTitle), \(ClipAgeFormatter.string(since: clip.date)) old")
            Spacer(minLength: 0)
            Button(action: onCopy) {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy original clip representations")
            .accessibilityLabel("Copy \(safeTitle)")
            .disabled(isSensitive)
        }
        .padding(.vertical, 5)
    }

    private var safeTitle: String {
        !isSensitive ? clip.title : "Potential secret — review securely"
    }
}

private struct SearchExplanationBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                Image(systemName: "line.3.horizontal.decrease.circle.fill")
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                if !model.activeSearchExplanation.isEmpty {
                    Menu("Explain", systemImage: "info.circle") {
                        ForEach(model.activeSearchExplanation, id: \.self) { explanation in
                            Text(explanation)
                        }
                    }
                    .font(.caption)
                    .help(model.activeSearchExplanation.joined(separator: ", "))
                    .accessibilityLabel("Explain active filters: \(model.activeSearchExplanation.joined(separator: ", "))")
                }
                ForEach(model.activeSearchChips) { chip in
                    HStack(spacing: 4) {
                        Text(chip.label)
                        Button {
                            model.removeSearchChip(chip)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove filter \(chip.label)")
                    }
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
                }
                Button("Clear") { model.clearOrdinarySearch() }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
                    .padding(.leading, 3)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Active search and metadata filters")
    }
}

private struct SearchHelpView: View {
    let apply: (String) -> Void

    private let fields: [(String, String)] = [
        ("source:", "source:Safari"),
        ("domain:", "domain:example.com"),
        ("folder:", "folder:Research or folder:unfiled"),
        ("tag:", "tag:lead"),
        ("origin:", "origin:history or origin:saved"),
        ("type:", "type:url, image, file, or pdf"),
        ("date:", "date:2026-08-10"),
        ("size:", "size:>1mb"),
        ("captures:", "captures:>=2"),
        ("pastes:", "pastes:>0"),
        ("pinned:", "pinned:true"),
        ("uti:", "uti:public.html"),
        ("device:", "device:MacBook"),
        ("location:", "location:Toronto"),
        ("secret:", "secret:*"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Find clips by content or metadata")
                    .font(.headline)
                Text("Fields combine with AND. Smart Views are read-only filters and never reorganize clips.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                ForEach(fields, id: \.0) { field, example in
                    GridRow {
                        Text(field).font(.caption.monospaced().weight(.semibold))
                        Text(example).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Divider()
            Text("Try an example")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack {
                Button("Safari links") { apply("source:Safari type:url") }
                Button("Used saved clips") { apply("origin:saved pastes:>0") }
                Button("Large PDFs") { apply("type:pdf size:>1mb") }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(16)
        .frame(width: 470)
    }
}

private struct ClipDetailView: View {
    @ObservedObject var model: AppModel
    @State private var folderPickerClip: PresentedClip?
    @State private var clipBeingRenamed: PresentedClip?
    @State private var renamedClipName = ""
    @State private var confirmsVaultMove = false
    @State private var confirmedVaultMoveSummary: VaultMoveSummary?
    @State private var noteEditorRequest: NoteEditorRequest?
    @State private var clipEditorRequest: ClipEditorRequest?
    @State private var newProjectClip: PresentedClip?
    @State private var tagEditorClip: PresentedClip?
    @State private var calendarDraft: CalendarEventDraftRequest?
    @State private var sensitiveExportClip: PresentedClip?
    @State private var isShowingDetails = false

    var body: some View {
        Group {
            if let clip = model.selectedClip {
                let isSensitive = model.isSensitiveForPresentation(clip)
                VStack(alignment: .leading, spacing: 0) {
                    detailHeader(clip)
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            if isSensitive {
                                sensitiveContentNotice(clip)
                            } else if clip.content.representations.thumbnail != nil {
                                ClipThumbnailView(
                                    reference: clip.content.representations.thumbnail,
                                    loader: model.thumbnailLoader,
                                    accessibilityLabel: "Thumbnail for \(clip.title)"
                                )
                                .frame(maxWidth: 420, minHeight: 180, maxHeight: 320)
                            }
                            if isSensitive {
                                EmptyView()
                            } else if let link = StoredLinkPreviewDescriptor(content: clip.content) {
                                LiveLinkPreviewCard(descriptor: link, clip: clip, model: model)
                            } else {
                                Text(clip.content.text)
                                    .font(clip.savedItemKind == .note ? .body : .body.monospaced())
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .topLeading)
                            }
                            detectedSuggestionsSection(clip)
                            automaticOrganizationSection(clip)
                            if case .saved = clip.origin, !clip.tags.isEmpty {
                                compactTagSection(clip)
                            }
                            detailsSection(clip)
                        }
                        .padding(22)
                    }
                }
                .sheet(item: $folderPickerClip) { targetClip in
                    FolderPickerSheet(
                        folders: model.snapshot.folders,
                        onSelect: { folderID in
                            model.saveHistoryClip(targetClip, folderID: folderID)
                            folderPickerClip = nil
                        },
                        onCreateFolder: { name in
                            try await model.saveHistoryClipInNewFolder(targetClip, named: name)
                        }
                    )
                }
                .alert(
                    "Rename Clip",
                    isPresented: Binding(
                        get: { clipBeingRenamed != nil },
                        set: { if !$0 { clipBeingRenamed = nil } }
                    ),
                    presenting: clipBeingRenamed
                ) { targetClip in
                    TextField("Clip name", text: $renamedClipName)
                    Button("Cancel", role: .cancel) { clipBeingRenamed = nil }
                    Button("Rename") {
                        model.renameSavedClip(id: targetClip.id, name: renamedClipName)
                        clipBeingRenamed = nil
                    }
                    .disabled(renamedClipName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .confirmationDialog(
                    "Move this clip to Vault?",
                    isPresented: $confirmsVaultMove,
                    titleVisibility: .visible
                ) {
                    if let summary = confirmedVaultMoveSummary {
                        Button("Move to Vault") {
                            model.moveClipToVault(clip, confirmedSummary: summary)
                            confirmedVaultMoveSummary = nil
                        }
                        .disabled(model.isBusy || !model.canMoveClipToVault(clip))
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    if let summary = confirmedVaultMoveSummary {
                        Text(summary.confirmationMessage)
                    }
                }
                .confirmationDialog(
                    "Export sensitive clip?",
                    isPresented: Binding(
                        get: { sensitiveExportClip != nil },
                        set: { if !$0 { sensitiveExportClip = nil } }
                    ),
                    titleVisibility: .visible
                ) {
                    if let sensitiveExportClip {
                        Button("Export Anyway", role: .destructive) {
                            model.exportOrdinaryClip(
                                sensitiveExportClip,
                                sensitiveContentConfirmed: true
                            )
                            self.sensitiveExportClip = nil
                        }
                    }
                    Button("Cancel", role: .cancel) { sensitiveExportClip = nil }
                } message: {
                    if let sensitiveExportClip,
                       case let .requiresSensitiveConfirmation(category) = model.clipExportDecision(
                           sensitiveExportClip
                       )
                    {
                        Text("This clip is marked as \(category). Export only to a trusted location.")
                    }
                }
                .sheet(item: $noteEditorRequest) { request in
                    NoteEditorSheet(request: request, folders: model.folderDestinations) { title, body, folderID in
                        switch request.mode {
                        case .create, .makeFromClip:
                            return await model.createNoteFromEditor(
                                title: title, body: body, folderID: folderID
                            )
                        case let .edit(editorClip):
                            return await model.updateNoteFromEditor(
                                editorClip, title: title, body: body, folderID: folderID
                            )
                        }
                    }
                }
                .sheet(item: $clipEditorRequest) { request in
                    ClipEditorSheet(request: request, folders: model.folderDestinations) { title, body, folderID in
                        await model.saveEditedClipFromEditor(
                            request.clip, title: title, body: body, folderID: folderID
                        )
                    }
                }
                .sheet(item: $newProjectClip) { targetClip in
                    DeveloperProjectEditorView(model: model, clipToAdd: targetClip) {
                        newProjectClip = nil
                    }
                }
                .sheet(item: $tagEditorClip) { targetClip in
                    TagEditorSheet(initialTags: targetClip.tags) { tags in
                        await model.updateTagsFromEditor(targetClip, tags: tags)
                    }
                }
                .sheet(item: $calendarDraft) { request in
                    CalendarEventDraftSheet(
                        draft: request.draft,
                        save: { reviewed in
                            let saved = await model.createCalendarEvent(
                                reviewed,
                                sourceClip: request.sourceClip
                            )
                            if saved { calendarDraft = nil }
                            return saved
                        },
                        cancel: { calendarDraft = nil }
                    )
                }
            } else if model.clipsForSelectedSection.isEmpty {
                emptySectionGuidance
            } else {
                EmptyStateCard(
                    title: "Select a clip",
                    message: "Preview, copy, organize, or edit a clip.",
                    systemImage: "cursorarrow.click.2"
                )
            }
        }
    }

    /// Guidance for a section that currently has no clips. An empty list previously left this
    /// pane completely blank, which reads as a rendering failure rather than an expected state.
    @ViewBuilder
    private var emptySectionGuidance: some View {
        switch model.selectedSection {
        case .privateSession:
            EmptyStateCard(
                title: "Private Session is recording nothing yet",
                message: "Clips you copy from now on stay in memory for this session only. Nothing is written to history, search, or disk, and the session clears when you end it.",
                systemImage: "eye.slash.fill",
                tint: .indigo
            ) {
                Button("End Private Session", role: .destructive) {
                    model.endPrivateSession()
                }
                .help("Discard every clip captured during this session")
            }
            .accessibilityIdentifier("uiAcceptance.library.privateSessionEmpty")
        case .clipboardHealth:
            EmptyStateCard(
                title: "No clips are quarantined",
                message: "Clipboard Router holds a clip here when it looks like a password, key, or token, so it never reaches ordinary history.",
                systemImage: "checkmark.shield",
                tint: .green
            )
        case .searchResults:
            EmptyStateCard(
                title: "No matches",
                message: "Nothing in History or Saved Clips matches this search. Try fewer words, or use the filter menu for field searches like app: and url:.",
                systemImage: "magnifyingglass"
            )
        default:
            EmptyStateCard(
                title: "Nothing here yet",
                message: "Copy something and it will appear in this list.",
                systemImage: "clipboard"
            )
        }
    }

    private func openAutomationSettings() {
        model.openActionsWorkspace(.automations)
    }

    private func detailHeader(_ clip: PresentedClip) -> some View {
        ViewThatFits(in: .horizontal) {
            detailHeaderLayout(clip, compact: false)
            detailHeaderLayout(clip, compact: true)
        }
        .padding(16)
    }

    private func detailHeaderLayout(_ clip: PresentedClip, compact: Bool) -> some View {
        HStack(spacing: compact ? 7 : 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(displayTitle(for: clip))
                    .font(.headline)
                    .lineLimit(1)
                    .accessibilityIdentifier(
                        "uiAcceptance.library.selected.\(clip.id.uuidString.lowercased())"
                    )
                if !compact {
                    Text(contentTypeName(clip.content.type))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 80, maxWidth: .infinity, alignment: .leading)

            if compact {
                detailCopyButton(clip)
                    .labelStyle(.iconOnly)
                detailContextualAction(clip)
                    .labelStyle(.iconOnly)
                detailMoreMenu(clip)
                    .labelStyle(.iconOnly)
            } else {
                detailCopyButton(clip)
                detailContextualAction(clip)
                detailMoreMenu(clip)
            }
        }
    }

    private func detailCopyButton(_ clip: PresentedClip) -> some View {
        Button {
            model.copy(clip)
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
        .keyboardShortcut(.return, modifiers: .command)
        .help("Copy this item")
        .accessibilityHint("Copies the selected clip without opening another app")
        .disabled(model.isSensitiveForPresentation(clip))
    }

    @ViewBuilder
    private func detailContextualAction(_ clip: PresentedClip) -> some View {
        switch clip.origin {
        case .history:
            Button("Save", systemImage: "bookmark") {
                folderPickerClip = clip
            }
            .accessibilityLabel("Save clip to a folder")
        case .saved:
            if clip.savedItemKind == .note, model.canEditNote(clip) {
                Button("Edit Note", systemImage: "square.and.pencil") {
                    noteEditorRequest = NoteEditorRequest(mode: .edit(clip))
                }
            } else if model.canEditClip(clip) {
                Button("Edit Clip", systemImage: "pencil") {
                    clipEditorRequest = ClipEditorRequest(mode: .editSaved(clip))
                }
            } else {
                Button(clip.isPinned ? "Unpin" : "Pin", systemImage: clip.isPinned ? "pin.slash" : "pin") {
                    model.setPinned(clip, pinned: !clip.isPinned)
                }
                .disabled(!model.clipContextMenuPolicy(for: clip).canMutateSavedClip)
            }
        case .privateSession:
            Label("Private Session", systemImage: "eye.slash")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func detailMoreMenu(_ clip: PresentedClip) -> some View {
        let inventory = ClipActionCatalog.inventory(for: clip, model: model, surface: .libraryInspector)
        let exportDecision = model.clipExportDecision(clip)
        let suggestions = model.suggestedActions(for: clip)
        let supportsAssistant = suggestions.contains { $0.kind == .askAI }
        let quickSuggestions = suggestions.filter { $0.kind != .askAI }
        let automations = model.applicableAutomations(for: clip)
        let flows = model.applicableFlows(for: clip)

        return Menu("More", systemImage: "ellipsis.circle") {
            if inventory.contains(.useAI) && supportsAssistant {
                Button("Use AI…", systemImage: "sparkles") {
                    model.presentAssistant(for: clip)
                }
                .help("Ask, enrich, rewrite, format, follow up, or research with explicit send")
                .clipActionAcceptance(inventory[.useAI], clipID: clip.id, inventory: inventory)
            }

            if inventory.contains(.saveToFolder) {
                Button("Save to Folder…", systemImage: "folder.badge.plus") {
                    folderPickerClip = clip
                }
                .clipActionAcceptance(inventory[.saveToFolder], clipID: clip.id, inventory: inventory)
            }

            if case let .saved(currentFolderID) = clip.origin,
               let action = inventory[.moveToFolder]
            {
                Menu(action.title, systemImage: action.symbolName) {
                    Button("Saved") { model.moveSavedClip(id: clip.id, to: nil) }
                        .disabled(currentFolderID == nil)
                    Divider()
                    ForEach(model.folderDestinations) { folder in
                        Button(folder.path) { model.moveSavedClip(id: clip.id, to: folder.id) }
                            .disabled(folder.id == currentFolderID || !folder.canAcceptItems)
                    }
                }
                .disabled(!action.isEnabled)
                .help(action.disabledReason ?? "Move this item to another folder")
                .clipActionAcceptance(action, clipID: clip.id, inventory: inventory)
            }

            if inventory.contains(.editNote) {
                Button("Edit Note…", systemImage: "square.and.pencil") {
                    noteEditorRequest = NoteEditorRequest(mode: .edit(clip))
                }
                .clipActionAcceptance(inventory[.editNote], clipID: clip.id, inventory: inventory)
            } else if inventory.contains(.makeNote) {
                Button("Make Note…", systemImage: "note.text.badge.plus") {
                    noteEditorRequest = NoteEditorRequest(mode: .makeFromClip(clip))
                }
                .help("Create a reviewed editable note while leaving the original clip unchanged")
                .clipActionAcceptance(inventory[.makeNote], clipID: clip.id, inventory: inventory)
            }

            if inventory.contains(.editClip) {
                Button(
                    clip.origin == .history ? "Edit a Saved Copy…" : "Edit Clip…",
                    systemImage: "pencil"
                ) {
                    clipEditorRequest = ClipEditorRequest(mode: clip.origin == .history
                        ? .editHistoryCopy(clip)
                        : .editSaved(clip))
                }
                .help(clip.origin == .history
                    ? "Keep History unchanged and edit a new saved copy"
                    : "Edit this saved item")
                .clipActionAcceptance(inventory[.editClip], clipID: clip.id, inventory: inventory)
            }

            if let action = inventory[.setShortcut] {
                Button(action.title, systemImage: action.symbolName) {
                    model.presentMenuBarContinuation(.shortcutEditor(clip))
                }
                .help("Create an abbreviation for this saved item in Quick Paste")
                .clipActionAcceptance(action, clipID: clip.id, inventory: inventory)
            }

            if let action = inventory[.editTags] {
                Button(clip.tags.isEmpty ? "Add Tags…" : action.title, systemImage: action.symbolName) {
                    tagEditorClip = clip
                }
                .disabled(!action.isEnabled)
                .help(action.disabledReason ?? "Organize this item with searchable tags")
                .clipActionAcceptance(action, clipID: clip.id, inventory: inventory)
            }

            if let action = inventory[.pin] {
                Button(action.title, systemImage: action.symbolName) {
                    model.togglePinOrSave(clip)
                }
                .disabled(model.isBusy || !action.isEnabled)
                .help(action.disabledReason ?? "Keep this item at the top of your saved clips")
                .clipActionAcceptance(action, clipID: clip.id, inventory: inventory)
            }

            if case .saved = clip.origin {
                Divider()
                let renameAction = inventory[.rename]
                Button(renameAction?.title ?? "Rename…", systemImage: renameAction?.symbolName ?? "character.cursor.ibeam") {
                    renamedClipName = clip.title
                    clipBeingRenamed = clip
                }
                .disabled(!(renameAction?.isEnabled ?? false))
                .help(renameAction?.disabledReason ?? "Change the saved item's display name")
                .clipActionAcceptance(renameAction, clipID: clip.id, inventory: inventory)
            }

            if let action = inventory[.moveToVault] {
                Button(action.title, systemImage: action.symbolName) {
                    confirmedVaultMoveSummary = model.vaultMoveSummary(for: clip)
                    confirmsVaultMove = confirmedVaultMoveSummary != nil
                }
                .disabled(model.isBusy || !action.isEnabled)
                .help(action.disabledReason ?? "Encrypts this clip, then removes its ordinary saved copy and linked history")
                .clipActionAcceptance(action, clipID: clip.id, inventory: inventory)
            }

            if clip.origin != .privateSession {
                Button("Copy Encrypted Share", systemImage: "lock.shield") {
                    model.presentEncryptedShare(clip)
                }
                .help("Copy an authenticated Clipboard Router envelope. The recipient key must already be trusted.")
                .accessibilityIdentifier("uiAcceptance.encryptedShare.\(clip.id.uuidString.lowercased())")
            }

            if inventory.contains(.share) || inventory.contains(.export) {
                Divider()
                if inventory.contains(.share) {
                    Button("Share Clip…", systemImage: "square.and.arrow.up") {
                        model.shareOrdinaryClip(clip)
                    }
                    .clipActionAcceptance(inventory[.share], clipID: clip.id, inventory: inventory)
                }
                if let action = inventory[.export] {
                    Button("Export Clip…", systemImage: "square.and.arrow.down") {
                        switch exportDecision {
                        case .available:
                            model.exportOrdinaryClip(clip)
                        case .requiresSensitiveConfirmation:
                            sensitiveExportClip = clip
                        case .unavailable:
                            break
                        }
                    }
                    .disabled(!action.isEnabled)
                    .help(action.disabledReason ?? "Export this clip as a portable archive")
                    .clipActionAcceptance(action, clipID: clip.id, inventory: inventory)
                }
            }

            if inventory.contains(.quickActions) || inventory.contains(.actions)
                || inventory.contains(.clipTools) || inventory.contains(.copyAndOpen)
                || inventory.contains(.useAI)
            {
                Divider()
            }

            if inventory.contains(.quickActions) || inventory.contains(.actions) {
                ActionableClipMenuContent(
                    suggestions: quickSuggestions,
                    automations: automations,
                    flows: flows,
                    runSuggestion: { suggestion in
                        calendarDraft = model.performSuggestedAction(suggestion, for: clip)
                    },
                    runAutomation: { model.runAutomation($0, for: clip) },
                    runFlow: { model.requestFlowRun($0, for: clip) },
                    canCreateCustomAction: clip.origin.isSaved,
                    createCustomAction: openAutomationSettings
                )
            }

            if inventory.contains(.copyAndOpen) {
                Button("Copy & Open…", systemImage: "arrow.up.forward.app") {
                    model.presentApplicationBrowser(for: clip)
                }
                .help("Search eligible installed apps, then copy and open one explicitly")
                .clipActionAcceptance(inventory[.copyAndOpen], clipID: clip.id, inventory: inventory)
            }

            if inventory.contains(.sendToCRM) {
                Button("Send to CRM…", systemImage: "building.2") {
                    model.presentCRMReview(for: clip)
                }
                .help("Review allowlisted fields before explicitly creating or updating a CRM record")
                .clipActionAcceptance(inventory[.sendToCRM], clipID: clip.id, inventory: inventory)
            }

            if inventory.contains(.clipTools) {
                Menu("Clip Tools", systemImage: "square.stack.3d.up") {
                    Button("Copy as Base64", systemImage: "number") {
                        model.copyAsBase64(clip)
                    }
                    .disabled(!clip.content.representations.referencedAssets.isEmpty || !clip.content.representations.files.isEmpty)
                    .help("Copy portable text or URL content as reversible Base64. Rich, image, and file clips stay local; Base64 is not encryption.")
                    Divider()
                    Button("Add to Combine Clips", systemImage: "square.stack.3d.up") {
                        model.addToCombinedClips(clip)
                    }
                    Button("Add to Debug Bundle", systemImage: "ladybug") {
                        model.addToDebugBundle(clip)
                    }
                    Menu("Add to Project", systemImage: "hammer") {
                        ForEach(model.developerProjects) { project in
                            Button(project.name) {
                                model.addToDeveloperProject(clip, projectID: project.id)
                            }
                        }
                        if !model.developerProjects.isEmpty { Divider() }
                        Button("New Project…", systemImage: "plus") {
                            newProjectClip = clip
                        }
                    }
                    .disabled(!model.canAddToDeveloperProject(clip))
                    Button("Add to Paste Stack", systemImage: "square.stack.3d.up") {
                        model.addToPasteStack(clip)
                    }
                    Divider()
                    transformMenu(clip)
                }
                .clipActionAcceptance(inventory[.clipTools], clipID: clip.id, inventory: inventory)
            }

            if let action = inventory[.delete] {
                Divider()
                Button("Delete", systemImage: "trash", role: .destructive) {
                    model.delete(clip)
                }
                .disabled(!action.isEnabled)
                .help(action.disabledReason ?? "Delete this item")
                .clipActionAcceptance(action, clipID: clip.id, inventory: inventory)
            }

        }
        .help("More actions for this item")
        .accessibilityIdentifier("uiAcceptance.library.more")
        .accessibilityValue(ClipActionAcceptanceAccessibility.inventoryValue(inventory))
        .accessibilityHint(ClipActionAcceptanceAccessibility.surface(.libraryInspector, clipID: clip.id))
    }

    @ViewBuilder
    private func detectedSuggestionsSection(_ clip: PresentedClip) -> some View {
        let suggestions = inlineSuggestions(for: clip)
        let canAsk = model.canPresentAssistant(for: clip)
        let showsAssistant = canAsk
        if !suggestions.isEmpty || showsAssistant {
            HStack(spacing: 8) {
                ForEach(suggestions) { suggestion in
                    Button(suggestion.title, systemImage: suggestion.symbolName) {
                        calendarDraft = model.performSuggestedAction(suggestion, for: clip)
                    }
                    .help(suggestion.valuePreview)
                }
                if showsAssistant {
                    Button("Use AI", systemImage: "sparkles") {
                        model.presentAssistant(for: clip)
                    }
                    .disabled(!canAsk)
                    .help(canAsk
                        ? "Ask, rewrite, format, enrich, follow up, or research"
                        : model.assistantUnavailableReason(for: clip))
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private func automaticOrganizationSection(_ clip: PresentedClip) -> some View {
        if case .saved = clip.origin {
            let suggestions = model.automaticOrganizationSuggestions(for: clip)
            if let suggestion = suggestions.first {
                OrganizationSuggestionCard(
                    model: model,
                    clip: clip,
                    suggestion: suggestion
                )
            } else if let receipt = model.latestAutomaticOrganizationReceipt(for: clip.id) {
                HStack {
                    Label("Organized automatically", systemImage: "wand.and.stars")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Undo", systemImage: "arrow.uturn.backward") {
                        model.undoAutomaticOrganization(receipt)
                    }
                    .disabled(model.isBusy)
                }
                .padding(10)
                .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func displayTitle(for clip: PresentedClip) -> String {
        model.isSensitiveForPresentation(clip)
            ? "Potential secret — review securely"
            : clip.title
    }

    private func sensitiveContentNotice(_ clip: PresentedClip) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Potential secret — content hidden", systemImage: "exclamationmark.shield.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text("Clipboard Router marked this as \(model.sensitivityCategoryForPresentation(clip) ?? "sensitive content"). Its value is hidden from previews and accessibility output.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Move to Vault…", systemImage: "lock") {
                confirmedVaultMoveSummary = model.vaultMoveSummary(for: clip)
                confirmsVaultMove = confirmedVaultMoveSummary != nil
            }
            .disabled(!model.canMoveClipToVault(clip))
            .help(model.vaultMoveUnavailableReason(for: clip) ?? "Encrypt and remove ordinary copies")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private func inlineSuggestions(for clip: PresentedClip) -> [SuggestedClipAction] {
        Array(model.suggestedActions(for: clip).lazy.filter {
            $0.kind != .askAI && $0.entity != nil
        }.prefix(2))
    }

    private func transformMenu(_ clip: PresentedClip) -> some View {
        Menu("Transform", systemImage: "wand.and.stars") {
            Button("Trim whitespace") {
                model.previewTransform(.trim, title: "Trim whitespace", for: clip)
            }
            Button("Plain text") {
                model.previewTransform(.plainText, title: "Plain text", for: clip)
            }
            Button("Normalize line endings") {
                model.previewTransform(
                    .lineEndings(.lineFeed),
                    title: "Unix line endings",
                    for: clip
                )
            }
            Divider()
            Button("UPPERCASE") {
                model.previewTransform(.uppercase, title: "UPPERCASE", for: clip)
            }
            Button("lowercase") {
                model.previewTransform(.lowercase, title: "lowercase", for: clip)
            }
            Button("Title Case") {
                model.previewTransform(.titleCase, title: "Title Case", for: clip)
            }
            Divider()
            Button("Markdown quote") {
                model.previewTransform(.quote, title: "Markdown quote", for: clip)
            }
            Button("Code block") {
                model.previewTransform(
                    .codeBlock(language: nil),
                    title: "Code block",
                    for: clip
                )
            }
            Divider()
            Button("Pretty JSON") {
                model.previewTransform(.prettyJSON, title: "Pretty JSON", for: clip)
            }
            Button("Strip ANSI") {
                model.previewTransform(.stripANSI, title: "Strip ANSI", for: clip)
            }
            Button("URL Decode") {
                model.previewTransform(.urlDecode, title: "URL Decode", for: clip)
            }
        }
    }

    private func detailsSection(_ clip: PresentedClip) -> some View {
        DisclosureGroup(isExpanded: $isShowingDetails) {
            metadataView(clip)
                .padding(.top, 10)
        } label: {
            HStack {
                Label("Details", systemImage: "info.circle")
                    .font(.headline)
                Spacer()
                Text(contentTypeName(clip.content.type))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private func compactTagSection(_ clip: PresentedClip) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "tag")
                .foregroundStyle(.secondary)
            ForEach(clip.tags.prefix(5), id: \.self) { tag in
                Text(tag)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.tint.opacity(0.12), in: Capsule())
            }
            if clip.tags.count > 5 {
                Text("+\(clip.tags.count - 5)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Edit Tags", systemImage: "pencil") {
                tagEditorClip = clip
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .disabled(!model.clipContextMenuPolicy(for: clip).canMutateSavedClip)
            .help("Edit tags")
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func metadataView(_ clip: PresentedClip) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
            metadataRow("Captured", clip.date.formatted(date: .abbreviated, time: .standard))
            metadataRow("Size", ByteCountFormatter.string(
                fromByteCount: Int64(clip.content.estimatedStorageByteCount),
                countStyle: .file
            ))
            metadataRow("Type", contentTypeName(clip.content.type))
            metadataRow("Characters", "\(clip.content.text.count)")
            metadataRow("Words", "\(clip.content.text.split { $0.isWhitespace }.count)")
            if let captureCount = clip.captureCount {
                metadataRow("Times captured", "\(captureCount)")
            }
            if let pasteCount = clip.pasteCount {
                metadataRow("One-click pastes", "\(pasteCount)")
            }
            if let lastPastedAt = clip.lastPastedAt {
                metadataRow(
                    "Last one-click paste",
                    lastPastedAt.formatted(date: .abbreviated, time: .standard)
                )
            }
            if let source = clip.captureContext?.sourceApplicationName
                ?? clip.sourceBundleIdentifier
            {
                metadataRow("Source", source)
            }
            if let domain = clip.captureContext?.sourceDomain {
                metadataRow("Domain", domain)
            }
            if let device = clip.captureContext?.deviceLabel {
                metadataRow("Device", device)
            }
            if let operatingSystem = clip.captureContext?.operatingSystem {
                metadataRow("System", operatingSystem)
            }
            if let location = clip.captureContext?.coarseLocation?.label {
                metadataRow("Coarse location", location)
            }
            if let image = clip.content.representations.imageMetadata {
                metadataRow("Dimensions", "\(image.pixelWidth) × \(image.pixelHeight)")
                metadataRow("Image format", image.format)
                if let byteCount = image.byteCount {
                    metadataRow("Original image", ByteCountFormatter.string(
                        fromByteCount: Int64(byteCount),
                        countStyle: .file
                    ))
                }
            }
            if !clip.content.representations.files.isEmpty {
                metadataRow("Files", "\(clip.content.representations.files.count)")
            }
            if !clip.pasteboardTypeIdentifiers.isEmpty {
                metadataRow("Pasteboard types", clip.pasteboardTypeIdentifiers.joined(separator: ", "))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func metadataRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).fontWeight(.semibold)
            Text(value).textSelection(.enabled)
        }
    }
}

private func clipSymbol(for type: SupportedContentType) -> String {
    switch type {
    case .plainText: "doc.plaintext"
    case .url: "link"
    case .richText: "doc.richtext"
    case .image: "photo"
    case .fileURLs: "doc.on.doc"
    }
}

private func contentTypeName(_ type: SupportedContentType) -> String {
    switch type {
    case .plainText: "Plain text"
    case .url: "Web address"
    case .richText: "Rich text"
    case .image: "Image"
    case .fileURLs: "Files"
    }
}

struct StatusToast: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            // Long status text previously stretched the capsule toward the full window width.
            // Wrapping to a bounded measure keeps the toast from crowding the pane it overlays.
            Text(message)
                .font(.callout)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss status")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 520)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .shadow(color: .black.opacity(0.15), radius: 16, y: 6)
    }
}

private struct NewFolderSheet: View {
    let onCreate: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("New Folder").font(.title2.weight(.semibold))
            TextField("Folder name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(create)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create", action: create)
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 380)
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onCreate(trimmed)
    }
}

private struct FolderPickerSheet: View {
    let folders: [ClipFolder]
    let onSelect: (UUID?) -> Void
    let onCreateFolder: (String) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFolderNameFocused: Bool
    @State private var isAddingFolder = false
    @State private var folderName = ""
    @State private var creationError: String?
    @State private var isSavingNewFolder = false

    init(
        folders: [ClipFolder],
        initiallyAddingFolder: Bool = false,
        onSelect: @escaping (UUID?) -> Void,
        onCreateFolder: @escaping (String) async throws -> Void
    ) {
        self.folders = folders
        self.onSelect = onSelect
        self.onCreateFolder = onCreateFolder
        _isAddingFolder = State(initialValue: initiallyAddingFolder)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Save Clip").font(.title2.weight(.semibold))
            Text("Choose where this clip should live.").foregroundStyle(.secondary)
            if isAddingFolder {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("New folder name", text: $folderName)
                        .textFieldStyle(.roundedBorder)
                        .focused($isFolderNameFocused)
                        .onSubmit(saveInNewFolder)
                        .disabled(isSavingNewFolder)
                        .accessibilityLabel("New saved clips folder name")
                    if let creationError {
                        Text(creationError)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .accessibilityLabel("Folder creation error: \(creationError)")
                    }
                    HStack {
                        Button("Back") {
                            isAddingFolder = false
                            creationError = nil
                        }
                        .disabled(isSavingNewFolder)
                        Spacer()
                        Button(action: saveInNewFolder) {
                            HStack(spacing: 7) {
                                if isSavingNewFolder {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                                Text("Create Folder & Save")
                            }
                        }
                            .buttonStyle(.borderedProminent)
                            .disabled(isSavingNewFolder || folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            } else {
                Button {
                    isAddingFolder = true
                    DispatchQueue.main.async { isFolderNameFocused = true }
                } label: {
                    Label("New Folder…", systemImage: "folder.badge.plus")
                }
                .accessibilityLabel("Create a new folder and save this clip")
                .accessibilityHint("Creates a folder, then saves the current clip inside it")
            }
            List {
                Button {
                    onSelect(nil)
                } label: {
                    Label("Saved", systemImage: "bookmark")
                }
                .buttonStyle(.plain)
                ForEach(sortedFolders) { folder in
                    Button {
                        onSelect(folder.id)
                    } label: {
                        Label(folderPath(for: folder.id), systemImage: "folder")
                    }
                    .buttonStyle(.plain)
                }
            }
            .disabled(isSavingNewFolder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .disabled(isSavingNewFolder)
            }
        }
        .padding(22)
        .frame(width: 400, height: isAddingFolder ? 470 : 390)
        .interactiveDismissDisabled(isSavingNewFolder)
        .onAppear {
            if isAddingFolder {
                DispatchQueue.main.async { isFolderNameFocused = true }
            }
        }
    }

    private var sortedFolders: [ClipFolder] {
        folders.sorted {
            folderPath(for: $0.id).localizedCaseInsensitiveCompare(folderPath(for: $1.id))
                == .orderedAscending
        }
    }

    private func folderPath(for id: UUID) -> String {
        let byID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        var parts: [String] = []
        var cursor: UUID? = id
        var visited: Set<UUID> = []
        while let current = cursor,
              let folder = byID[current],
              visited.insert(current).inserted
        {
            parts.append(folder.name)
            cursor = folder.parentFolderID
        }
        return parts.reversed().joined(separator: " / ")
    }

    private func saveInNewFolder() {
        let name = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !isSavingNewFolder else { return }
        creationError = nil
        isSavingNewFolder = true
        Task {
            do {
                try await onCreateFolder(name)
                dismiss()
            } catch {
                creationError = error.localizedDescription
            }
            isSavingNewFolder = false
        }
    }
}
