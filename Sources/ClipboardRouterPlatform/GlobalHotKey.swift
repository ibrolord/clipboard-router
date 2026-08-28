import Carbon
import Foundation

public struct GlobalHotKeyDescriptor: Equatable, Sendable {
    public let keyCode: UInt32
    public let modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public static let showClipboardRouter = GlobalHotKeyDescriptor(
        keyCode: UInt32(kVK_ANSI_V),
        modifiers: UInt32(cmdKey | shiftKey)
    )
}

/// Stable command identity used by Carbon's event callback. Keeping the identity separate from
/// the key combination lets callers change one shortcut without unregistering unrelated ones.
public struct GlobalHotKeyRegistrationID: RawRepresentable, Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let showClipboardRouter = GlobalHotKeyRegistrationID(rawValue: 1)
    public static let createNote = GlobalHotKeyRegistrationID(rawValue: 2)
    public static let insertPalette = GlobalHotKeyRegistrationID(rawValue: 3)
}

public enum GlobalHotKeyChoice: String, CaseIterable, Identifiable, Sendable {
    case commandShiftV
    case commandShiftC
    case commandOptionV
    case controlOptionV
    case commandShiftN
    case commandOptionN
    case controlOptionN

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .commandShiftV: "⌘⇧V"
        case .commandShiftC: "⌘⇧C"
        case .commandOptionV: "⌘⌥V"
        case .controlOptionV: "⌃⌥V"
        case .commandShiftN: "⌘⇧N"
        case .commandOptionN: "⌘⌥N"
        case .controlOptionN: "⌃⌥N"
        }
    }

    public var descriptor: GlobalHotKeyDescriptor {
        switch self {
        case .commandShiftV:
            GlobalHotKeyDescriptor(
                keyCode: UInt32(kVK_ANSI_V),
                modifiers: UInt32(cmdKey | shiftKey)
            )
        case .commandShiftC:
            GlobalHotKeyDescriptor(
                keyCode: UInt32(kVK_ANSI_C),
                modifiers: UInt32(cmdKey | shiftKey)
            )
        case .commandOptionV:
            GlobalHotKeyDescriptor(
                keyCode: UInt32(kVK_ANSI_V),
                modifiers: UInt32(cmdKey | optionKey)
            )
        case .controlOptionV:
            GlobalHotKeyDescriptor(
                keyCode: UInt32(kVK_ANSI_V),
                modifiers: UInt32(controlKey | optionKey)
            )
        case .commandShiftN:
            GlobalHotKeyDescriptor(keyCode: UInt32(kVK_ANSI_N), modifiers: UInt32(cmdKey | shiftKey))
        case .commandOptionN:
            GlobalHotKeyDescriptor(keyCode: UInt32(kVK_ANSI_N), modifiers: UInt32(cmdKey | optionKey))
        case .controlOptionN:
            GlobalHotKeyDescriptor(keyCode: UInt32(kVK_ANSI_N), modifiers: UInt32(controlKey | optionKey))
        }
    }
}

public enum GlobalHotKeyError: Error, LocalizedError, Sendable {
    case eventHandlerInstallationFailed(OSStatus)
    case registrationFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case let .eventHandlerInstallationFailed(status):
            "The global shortcut handler could not be installed (\(status))."
        case let .registrationFailed(status):
            "The global shortcut could not be registered (\(status))."
        }
    }
}

@MainActor
public protocol GlobalHotKeyRegistering: AnyObject {
    func register(
        _ descriptor: GlobalHotKeyDescriptor,
        handler: @escaping @MainActor () -> Void
    ) throws
    func unregister()

    func register(
        id: GlobalHotKeyRegistrationID,
        descriptor: GlobalHotKeyDescriptor,
        handler: @escaping @MainActor () -> Void
    ) throws
    func unregister(id: GlobalHotKeyRegistrationID)
}

public extension GlobalHotKeyRegistering {
    /// Compatibility bridge for injected registrars that only support the original single
    /// shortcut contract. Production uses `CarbonGlobalHotKeyRegistrar`'s multi-command
    /// implementation below.
    func register(
        id _: GlobalHotKeyRegistrationID,
        descriptor: GlobalHotKeyDescriptor,
        handler: @escaping @MainActor () -> Void
    ) throws {
        try register(descriptor, handler: handler)
    }

    func unregister(id _: GlobalHotKeyRegistrationID) {
        unregister()
    }
}

/// Carbon remains the macOS API that registers a shortcut without Accessibility permission.
@MainActor
public final class CarbonGlobalHotKeyRegistrar: GlobalHotKeyRegistering {
    private static let signature: OSType = 0x4352_5452 // "CRTR"

    // `deinit` is nonisolated in Swift 6. These opaque Carbon handles are only created and
    // mutated on MainActor, then synchronously released during destruction.
    nonisolated(unsafe) private var hotKeyReferences: [UInt32: EventHotKeyRef] = [:]
    nonisolated(unsafe) private var eventHandlerReference: EventHandlerRef?
    private var handlers: [UInt32: @MainActor () -> Void] = [:]

    public init() {}

    deinit {
        for hotKeyReference in hotKeyReferences.values {
            UnregisterEventHotKey(hotKeyReference)
        }
        if let eventHandlerReference {
            RemoveEventHandler(eventHandlerReference)
        }
    }

    public func register(
        _ descriptor: GlobalHotKeyDescriptor,
        handler: @escaping @MainActor () -> Void
    ) throws {
        unregister()
        try register(id: .showClipboardRouter, descriptor: descriptor, handler: handler)
    }

    public func register(
        id: GlobalHotKeyRegistrationID,
        descriptor: GlobalHotKeyDescriptor,
        handler: @escaping @MainActor () -> Void
    ) throws {
        unregister(id: id)

        if eventHandlerReference == nil {
            var eventType = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            )
            let installStatus = InstallEventHandler(
                GetApplicationEventTarget(),
                { _, event, userData in
                    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                    let registrar = Unmanaged<CarbonGlobalHotKeyRegistrar>
                        .fromOpaque(userData)
                        .takeUnretainedValue()
                    return registrar.handle(event: event)
                },
                1,
                &eventType,
                Unmanaged.passUnretained(self).toOpaque(),
                &eventHandlerReference
            )
            guard installStatus == noErr else {
                throw GlobalHotKeyError.eventHandlerInstallationFailed(installStatus)
            }
        }

        let hotKeyID = EventHotKeyID(
            signature: Self.signature,
            id: id.rawValue
        )
        var hotKeyReference: EventHotKeyRef?
        let registerStatus = RegisterEventHotKey(
            descriptor.keyCode,
            descriptor.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyReference
        )
        guard registerStatus == noErr else {
            if handlers.isEmpty, let eventHandlerReference {
                RemoveEventHandler(eventHandlerReference)
                self.eventHandlerReference = nil
            }
            throw GlobalHotKeyError.registrationFailed(registerStatus)
        }
        guard let hotKeyReference else {
            throw GlobalHotKeyError.registrationFailed(OSStatus(eventInternalErr))
        }
        hotKeyReferences[id.rawValue] = hotKeyReference
        handlers[id.rawValue] = handler
    }

    public func unregister() {
        for hotKeyReference in hotKeyReferences.values {
            UnregisterEventHotKey(hotKeyReference)
        }
        hotKeyReferences.removeAll()
        handlers.removeAll()
        if let eventHandlerReference {
            RemoveEventHandler(eventHandlerReference)
            self.eventHandlerReference = nil
        }
    }

    public func unregister(id: GlobalHotKeyRegistrationID) {
        if let hotKeyReference = hotKeyReferences.removeValue(forKey: id.rawValue) {
            UnregisterEventHotKey(hotKeyReference)
        }
        handlers.removeValue(forKey: id.rawValue)
        if handlers.isEmpty, let eventHandlerReference {
            RemoveEventHandler(eventHandlerReference)
            self.eventHandlerReference = nil
        }
    }

    private func handle(event: EventRef) -> OSStatus {
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        guard status == noErr,
              hotKeyID.signature == Self.signature,
              let handler = handlers[hotKeyID.id]
        else { return OSStatus(eventNotHandledErr) }

        MainActor.assumeIsolated {
            handler()
        }
        return noErr
    }
}
