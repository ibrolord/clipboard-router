import AppKit
import ApplicationServices
import Carbon.HIToolbox
import ClipboardRouterCore
import CoreGraphics
import Foundation

public enum TextExpansionAccessStatus: Equatable, Sendable {
    case off
    case permissionRequired
    case ready
    case blocked(String)
}

public struct TextExpansionFocus: Equatable, Sendable {
    public let processIdentifier: pid_t
    public let bundleIdentifier: String
    public let role: String
    public let identity: String
    public let allowsTriggerStart: Bool

    public init(
        processIdentifier: pid_t,
        bundleIdentifier: String,
        role: String,
        identity: String,
        allowsTriggerStart: Bool = true
    ) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier.lowercased()
        self.role = role
        self.identity = identity
        self.allowsTriggerStart = allowsTriggerStart
    }
}

public struct TextExpansionMutationReceipt: Equatable, Sendable {
    public let focusIdentity: String
    public let insertionLocation: Int
    public let insertedUTF16Length: Int
    public let originalText: String

    public init(
        focusIdentity: String,
        insertionLocation: Int,
        insertedUTF16Length: Int,
        originalText: String
    ) {
        self.focusIdentity = focusIdentity
        self.insertionLocation = insertionLocation
        self.insertedUTF16Length = insertedUTF16Length
        self.originalText = originalText
    }
}

@MainActor public protocol TextExpansionAccessibilityControlling: AnyObject {
    func access(promptIfNeeded: Bool) -> PasteAutomationAccess
    func focusedTarget() -> TextExpansionFocus?
    func replaceCharactersBeforeCursor(
        _ count: Int,
        with replacement: String,
        focus: TextExpansionFocus
    ) -> TextExpansionMutationReceipt?
    func undo(_ receipt: TextExpansionMutationReceipt) -> Bool
}

@MainActor public protocol TextExpansionEventMonitoring: AnyObject {
    func start(handler: @escaping @MainActor (Character, Date) -> Void) -> Bool
    func stop()
}

@MainActor
public final class SystemTextExpansionAccessibilityController:
    TextExpansionAccessibilityControlling
{
    private let trust = SystemAccessibilityTrustChecker()

    public init() {}

    public func access(promptIfNeeded: Bool) -> PasteAutomationAccess {
        trust.access(promptIfNeeded: promptIfNeeded)
    }

    public func focusedTarget() -> TextExpansionFocus? {
        guard trust.access(promptIfNeeded: false) == .trusted,
              !IsSecureEventInputEnabled(),
              let application = NSWorkspace.shared.frontmostApplication,
              application.bundleIdentifier?.lowercased() != "com.clipboardrouter.clipboardrouter",
              let element = focusedElement()
        else { return nil }
        let role = stringAttribute(kAXRoleAttribute, of: element) ?? ""
        let allowed = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField"]
        guard allowed.contains(role), role != "AXSecureTextField" else { return nil }
        let protected = booleanAttribute("AXProtectedContent" as CFString, of: element) ?? false
        guard !protected else { return nil }
        return TextExpansionFocus(
            processIdentifier: application.processIdentifier,
            bundleIdentifier: application.bundleIdentifier ?? "",
            role: role,
            identity: "\(application.processIdentifier):\(CFHash(element))",
            allowsTriggerStart: triggerCanStart(at: element)
        )
    }

    public func replaceCharactersBeforeCursor(
        _ count: Int,
        with replacement: String,
        focus: TextExpansionFocus
    ) -> TextExpansionMutationReceipt? {
        guard count > 0, let element = verifiedFocusedElement(focus),
              var range = selectedRange(of: element), range.length == 0,
              range.location >= count
        else { return nil }
        range.location -= count
        range.length = count
        guard setRange(range, on: element),
              AXUIElementSetAttributeValue(
                  element,
                  kAXSelectedTextAttribute as CFString,
                  replacement as CFTypeRef
              ) == .success
        else { return nil }
        return TextExpansionMutationReceipt(
            focusIdentity: focus.identity,
            insertionLocation: range.location,
            insertedUTF16Length: replacement.utf16.count,
            originalText: ""
        )
    }

    public func undo(_ receipt: TextExpansionMutationReceipt) -> Bool {
        guard let focus = focusedTarget(), focus.identity == receipt.focusIdentity,
              let element = verifiedFocusedElement(focus),
              var range = selectedRange(of: element), range.length == 0,
              range.location == receipt.insertionLocation + receipt.insertedUTF16Length
        else { return false }
        range.location = receipt.insertionLocation
        range.length = receipt.insertedUTF16Length
        return setRange(range, on: element)
            && AXUIElementSetAttributeValue(
                element,
                kAXSelectedTextAttribute as CFString,
                receipt.originalText as CFTypeRef
            ) == .success
    }

    private func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system,
            kAXFocusedUIElementAttribute as CFString,
            &value
        ) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    private func verifiedFocusedElement(_ focus: TextExpansionFocus) -> AXUIElement? {
        guard focusedTarget()?.identity == focus.identity else { return nil }
        return focusedElement()
    }

    private func stringAttribute(_ name: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    private func booleanAttribute(_ name: CFString, of element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success
        else { return nil }
        return value as? Bool
    }

    private func selectedRange(of element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        var range = CFRange()
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &value
        ) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        let axValue = value as! AXValue
        guard
              AXValueGetType(axValue) == .cfRange,
              AXValueGetValue(axValue, .cfRange, &range)
        else { return nil }
        return range
    }

    private func triggerCanStart(at element: AXUIElement) -> Bool {
        guard let range = selectedRange(of: element), range.length == 0 else { return false }
        guard range.location > 0 else { return true }
        var priorRange = CFRange(location: range.location - 1, length: 1)
        guard let rangeValue = AXValueCreate(.cfRange, &priorRange) else { return false }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &value
        ) == .success,
              let character = (value as? String)?.first
        else { return false }
        return character.isWhitespace || character.isPunctuation
    }

    private func setRange(_ range: CFRange, on element: AXUIElement) -> Bool {
        var mutable = range
        guard let value = AXValueCreate(.cfRange, &mutable) else { return false }
        return AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            value
        ) == .success
    }
}

@MainActor
public final class SystemTextExpansionEventMonitor: TextExpansionEventMonitoring {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var handler: (@MainActor (Character, Date) -> Void)?

    public init() {}

    public func start(handler: @escaping @MainActor (Character, Date) -> Void) -> Bool {
        stop()
        self.handler = handler
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.leftMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.rightMouseDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<SystemTextExpansionEventMonitor>
                    .fromOpaque(userInfo).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    monitor.reenableTap()
                    return Unmanaged.passUnretained(event)
                }
                if type == .leftMouseDown || type == .rightMouseDown {
                    monitor.cancelCurrentToken()
                } else if type == .keyDown {
                    monitor.receive(event)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    public func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        source = nil
        tap = nil
        handler = nil
    }

    private func reenableTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    private func cancelCurrentToken() {
        let date = Date()
        DispatchQueue.main.async { [weak self] in self?.handler?("\u{7f}", date) }
    }

    private func receive(_ event: CGEvent) {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let cancellationKeyCodes: Set<Int64> = [51, 53, 115, 116, 117, 119, 121, 123, 124, 125, 126]
        if cancellationKeyCodes.contains(keyCode)
            || !event.flags.intersection([.maskCommand, .maskControl]).isEmpty
        {
            let date = Date()
            let cancellation: Character = keyCode == 53 ? "\u{1b}" : "\u{7f}"
            DispatchQueue.main.async { [weak self] in self?.handler?(cancellation, date) }
            return
        }
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(
            maxStringLength: buffer.count,
            actualStringLength: &length,
            unicodeString: &buffer
        )
        guard length > 0,
              let value = String(utf16CodeUnits: buffer, count: length).first
        else { return }
        let date = Date()
        // The tap observes the key before the target app necessarily advances its AX
        // selection. Defer one main-run-loop turn so replacement ranges include the delimiter.
        DispatchQueue.main.async { [weak self] in self?.handler?(value, date) }
    }
}

@MainActor
public final class TextExpansionController {
    private let accessibility: any TextExpansionAccessibilityControlling
    private let events: any TextExpansionEventMonitoring
    private let definitions: () -> [TextExpansionDefinition]
    private let isAllowed: (TextExpansionFocus) -> Bool
    private var matcher = TextExpansionMatcher()
    private var lastReceipt: TextExpansionMutationReceipt?
    public private(set) var status: TextExpansionAccessStatus = .off

    public init(
        accessibility: any TextExpansionAccessibilityControlling =
            SystemTextExpansionAccessibilityController(),
        events: any TextExpansionEventMonitoring = SystemTextExpansionEventMonitor(),
        definitions: @escaping () -> [TextExpansionDefinition],
        isAllowed: @escaping (TextExpansionFocus) -> Bool
    ) {
        self.accessibility = accessibility
        self.events = events
        self.definitions = definitions
        self.isAllowed = isAllowed
    }

    public func start(promptIfNeeded: Bool = false) {
        guard accessibility.access(promptIfNeeded: promptIfNeeded) == .trusted else {
            stop(status: .permissionRequired)
            return
        }
        status = events.start { [weak self] character, date in
            self?.handle(character, at: date)
        } ? .ready : .blocked("macOS did not allow the keyboard event monitor.")
    }

    public func stop(status: TextExpansionAccessStatus = .off) {
        events.stop()
        matcher.reset()
        lastReceipt = nil
        self.status = status
    }

    private func handle(_ character: Character, at date: Date) {
        guard accessibility.access(promptIfNeeded: false) == .trusted else {
            stop(status: .permissionRequired)
            return
        }
        if character == "\u{1b}" {
            if let receipt = lastReceipt { _ = accessibility.undo(receipt) }
            lastReceipt = nil
            matcher.reset()
            return
        }
        if character == "\u{7f}" {
            matcher.reset(mayStartTrigger: false)
            lastReceipt = nil
            return
        }
        guard let focus = accessibility.focusedTarget(), isAllowed(focus) else {
            matcher.reset()
            lastReceipt = nil
            return
        }
        lastReceipt = nil
        let candidateDefinitions: [TextExpansionDefinition]
        if character == " " || character == "\t" || character == "\n" {
            candidateDefinitions = definitions()
        } else {
            candidateDefinitions = []
        }
        guard let match = matcher.consume(
            character,
            at: date,
            contextID: focus.identity,
            mayStartAtContextChange: focus.allowsTriggerStart,
            definitions: candidateDefinitions
        ) else { return }
        let replacement = match.definition.replacement + String(match.delimiter)
        lastReceipt = accessibility.replaceCharactersBeforeCursor(
            match.replacedUTF16Length,
            with: replacement,
            focus: focus
        ).map {
            TextExpansionMutationReceipt(
                focusIdentity: $0.focusIdentity,
                insertionLocation: $0.insertionLocation,
                insertedUTF16Length: $0.insertedUTF16Length,
                originalText: match.definition.trigger + String(match.delimiter)
            )
        }
    }
}
