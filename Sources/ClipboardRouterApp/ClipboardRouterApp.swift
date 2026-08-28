import AppKit
import CloudKit
import ClipboardRouterPlatform
import SwiftUI

@main
struct ClipboardRouterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model: AppModel

    init() {
        _model = StateObject(wrappedValue: AppDelegate.sharedModel)
    }

    var body: some Scene {
        Window("Clipboard Router", id: "library") {
            LibrarySceneRoot(model: model) { openLibrary in
                appDelegate.registerLibrarySceneReopen(openLibrary)
            }
                // The floor is the sum of the three column minimums (240 + 240 + 300) plus
                // dividers. A larger hard minimum than the layout actually needs prevents the
                // window from fitting a small or scaled display at all.
                .frame(
                    minWidth: 800,
                    idealWidth: 1_040,
                    minHeight: 520,
                    idealHeight: 660
                )
        }
        .defaultSize(width: 1_040, height: 660)
        .commands {
            CommandGroup(after: .newItem) {
                Button(model.isCaptureActive ? "Pause Clipboard Capture" : "Resume Clipboard Capture") {
                    model.toggleCapture()
                }
                .keyboardShortcut("p", modifiers: [.command, .option])
            }

            CommandGroup(after: .saveItem) {
                Button("Export Saved Library…") {
                    model.exportSavedLibrary()
                }
                .disabled(model.snapshot.savedClips.isEmpty)
            }

            CommandMenu("Clip") {
                Button("Copy Selected Clip") {
                    if let clip = model.selectedClip { model.copy(clip) }
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(model.selectedClip == nil)

                Button("Search Clips and Metadata") {
                    model.focusLibrarySearch()
                }
                .keyboardShortcut("k", modifiers: .command)

                Button("Pin or Unpin Selected Item") {
                    model.toggleSelectedPin()
                }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(model.selectedClip == nil)

                Button("Create Note") {
                    model.requestCreateNote()
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])

                Button("Open Quick Paste") {
                    model.requestInsertPalette()
                }

                Divider()
                ForEach(0..<9, id: \.self) { index in
                    Button("Open Pinned Note \(index + 1)") {
                        model.selectPinnedNote(at: index)
                    }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                    .disabled(model.pinnedNoteCount <= index)
                }

                Button("Copy & Open in Preferred App") {
                    model.routeSelectedToPreferredDestination()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!model.canRouteSelectedClipToAI)
            }
        }

        MenuBarExtra {
            MenuBarSceneRoot(model: model) { openLibrary in
                appDelegate.registerLibraryReopen(openLibrary)
            }
        } label: {
            Label("Clipboard Router", systemImage: model.isCaptureActive ? "clipboard" : "pause.circle")
                .accessibilityLabel(model.isCaptureActive ? "Clipboard Router, capturing" : "Clipboard Router, paused")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
                .frame(
                    minWidth: 680,
                    idealWidth: 760,
                    maxWidth: .infinity,
                    minHeight: 560,
                    idealHeight: 640,
                    maxHeight: .infinity
                )
        }
    }
}

/// Registers SwiftUI's scene opener from the menu-bar surface itself. This is available before
/// Library has ever existed, allowing a successful cold-launch continuation to recreate Library
/// through the same bridge used by Dock reopen.
private struct MenuBarSceneRoot: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var model: AppModel
    let registerReopen: (@escaping @MainActor () -> Void) -> Void

    var body: some View {
        MenuBarView(model: model)
            .onAppear {
                registerReopen {
                    openWindow(id: LibraryWindowPresenter.libraryWindowIdentifier)
                }
            }
    }
}

private struct LibrarySceneRoot: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var model: AppModel
    let registerReopen: (@escaping @MainActor () -> Void) -> Void

    var body: some View {
        MainWindowView(model: model)
            .onAppear {
                registerReopen {
                    openWindow(id: LibraryWindowPresenter.libraryWindowIdentifier)
                }
                clampToVisibleFrame()
            }
    }

    /// A restored frame from a larger display, or a default size on a small one, can place the
    /// window partly off the visible desktop. Shrink to fit and nudge back on screen without
    /// moving a window that already fits.
    private func clampToVisibleFrame() {
        DispatchQueue.main.async {
            guard let window = NSApp.windows.first(where: {
                $0.identifier?.rawValue == LibraryWindowPresenter.libraryWindowIdentifier
                    || $0.isKeyWindow
            }) else { return }
            guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
            var frame = window.frame
            guard !visible.contains(frame) else { return }
            frame.size.width = min(frame.width, visible.width)
            frame.size.height = min(frame.height, visible.height)
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
            window.setFrame(frame, display: true)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let sharedModel = UIAcceptanceRuntime.makeModelIfEnabled() ?? AppModel()
    private weak var model: AppModel?
    private var pendingShareMetadata: [CKShare.Metadata] = []
    private var pendingRemoteNotifications: [[String: Any]] = []
    private var pendingRemoteRegistrationError: (any Error)?
    private var didRegisterForRemoteNotifications = false
    private var pendingCRMCallbackURLs: [URL] = []
    private let libraryReopenBridge = LibraryWindowReopenBridge()
    private var menuBarContinuationWindowController: MenuBarContinuationWindowController?

    func registerLibraryReopen(_ openLibrary: @escaping @MainActor () -> Void) {
        libraryReopenBridge.register(openLibrary: openLibrary)
    }

    func registerLibrarySceneReopen(_ openLibrary: @escaping @MainActor () -> Void) {
        libraryReopenBridge.registerSceneFallback(openLibrary: openLibrary)
    }

    func connect(model: AppModel) {
        let needsContinuationPresenter = self.model !== model
            || menuBarContinuationWindowController == nil
        self.model = model
        if needsContinuationPresenter {
            menuBarContinuationWindowController?.dismiss()
            let controller = MenuBarContinuationWindowController(
                model: model,
                revealLibrary: { [weak self] in
                    self?.revealLibraryAfterSuccessfulContinuation()
                }
            )
            menuBarContinuationWindowController = controller
            model.registerMenuBarContinuationPresenter(controller)
        }
        let pending = pendingShareMetadata
        pendingShareMetadata.removeAll()
        for metadata in pending {
            model.acceptCloudKitShare(metadata)
        }
        if didRegisterForRemoteNotifications {
            model.noteCloudPushRegistrationSucceeded()
        } else if let pendingRemoteRegistrationError {
            model.noteCloudPushRegistrationFailure(pendingRemoteRegistrationError)
        }
        let notifications = pendingRemoteNotifications
        pendingRemoteNotifications.removeAll()
        for userInfo in notifications {
            Task { @MainActor in
                _ = await model.receiveCloudKitRemoteNotification(userInfo)
            }
        }
        let callbacks = pendingCRMCallbackURLs
        pendingCRMCallbackURLs.removeAll()
        callbacks.forEach(model.handleCRMOAuthCallback)
    }

    private func revealLibraryAfterSuccessfulContinuation() {
        _ = libraryReopenBridge.reopen { [weak model] message in
            model?.errorMessage = message
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let model = Self.sharedModel
        connect(model: model)
        Task { @MainActor in
            await model.start()
            guard UIAcceptanceRuntime.configuration() != nil, model.isReady else { return }
            FileHandle.standardError.write(Data("UI_ACCEPTANCE_READY\n".utf8))
        }
    }

    func application(
        _ application: NSApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        didRegisterForRemoteNotifications = true
        pendingRemoteRegistrationError = nil
        model?.noteCloudPushRegistrationSucceeded()
    }

    func application(
        _ application: NSApplication,
        didFailToRegisterForRemoteNotificationsWithError error: any Error
    ) {
        didRegisterForRemoteNotifications = false
        pendingRemoteRegistrationError = error
        model?.noteCloudPushRegistrationFailure(error)
    }

    func application(
        _ application: NSApplication,
        didReceiveRemoteNotification userInfo: [String: Any]
    ) {
        guard let model else {
            pendingRemoteNotifications.append(userInfo)
            return
        }
        Task { @MainActor in
            _ = await model.receiveCloudKitRemoteNotification(userInfo)
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        logAcceptanceLifecycle("applicationShouldHandleReopen visible=\(flag)")
        if !flag {
            libraryReopenBridge.reopen { [weak self] message in
                self?.model?.errorMessage = message
            }
        }
        return true
    }

    /// A directly launched menu-bar process can be activated from its exact Dock tile without
    /// AppKit delivering `applicationShouldHandleReopen` after the last SwiftUI scene window was
    /// destroyed. Treat that real activation as the same user intent, but only after Library has
    /// promoted the app to a regular Dock application and no titled window is already visible.
    func applicationDidBecomeActive(_ notification: Notification) {
        logAcceptanceLifecycle("applicationDidBecomeActive")
        guard NSApp.activationPolicy() == .regular,
              !NSApp.windows.contains(where: {
                  $0.isVisible && $0.styleMask.contains(.titled)
              })
        else { return }
        libraryReopenBridge.reopen { [weak self] message in
            self?.model?.errorMessage = message
        }
    }

    func applicationDidResignActive(_ notification: Notification) {
        logAcceptanceLifecycle("applicationDidResignActive")
    }

    private func logAcceptanceLifecycle(_ event: String) {
        guard UIAcceptanceRuntime.configuration() != nil else { return }
        let visibleTitled = NSApp.windows.filter {
            $0.isVisible && $0.styleMask.contains(.titled)
        }.count
        let line = "UI_ACCEPTANCE_LIFECYCLE \(event) policy=\(NSApp.activationPolicy().rawValue) "
            + "windows=\(NSApp.windows.count) visibleTitled=\(visibleTitled)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme?.lowercased() == "clipboardrouter" {
            if let model {
                model.handleCRMOAuthCallback(url)
            } else {
                pendingCRMCallbackURLs.append(url)
            }
        }
        application.activate(ignoringOtherApps: true)
    }

    func application(
        _ application: NSApplication,
        userDidAcceptCloudKitShareWith metadata: CKShare.Metadata
    ) {
        if let model {
            model.acceptCloudKitShare(metadata)
        } else {
            // macOS may deliver metadata during relaunch before SwiftUI constructs the model.
            pendingShareMetadata.append(metadata)
        }
        application.activate(ignoringOtherApps: true)
    }
}
