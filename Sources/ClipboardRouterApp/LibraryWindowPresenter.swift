import AppKit
import SwiftUI

@MainActor
protocol LibraryWindowPresentingWindow: AnyObject {
    var identifierValue: String? { get }
    var title: String { get }
    var isTitled: Bool { get }
    var canBecomeKey: Bool { get }
    var isKeyWindow: Bool { get }
    var isVisible: Bool { get }
    var isMiniaturized: Bool { get }

    func deminiaturize()
    func makeKeyAndOrderFront()
    func orderFrontRegardless()
}

@MainActor
protocol LibraryWindowPresentingApplication: AnyObject {
    var activationPolicy: NSApplication.ActivationPolicy { get }
    var windows: [any LibraryWindowPresentingWindow] { get }

    @discardableResult
    func setActivationPolicy(_ policy: NSApplication.ActivationPolicy) -> Bool
    func unhide()
    func activate()
}

@MainActor
private final class SystemLibraryWindow: LibraryWindowPresentingWindow {
    private let window: NSWindow

    init(window: NSWindow) {
        self.window = window
    }

    var identifierValue: String? { window.identifier?.rawValue }
    var title: String { window.title }
    var isTitled: Bool { window.styleMask.contains(.titled) }
    var canBecomeKey: Bool { window.canBecomeKey }
    var isKeyWindow: Bool { window.isKeyWindow }
    var isVisible: Bool { window.isVisible }
    var isMiniaturized: Bool { window.isMiniaturized }

    func deminiaturize() { window.deminiaturize(nil) }
    func makeKeyAndOrderFront() { window.makeKeyAndOrderFront(nil) }
    func orderFrontRegardless() { window.orderFrontRegardless() }
}

@MainActor
private final class SystemLibraryApplication: LibraryWindowPresentingApplication {
    private let application: NSApplication

    init(application: NSApplication = NSApp) {
        self.application = application
    }

    var activationPolicy: NSApplication.ActivationPolicy {
        application.activationPolicy()
    }

    var windows: [any LibraryWindowPresentingWindow] {
        application.windows.map(SystemLibraryWindow.init)
    }

    func setActivationPolicy(_ policy: NSApplication.ActivationPolicy) -> Bool {
        application.setActivationPolicy(policy)
    }

    func unhide() { application.unhide(nil) }

    func activate() {
        application.activate(ignoringOtherApps: true)
    }
}

/// Owns the transition from Clipboard Router's quiet menu-bar launch to its persistent desktop
/// Library. The app intentionally remains `.regular` after this succeeds, so closing Library does
/// not make Clipboard Router disappear from the Dock until the user quits it.
@MainActor
enum LibraryWindowPresenter {
    static let activationPolicy: NSApplication.ActivationPolicy = .regular
    static let libraryWindowIdentifier = "library"
    // A cold SwiftUI scene can take multiple seconds to create its first NSWindow. Keep the
    // continuation alive long enough for that launch, while remaining bounded and cancellable.
    static let maximumRaiseAttempts = 80
    static let raiseRetryDelay: Duration = .milliseconds(60)
    static let presentationFailureMessage =
        "Library could not be opened as a desktop window. Clipboard capture is still available from the menu bar."

    typealias Sleeper = @MainActor (Duration) async -> Void
    private static var pendingPresentation: Task<Bool, Never>?

    /// SwiftUI entry point. The returned task owns the follow-up after a MenuBarExtra closes.
    @discardableResult
    static func show(
        using openWindow: OpenWindowAction,
        onFailure: @escaping @MainActor (String) -> Void
    ) -> Task<Bool, Never> {
        show(
            openLibrary: { openWindow(id: libraryWindowIdentifier) },
            application: SystemLibraryApplication(),
            sleeper: defaultSleeper,
            onFailure: onFailure
        )
    }

    @discardableResult
    static func show(
        openLibrary: @escaping @MainActor () -> Void,
        application: any LibraryWindowPresentingApplication,
        sleeper: @escaping Sleeper = defaultSleeper,
        onFailure: @escaping @MainActor (String) -> Void
    ) -> Task<Bool, Never> {
        if let pendingPresentation { return pendingPresentation }
        let task = Task { @MainActor in
            let didPresent = await present(
                openLibrary: openLibrary,
                application: application,
                sleeper: sleeper
            )
            if !didPresent && !Task.isCancelled { onFailure(presentationFailureMessage) }
            pendingPresentation = nil
            return didPresent
        }
        pendingPresentation = task
        return task
    }

    /// Presents Library and runs a continuation only after its window is key. The returned task
    /// can be cancelled by the caller without cancelling a coalesced presentation requested by
    /// another surface; cancellation only suppresses this continuation.
    @discardableResult
    static func performWhenReady(
        using openWindow: OpenWindowAction,
        onFailure: @escaping @MainActor (String) -> Void,
        action: @escaping @MainActor @Sendable () -> Void
    ) -> Task<Void, Never> {
        performWhenReady(
            openLibrary: { openWindow(id: libraryWindowIdentifier) },
            application: SystemLibraryApplication(),
            sleeper: defaultSleeper,
            onFailure: onFailure,
            action: action
        )
    }

    @discardableResult
    static func performWhenReady(
        openLibrary: @escaping @MainActor () -> Void,
        application: any LibraryWindowPresentingApplication,
        sleeper: @escaping Sleeper = defaultSleeper,
        onFailure: @escaping @MainActor (String) -> Void,
        action: @escaping @MainActor @Sendable () -> Void
    ) -> Task<Void, Never> {
        let presentation = show(
            openLibrary: openLibrary,
            application: application,
            sleeper: sleeper,
            onFailure: onFailure
        )
        return Task { @MainActor in
            let isReady = await presentation.value
            guard isReady, !Task.isCancelled else { return }
            action()
        }
    }

    /// Testable presentation core. It never opens a second Library when an existing closed,
    /// minimized, or background Library window can be raised.
    static func present(
        openLibrary: @escaping @MainActor () -> Void,
        application: any LibraryWindowPresentingApplication,
        retryAttempts: Int = maximumRaiseAttempts,
        sleeper: @escaping Sleeper = defaultSleeper
    ) async -> Bool {
        if application.activationPolicy != activationPolicy {
            let accepted = application.setActivationPolicy(activationPolicy)
            guard accepted || application.activationPolicy == activationPolicy else {
                return false
            }
        }

        let initialState = raiseLibraryWindow(application: application)
        if initialState == .ready {
            return true
        }

        if initialState == .missing {
            openLibrary()
        }
        let attempts = max(1, retryAttempts)
        for attempt in 0..<attempts {
            guard !Task.isCancelled else { return false }
            if raiseLibraryWindow(application: application) == .ready {
                return true
            }
            if attempt < attempts - 1 {
                await sleeper(raiseRetryDelay)
                guard !Task.isCancelled else { return false }
            }
        }
        return false
    }

    /// Used by AppKit's Dock-reopen callback after Library has already promoted the app.
    @discardableResult
    static func revealExistingLibraryWindow(
        application: any LibraryWindowPresentingApplication = SystemLibraryApplication()
    ) -> Bool {
        raiseLibraryWindow(application: application) != .missing
    }

    private enum LibraryWindowReadiness: Equatable {
        case missing
        case waitingForKey
        case ready
    }

    private static func raiseLibraryWindow(
        application: any LibraryWindowPresentingApplication
    ) -> LibraryWindowReadiness {
        guard let window = libraryWindow(in: application.windows) else { return .missing }

        application.unhide()
        // SwiftUI can retain the destroyed scene's NSWindow after the user closes its last
        // window. It still has the Library identifier and can become key in principle, but
        // ordering it front is a no-op. Treat that retained, ordered-out window as missing so
        // the persistent scene opener can recreate Library. Minimized windows remain visible
        // to AppKit and continue through the normal deminiaturize path.
        guard window.isVisible || window.isMiniaturized else { return .missing }
        application.activate()
        if window.isMiniaturized { window.deminiaturize() }
        window.makeKeyAndOrderFront()
        window.orderFrontRegardless()
        return window.isKeyWindow ? .ready : .waitingForKey
    }

    private static func libraryWindow(
        in windows: [any LibraryWindowPresentingWindow]
    ) -> (any LibraryWindowPresentingWindow)? {
        windows.first(where: { $0.identifierValue == libraryWindowIdentifier })
            ?? windows.first(where: {
                $0.title == "Clipboard Router" && $0.isTitled && $0.canBecomeKey
            })
    }

    private static func defaultSleeper(_ duration: Duration) async {
        try? await Task.sleep(for: duration)
    }
}

/// Keeps SwiftUI's scene-opening capability available to AppKit after the Library scene has been
/// closed and its last NSWindow has been destroyed. The persistent menu-bar scene owns the primary
/// opener; Dock/App Switcher reopen can then recreate Library without fabricating a parallel
/// AppKit window hierarchy.
@MainActor
final class LibraryWindowReopenBridge {
    private var persistentOpenLibrary: (@MainActor () -> Void)?
    private var sceneFallbackOpenLibrary: (@MainActor () -> Void)?

    /// Registers the opener owned by the persistent menu-bar scene. Once available, this must
    /// remain authoritative because a Library scene's environment action becomes inert when its
    /// last window is closed.
    func register(openLibrary: @escaping @MainActor () -> Void) {
        persistentOpenLibrary = openLibrary
    }

    /// Keeps cold-start/library-only construction testable without allowing a short-lived
    /// Library scene to replace the persistent menu-bar opener.
    func registerSceneFallback(openLibrary: @escaping @MainActor () -> Void) {
        sceneFallbackOpenLibrary = openLibrary
    }

    @discardableResult
    func reopen(
        application: any LibraryWindowPresentingApplication,
        sleeper: @escaping LibraryWindowPresenter.Sleeper,
        onFailure: @escaping @MainActor (String) -> Void
    ) -> Task<Bool, Never>? {
        if LibraryWindowPresenter.revealExistingLibraryWindow(application: application) {
            return nil
        }
        guard let openLibrary = persistentOpenLibrary ?? sceneFallbackOpenLibrary else {
            // A login-item/menu-bar launch can receive a Dock/Finder reopen before SwiftUI has
            // ever materialized the Library scene and supplied an OpenWindowAction. Nothing has
            // failed in that state, so do not show the presentation-failure message. The menu-bar
            // Open Library action will register the scene opener when the Library first appears.
            return nil
        }
        return LibraryWindowPresenter.show(
            openLibrary: openLibrary,
            application: application,
            sleeper: sleeper,
            onFailure: onFailure
        )
    }

    @discardableResult
    func reopen(
        onFailure: @escaping @MainActor (String) -> Void
    ) -> Task<Bool, Never>? {
        reopen(
            application: SystemLibraryApplication(),
            sleeper: { duration in try? await Task.sleep(for: duration) },
            onFailure: onFailure
        )
    }
}
