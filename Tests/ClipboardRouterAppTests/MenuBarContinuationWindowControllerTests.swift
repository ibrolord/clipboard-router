import AppKit
import ClipboardRouterCore
import ClipboardRouterPlatform
import SwiftUI
import XCTest
@testable import ClipboardRouterApp

@MainActor
final class MenuBarContinuationWindowControllerTests: XCTestCase {
    func testRootIsInstalledBeforeWindowIsShown() throws {
        let model = makeModel()
        var events: [String] = []
        var shownWindow: NSWindow?
        let presenter = MenuBarContinuationWindowController(
            model: model,
            hostingControllerFactory: { _ in
                events.append("root-created")
                return NSViewController()
            },
            windowFactory: { root in
                events.append("window-created")
                let window = Self.makeWindow()
                window.contentViewController = root
                return window
            },
            windowShower: { window in
                XCTAssertNotNil(window.contentViewController)
                events.append("window-shown")
                shownWindow = window
            }
        )

        XCTAssertTrue(presenter.present(.quickPaste))

        XCTAssertEqual(events, ["root-created", "window-created", "window-shown"])
        let window = try XCTUnwrap(shownWindow)
        XCTAssertEqual(
            window.identifier?.rawValue,
            MenuBarContinuationWindowController.accessibilityIdentifier
        )
        XCTAssertEqual(
            window.accessibilityIdentifier(),
            MenuBarContinuationWindowController.accessibilityIdentifier
        )
    }

    func testOneNormalWindowRejectsSecondRequestWithoutReplacingFirst() throws {
        let model = makeModel()
        var createdWindows: [NSWindow] = []
        var showCount = 0
        let presenter = MenuBarContinuationWindowController(
            model: model,
            hostingControllerFactory: { _ in NSViewController() },
            windowFactory: { root in
                let window = Self.makeWindow()
                window.contentViewController = root
                createdWindows.append(window)
                return window
            },
            windowShower: { _ in showCount += 1 }
        )

        XCTAssertTrue(presenter.present(.quickPaste))
        let firstRequestID = try XCTUnwrap(presenter.activeRequest?.id)
        XCTAssertFalse(
            presenter.present(.noteEditor(NoteEditorRequest(mode: .create)))
        )

        XCTAssertEqual(createdWindows.count, 1)
        XCTAssertEqual(showCount, 1)
        XCTAssertEqual(createdWindows[0].level, .normal)
        XCTAssertEqual(presenter.activeRequest?.id, firstRequestID)
    }

    func testCloseClearsSessionAndAllowsNextRequest() {
        let model = makeModel()
        var createdWindowCount = 0
        let presenter = MenuBarContinuationWindowController(
            model: model,
            hostingControllerFactory: { _ in NSViewController() },
            windowFactory: { root in
                createdWindowCount += 1
                let window = Self.makeWindow()
                window.contentViewController = root
                return window
            },
            windowShower: { _ in }
        )

        XCTAssertTrue(presenter.present(.quickPaste))
        XCTAssertNotNil(presenter.activeRequest)

        presenter.dismiss()

        XCTAssertNil(presenter.activeRequest)
        XCTAssertNil(presenter.window)
        XCTAssertTrue(
            presenter.present(.noteEditor(NoteEditorRequest(mode: .create)))
        )
        XCTAssertEqual(createdWindowCount, 2)
    }

    func testModelCancelDismissesPresenterWithoutOpeningLibrary() {
        let model = makeModel()
        var libraryOpenCount = 0
        var showCount = 0
        let presenter = MenuBarContinuationWindowController(
            model: model,
            hostingControllerFactory: { _ in NSViewController() },
            windowFactory: { root in
                let window = Self.makeWindow()
                window.contentViewController = root
                return window
            },
            windowShower: { _ in showCount += 1 }
        )
        model.registerMenuBarContinuationPresenter(presenter)
        let unusedLibraryOpener = { libraryOpenCount += 1 }

        model.presentMenuBarContinuation(.quickPaste)
        model.dismissMenuBarContinuation()

        withExtendedLifetime(unusedLibraryOpener) {}
        XCTAssertEqual(showCount, 1)
        XCTAssertEqual(libraryOpenCount, 0)
        XCTAssertNil(presenter.activeRequest)
    }

    func testSuccessfulEditorCompletionClosesThenRevealsLibraryExactlyOnce() {
        let model = makeModel()
        var events: [String] = []
        var presenter: MenuBarContinuationWindowController!
        presenter = MenuBarContinuationWindowController(
            model: model,
            hostingControllerFactory: { _ in NSViewController() },
            windowFactory: { root in
                let window = Self.makeWindow()
                window.contentViewController = root
                return window
            },
            windowShower: { _ in events.append("continuation-shown") },
            revealLibrary: {
                XCTAssertNil(presenter.activeRequest)
                XCTAssertNil(presenter.window)
                events.append("library-revealed")
            }
        )

        XCTAssertTrue(
            presenter.present(.noteEditor(NoteEditorRequest(mode: .create)))
        )
        presenter.completeAndRevealLibrary()
        presenter.completeAndRevealLibrary()

        XCTAssertEqual(events, ["continuation-shown", "library-revealed"])
    }

    func testCancelClosesWithoutRevealingLibrary() {
        let model = makeModel()
        var revealCount = 0
        let presenter = MenuBarContinuationWindowController(
            model: model,
            hostingControllerFactory: { _ in NSViewController() },
            windowFactory: { root in
                let window = Self.makeWindow()
                window.contentViewController = root
                return window
            },
            windowShower: { _ in },
            revealLibrary: { revealCount += 1 }
        )

        XCTAssertTrue(
            presenter.present(.noteEditor(NoteEditorRequest(mode: .create)))
        )
        presenter.dismiss()

        XCTAssertNil(presenter.activeRequest)
        XCTAssertEqual(revealCount, 0)
    }

    func testConsecutiveDifferentActionsReplaceHostedChildContent() throws {
        let model = makeModel()
        let presenter = MenuBarContinuationWindowController(
            model: model,
            windowFactory: { root in
                let window = Self.makeWindow()
                window.contentViewController = root
                return window
            },
            windowShower: { _ in }
        )

        XCTAssertTrue(
            presenter.present(.noteEditor(NoteEditorRequest(mode: .create)))
        )
        let noteWindow = try XCTUnwrap(presenter.window)
        let noteController = try XCTUnwrap(noteWindow.contentViewController)
        let noteRoot = noteController.view
        noteRoot.layoutSubtreeIfNeeded()
        guard case .noteEditor = try XCTUnwrap(presenter.activeRequest).action else {
            return XCTFail("The first hosted child must be the New Note editor")
        }

        presenter.dismiss()
        XCTAssertNil(noteWindow.contentViewController)

        let clip = PresentedClip(
            id: UUID(),
            title: "Editable clip",
            content: try ClipContent.detect(text: "Editable content"),
            date: .now,
            sourceBundleIdentifier: nil,
            origin: .saved(folderID: nil)
        )
        XCTAssertTrue(
            presenter.present(.clipEditor(ClipEditorRequest(mode: .editSaved(clip))))
        )
        let clipWindow = try XCTUnwrap(presenter.window)
        let clipController = try XCTUnwrap(clipWindow.contentViewController)
        let clipRoot = clipController.view
        clipRoot.layoutSubtreeIfNeeded()

        XCTAssertFalse(clipWindow === noteWindow)
        XCTAssertFalse(clipController === noteController)
        XCTAssertFalse(clipRoot === noteRoot)
        guard case .clipEditor = try XCTUnwrap(presenter.activeRequest).action else {
            return XCTFail("The second hosted child must be the Edit Clip editor")
        }
    }

    private func makeModel() -> AppModel {
        let suite = "MenuBarContinuationWindowControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return AppModel(
            defaults: defaults,
            hotKey: ContinuationWindowFakeHotKeyRegistrar(),
            supportDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent(suite, isDirectory: true)
        )
    }

    private static func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
    }

}

@MainActor
private final class ContinuationWindowFakeHotKeyRegistrar: GlobalHotKeyRegistering {
    func register(
        _ descriptor: GlobalHotKeyDescriptor,
        handler: @escaping @MainActor () -> Void
    ) throws {}

    func unregister() {}
}
