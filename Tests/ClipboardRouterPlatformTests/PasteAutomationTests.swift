import ClipboardRouterPlatform
import Darwin
import Testing

@MainActor
struct PasteAutomationTests {
    @Test("Permission checks do not prompt during ordinary status refresh")
    func currentAccessDoesNotPrompt() {
        let trust = FakeAccessibilityTrustChecker(access: .permissionRequired)
        let poster = FakePasteShortcutPoster()
        let controller = PasteAutomationController(trustChecker: trust, shortcutPoster: poster)

        #expect(controller.currentAccess() == .permissionRequired)
        #expect(trust.promptValues == [false])
        #expect(poster.postCount == 0)
    }

    @Test("The explicit request is the only path that asks macOS for Accessibility access")
    func requestAccessPrompts() {
        let trust = FakeAccessibilityTrustChecker(access: .permissionRequired)
        let controller = PasteAutomationController(
            trustChecker: trust,
            shortcutPoster: FakePasteShortcutPoster()
        )

        #expect(controller.requestAccess() == .permissionRequired)
        #expect(trust.promptValues == [true])
    }

    @Test("An untrusted app never synthesizes a paste shortcut")
    func untrustedAppFallsBackToCopiedOnly() {
        let trust = FakeAccessibilityTrustChecker(access: .permissionRequired)
        let poster = FakePasteShortcutPoster()
        let controller = PasteAutomationController(trustChecker: trust, shortcutPoster: poster)

        #expect(controller.pasteIfAuthorized(to: 123) == .permissionRequired)
        #expect(poster.postCount == 0)
    }

    @Test("A trusted app posts one paste shortcut")
    func trustedAppPastes() {
        let trust = FakeAccessibilityTrustChecker(access: .trusted)
        let poster = FakePasteShortcutPoster()
        let controller = PasteAutomationController(trustChecker: trust, shortcutPoster: poster)

        #expect(controller.pasteIfAuthorized(to: 321) == .shortcutPosted)
        #expect(poster.postCount == 1)
        #expect(poster.processIdentifiers == [321])
    }

    @Test("A Quartz event creation failure is surfaced")
    func eventFailureIsSurfaced() {
        let trust = FakeAccessibilityTrustChecker(access: .trusted)
        let poster = FakePasteShortcutPoster(shouldSucceed: false)
        let controller = PasteAutomationController(trustChecker: trust, shortcutPoster: poster)

        #expect(controller.pasteIfAuthorized(to: 456) == .eventCreationFailed)
        #expect(poster.postCount == 1)
    }
}

@MainActor
private final class FakeAccessibilityTrustChecker: AccessibilityTrustChecking {
    let configuredAccess: PasteAutomationAccess
    private(set) var promptValues: [Bool] = []

    init(access: PasteAutomationAccess) {
        configuredAccess = access
    }

    func access(promptIfNeeded: Bool) -> PasteAutomationAccess {
        promptValues.append(promptIfNeeded)
        return configuredAccess
    }
}

@MainActor
private final class FakePasteShortcutPoster: PasteShortcutPosting {
    let shouldSucceed: Bool
    private(set) var postCount = 0
    private(set) var processIdentifiers: [pid_t] = []

    init(shouldSucceed: Bool = true) {
        self.shouldSucceed = shouldSucceed
    }

    func postPasteShortcut(to processIdentifier: pid_t) -> Bool {
        postCount += 1
        processIdentifiers.append(processIdentifier)
        return shouldSucceed
    }
}
