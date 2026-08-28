import AppKit
import ClipboardRouterCore
import EventKit
import Foundation

public enum ClipActionExecutionReceipt: Equatable, Sendable {
    case openedLink(host: String)
    case openedEmailDraft(recipient: String)
    case openedCallingApp(number: String)
    case openedApplication(name: String)
    case openedAutomationURL(host: String)
    case calendarEventCreated(title: String)

    public var userMessage: String {
        switch self {
        case let .openedLink(host): "Opened \(host)."
        case let .openedEmailDraft(recipient): "Opened an email draft to \(recipient). Nothing was sent."
        case let .openedCallingApp(number): "Opened the calling app for \(number). No call was placed by Clipboard Router."
        case let .openedApplication(name): "Copied the clip and opened \(name)."
        case let .openedAutomationURL(host): "Opened the automation URL on \(host)."
        case let .calendarEventCreated(title): "Added “\(title)” to Calendar."
        }
    }
}

public enum ClipActionExecutionError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedEntity
    case invalidLink
    case invalidEmail
    case invalidPhoneNumber
    case targetCouldNotOpen
    case applicationCouldNotOpenAfterCopy(String)
    case clipboardWriteFailed
    case invalidApplicationBookmark
    case untrustedApplication
    case calendarAccessDenied
    case calendarUnavailable
    case calendarSaveFailed

    public var errorDescription: String? {
        switch self {
        case .unsupportedEntity: "This detected value does not have an external action."
        case .invalidLink: "Clipboard Router refused to open an invalid or unsafe link."
        case .invalidEmail: "Clipboard Router could not create a safe email draft for this address."
        case .invalidPhoneNumber: "Clipboard Router could not create a safe calling-app link for this number."
        case .targetCouldNotOpen: "macOS could not open the selected action."
        case let .applicationCouldNotOpenAfterCopy(name):
            "The clip was copied, but macOS could not open \(name)."
        case .clipboardWriteFailed: "Clipboard Router could not copy this clip."
        case .invalidApplicationBookmark: "The selected application is no longer available. Edit this automation in Settings."
        case .untrustedApplication: "The selected automation target is not a valid signed macOS application."
        case .calendarAccessDenied: "Calendar access was not granted. You can change this in System Settings > Privacy & Security > Calendars."
        case .calendarUnavailable: "Calendar has no writable default calendar."
        case .calendarSaveFailed: "The event could not be added to Calendar."
        }
    }
}

@MainActor
public final class ClipActionExecutor {
    private let opener: any ExternalURLOpening
    private let pasteboard: any PasteboardWriting
    private let bookmarks: any ApplicationBookmarking
    private let metadataInspector: any ApplicationMetadataInspecting

    public init(
        opener: any ExternalURLOpening = WorkspaceExternalURLOpener(),
        pasteboard: any PasteboardWriting = SystemPasteboardWriter(),
        bookmarks: any ApplicationBookmarking = SecurityScopedApplicationBookmarkStore(),
        metadataInspector: any ApplicationMetadataInspecting = SystemApplicationMetadataInspector()
    ) {
        self.opener = opener
        self.pasteboard = pasteboard
        self.bookmarks = bookmarks
        self.metadataInspector = metadataInspector
    }

    public func perform(_ entity: DetectedClipEntity) async throws -> ClipActionExecutionReceipt {
        switch entity.kind {
        case .webURL:
            let url = try validatedWebURL(entity.normalizedValue)
            guard opener.openWebURL(url) else { throw ClipActionExecutionError.targetCouldNotOpen }
            return .openedLink(host: url.host() ?? url.absoluteString)
        case .emailAddress:
            let address = try validatedEmail(entity.normalizedValue)
            var components = URLComponents()
            components.scheme = "mailto"
            components.path = address
            guard let url = components.url, opener.openWebURL(url) else {
                throw ClipActionExecutionError.targetCouldNotOpen
            }
            return .openedEmailDraft(recipient: address)
        case .phoneNumber:
            let number = try validatedPhone(entity.normalizedValue)
            guard let url = URL(string: "tel:\(number)"), opener.openWebURL(url) else {
                throw ClipActionExecutionError.targetCouldNotOpen
            }
            return .openedCallingApp(number: number)
        case .date:
            throw ClipActionExecutionError.unsupportedEntity
        }
    }

    public func run(
        _ automation: ClipAutomation,
        clipText: String,
        entities: [DetectedClipEntity]
    ) async throws -> ClipActionExecutionReceipt {
        switch automation.target {
        case let .webURLTemplate(rawTemplate):
            let url = try AutomationURLTemplate(rawTemplate).render(
                clipText: clipText,
                entities: entities
            )
            guard opener.openWebURL(url) else { throw ClipActionExecutionError.targetCouldNotOpen }
            return .openedAutomationURL(host: url.host() ?? url.absoluteString)
        case let .application(bookmarkData, _):
            let bookmark: ResolvedApplicationBookmark
            do {
                bookmark = try bookmarks.resolveApplicationBookmark(bookmarkData)
            } catch {
                throw ClipActionExecutionError.invalidApplicationBookmark
            }
            defer { bookmarks.stopAccessing(bookmark) }
            guard bookmark.url.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
                  let metadata = metadataInspector.metadata(forApplicationAt: bookmark.url),
                  case .valid = metadata.signature
            else { throw ClipActionExecutionError.untrustedApplication }
            let verifiedDisplayName = metadata.displayName ?? metadata.bundleName
                ?? bookmark.url.deletingPathExtension().lastPathComponent
            guard pasteboard.writeForRouting(clipText) else {
                throw ClipActionExecutionError.clipboardWriteFailed
            }
            guard await opener.openApplication(at: bookmark.url) else {
                throw ClipActionExecutionError.applicationCouldNotOpenAfterCopy(verifiedDisplayName)
            }
            return .openedApplication(name: verifiedDisplayName)
        }
    }

    /// Performs a one-off reviewed app-browser action. The application is re-inspected before
    /// the clipboard changes, then the exact selected bundle is opened. It never types or sends.
    public func copyAndOpen(
        clipText: String,
        applicationURL: URL,
        expectedBundleIdentifier: String,
        expectedTeamIdentifier: String?
    ) async throws -> ClipActionExecutionReceipt {
        guard !clipText.isEmpty else { throw ClipActionExecutionError.clipboardWriteFailed }
        guard applicationURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
              let metadata = metadataInspector.metadata(forApplicationAt: applicationURL),
              case let .valid(observedTeamIdentifier) = metadata.signature,
              let bundleIdentifier = metadata.bundleIdentifier,
              !bundleIdentifier.isEmpty,
              bundleIdentifier == expectedBundleIdentifier,
              observedTeamIdentifier == expectedTeamIdentifier
        else { throw ClipActionExecutionError.untrustedApplication }
        let verifiedDisplayName = metadata.displayName ?? metadata.bundleName
            ?? applicationURL.deletingPathExtension().lastPathComponent
        guard pasteboard.writeForRouting(clipText) else {
            throw ClipActionExecutionError.clipboardWriteFailed
        }
        guard await opener.openApplication(at: applicationURL) else {
            throw ClipActionExecutionError.applicationCouldNotOpenAfterCopy(verifiedDisplayName)
        }
        return .openedApplication(name: verifiedDisplayName)
    }

    private func validatedWebURL(_ value: String) throws -> URL {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              let url = components.url
        else { throw ClipActionExecutionError.invalidLink }
        return url
    }

    private func validatedEmail(_ value: String) throws -> String {
        guard !value.isEmpty,
              value.utf8.count <= 320,
              !value.contains(where: { $0.isWhitespace || $0.isNewline }),
              value.filter({ $0 == "@" }).count == 1,
              let at = value.lastIndex(of: "@"),
              value[value.index(after: at)...].contains(".")
        else { throw ClipActionExecutionError.invalidEmail }
        return value
    }

    private func validatedPhone(_ value: String) throws -> String {
        let hasLeadingPlus = value.hasPrefix("+")
        let digits = value.unicodeScalars.filter(CharacterSet.decimalDigits.contains)
            .map(String.init).joined()
        guard (7...15).contains(digits.count),
              value.dropFirst(hasLeadingPlus ? 1 : 0).allSatisfy({ $0.isNumber })
        else { throw ClipActionExecutionError.invalidPhoneNumber }
        return hasLeadingPlus ? "+\(digits)" : digits
    }
}

public struct CalendarEventDraft: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var startDate: Date
    public var endDate: Date
    public var notes: String

    public init(
        id: UUID = UUID(),
        title: String,
        startDate: Date,
        endDate: Date,
        notes: String
    ) {
        self.id = id
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.notes = notes
    }
}

@MainActor
public protocol CalendarEventCreating: AnyObject {
    func create(_ draft: CalendarEventDraft) async throws -> ClipActionExecutionReceipt
}

@MainActor
public final class SystemCalendarEventCreator: CalendarEventCreating {
    private let store: EKEventStore

    public init(store: EKEventStore = EKEventStore()) {
        self.store = store
    }

    public func create(_ draft: CalendarEventDraft) async throws -> ClipActionExecutionReceipt {
        guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              draft.endDate > draft.startDate
        else { throw ClipActionExecutionError.calendarSaveFailed }

        let granted: Bool
        do {
            granted = try await withCheckedThrowingContinuation { continuation in
                store.requestWriteOnlyAccessToEvents { allowed, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: allowed) }
                }
            }
        } catch {
            throw ClipActionExecutionError.calendarAccessDenied
        }
        guard granted else { throw ClipActionExecutionError.calendarAccessDenied }
        guard let calendar = store.defaultCalendarForNewEvents else {
            throw ClipActionExecutionError.calendarUnavailable
        }

        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        event.startDate = draft.startDate
        event.endDate = draft.endDate
        event.notes = draft.notes
        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            throw ClipActionExecutionError.calendarSaveFailed
        }
        return .calendarEventCreated(title: event.title)
    }
}
