import AppKit
import ClipboardRouterCore
import ClipboardRouterPlatform
import SwiftUI

enum MenuBarActionPresentationPolicy {
    static let debugBundleSurface: RequestPresentationSurface = .library

    static func surface(for action: SuggestedClipAction) -> RequestPresentationSurface {
        switch action.kind {
        case .findRelated:
            .library
        case .askAI, .saveContact, .createCalendarEvent,
             .openLink, .composeEmail, .openCallingApp:
            .menuBar
        }
    }
}

/// Defers persistent window work until the MenuBarExtra window has actually disappeared.
///
/// AppKit can drain the main queue while the transient panel is still in its ordering transaction.
/// The order-out observer acknowledges that the menu is no longer visible, then schedules the
/// persistent presentation only after `orderOut` has returned. That gives every action requiring
/// a second interaction a stable window instead of leaving it attached to the dismissed menu.
@MainActor
final class MenuBarLibraryPresentationBoundary: ObservableObject {
    typealias Presentation = @MainActor () -> Void
    typealias DismissMenuBar = @MainActor () -> Bool

    private var pendingPresentation: Presentation?
    private var dismissalObservation: MenuBarTransientWindowDismissalObservation?

    @discardableResult
    func request(presentation: @escaping Presentation) -> Bool {
        guard pendingPresentation == nil else { return false }
        pendingPresentation = presentation
        guard let observation = MenuBarTransientWindowDismissalObservation.make(
            completion: { [weak self] in self?.menuBarDidDisappear() }
        ) else {
            pendingPresentation = nil
            return false
        }
        dismissalObservation = observation
        observation.orderOut()
        return true
    }

    @discardableResult
    func request(
        dismissMenuBar: DismissMenuBar,
        presentation: @escaping Presentation
    ) -> Bool {
        guard pendingPresentation == nil else { return false }
        pendingPresentation = presentation
        guard dismissMenuBar() else {
            pendingPresentation = nil
            return false
        }
        return true
    }

    func menuBarDidDisappear() {
        guard let presentation = pendingPresentation else { return }
        pendingPresentation = nil
        dismissalObservation?.cancel()
        dismissalObservation = nil
        presentation()
    }

    func cancel() {
        pendingPresentation = nil
        dismissalObservation?.cancel()
        dismissalObservation = nil
    }
}

@MainActor
private final class MenuBarTransientWindowDismissalObservation {
    private let window: NSWindow
    private var token: NSObjectProtocol?
    private var completion: (@MainActor () -> Void)?

    private init(window: NSWindow, completion: @escaping @MainActor () -> Void) {
        self.window = window
        self.completion = completion
        token = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.finish()
            }
        }
    }

    static func make(
        completion: @escaping @MainActor () -> Void
    ) -> MenuBarTransientWindowDismissalObservation? {
        let candidate = NSApp.keyWindow ?? NSApp.windows.first(where: { window in
            window.isVisible
                && (window is NSPanel || !window.styleMask.contains(.titled))
        })
        guard let candidate,
              candidate.identifier?.rawValue != LibraryWindowPresenter.libraryWindowIdentifier,
              candidate is NSPanel || !candidate.styleMask.contains(.titled)
        else { return nil }
        return MenuBarTransientWindowDismissalObservation(
            window: candidate,
            completion: completion
        )
    }

    func orderOut() {
        window.orderOut(nil)
        // Ordering out the key MenuBarExtra posts `didResignKey`. The visibility check covers
        // custom/test windows that order out without posting while preserving the same lifecycle
        // condition: the continuation cannot run while the transient window is visible.
        if !window.isVisible { finish() }
    }

    private func finish() {
        guard let completion else { return }
        self.completion = nil
        if let token {
            NotificationCenter.default.removeObserver(token)
            self.token = nil
        }
        // `didResignKey` can be posted synchronously from `orderOut`. Queueing only after that
        // lifecycle event guarantees the window-ordering call itself has unwound before the
        // persistent scene/window is created. This is an event boundary, not a timing delay.
        DispatchQueue.main.async {
            completion()
        }
    }

    func cancel() {
        completion = nil
        if let token {
            NotificationCenter.default.removeObserver(token)
            self.token = nil
        }
    }
}

/// Fixed geometry for the compact menu-bar window. Keeping these values together makes
/// the expected 420-point surface predictable across clip-count settings.
enum MenuBarLayoutMetrics {
    static let width: CGFloat = 420
    static let height: CGFloat = 500
    static let clipTitleMinimumWidth: CGFloat = 180
    static let clipRowHeight: CGFloat = 48
    static let clipActionTarget: CGFloat = 28
    static let clipActionSpacing: CGFloat = 8
    static let minimumCompleteClipRows = 4
    static let clipListMinimumHeight =
        (clipRowHeight * CGFloat(minimumCompleteClipRows)) + 28
}

struct MenuBarView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var query = ""
    @StateObject private var libraryPresentationBoundary = MenuBarLibraryPresentationBoundary()
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Clipboard Router").font(.headline)
                    Label(statusTitle, systemImage: model.isCaptureActive
                        ? "circle.fill" : "pause.circle.fill")
                        .font(.caption)
                        .foregroundStyle(model.isCaptureActive ? .green : .orange)
                }
                Spacer()
                Button {
                    model.toggleCapture()
                } label: {
                    Image(systemName: model.isCaptureActive ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.borderless)
                .disabled(model.isBusy)
                .accessibilityLabel(model.isCaptureActive
                    ? "Pause clipboard capture" : "Resume clipboard capture")
            }
            .padding(12)

            HStack(spacing: 8) {
                Menu {
                    Button("No Active Project") { model.setActiveDeveloperProject(nil) }
                    if !model.developerProjects.isEmpty { Divider() }
                    ForEach(model.developerProjects) { project in
                        Button {
                            model.setActiveDeveloperProject(project.id)
                        } label: {
                            if project.id == model.activeDeveloperProject?.id {
                                Label(project.name, systemImage: "checkmark")
                            } else {
                                Text(project.name)
                            }
                        }
                    }
                    Divider()
                    Button("Manage Projects…", systemImage: "rectangle.3.group") {
                        openProjects()
                    }
                } label: {
                    Label(
                        model.activeDeveloperProject?.name ?? "No Active Project",
                        systemImage: "hammer"
                    )
                    .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .disabled(model.isBusy)
                Spacer()
                if let activeProject = model.activeDeveloperProject,
                   activeProject.autoAddDeveloperClips,
                   !activeProject.allowedSourceBundleIdentifiers.isEmpty
                {
                    Text("AUTO")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Automatic project capture enabled")
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            TextField("Search clips", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
                .onChange(of: query) { _, value in model.updateMenuSearch(value) }
                .accessibilityIdentifier("uiAcceptance.menu.search")

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        if !model.menuMatchingSmartViews.isEmpty {
                            sectionHeader("SMART VIEWS")
                            ForEach(model.menuMatchingSmartViews) { smartView in
                                Button {
                                    model.applySmartView(smartView.id)
                                    openPersistentLibrary()
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: smartView.systemImage)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(smartView.title).lineLimit(1)
                                            Text(smartView.query)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                        Spacer()
                                        Text("\(smartView.count)")
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .accessibilityHint("Open this saved query in Library")
                            }
                        }
                        sectionHeader("SEARCH RESULTS")
                        if model.menuSearchResults.isEmpty && model.menuMatchingSmartViews.isEmpty {
                            emptyMessage("No matching clips")
                        } else {
                            ForEach(model.menuSearchResults) { clip in
                                MenuBarClipButton(
                                    model: model,
                                    libraryPresentationBoundary: libraryPresentationBoundary,
                                    clip: clip,
                                    thumbnailLoader: model.thumbnailLoader,
                                    copy: { model.copy(clip) },
                                    paste: { model.pasteIntoRememberedApplication(clip) },
                                    togglePin: { model.togglePinOrSave(clip) },
                                    canTogglePin: canTogglePin(clip) && !model.isBusy,
                                    organization: model.clipContextMenuPolicy(for: clip).organization,
                                    folders: model.folderDestinations,
                                    saveToFolder: { model.saveHistoryClip(clip, folderID: $0) },
                                    moveToFolder: { model.moveSavedClip(id: clip.id, to: $0) },
                                    requestNewFolder: { presentPersistently(.newFolder(clip)) },
                                    canConvertToNote: model.canConvertToNote(clip),
                                    convertToNote: { presentPersistently(.noteEditor(NoteEditorRequest(mode: .makeFromClip(clip)))) },
                                    canEditNote: model.canEditNote(clip),
                                    editNote: { presentPersistently(.noteEditor(NoteEditorRequest(mode: .edit(clip)))) },
                                    canEditClip: model.canEditClip(clip),
                                    editClip: { requestClipEditPersistently(clip) },
                                    requestVaultMove: { requestVaultMovePersistently(clip) },
                                    canMoveToVault: model.canMoveClipToVault(clip) && !model.isBusy,
                                    vaultUnavailableReason: model.vaultMoveUnavailableReason(for: clip),
                                    runSuggestion: { runSuggestion($0, for: clip) }
                                )
                            }
                        }
                    } else {
                        if !model.menuBarPinnedClips.isEmpty {
                            sectionHeader("PINNED")
                            ForEach(model.menuBarPinnedClips) { clip in
                                MenuBarClipButton(
                                    model: model,
                                    libraryPresentationBoundary: libraryPresentationBoundary,
                                    clip: clip,
                                    thumbnailLoader: model.thumbnailLoader,
                                    copy: { model.copy(clip) },
                                    paste: { model.pasteIntoRememberedApplication(clip) },
                                    togglePin: { model.togglePinOrSave(clip) },
                                    canTogglePin: canTogglePin(clip) && !model.isBusy,
                                    organization: model.clipContextMenuPolicy(for: clip).organization,
                                    folders: model.folderDestinations,
                                    saveToFolder: { model.saveHistoryClip(clip, folderID: $0) },
                                    moveToFolder: { model.moveSavedClip(id: clip.id, to: $0) },
                                    requestNewFolder: { presentPersistently(.newFolder(clip)) },
                                    canConvertToNote: model.canConvertToNote(clip),
                                    convertToNote: { presentPersistently(.noteEditor(NoteEditorRequest(mode: .makeFromClip(clip)))) },
                                    canEditNote: model.canEditNote(clip),
                                    editNote: { presentPersistently(.noteEditor(NoteEditorRequest(mode: .edit(clip)))) },
                                    canEditClip: model.canEditClip(clip),
                                    editClip: { requestClipEditPersistently(clip) },
                                    requestVaultMove: { requestVaultMovePersistently(clip) },
                                    canMoveToVault: model.canMoveClipToVault(clip) && !model.isBusy,
                                    vaultUnavailableReason: model.vaultMoveUnavailableReason(for: clip),
                                    runSuggestion: { runSuggestion($0, for: clip) }
                                )
                            }
                        }
                        sectionHeader("RECENT")
                        if model.menuBarRecentClips.isEmpty {
                            emptyMessage("Your recent clips will appear here.")
                        } else {
                            ForEach(model.menuBarRecentClips) { clip in
                                MenuBarClipButton(
                                    model: model,
                                    libraryPresentationBoundary: libraryPresentationBoundary,
                                    clip: clip,
                                    thumbnailLoader: model.thumbnailLoader,
                                    copy: { model.copy(clip) },
                                    paste: { model.pasteIntoRememberedApplication(clip) },
                                    togglePin: { model.togglePinOrSave(clip) },
                                    canTogglePin: canTogglePin(clip) && !model.isBusy,
                                    organization: model.clipContextMenuPolicy(for: clip).organization,
                                    folders: model.folderDestinations,
                                    saveToFolder: { model.saveHistoryClip(clip, folderID: $0) },
                                    moveToFolder: { model.moveSavedClip(id: clip.id, to: $0) },
                                    requestNewFolder: { presentPersistently(.newFolder(clip)) },
                                    canConvertToNote: model.canConvertToNote(clip),
                                    convertToNote: { presentPersistently(.noteEditor(NoteEditorRequest(mode: .makeFromClip(clip)))) },
                                    canEditNote: model.canEditNote(clip),
                                    editNote: { presentPersistently(.noteEditor(NoteEditorRequest(mode: .edit(clip)))) },
                                    canEditClip: model.canEditClip(clip),
                                    editClip: { requestClipEditPersistently(clip) },
                                    requestVaultMove: { requestVaultMovePersistently(clip) },
                                    canMoveToVault: model.canMoveClipToVault(clip) && !model.isBusy,
                                    vaultUnavailableReason: model.vaultMoveUnavailableReason(for: clip),
                                    runSuggestion: { runSuggestion($0, for: clip) }
                                )
                            }
                        }
                    }
                }
            }
            .frame(
                minHeight: MenuBarLayoutMetrics.clipListMinimumHeight,
                maxHeight: 340
            )
            .layoutPriority(1)

            Divider()
            if let status = model.statusMessage {
                HStack(spacing: 8) {
                    Label(status, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                    Button("Dismiss", systemImage: "xmark") { model.dismissStatus() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

            HStack(spacing: 8) {
                Button("Open Library", systemImage: "rectangle.3.group") {
                    openPersistentLibrary()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .frame(maxWidth: .infinity)
                .accessibilityHint("Open the full searchable clipboard library")
                .accessibilityIdentifier("uiAcceptance.menu.openLibrary")

                Button("New Note", systemImage: "square.and.pencil") {
                    presentPersistently(.noteEditor(NoteEditorRequest(mode: .create)))
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .accessibilityIdentifier("uiAcceptance.menu.newNote")
                .help("Create a note (⌘⇧N)")

                Button("Quick Paste", systemImage: "text.badge.plus") {
                    model.requestInsertPalette(
                        capturingCurrentApplication: false,
                        preservingRememberedApplication: true,
                        notifyPresentationHosts: false
                    )
                    presentPersistently(.quickPaste)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .help("Open Quick Paste (\(model.insertPaletteHotKeyChoice.displayName))")

                Menu {
                    Button("Settings…", systemImage: "gearshape") { openSettings() }
                    Divider()
                    Button("Quit Clipboard Router", systemImage: "power", role: .destructive) {
                        NSApp.terminate(nil)
                    }
                    .keyboardShortcut("q")
                } label: {
                    Image(systemName: "gearshape")
                        .frame(
                            width: MenuBarLayoutMetrics.clipActionTarget,
                            height: MenuBarLayoutMetrics.clipActionTarget
                        )
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Settings and app controls")
                .accessibilityLabel("Settings and app controls")
                .accessibilityIdentifier("uiAcceptance.menu.controls")
            }
            .padding(12)
        }
        .frame(width: MenuBarLayoutMetrics.width, height: MenuBarLayoutMetrics.height)
        .onAppear {
            model.rememberPasteTarget()
            searchFocused = true
            model.updateMenuSearch(query)
        }
    }

    private func requestVaultMovePersistently(_ clip: PresentedClip) {
        guard let summary = model.vaultMoveSummary(for: clip) else { return }
        presentPersistently(.vaultMove(clip: clip, summary: summary))
    }

    private func requestClipEditPersistently(_ clip: PresentedClip) {
        switch clip.origin {
        case .history:
            presentPersistently(.clipEditor(ClipEditorRequest(mode: .editHistoryCopy(clip))))
        case .saved:
            presentPersistently(.clipEditor(ClipEditorRequest(mode: .editSaved(clip))))
        case .privateSession:
            break
        }
    }

    private func runSuggestion(_ action: SuggestedClipAction, for clip: PresentedClip) {
        let presentationSurface = MenuBarActionPresentationPolicy.surface(for: action)
        if presentationSurface == .library {
            performFromPersistentLibrary {
                let calendarDraft = model.performSuggestedAction(
                    action,
                    for: clip,
                    presentationSurface: presentationSurface
                )
                if let calendarDraft {
                    model.presentMenuBarContinuation(.calendar(calendarDraft))
                }
            }
            return
        }
        switch action.kind {
        case .askAI, .saveContact, .createCalendarEvent:
            guard libraryPresentationBoundary.request(presentation: {
                let calendarDraft = model.performSuggestedAction(
                    action,
                    for: clip,
                    presentationSurface: presentationSurface
                )
                if let calendarDraft {
                    model.presentMenuBarContinuation(.calendar(calendarDraft))
                }
            }) else {
                model.errorMessage = "The panel could not be opened because the menu-bar window did not close."
                return
            }
        case .openLink, .composeEmail, .openCallingApp, .findRelated:
            _ = model.performSuggestedAction(
                action,
                for: clip,
                presentationSurface: presentationSurface
            )
        }
    }

    private func presentPersistently(_ action: MenuBarContinuationRequest.Action) {
        guard libraryPresentationBoundary.request(presentation: {
            model.presentMenuBarContinuation(action)
        }) else {
            model.errorMessage = "The panel could not be opened because the menu-bar window did not close."
            return
        }
    }

    private func openPersistentLibrary() {
        guard libraryPresentationBoundary.request(presentation: {
            LibraryWindowPresenter.show(using: openWindow) { message in
                model.errorMessage = message
            }
        }) else {
            model.errorMessage = "Library could not be opened because the menu-bar window did not close."
            return
        }
    }

    private func performFromPersistentLibrary(
        _ action: @escaping @MainActor @Sendable () -> Void
    ) {
        guard libraryPresentationBoundary.request(presentation: {
            LibraryWindowPresenter.performWhenReady(
                using: openWindow,
                onFailure: { message in model.errorMessage = message },
                action: action
            )
        }) else {
            model.errorMessage = "Library could not be opened because the menu-bar window did not close."
            return
        }
    }

    private func openProjects() {
        model.selectLibrarySection(.developerProjects)
        openPersistentLibrary()
    }

    private var statusTitle: String {
        if model.pasteboardAccessState == .denied { return "Clipboard access blocked" }
        if model.isPrivateSessionActive { return "Private Session — memory only" }
        return model.isCaptureActive ? "Capturing clipboard" : "Capture paused"
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }

    private func emptyMessage(_ message: String) -> some View {
        Text(message)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func canTogglePin(_ clip: PresentedClip) -> Bool {
        switch clip.origin {
        case .history:
            true
        case .saved:
            model.clipContextMenuPolicy(for: clip).canMutateSavedClip
        case .privateSession:
            false
        }
    }
}

private struct MenuBarClipButton: View {
    @Environment(\.openWindow) private var openWindow
    let model: AppModel
    let libraryPresentationBoundary: MenuBarLibraryPresentationBoundary
    let clip: PresentedClip
    let thumbnailLoader: ClipThumbnailLoader
    let copy: () -> Void
    let paste: () -> Void
    let togglePin: () -> Void
    let canTogglePin: Bool
    let organization: ClipContextMenuPolicy.Organization
    let folders: [FolderDestination]
    let saveToFolder: (UUID?) -> Void
    let moveToFolder: (UUID?) -> Void
    let requestNewFolder: () -> Void
    let canConvertToNote: Bool
    let convertToNote: () -> Void
    let canEditNote: Bool
    let editNote: () -> Void
    let canEditClip: Bool
    let editClip: () -> Void
    let requestVaultMove: () -> Void
    let canMoveToVault: Bool
    let vaultUnavailableReason: String?
    let runSuggestion: (SuggestedClipAction) -> Void

    @State private var isRowHovered = false
    @State private var isPreviewHovered = false
    @State private var isPreviewPresented = false
    @State private var pendingPresentation: Task<Void, Never>?
    @State private var pendingDismissal: Task<Void, Never>?

    var body: some View {
        let assistantAction = model.suggestedActions(for: clip).first { $0.kind == .askAI }

        HStack(spacing: MenuBarLayoutMetrics.clipActionSpacing) {
            Button(action: copy) {
                HStack(spacing: 9) {
                    Image(systemName: symbol)
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(clip.title)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        HStack(spacing: 5) {
                            MinuteRelativeTimestamp(date: clip.date)
                            if let source = clip.captureContext?.sourceApplicationName
                                ?? clip.sourceBundleIdentifier
                            {
                                Text("•")
                                Text(source).lineLimit(1)
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    .frame(
                        minWidth: MenuBarLayoutMetrics.clipTitleMinimumWidth,
                        maxWidth: .infinity,
                        alignment: .leading
                    )
                    Spacer(minLength: 8)
                    Image(systemName: "doc.on.doc")
                        .foregroundStyle(.tertiary)
                }
                .frame(height: MenuBarLayoutMetrics.clipRowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Copy clip: \(clip.title)")
            .accessibilityValue(uiAcceptancePasteboardName)
            .accessibilityIdentifier("uiAcceptance.menu.copy.\(clip.id.uuidString.lowercased())")
            .accessibilitySortPriority(4)

            Button(action: paste) {
                Image(systemName: "keyboard.badge.ellipsis")
                    .frame(
                        width: MenuBarLayoutMetrics.clipActionTarget,
                        height: MenuBarLayoutMetrics.clipActionTarget
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Copy and paste into the app that was active before this menu opened")
            .accessibilityLabel("Paste \(clip.title) into the previous app")
            .accessibilitySortPriority(3)

            if let assistantAction {
                Button {
                    runSuggestion(assistantAction)
                } label: {
                    Image(systemName: "sparkles")
                        .frame(
                            width: MenuBarLayoutMetrics.clipActionTarget,
                            height: MenuBarLayoutMetrics.clipActionTarget
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Use AI with this clip")
                .accessibilityLabel("Use AI with \(clip.title)")
                .accessibilityIdentifier("uiAcceptance.menu.useAI.\(clip.id.uuidString.lowercased())")
                .accessibilitySortPriority(2)
            }

            Menu {
                managementActions
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(
                        width: MenuBarLayoutMetrics.clipActionTarget,
                        height: MenuBarLayoutMetrics.clipActionTarget
                    )
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Act on, organize, edit, or protect this clip")
            .accessibilityLabel("More actions for \(clip.title)")
            .accessibilityIdentifier("uiAcceptance.menu.more.\(clip.id.uuidString.lowercased())")
            .accessibilitySortPriority(1)
        }
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
        .onHover(perform: updateRowHover)
        .onDisappear(perform: cancelPreview)
        .modifier(MenuBarHoverPreviewAccessibilityAction(
            isEnabled: MenuBarHoverPreviewPolicy.allowsPreview(
                for: clip,
                isSensitive: model.isSensitiveForPresentation(clip)
            ),
            action: showPreviewImmediately
        ))
        .popover(isPresented: previewBinding, arrowEdge: .trailing) {
            MenuBarClipHoverPreview(
                clip: clip,
                descriptor: MenuBarHoverPreviewDescriptor(clip: clip),
                thumbnailLoader: thumbnailLoader,
                onHover: updatePreviewHover
            )
        }
    }

    private var previewBinding: Binding<Bool> {
        Binding(
            get: {
                MenuBarHoverPreviewPolicy.allowsPreview(
                    for: clip,
                    isSensitive: model.isSensitiveForPresentation(clip)
                ) && isPreviewPresented
            },
            set: { isPreviewPresented = $0 }
        )
    }

    private func updateRowHover(_ hovering: Bool) {
        isRowHovered = hovering
        updatePreviewPresentation()
    }

    private func updatePreviewHover(_ hovering: Bool) {
        isPreviewHovered = hovering
        updatePreviewPresentation()
    }

    private func updatePreviewPresentation() {
        guard MenuBarHoverPreviewPolicy.allowsPreview(
            for: clip,
            isSensitive: model.isSensitiveForPresentation(clip)
        ) else {
            cancelPreview()
            return
        }
        if isRowHovered || isPreviewHovered {
            pendingDismissal?.cancel()
            pendingDismissal = nil
            guard !isPreviewPresented else { return }
            pendingPresentation?.cancel()
            pendingPresentation = Task {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled, isRowHovered || isPreviewHovered else { return }
                isPreviewPresented = true
            }
        } else {
            pendingPresentation?.cancel()
            pendingPresentation = nil
            guard isPreviewPresented else { return }
            pendingDismissal?.cancel()
            pendingDismissal = Task {
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled, !isRowHovered, !isPreviewHovered else { return }
                isPreviewPresented = false
            }
        }
    }

    private func cancelPreview() {
        pendingPresentation?.cancel()
        pendingDismissal?.cancel()
        isPreviewPresented = false
    }

    private func showPreviewImmediately() {
        guard MenuBarHoverPreviewPolicy.allowsPreview(
            for: clip,
            isSensitive: model.isSensitiveForPresentation(clip)
        ) else { return }
        pendingPresentation?.cancel()
        pendingDismissal?.cancel()
        isPreviewPresented = true
    }

    @ViewBuilder
    private var managementActions: some View {
        let policy = model.clipContextMenuPolicy(for: clip)
        let inventory = ClipActionCatalog.inventory(for: clip, model: model, surface: .menuBar)
        let suggestions = model.suggestedActions(for: clip)
        let assistantAction = suggestions.first(where: { $0.kind == .askAI })
        let quickSuggestions = suggestions.filter { $0.kind != .askAI }
        let automations = model.applicableAutomations(for: clip)
        let flows = model.applicableFlows(for: clip)

        if model.isEncryptedShare(clip) {
            Button("Decrypt Encrypted Share…", systemImage: "lock.open") {
                Task { _ = await model.decryptEncryptedShare(clip) }
            }
            .help("Authenticate and show the decrypted payload in an ephemeral preview")
            .accessibilityIdentifier("uiAcceptance.decryptShare.\(clip.id.uuidString.lowercased())")
        }

        if inventory.contains(.showInLibrary) {
            Button("Show in Library…", systemImage: "text.viewfinder", action: revealClipInLibrary)
        }

        if inventory.contains(.useAI), let assistantAction {
            Button("Use AI…", systemImage: "sparkles") {
                runSuggestion(assistantAction)
            }
            .help("Rewrite, extract details, research, or ask about this clip")
        }

        if inventory.contains(.showInLibrary) || inventory.contains(.useAI) {
            Divider()
        }

        switch policy.organization {
        case .saveToFolder:
            Menu("Save to Folder", systemImage: "folder.badge.plus") {
                Button("Saved") { saveToFolder(nil) }
                Divider()
                ForEach(folders) { folder in
                    Button(folder.path) { saveToFolder(folder.id) }
                        .disabled(!folder.canAcceptItems)
                }
                Divider()
                Button("New Folder…", systemImage: "folder.badge.plus", action: requestNewFolder)
            }
        case .moveToFolder:
            Menu("Move to Folder", systemImage: "folder") {
                Button("Saved") { moveToFolder(nil) }
                Divider()
                ForEach(folders) { folder in
                    Button(folder.path) { moveToFolder(folder.id) }
                        .disabled(!folder.canAcceptItems || clip.origin == .saved(folderID: folder.id))
                }
            }
        case .none:
            EmptyView()
        }

        if let action = inventory[.pin] {
            Button(action.title, systemImage: action.symbolName, action: togglePin)
                .disabled(!action.isEnabled || !canTogglePin)
                .help(action.disabledReason ?? "Keep this item at the top of your saved clips")
        }

        if inventory.contains(.editNote) {
            Button("Edit Note…", systemImage: "square.and.pencil", action: editNote)
        } else {
            if inventory.contains(.editClip) {
                Button(
                    clip.origin == .history ? "Edit a Saved Copy…" : "Edit Clip…",
                    systemImage: "pencil",
                    action: editClip
                )
            }
            if inventory.contains(.makeNote) {
                Button("Make Note…", systemImage: "note.text.badge.plus", action: convertToNote)
            }
        }

        if inventory.contains(.setShortcut) {
            Button("Set Shortcut…", systemImage: "character.textbox") {
                presentPersistently(.shortcutEditor(clip))
            }
            .help("Create an abbreviation for this saved item in Quick Paste")
        }

        if let action = inventory[.moveToVault] {
            Button(action.title, systemImage: action.symbolName, action: requestVaultMove)
                .disabled(!action.isEnabled)
                .help(action.disabledReason ?? "Encrypt this clip and remove its ordinary copy")
        }

        if clip.origin != .privateSession {
            Button("Encrypt & Share…", systemImage: "lock.shield") {
                presentPersistently(.encryptedShare(EncryptedShareRequest(clip: clip)))
            }
            .help("Open the recipient-key composer. Clipboard Router never discovers or trusts keys automatically.")
            .accessibilityIdentifier("uiAcceptance.encryptedShare.\(clip.id.uuidString.lowercased())")
        }

        if inventory.contains(.share) {
            Button("Share Clip…", systemImage: "square.and.arrow.up") {
                performFromPersistentLibrary {
                    model.shareOrdinaryClip(clip)
                }
            }
        }

        if let action = inventory[.export] {
            let exportDecision = model.clipExportDecision(clip)
            Button("Export Clip…", systemImage: "square.and.arrow.down") {
                switch exportDecision {
                case .available:
                    performFromPersistentLibrary {
                        model.exportOrdinaryClip(clip)
                    }
                case let .requiresSensitiveConfirmation(category):
                    presentPersistently(.sensitiveExport(clip: clip, category: category))
                case .unavailable:
                    break
                }
            }
            .disabled(!action.isEnabled)
            .help(action.disabledReason ?? "Export this clip as a portable archive")
        }

        if inventory.contains(.quickActions) {
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

        if inventory.contains(.actions) {
            Menu("Actions", systemImage: "play.square.stack") {
                if !automations.isEmpty {
                    Section("One-click destinations") {
                        ForEach(automations) { automation in
                            Button(automation.name) {
                                model.runAutomation(automation, for: clip)
                            }
                        }
                    }
                }
                if !flows.isEmpty {
                    Section("Custom actions") {
                        ForEach(flows) { flow in
                            Button(flow.name) {
                                performFromPersistentLibrary {
                                    model.requestFlowRun(flow, for: clip, presentationSurface: .library)
                                }
                            }
                        }
                    }
                }
                if !automations.isEmpty || !flows.isEmpty {
                    Divider()
                }
                Button("Manage Actions…", systemImage: "gearshape", action: openActions)
            }
        }

        if inventory.contains(.copyAndOpen) {
            Button("Copy & Open…", systemImage: "arrow.up.forward.app") {
                performFromPersistentLibrary {
                    model.presentApplicationBrowser(for: clip, presentationSurface: .library)
                }
            }
            .help("Copy this clip and choose a verified installed app to open; nothing is pasted or submitted")
        }

        if inventory.contains(.sendToCRM) {
            Button("Send to CRM…", systemImage: "building.2") {
                performFromPersistentLibrary {
                    model.presentCRMReview(for: clip)
                }
            }
            .help("Continue in Library to review every field before the CRM write")
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
                    if MenuBarActionPresentationPolicy.debugBundleSurface == .library {
                        openActions()
                    }
                }
                Menu("Add to Project", systemImage: "hammer") {
                    ForEach(model.developerProjects) { project in
                        Button(project.name) {
                            model.addToDeveloperProject(clip, projectID: project.id)
                        }
                    }
                    if !model.developerProjects.isEmpty { Divider() }
                    Button("New Project…", systemImage: "plus") {
                        presentPersistently(.newDeveloperProject(clip))
                    }
                }
                .disabled(!model.canAddToDeveloperProject(clip))
                Button("Add to Paste Stack", systemImage: "square.stack.3d.up") {
                    model.addToPasteStack(clip)
                }
                Divider()
                Button("Open Clip Tools…", systemImage: "rectangle.3.group") {
                    openActions()
                }
            }
        }

        if let action = inventory[.delete] {
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) {
                model.delete(clip)
            }
            .disabled(!action.isEnabled)
            .help(action.disabledReason ?? "Delete this item")
        }
    }

    private var pinActionTitle: String {
        switch clip.origin {
        case .history:
            "Pin & Save"
        case .saved:
            clip.isPinned ? "Unpin" : "Pin"
        case .privateSession:
            "Pin"
        }
    }

    private var canSetShortcut: Bool {
        guard case .saved = clip.origin else { return false }
        return model.insertAliasResults(matching: clip.title).contains { $0.clip.id == clip.id }
    }

    private func openActions() {
        model.openActionsWorkspace(.pasteTools)
        openPersistentLibrary()
    }

    private func openProjects() {
        model.selectLibrarySection(.developerProjects)
        openPersistentLibrary()
    }

    private func revealClipInLibrary() {
        switch clip.origin {
        case .history:
            model.selectLibrarySection(.history)
        case .saved:
            model.selectLibrarySection(.allSaved)
        case .privateSession:
            return
        }
        model.selectedClipID = clip.id
        openPersistentLibrary()
    }

    private func presentPersistently(_ action: MenuBarContinuationRequest.Action) {
        guard libraryPresentationBoundary.request(presentation: {
            model.presentMenuBarContinuation(action)
        }) else {
            model.errorMessage = "The panel could not be opened because the menu-bar window did not close."
            return
        }
    }

    private func performFromPersistentLibrary(
        _ action: @escaping @MainActor @Sendable () -> Void
    ) {
        guard libraryPresentationBoundary.request(presentation: {
            LibraryWindowPresenter.performWhenReady(
                using: openWindow,
                onFailure: { message in model.errorMessage = message },
                action: action
            )
        }) else {
            model.errorMessage = "Library could not be opened because the menu-bar window did not close."
            return
        }
    }

    private func openPersistentLibrary() {
        guard libraryPresentationBoundary.request(presentation: {
            LibraryWindowPresenter.show(using: openWindow) { message in
                model.errorMessage = message
            }
        }) else {
            model.errorMessage = "Library could not be opened because the menu-bar window did not close."
            return
        }
    }

    private var pinSystemImage: String {
        clip.isPinned ? "pin.slash" : "pin"
    }

    private var symbol: String {
        if clip.savedItemKind == .note { return "note.text" }
        return switch clip.content.type {
        case .plainText: "doc.plaintext"
        case .url: "link"
        case .richText: "doc.richtext"
        case .image: "photo"
        case .fileURLs: "doc.on.doc"
        }
    }

    /// The external packaged runner needs to inspect the exact OS-managed board used by the
    /// acceptance process without ever reading or changing the user's General pasteboard.
    /// This value is absent from every production launch because the runtime is double-gated by
    /// bundle identifier and an explicit launch argument.
    private var uiAcceptancePasteboardName: String {
        guard let configuration = UIAcceptanceRuntime.configuration() else { return "" }
        return UIAcceptanceRuntime.pasteboard(for: configuration).name.rawValue
    }
}

struct MenuBarInsertShortcutSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel
    let clip: PresentedClip
    let explicitDismiss: (() -> Void)?

    @State private var abbreviation: String
    @State private var delivery: InsertAliasDelivery

    private var existingAlias: InsertAlias? {
        model.insertAliases.first { $0.savedClipID == clip.id }
    }

    init(model: AppModel, clip: PresentedClip, dismiss: (() -> Void)? = nil) {
        self.model = model
        self.clip = clip
        explicitDismiss = dismiss
        let alias = model.insertAliases.first { $0.savedClipID == clip.id }
        _abbreviation = State(initialValue: alias?.abbreviation ?? "")
        _delivery = State(initialValue: alias?.delivery ?? .copy)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set Shortcut")
                .font(.title2.weight(.semibold))
            Text("Use an abbreviation to find \(clip.title) quickly in Quick Paste.")
                .foregroundStyle(.secondary)
                .lineLimit(2)

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

            Text("Shortcuts work only inside Quick Paste. Clipboard Router never monitors everything you type.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                if let existingAlias {
                    Button("Remove Shortcut", role: .destructive) {
                        model.removeInsertAlias(existingAlias)
                        close()
                    }
                }
                Spacer()
                Button("Cancel") { close() }
                    .keyboardShortcut(.cancelAction)
                Button("Save Shortcut") {
                    if model.saveInsertAlias(
                        for: clip,
                        abbreviation: abbreviation,
                        delivery: delivery
                    ) {
                        close()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(InsertAlias.normalize(abbreviation).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 430)
    }

    private func close() {
        if let explicitDismiss {
            explicitDismiss()
        } else {
            dismiss()
        }
    }
}

struct MenuBarNewFolderSheet: View {
    let create: (String) -> Void
    let explicitDismiss: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    init(dismiss: (() -> Void)? = nil, create: @escaping (String) -> Void) {
        explicitDismiss = dismiss
        self.create = create
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Folder").font(.title2.weight(.semibold))
            Text("Create a folder and save this clip inside it.")
                .foregroundStyle(.secondary)
            TextField("Folder name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
            HStack {
                Spacer()
                Button("Cancel") { close() }
                Button("Create & Save", action: submit)
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 400)
    }

    private func submit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        create(trimmed)
    }

    private func close() {
        if let explicitDismiss {
            explicitDismiss()
        } else {
            dismiss()
        }
    }
}

/// Keeps menu-bar previews inside the ordinary local library boundary.
/// Vault items have no `PresentedClip` origin and Private Session clips must remain memory-only.
enum MenuBarHoverPreviewPolicy {
    static func allowsPreview(
        for clip: PresentedClip,
        isSensitive: Bool = false
    ) -> Bool {
        clip.origin != .privateSession && clip.sensitivity == nil && !isSensitive
    }
}

struct MenuBarHoverPreviewDescriptor: Equatable {
    let title: String
    let contentTypeName: String
    let text: String
    let fileNames: [String]
    let imageMetadata: String?
    let hasThumbnail: Bool

    init(clip: PresentedClip) {
        title = clip.title
        contentTypeName = Self.name(for: clip.content.type)
        text = clip.content.text
        fileNames = clip.content.representations.files.map(\.displayName)
        imageMetadata = clip.content.representations.imageMetadata.map {
            "\($0.pixelWidth) × \($0.pixelHeight) · \($0.format)"
        }
        hasThumbnail = clip.content.representations.thumbnail != nil
    }

    private static func name(for type: SupportedContentType) -> String {
        switch type {
        case .plainText: "Plain text"
        case .url: "Web address"
        case .richText: "Rich text"
        case .image: "Image"
        case .fileURLs: "Files"
        }
    }
}

private struct MenuBarClipHoverPreview: View {
    let clip: PresentedClip
    let descriptor: MenuBarHoverPreviewDescriptor
    let thumbnailLoader: ClipThumbnailLoader
    let onHover: (Bool) -> Void

    init(
        clip: PresentedClip,
        descriptor: MenuBarHoverPreviewDescriptor,
        thumbnailLoader: ClipThumbnailLoader,
        onHover: @escaping (Bool) -> Void
    ) {
        self.clip = clip
        self.descriptor = descriptor
        self.thumbnailLoader = thumbnailLoader
        self.onHover = onHover
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(descriptor.title)
                        .font(.headline)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Text(descriptor.contentTypeName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if descriptor.hasThumbnail,
                   let thumbnail = clip.content.representations.thumbnail
                {
                    ClipThumbnailView(
                        reference: thumbnail,
                        loader: thumbnailLoader,
                        contentMode: .fit,
                        accessibilityLabel: "Preview image for \(descriptor.title)"
                    )
                    .frame(maxWidth: .infinity)
                    .frame(height: 180)
                }

                if let imageMetadata = descriptor.imageMetadata {
                    Label(imageMetadata, systemImage: "photo")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !descriptor.fileNames.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Files").font(.caption.weight(.semibold))
                        ForEach(Array(descriptor.fileNames.enumerated()), id: \.offset) { _, name in
                            Label(name, systemImage: "doc")
                                .font(.callout)
                                .textSelection(.enabled)
                        }
                    }
                }

                MenuBarClipPreviewTextView(text: descriptor.text)
                    .frame(maxWidth: .infinity)
                    .frame(height: 132)
                    .accessibilityLabel("Full stored content for \(descriptor.title)")
            }
            .padding(14)
        }
        .frame(width: 360, height: 280)
        .onHover(perform: onHover)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Preview of \(descriptor.title)")
        .accessibilityHint("Full stored clip content. Text can be selected and copied.")
    }
}

private struct MenuBarHoverPreviewAccessibilityAction: ViewModifier {
    let isEnabled: Bool
    let action: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.accessibilityAction(named: "Show full clip preview", action)
        } else {
            content
        }
    }
}

/// A TextKit-backed text surface prevents very large stored clips from being laid out as a
/// single SwiftUI `Text` while retaining the full, local content for selection and scrolling.
private struct MenuBarClipPreviewTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.drawsBackground = false

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 7, height: 7)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 1,
            height: CGFloat.greatestFiniteMagnitude
        )
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView,
              textView.string != text
        else { return }
        textView.string = text
    }
}
