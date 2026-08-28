import AppKit
import SwiftUI

/// The narrow presentation seam used by `AppModel`.
///
/// `AppModel` deliberately does not retain the presenter. The AppKit application delegate owns
/// the window controller and the controller owns the active request for exactly as long as its
/// normal window is open.
@MainActor
protocol MenuBarContinuationPresenting: AnyObject {
    @discardableResult
    func present(_ action: MenuBarContinuationRequest.Action) -> Bool

    func dismiss()
}

/// A persistent, ordinary AppKit window for work started from the transient menu-bar surface.
///
/// This window is intentionally independent from the Library scene. In particular, creating a
/// note, editing a clip, or using AI never cold-opens the Library just to obtain a sheet anchor.
@MainActor
final class MenuBarContinuationWindowController: NSWindowController,
    NSWindowDelegate,
    MenuBarContinuationPresenting
{
    static let accessibilityIdentifier = "uiAcceptance.menuBarContinuation.window"

    typealias HostingControllerFactory = @MainActor (AnyView) -> NSViewController
    typealias WindowFactory = @MainActor (NSViewController) -> NSWindow
    typealias WindowShower = @MainActor (NSWindow) -> Void

    private let model: AppModel
    private let hostingControllerFactory: HostingControllerFactory
    private let windowFactory: WindowFactory
    private let windowShower: WindowShower
    private let revealLibrary: @MainActor () -> Void
    private(set) var activeRequest: MenuBarContinuationRequest?

    init(
        model: AppModel,
        hostingControllerFactory: @escaping HostingControllerFactory = {
            NSHostingController(rootView: $0)
        },
        windowFactory: @escaping WindowFactory = MenuBarContinuationWindowController.makeWindow,
        windowShower: @escaping WindowShower = MenuBarContinuationWindowController.showWindow,
        revealLibrary: @escaping @MainActor () -> Void = {}
    ) {
        self.model = model
        self.hostingControllerFactory = hostingControllerFactory
        self.windowFactory = windowFactory
        self.windowShower = windowShower
        self.revealLibrary = revealLibrary
        super.init(window: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @discardableResult
    func present(_ action: MenuBarContinuationRequest.Action) -> Bool {
        guard activeRequest == nil else { return false }

        let request = MenuBarContinuationRequest(action: action)
        activeRequest = request

        let root = AnyView(
            MenuBarContinuationWindowRoot(
                model: model,
                request: request,
                dismiss: { [weak self] in self?.dismiss() },
                revealLibraryAfterSuccess: { [weak self] in
                    self?.completeAndRevealLibrary()
                }
            )
        )
        let hostingController = hostingControllerFactory(root)
        let continuationWindow = windowFactory(hostingController)
        configure(continuationWindow, for: request)

        // Assign the fully-rooted window before it is made visible. This prevents a blank or
        // transiently unowned AppKit surface during the menu's dismissal turn.
        window = continuationWindow
        continuationWindow.delegate = self
        windowShower(continuationWindow)
        return true
    }

    func dismiss() {
        guard let window else {
            activeRequest = nil
            return
        }
        window.close()
        // `NSWindowDelegate.windowWillClose` is synchronous for ordinary close requests, but
        // clear defensively for injected test windows and unusual AppKit subclasses.
        if activeRequest != nil {
            clearSession(for: window)
        }
    }

    /// Completes an editor continuation in a strict order: first close and clear the dedicated
    /// window session, then ask the existing Library reopen bridge to reveal the saved result.
    func completeAndRevealLibrary() {
        guard activeRequest != nil else { return }
        dismiss()
        revealLibrary()
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow,
              closingWindow === window
        else { return }
        clearSession(for: closingWindow)
    }

    private func configure(_ window: NSWindow, for request: MenuBarContinuationRequest) {
        window.identifier = NSUserInterfaceItemIdentifier(Self.accessibilityIdentifier)
        window.setAccessibilityIdentifier(Self.accessibilityIdentifier)
        window.title = request.windowTitle
        window.level = .normal
        window.isReleasedWhenClosed = false
        window.collectionBehavior.remove(.transient)
        window.collectionBehavior.insert(.managed)
        window.setFrameAutosaveName("ClipboardRouter.MenuBarContinuation")
        window.center()
    }

    private func clearSession(for closingWindow: NSWindow) {
        guard closingWindow === window else { return }
        closingWindow.delegate = nil
        // Detach the old SwiftUI accessibility tree before this controller accepts another
        // request. AppKit can retain a recently-closed NSWindow long enough for AX clients to
        // observe it; leaving its hosting controller attached made a subsequent Edit window
        // expose the prior New Note descendants despite the new window title.
        closingWindow.contentViewController = nil
        activeRequest = nil
        window = nil
    }

    private static func makeWindow(rootViewController: NSViewController) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = rootViewController
        window.minSize = NSSize(width: 520, height: 360)
        return window
    }

    private static func showWindow(_ window: NSWindow) {
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}

private struct MenuBarContinuationWindowRoot: View {
    @ObservedObject var model: AppModel
    let request: MenuBarContinuationRequest
    let dismiss: () -> Void
    let revealLibraryAfterSuccess: () -> Void

    var body: some View {
        MenuBarContinuationSheet(
            model: model,
            request: request,
            dismiss: dismiss,
            revealLibraryAfterSuccess: revealLibraryAfterSuccess
        )
        .id(request.id)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
            .alert(
                "Clipboard Router",
                isPresented: Binding(
                    get: { model.errorMessage != nil },
                    set: { if !$0 { model.errorMessage = nil } }
                )
            ) {
                Button("OK") { model.errorMessage = nil }
            } message: {
                Text(model.errorMessage ?? "An unknown error occurred.")
            }
    }
}

private extension MenuBarContinuationRequest {
    var windowTitle: String {
        switch action {
        case .quickPaste: "Quick Paste"
        case let .noteEditor(request):
            switch request.mode {
            case .create: "New Note"
            case .makeFromClip: "Make an Editable Note"
            case .edit: "Edit Note"
            }
        case .clipEditor: "Edit Clip"
        case .calendar: "Add to Calendar"
        case .newFolder: "New Folder"
        case .vaultMove: "Move to Vault"
        case .shortcutEditor: "Set Insert Shortcut"
        case .encryptedShare: "Encrypted Share"
        case .sensitiveExport: "Export Sensitive Clip"
        case .newDeveloperProject: "New Developer Project"
        case .assistant: "Use AI"
        case .contact: "Save to Contacts"
        }
    }
}
