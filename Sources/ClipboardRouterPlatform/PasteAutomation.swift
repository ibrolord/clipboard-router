import ApplicationServices
import CoreGraphics
import Foundation

/// Accessibility is required only for the optional "paste into the current app" action.
/// Clipboard capture and ordinary click-to-copy continue to work without this permission.
public enum PasteAutomationAccess: Equatable, Sendable {
    case trusted
    case permissionRequired
}

public enum PasteAutomationResult: Equatable, Sendable {
    case shortcutPosted
    case permissionRequired
    case eventCreationFailed
}

@MainActor
public protocol AccessibilityTrustChecking: AnyObject {
    func access(promptIfNeeded: Bool) -> PasteAutomationAccess
}

@MainActor
public protocol PasteShortcutPosting: AnyObject {
    func postPasteShortcut(to processIdentifier: pid_t) -> Bool
}

@MainActor
public final class SystemAccessibilityTrustChecker: AccessibilityTrustChecking {
    public init() {}

    public func access(promptIfNeeded: Bool) -> PasteAutomationAccess {
        // Swift 6 treats the imported Core Foundation global as shared mutable state. The
        // documented CFDictionary key has this stable string value, so constructing it here
        // preserves the API contract without touching nonisolated global storage.
        let options = ["AXTrustedCheckOptionPrompt": promptIfNeeded as CFBoolean] as CFDictionary
        return AXIsProcessTrustedWithOptions(options) ? .trusted : .permissionRequired
    }
}

@MainActor
public final class SystemPasteShortcutPoster: PasteShortcutPosting {
    /// ANSI V. This is the physical shortcut macOS uses for Command-V and is independent of
    /// the text produced by the user's active keyboard layout.
    private static let vKeyCode: CGKeyCode = 9

    public init() {}

    public func postPasteShortcut(to processIdentifier: pid_t) -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: Self.vKeyCode,
                  keyDown: true
              ),
              let keyUp = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: Self.vKeyCode,
                  keyDown: false
              )
        else {
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.postToPid(processIdentifier)
        keyUp.postToPid(processIdentifier)
        return true
    }
}

/// A small, injectable boundary around the only synthesized-input behavior in the app.
/// Callers must write the desired clip to the pasteboard first. If permission is absent, the
/// content therefore remains copied and the UI can present an honest manual Command-V fallback.
@MainActor
public final class PasteAutomationController {
    private let trustChecker: any AccessibilityTrustChecking
    private let shortcutPoster: any PasteShortcutPosting

    public init(
        trustChecker: any AccessibilityTrustChecking = SystemAccessibilityTrustChecker(),
        shortcutPoster: any PasteShortcutPosting = SystemPasteShortcutPoster()
    ) {
        self.trustChecker = trustChecker
        self.shortcutPoster = shortcutPoster
    }

    public func currentAccess() -> PasteAutomationAccess {
        trustChecker.access(promptIfNeeded: false)
    }

    public func requestAccess() -> PasteAutomationAccess {
        trustChecker.access(promptIfNeeded: true)
    }

    public func pasteIfAuthorized(to processIdentifier: pid_t) -> PasteAutomationResult {
        guard trustChecker.access(promptIfNeeded: false) == .trusted else {
            return .permissionRequired
        }
        return shortcutPoster.postPasteShortcut(to: processIdentifier)
            ? .shortcutPosted
            : .eventCreationFailed
    }
}
