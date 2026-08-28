import AppKit
import XCTest
@testable import ClipboardRouterApp

@MainActor
final class LibraryWindowPresenterTests: XCTestCase {
    func testActivationFailureDoesNotOpenLibraryAndReportsFailure() async {
        let application = FakeLibraryApplication(policy: .accessory)
        application.acceptsPolicyChange = false
        var openCount = 0
        var failure: String?

        let task = LibraryWindowPresenter.show(
            openLibrary: { openCount += 1 },
            application: application,
            sleeper: { _ in },
            onFailure: { failure = $0 }
        )
        _ = await task.value

        XCTAssertEqual(openCount, 0)
        XCTAssertEqual(application.requestedPolicies, [.regular])
        XCTAssertEqual(failure, LibraryWindowPresenter.presentationFailureMessage)
    }

    func testExistingMinimizedLibraryIsRaisedWithoutOpeningDuplicate() async {
        let application = FakeLibraryApplication(policy: .accessory)
        let window = FakeLibraryWindow(identifier: "library", isMiniaturized: true)
        application.fakeWindows = [window]
        var openCount = 0

        let presented = await LibraryWindowPresenter.present(
            openLibrary: { openCount += 1 },
            application: application,
            sleeper: { _ in }
        )

        XCTAssertTrue(presented)
        XCTAssertEqual(application.activationPolicy, .regular)
        XCTAssertEqual(openCount, 0)
        XCTAssertEqual(window.deminaturizeCount, 1)
        XCTAssertEqual(window.makeKeyCount, 1)
        XCTAssertEqual(window.orderFrontCount, 1)
        XCTAssertEqual(application.unhideCount, 1)
        XCTAssertEqual(application.activateCount, 1)
    }

    func testNewLibraryOpensOnceThenRepeatedPresentationRaisesSameWindow() async {
        let application = FakeLibraryApplication(policy: .accessory)

        let first = await LibraryWindowPresenter.present(
            openLibrary: { application.openLibraryWindow() },
            application: application,
            sleeper: { _ in }
        )
        let firstWindow = application.fakeWindows[0]
        let second = await LibraryWindowPresenter.present(
            openLibrary: { application.openLibraryWindow() },
            application: application,
            sleeper: { _ in }
        )

        XCTAssertTrue(first)
        XCTAssertTrue(second)
        XCTAssertEqual(application.openLibraryCount, 1)
        XCTAssertEqual(application.requestedPolicies, [.regular])
        XCTAssertEqual(firstWindow.makeKeyCount, 2)
        XCTAssertEqual(firstWindow.orderFrontCount, 2)
    }

    func testClosedWindowFallbackUsesOnlyKeyableTitledClipboardRouterWindow() async {
        let application = FakeLibraryApplication(policy: .regular)
        let unrelated = FakeLibraryWindow(
            identifier: nil,
            title: "Clipboard Router",
            isTitled: false,
            canBecomeKey: true
        )
        let library = FakeLibraryWindow(
            identifier: nil,
            title: "Clipboard Router",
            isTitled: true,
            canBecomeKey: true
        )
        application.fakeWindows = [unrelated, library]
        var openCount = 0

        let presented = await LibraryWindowPresenter.present(
            openLibrary: { openCount += 1 },
            application: application,
            sleeper: { _ in }
        )

        XCTAssertTrue(presented)
        XCTAssertEqual(openCount, 0)
        XCTAssertEqual(unrelated.makeKeyCount, 0)
        XCTAssertEqual(library.makeKeyCount, 1)
    }

    func testMissingWindowRetriesBoundedlyAndFailsTruthfully() async {
        let application = FakeLibraryApplication(policy: .regular)
        var openCount = 0
        var sleepCount = 0

        let presented = await LibraryWindowPresenter.present(
            openLibrary: { openCount += 1 },
            application: application,
            retryAttempts: 4,
            sleeper: { _ in sleepCount += 1 }
        )

        XCTAssertFalse(presented)
        XCTAssertEqual(openCount, 1)
        XCTAssertEqual(sleepCount, 3)
    }

    func testRetainedClosedWindowIsIgnoredAndLibrarySceneIsRecreated() async {
        let application = FakeLibraryApplication(policy: .regular)
        let retainedClosedWindow = FakeLibraryWindow(
            identifier: "library",
            isVisible: false,
            isKeyWindow: false
        )
        application.fakeWindows = [retainedClosedWindow]

        let presented = await LibraryWindowPresenter.present(
            openLibrary: { application.openLibraryWindow() },
            application: application,
            sleeper: { _ in }
        )

        XCTAssertTrue(presented)
        XCTAssertEqual(application.openLibraryCount, 1)
        XCTAssertEqual(retainedClosedWindow.makeKeyCount, 0)
        XCTAssertTrue(application.fakeWindows[0].isVisible)
        XCTAssertTrue(application.fakeWindows[0].isKeyWindow)
    }

    func testContinuationWaitsUntilDelayedWindowBecomesKey() async {
        let application = FakeLibraryApplication(policy: .regular)
        var sleepCount = 0
        var actionCount = 0
        var failure: String?

        let task = LibraryWindowPresenter.performWhenReady(
            openLibrary: {
                application.openLibraryWindow(isKeyAfterRaiseCount: 3)
            },
            application: application,
            sleeper: { _ in
                XCTAssertEqual(
                    actionCount,
                    0,
                    "Continuation state must not publish before Library is key"
                )
                sleepCount += 1
            },
            onFailure: { failure = $0 },
            action: { actionCount += 1 }
        )
        await task.value

        XCTAssertNil(failure)
        XCTAssertEqual(actionCount, 1)
        XCTAssertEqual(application.openLibraryCount, 1)
        XCTAssertEqual(sleepCount, 2)
        XCTAssertEqual(application.fakeWindows[0].makeKeyCount, 3)
        XCTAssertTrue(application.fakeWindows[0].isKeyWindow)
    }

    func testPersistentPresentationWaitsForMenuBarDisappearance() {
        let boundary = MenuBarLibraryPresentationBoundary()
        var dismissCount = 0
        var presentationCount = 0

        let accepted = boundary.request(
            dismissMenuBar: {
                dismissCount += 1
                return true
            },
            presentation: { presentationCount += 1 }
        )

        XCTAssertTrue(accepted)
        XCTAssertEqual(dismissCount, 1)
        XCTAssertEqual(presentationCount, 0)

        boundary.menuBarDidDisappear()
        XCTAssertEqual(presentationCount, 1)
        boundary.menuBarDidDisappear()
        XCTAssertEqual(presentationCount, 1)
    }

    func testPersistentPresentationFailsClosedWhenMenuBarCannotDismiss() {
        let boundary = MenuBarLibraryPresentationBoundary()
        var presentationCount = 0

        XCTAssertFalse(boundary.request(
            dismissMenuBar: { false },
            presentation: { presentationCount += 1 }
        ))
        boundary.menuBarDidDisappear()
        XCTAssertEqual(presentationCount, 0)
    }

    func testPersistentPresentationCoalescesUntilDisappearThenAcceptsNextRequest() {
        let boundary = MenuBarLibraryPresentationBoundary()
        var presentations: [String] = []

        XCTAssertTrue(boundary.request(
            dismissMenuBar: { true },
            presentation: { presentations.append("first") }
        ))
        XCTAssertFalse(boundary.request(
            dismissMenuBar: { true },
            presentation: { presentations.append("duplicate") }
        ))
        boundary.menuBarDidDisappear()
        XCTAssertEqual(presentations, ["first"])

        XCTAssertTrue(boundary.request(
            dismissMenuBar: { true },
            presentation: { presentations.append("second") }
        ))
        boundary.menuBarDidDisappear()
        XCTAssertEqual(presentations, ["first", "second"])
    }

    func testContinuationSurvivesColdSceneCreationBeyondLegacyRetryWindow() async {
        let application = FakeLibraryApplication(policy: .regular)
        var sleepCount = 0
        var actionCount = 0

        let task = LibraryWindowPresenter.performWhenReady(
            openLibrary: {
                application.openLibraryWindow(isKeyAfterRaiseCount: 50)
            },
            application: application,
            sleeper: { _ in sleepCount += 1 },
            onFailure: { _ in XCTFail("A bounded cold launch should remain eligible") },
            action: { actionCount += 1 }
        )
        await task.value

        XCTAssertEqual(actionCount, 1)
        XCTAssertEqual(application.openLibraryCount, 1)
        XCTAssertEqual(sleepCount, 49)
        XCTAssertTrue(application.fakeWindows[0].isKeyWindow)
    }

    func testContinuationDoesNotRunWhenWindowNeverBecomesKey() async {
        let application = FakeLibraryApplication(policy: .regular)
        var actionCount = 0
        var failure: String?

        let task = LibraryWindowPresenter.performWhenReady(
            openLibrary: {
                application.openLibraryWindow(isKeyAfterRaiseCount: .max)
            },
            application: application,
            sleeper: { _ in },
            onFailure: { failure = $0 },
            action: { actionCount += 1 }
        )
        await task.value

        XCTAssertEqual(actionCount, 0)
        XCTAssertEqual(failure, LibraryWindowPresenter.presentationFailureMessage)
        XCTAssertEqual(application.openLibraryCount, 1)
        XCTAssertEqual(
            application.fakeWindows[0].makeKeyCount,
            LibraryWindowPresenter.maximumRaiseAttempts
        )
    }

    func testCancelledContinuationDoesNotRunOrDuplicatePresentation() async {
        let application = FakeLibraryApplication(policy: .regular)
        let gate = AsyncSleeperGate()
        var actionCount = 0
        var failure: String?

        let task = LibraryWindowPresenter.performWhenReady(
            openLibrary: {
                application.openLibraryWindow(isKeyAfterRaiseCount: 2)
            },
            application: application,
            sleeper: { _ in await gate.wait() },
            onFailure: { failure = $0 },
            action: { actionCount += 1 }
        )
        await gate.waitUntilEntered()
        task.cancel()
        gate.resume()
        await task.value

        XCTAssertEqual(actionCount, 0)
        XCTAssertNil(failure)
        XCTAssertEqual(application.openLibraryCount, 1)
    }

    func testConcurrentPresentationRequestsCoalesceOneOpen() async {
        let application = FakeLibraryApplication(policy: .accessory)

        let first = LibraryWindowPresenter.show(
            openLibrary: { application.openLibraryWindow() },
            application: application,
            sleeper: { _ in },
            onFailure: { _ in XCTFail("Presentation should succeed") }
        )
        let second = LibraryWindowPresenter.show(
            openLibrary: { application.openLibraryWindow() },
            application: application,
            sleeper: { _ in },
            onFailure: { _ in XCTFail("Presentation should succeed") }
        )
        _ = await first.value
        _ = await second.value

        XCTAssertEqual(application.openLibraryCount, 1)
        XCTAssertEqual(application.requestedPolicies, [.regular])
    }

    func testDockReopenBridgeRecreatesLibraryWhenNoWindowExists() async {
        let application = FakeLibraryApplication(policy: .regular)
        let bridge = LibraryWindowReopenBridge()
        bridge.register { application.openLibraryWindow() }
        var failure: String?

        let task = bridge.reopen(
            application: application,
            sleeper: { _ in },
            onFailure: { failure = $0 }
        )
        _ = await task?.value

        XCTAssertNil(failure)
        XCTAssertEqual(application.openLibraryCount, 1)
        XCTAssertEqual(application.fakeWindows.count, 1)
        XCTAssertEqual(application.fakeWindows[0].makeKeyCount, 1)
        XCTAssertEqual(application.fakeWindows[0].orderFrontCount, 1)
    }

    func testColdMenuRegistrationLetsFirstSuccessfulContinuationOpenLibraryExactlyOnce() async {
        let application = FakeLibraryApplication(policy: .accessory)
        let bridge = LibraryWindowReopenBridge()
        bridge.register { application.openLibraryWindow() }
        var failure: String?

        let firstReveal = bridge.reopen(
            application: application,
            sleeper: { _ in },
            onFailure: { failure = $0 }
        )
        _ = await firstReveal?.value
        let secondReveal = bridge.reopen(
            application: application,
            sleeper: { _ in },
            onFailure: { failure = $0 }
        )
        _ = await secondReveal?.value

        XCTAssertNil(failure)
        XCTAssertEqual(application.openLibraryCount, 1)
        XCTAssertEqual(application.fakeWindows.count, 1)
        XCTAssertNil(secondReveal, "An existing Library must be raised, not recreated")
        XCTAssertEqual(application.fakeWindows[0].makeKeyCount, 2)
    }

    func testDockReopenBeforeSceneRegistrationDoesNotReportFalseFailure() {
        let application = FakeLibraryApplication(policy: .regular)
        let bridge = LibraryWindowReopenBridge()
        var failure: String?

        let task = bridge.reopen(
            application: application,
            sleeper: { _ in },
            onFailure: { failure = $0 }
        )

        XCTAssertNil(task)
        XCTAssertNil(failure)
        XCTAssertTrue(application.fakeWindows.isEmpty)
    }

    func testPersistentMenuOpenerWinsOverLaterLibrarySceneFallback() async {
        let application = FakeLibraryApplication(policy: .regular)
        let bridge = LibraryWindowReopenBridge()
        var persistentOpenCount = 0
        var staleSceneOpenCount = 0
        bridge.register {
            persistentOpenCount += 1
            application.openLibraryWindow()
        }
        bridge.registerSceneFallback {
            staleSceneOpenCount += 1
        }

        let task = bridge.reopen(
            application: application,
            sleeper: { _ in },
            onFailure: { _ in XCTFail("Persistent menu opener should recreate Library") }
        )
        _ = await task?.value

        XCTAssertEqual(persistentOpenCount, 1)
        XCTAssertEqual(staleSceneOpenCount, 0)
        XCTAssertEqual(application.openLibraryCount, 1)
        XCTAssertEqual(application.fakeWindows.count, 1)
    }
}

@MainActor
private final class FakeLibraryApplication: LibraryWindowPresentingApplication {
    var activationPolicy: NSApplication.ActivationPolicy
    var fakeWindows: [FakeLibraryWindow] = []
    var windows: [any LibraryWindowPresentingWindow] { fakeWindows }
    var acceptsPolicyChange = true
    private(set) var requestedPolicies: [NSApplication.ActivationPolicy] = []
    private(set) var unhideCount = 0
    private(set) var activateCount = 0
    private(set) var openLibraryCount = 0

    init(policy: NSApplication.ActivationPolicy) {
        activationPolicy = policy
    }

    func setActivationPolicy(_ policy: NSApplication.ActivationPolicy) -> Bool {
        requestedPolicies.append(policy)
        if acceptsPolicyChange { activationPolicy = policy }
        return acceptsPolicyChange
    }

    func unhide() { unhideCount += 1 }
    func activate() { activateCount += 1 }

    func openLibraryWindow(isKeyAfterRaiseCount: Int = 1) {
        openLibraryCount += 1
        fakeWindows = [FakeLibraryWindow(
            identifier: "library",
            isKeyWindow: false,
            isKeyAfterRaiseCount: isKeyAfterRaiseCount
        )]
    }
}

@MainActor
private final class FakeLibraryWindow: LibraryWindowPresentingWindow {
    let identifierValue: String?
    let title: String
    let isTitled: Bool
    let canBecomeKey: Bool
    private let isKeyAfterRaiseCount: Int
    private(set) var isMiniaturized: Bool
    private(set) var isKeyWindow: Bool
    private(set) var isVisible: Bool
    private(set) var deminaturizeCount = 0
    private(set) var makeKeyCount = 0
    private(set) var orderFrontCount = 0

    init(
        identifier: String?,
        title: String = "Clipboard Router",
        isTitled: Bool = true,
        canBecomeKey: Bool = true,
        isVisible: Bool = true,
        isMiniaturized: Bool = false,
        isKeyWindow: Bool = true,
        isKeyAfterRaiseCount: Int = 1
    ) {
        identifierValue = identifier
        self.title = title
        self.isTitled = isTitled
        self.canBecomeKey = canBecomeKey
        self.isVisible = isVisible
        self.isMiniaturized = isMiniaturized
        self.isKeyWindow = isKeyWindow
        self.isKeyAfterRaiseCount = isKeyAfterRaiseCount
    }

    func deminiaturize() {
        deminaturizeCount += 1
        isMiniaturized = false
    }

    func makeKeyAndOrderFront() {
        makeKeyCount += 1
        if makeKeyCount >= isKeyAfterRaiseCount { isKeyWindow = true }
    }
    func orderFrontRegardless() { orderFrontCount += 1 }
}

@MainActor
private final class AsyncSleeperGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var hasEntered = false

    func wait() async {
        hasEntered = true
        enteredContinuation?.resume()
        enteredContinuation = nil
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilEntered() async {
        if hasEntered { return }
        await withCheckedContinuation { enteredContinuation = $0 }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
