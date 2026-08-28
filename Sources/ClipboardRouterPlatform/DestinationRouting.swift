import AppKit
import ClipboardRouterCore
import Foundation
import Security

public enum ExternalProductIdentity: String, Codable, Hashable, Sendable {
    case chatGPT
    case claude
    case codex
}

/// A product identity is deliberately stricter than a bundle identifier. Some official OpenAI
/// desktop builds use `com.openai.codex` while still identifying their product as ChatGPT.
public struct ExternalApplicationIdentity: Hashable, Sendable {
    public let product: ExternalProductIdentity
    public let bundleIdentifiers: Set<String>
    public let productNames: Set<String>
    public let teamIdentifiers: Set<String>

    public init(
        product: ExternalProductIdentity,
        bundleIdentifiers: Set<String>,
        productNames: Set<String>,
        teamIdentifiers: Set<String>
    ) {
        self.product = product
        self.bundleIdentifiers = bundleIdentifiers
        self.productNames = productNames
        self.teamIdentifiers = teamIdentifiers
    }
}

public struct ExternalDestination: Hashable, Identifiable, Sendable {
    public enum ID: String, CaseIterable, Codable, Sendable {
        case chatGPT
        case claude
        case codex
    }

    public let id: ID
    public let productIdentity: ExternalProductIdentity
    public let displayName: String
    public let symbolName: String
    public let applicationIdentities: [ExternalApplicationIdentity]
    public let webFallbackURL: URL?

    /// Retained as a read-only compatibility surface for settings and diagnostics. Routing never
    /// treats this list alone as proof that an application is the requested product.
    public var applicationBundleIdentifierCandidates: [String] {
        Array(Set(applicationIdentities.flatMap(\.bundleIdentifiers))).sorted()
    }

    public init(
        id: ID,
        productIdentity: ExternalProductIdentity,
        displayName: String,
        symbolName: String,
        applicationIdentities: [ExternalApplicationIdentity],
        webFallbackURL: URL?
    ) {
        self.id = id
        self.productIdentity = productIdentity
        self.displayName = displayName
        self.symbolName = symbolName
        self.applicationIdentities = applicationIdentities
        self.webFallbackURL = webFallbackURL
    }
}

public enum DestinationRegistry {
    private static let openAITeamIdentifier = "2DC432GLL2"
    private static let anthropicTeamIdentifier = "Q6L2SF6YDW"

    public static let chatGPT = ExternalDestination(
        id: .chatGPT,
        productIdentity: .chatGPT,
        displayName: "ChatGPT",
        symbolName: "sparkles",
        applicationIdentities: [
            ExternalApplicationIdentity(
                product: .chatGPT,
                bundleIdentifiers: ["com.openai.chat", "com.openai.codex"],
                productNames: ["ChatGPT"],
                teamIdentifiers: [openAITeamIdentifier]
            )
        ],
        webFallbackURL: URL(string: "https://chatgpt.com/")!
    )

    public static let claude = ExternalDestination(
        id: .claude,
        productIdentity: .claude,
        displayName: "Claude",
        symbolName: "sun.max",
        applicationIdentities: [
            ExternalApplicationIdentity(
                product: .claude,
                bundleIdentifiers: ["com.anthropic.claudefordesktop"],
                productNames: ["Claude"],
                teamIdentifiers: [anthropicTeamIdentifier]
            )
        ],
        webFallbackURL: URL(string: "https://claude.ai/new")!
    )

    public static let codex = ExternalDestination(
        id: .codex,
        productIdentity: .codex,
        displayName: "Codex",
        symbolName: "chevron.left.forwardslash.chevron.right",
        applicationIdentities: [
            ExternalApplicationIdentity(
                product: .codex,
                bundleIdentifiers: ["com.openai.codex"],
                productNames: ["Codex"],
                teamIdentifiers: [openAITeamIdentifier]
            )
        ],
        // Codex is intentionally installed-app-only. No stable product-owned web handoff
        // contract has been approved.
        webFallbackURL: nil
    )

    public static let all: [ExternalDestination] = [chatGPT, claude, codex]

    public static func destination(id: ExternalDestination.ID) -> ExternalDestination {
        switch id {
        case .chatGPT: chatGPT
        case .claude: claude
        case .codex: codex
        }
    }
}

@MainActor
public protocol PasteboardWriting: AnyObject {
    @discardableResult
    func writeForRouting(_ text: String) -> Bool
}

@MainActor
public final class SystemPasteboardWriter: PasteboardWriting {
    private let pasteboard: NSPasteboard

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    @discardableResult
    public func writeForRouting(_ text: String) -> Bool {
        pasteboard.clearContents()
        let markerType = NSPasteboard.PasteboardType(ClipboardRouterPasteboardType.appOrigin)
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setString("1", forType: markerType)
        return pasteboard.writeObjects([item])
    }
}

@MainActor
public protocol ApplicationLocating: AnyObject {
    func applicationURLs(forBundleIdentifier bundleIdentifier: String) -> [URL]
}

@MainActor
public final class WorkspaceApplicationLocator: ApplicationLocating {
    private let workspace: NSWorkspace

    public init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
    }

    public func applicationURLs(forBundleIdentifier bundleIdentifier: String) -> [URL] {
        workspace.urlsForApplications(withBundleIdentifier: bundleIdentifier)
    }
}

public enum ApplicationSignatureValidation: Equatable, Sendable {
    case valid(teamIdentifier: String?)
    case invalid
    case unavailable
}

public struct InstalledApplicationMetadata: Equatable, Sendable {
    public let url: URL
    public let bundleIdentifier: String?
    public let bundleName: String?
    public let displayName: String?
    public let executableName: String?
    public let signature: ApplicationSignatureValidation

    public init(
        url: URL,
        bundleIdentifier: String?,
        bundleName: String?,
        displayName: String?,
        executableName: String?,
        signature: ApplicationSignatureValidation
    ) {
        self.url = url.standardizedFileURL
        self.bundleIdentifier = bundleIdentifier
        self.bundleName = bundleName
        self.displayName = displayName
        self.executableName = executableName
        self.signature = signature
    }
}

@MainActor
public protocol ApplicationMetadataInspecting: AnyObject {
    func metadata(forApplicationAt url: URL) -> InstalledApplicationMetadata?
}

@MainActor
public final class SystemApplicationMetadataInspector: ApplicationMetadataInspecting {
    public init() {}

    public func metadata(forApplicationAt url: URL) -> InstalledApplicationMetadata? {
        Self.metadataSnapshot(forApplicationAt: url)
    }

    /// Code-signature inspection is synchronous and can be expensive across an Applications
    /// directory. App discovery calls this immutable snapshot helper from a utility task so the
    /// SwiftUI main actor never stalls while signatures are checked.
    public nonisolated static func metadataSnapshot(
        forApplicationAt url: URL
    ) -> InstalledApplicationMetadata? {
        metadataSnapshot(
            forApplicationAt: url,
            validityFlags: SecCSFlags(rawValue: kSecCSCheckAllArchitectures)
        )
    }

    /// Installed-app discovery needs to inspect hundreds of bundles without blocking Settings.
    /// Validate the code used by this Mac for discovery, then let every actual handoff perform
    /// the stricter all-architectures validation through `metadataSnapshot(forApplicationAt:)`.
    public nonisolated static func discoveryMetadataSnapshot(
        forApplicationAt url: URL
    ) -> InstalledApplicationMetadata? {
        metadataSnapshot(
            forApplicationAt: url,
            validityFlags: SecCSFlags(rawValue: 0)
        )
    }

    private nonisolated static func metadataSnapshot(
        forApplicationAt url: URL,
        validityFlags: SecCSFlags
    ) -> InstalledApplicationMetadata? {
        let standardizedURL = url.standardizedFileURL
        guard standardizedURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
              let bundle = Bundle(url: standardizedURL)
        else { return nil }

        return InstalledApplicationMetadata(
            url: standardizedURL,
            bundleIdentifier: bundle.bundleIdentifier,
            bundleName: bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
            displayName: bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
            executableName: bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String,
            signature: Self.signatureValidation(for: standardizedURL, validityFlags: validityFlags)
        )
    }

    private nonisolated static func signatureValidation(
        for url: URL,
        validityFlags: SecCSFlags
    ) -> ApplicationSignatureValidation {
        var staticCode: SecStaticCode?
        let creationStatus = SecStaticCodeCreateWithPath(
            url as CFURL,
            SecCSFlags(rawValue: 0),
            &staticCode
        )
        guard creationStatus == errSecSuccess, let staticCode else { return .unavailable }

        let validityStatus = SecStaticCodeCheckValidity(
            staticCode,
            validityFlags,
            nil
        )
        guard validityStatus == errSecSuccess else { return .invalid }

        var signingInformation: CFDictionary?
        let informationStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInformation
        )
        guard informationStatus == errSecSuccess,
              let information = signingInformation as? [String: Any]
        else { return .valid(teamIdentifier: nil) }

        return .valid(teamIdentifier: information[kSecCodeInfoTeamIdentifier as String] as? String)
    }
}

public struct InstalledDestinationApplication: Equatable, Sendable {
    public let url: URL
    public let product: ExternalProductIdentity
    public let bundleIdentifier: String
    public let displayName: String
    public let teamIdentifier: String

    public init(
        url: URL,
        product: ExternalProductIdentity,
        bundleIdentifier: String,
        displayName: String,
        teamIdentifier: String
    ) {
        self.url = url.standardizedFileURL
        self.product = product
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.teamIdentifier = teamIdentifier
    }
}

public protocol DestinationApplicationPreferenceProviding: AnyObject {
    func selectedApplicationBookmarkData(for destination: ExternalDestination.ID) -> Data?
    func setSelectedApplicationBookmarkData(
        _ bookmarkData: Data?,
        for destination: ExternalDestination.ID
    )
}

public final class UserDefaultsDestinationApplicationPreferences:
    DestinationApplicationPreferenceProviding
{
    private let defaults: UserDefaults
    private let keyPrefix: String

    public init(
        defaults: UserDefaults = .standard,
        keyPrefix: String = "destinationApplicationBookmark.v2."
    ) {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    public func selectedApplicationBookmarkData(
        for destination: ExternalDestination.ID
    ) -> Data? {
        defaults.data(forKey: keyPrefix + destination.rawValue)
    }

    public func setSelectedApplicationBookmarkData(
        _ bookmarkData: Data?,
        for destination: ExternalDestination.ID
    ) {
        let key = keyPrefix + destination.rawValue
        if let bookmarkData {
            defaults.set(bookmarkData, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

public struct ResolvedApplicationBookmark: Equatable, Sendable {
    public let url: URL
    public let isStale: Bool
    public let isAccessingSecurityScopedResource: Bool

    public init(
        url: URL,
        isStale: Bool,
        isAccessingSecurityScopedResource: Bool
    ) {
        self.url = url.standardizedFileURL
        self.isStale = isStale
        self.isAccessingSecurityScopedResource = isAccessingSecurityScopedResource
    }
}

public protocol ApplicationBookmarking: AnyObject, Sendable {
    func bookmarkData(forApplicationAt url: URL) throws -> Data
    func resolveApplicationBookmark(_ data: Data) throws -> ResolvedApplicationBookmark
    func stopAccessing(_ bookmark: ResolvedApplicationBookmark)
}

public final class SecurityScopedApplicationBookmarkStore: ApplicationBookmarking, @unchecked Sendable {
    public init() {}

    public func bookmarkData(forApplicationAt url: URL) throws -> Data {
        try url.standardizedFileURL.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    public func resolveApplicationBookmark(_ data: Data) throws -> ResolvedApplicationBookmark {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ).standardizedFileURL
        return ResolvedApplicationBookmark(
            url: url,
            isStale: isStale,
            isAccessingSecurityScopedResource: url.startAccessingSecurityScopedResource()
        )
    }

    public func stopAccessing(_ bookmark: ResolvedApplicationBookmark) {
        if bookmark.isAccessingSecurityScopedResource {
            bookmark.url.stopAccessingSecurityScopedResource()
        }
    }
}

public enum DestinationApplicationCatalogError: Error, Equatable, LocalizedError, Sendable {
    case applicationIsNotRecognized(ExternalDestination.ID)
    case bookmarkCouldNotBeCreated(ExternalDestination.ID)

    public var errorDescription: String? {
        switch self {
        case let .applicationIsNotRecognized(destination):
            "The selected app is not a verified \(DestinationRegistry.destination(id: destination).displayName) desktop app."
        case let .bookmarkCouldNotBeCreated(destination):
            "Clipboard Router could not remember the selected \(DestinationRegistry.destination(id: destination).displayName) app."
        }
    }
}

@MainActor
public final class DestinationApplicationCatalog {
    private let applications: any ApplicationLocating
    private let metadataInspector: any ApplicationMetadataInspecting
    private let preferences: any DestinationApplicationPreferenceProviding
    private let bookmarks: any ApplicationBookmarking

    public init(
        applications: any ApplicationLocating = WorkspaceApplicationLocator(),
        metadataInspector: any ApplicationMetadataInspecting = SystemApplicationMetadataInspector(),
        preferences: any DestinationApplicationPreferenceProviding =
            UserDefaultsDestinationApplicationPreferences(),
        bookmarks: any ApplicationBookmarking = SecurityScopedApplicationBookmarkStore()
    ) {
        self.applications = applications
        self.metadataInspector = metadataInspector
        self.preferences = preferences
        self.bookmarks = bookmarks
    }

    public func installedApplications(
        for destination: ExternalDestination
    ) -> [InstalledDestinationApplication] {
        var seenPaths = Set<String>()
        return destination.applicationBundleIdentifierCandidates
            .flatMap { applications.applicationURLs(forBundleIdentifier: $0) }
            .map(\.standardizedFileURL)
            .filter { seenPaths.insert($0.path).inserted }
            .compactMap { verifiedApplication(at: $0, for: destination) }
            .sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
    }

    public func installedApplicationURLs(for destination: ExternalDestination) -> [URL] {
        installedApplications(for: destination).map(\.url)
    }

    public func selectedApplicationURL(for destination: ExternalDestination) -> URL? {
        guard let selection = selectedApplicationHoldingAccess(for: destination) else { return nil }
        defer { bookmarks.stopAccessing(selection.bookmark) }
        return selection.application.url
    }

    /// Validates a URL selected by an application picker and persists a security-scoped bookmark.
    /// The URL does not have to appear in Launch Services results, which makes an explicit
    /// "Choose Application…" flow possible for apps installed in nonstandard locations.
    @discardableResult
    public func chooseApplication(
        at url: URL,
        for destination: ExternalDestination
    ) throws -> InstalledDestinationApplication {
        guard let application = verifiedApplication(at: url, for: destination) else {
            throw DestinationApplicationCatalogError.applicationIsNotRecognized(destination.id)
        }
        let bookmarkData: Data
        do {
            bookmarkData = try bookmarks.bookmarkData(forApplicationAt: application.url)
        } catch {
            throw DestinationApplicationCatalogError.bookmarkCouldNotBeCreated(destination.id)
        }
        preferences.setSelectedApplicationBookmarkData(bookmarkData, for: destination.id)
        return application
    }

    /// Compatibility API used by the existing settings UI. New pickers should call
    /// `chooseApplication(at:for:)` so validation failures can be presented to the user.
    @discardableResult
    public func setSelectedApplicationURL(
        _ url: URL?,
        for destination: ExternalDestination
    ) -> Bool {
        guard let url else {
            preferences.setSelectedApplicationBookmarkData(nil, for: destination.id)
            return true
        }
        do {
            try chooseApplication(at: url, for: destination)
            return true
        } catch {
            return false
        }
    }

    fileprivate func resolveTarget(
        for destination: ExternalDestination
    ) throws -> ResolvedDestinationTarget {
        if let selection = selectedApplicationHoldingAccess(for: destination) {
            return .desktop(selection.application, bookmark: selection.bookmark)
        }

        let installed = installedApplications(for: destination)
        if installed.count == 1 {
            return .desktop(installed[0], bookmark: nil)
        }
        if installed.count > 1 {
            throw DestinationRoutingError.applicationSelectionRequired(destination.id)
        }
        if let webFallbackURL = destination.webFallbackURL {
            return .web(webFallbackURL)
        }
        return .copyOnly
    }

    fileprivate func prepareTarget(
        ownerID: UUID,
        for destination: ExternalDestination
    ) throws -> PreparedDestinationTarget {
        let resolvedTarget = try resolveTarget(for: destination)
        return PreparedDestinationTarget(
            ownerID: ownerID,
            destination: destination,
            resolvedTarget: resolvedTarget,
            bookmarks: bookmarks
        )
    }

    private func selectedApplicationHoldingAccess(
        for destination: ExternalDestination
    ) -> (application: InstalledDestinationApplication, bookmark: ResolvedApplicationBookmark)? {
        guard let bookmarkData = preferences.selectedApplicationBookmarkData(for: destination.id)
        else { return nil }

        do {
            let bookmark = try bookmarks.resolveApplicationBookmark(bookmarkData)
            guard let application = verifiedApplication(at: bookmark.url, for: destination) else {
                bookmarks.stopAccessing(bookmark)
                preferences.setSelectedApplicationBookmarkData(nil, for: destination.id)
                return nil
            }
            if bookmark.isStale,
               let refreshed = try? bookmarks.bookmarkData(forApplicationAt: bookmark.url)
            {
                preferences.setSelectedApplicationBookmarkData(refreshed, for: destination.id)
            }
            return (application, bookmark)
        } catch {
            preferences.setSelectedApplicationBookmarkData(nil, for: destination.id)
            return nil
        }
    }

    private func verifiedApplication(
        at url: URL,
        for destination: ExternalDestination
    ) -> InstalledDestinationApplication? {
        guard let metadata = metadataInspector.metadata(forApplicationAt: url),
              let bundleIdentifier = metadata.bundleIdentifier,
              let identity = destination.applicationIdentities.first(where: {
                  Self.matches(metadata, identity: $0)
              }),
              identity.product == destination.productIdentity,
              case let .valid(teamIdentifier?) = metadata.signature
        else { return nil }

        let displayName = metadata.displayName ?? metadata.bundleName ?? metadata.executableName
        guard let displayName else { return nil }
        return InstalledDestinationApplication(
            url: metadata.url,
            product: identity.product,
            bundleIdentifier: bundleIdentifier,
            displayName: displayName,
            teamIdentifier: teamIdentifier
        )
    }

    private static func matches(
        _ metadata: InstalledApplicationMetadata,
        identity: ExternalApplicationIdentity
    ) -> Bool {
        guard let bundleIdentifier = metadata.bundleIdentifier,
              identity.bundleIdentifiers.contains(bundleIdentifier),
              case let .valid(teamIdentifier?) = metadata.signature,
              identity.teamIdentifiers.contains(teamIdentifier)
        else { return false }

        let observedNames = [metadata.displayName, metadata.bundleName, metadata.executableName]
            .compactMap { $0 }
            .map(normalizeProductName)
        let acceptedNames = Set(identity.productNames.map(normalizeProductName))
        return observedNames.contains { acceptedNames.contains($0) }
    }

    private static func normalizeProductName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
    }
}

@MainActor
public protocol ExternalURLOpening: AnyObject {
    func openApplication(at url: URL) async -> Bool
    func openWebURL(_ url: URL) -> Bool
}

@MainActor
public final class WorkspaceExternalURLOpener: ExternalURLOpening {
    private let workspace: NSWorkspace

    public init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
    }

    public func openApplication(at url: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            workspace.openApplication(
                at: url,
                configuration: NSWorkspace.OpenConfiguration()
            ) { _, error in
                continuation.resume(returning: error == nil)
            }
        }
    }

    public func openWebURL(_ url: URL) -> Bool {
        workspace.open(url)
    }
}

public enum DestinationLaunchTarget: Equatable, Sendable {
    case desktopApplication(product: ExternalProductIdentity, bundleIdentifier: String)
    case web(URL)
    case copyOnly
}

public struct DestinationRouteReceipt: Equatable, Sendable {
    public let destination: ExternalDestination.ID
    public let target: DestinationLaunchTarget

    public init(destination: ExternalDestination.ID, target: DestinationLaunchTarget) {
        self.destination = destination
        self.target = target
    }

    public var userMessage: String {
        let name = DestinationRegistry.destination(id: destination).displayName
        return switch target {
        case .desktopApplication:
            "Copied — paste in \(name) desktop."
        case .web:
            "Copied — paste in \(name) on the web."
        case .copyOnly:
            "Copied. \(name) desktop was not found; paste manually."
        }
    }
}

public enum DestinationRoutingError: Error, Equatable, LocalizedError, Sendable {
    case emptyContent
    case clipboardWriteFailed
    case applicationSelectionRequired(ExternalDestination.ID)
    case applicationNotInstalled(ExternalDestination.ID)
    case destinationCouldNotOpen(ExternalDestination.ID)
    case preparedTargetAlreadyConsumed
    case preparedTargetBelongsToDifferentRouter

    public var errorDescription: String? {
        switch self {
        case .emptyContent:
            "There is no clip content to copy."
        case .clipboardWriteFailed:
            "Clipboard Router could not copy this clip."
        case let .applicationSelectionRequired(destination):
            "More than one verified \(DestinationRegistry.destination(id: destination).displayName) app is installed. Choose the exact app in Settings."
        case let .applicationNotInstalled(destination):
            "The \(DestinationRegistry.destination(id: destination).displayName) desktop app is not installed."
        case let .destinationCouldNotOpen(destination):
            "The clip is on the clipboard, but Clipboard Router could not open \(DestinationRegistry.destination(id: destination).displayName)."
        case .preparedTargetAlreadyConsumed:
            "This prepared destination has already been opened or cancelled."
        case .preparedTargetBelongsToDifferentRouter:
            "This prepared destination belongs to a different router."
        }
    }
}

fileprivate enum ResolvedDestinationTarget {
    case desktop(InstalledDestinationApplication, bookmark: ResolvedApplicationBookmark?)
    case web(URL)
    case copyOnly

    var publicLaunchTarget: DestinationLaunchTarget {
        switch self {
        case let .desktop(application, _):
            .desktopApplication(
                product: application.product,
                bundleIdentifier: application.bundleIdentifier
            )
        case let .web(url):
            .web(url)
        case .copyOnly:
            .copyOnly
        }
    }
}

/// A preflighted, exact launch target. If it was resolved from a security-scoped bookmark, that
/// access remains active until `openPreparedTarget(_:)`, `cancel()`, or deinitialization.
/// Instances are single-use and intentionally not `Sendable`; destination work is MainActor-bound.
@MainActor
public final class PreparedDestinationTarget {
    private enum State: Equatable {
        case ready
        case consumed
        case cancelled
    }

    public let destinationID: ExternalDestination.ID
    public let launchTarget: DestinationLaunchTarget

    fileprivate let ownerID: UUID
    fileprivate let destination: ExternalDestination
    fileprivate let resolvedTarget: ResolvedDestinationTarget
    private let bookmarks: any ApplicationBookmarking
    private var state: State = .ready
    private var releasedSecurityScope = false

    fileprivate init(
        ownerID: UUID,
        destination: ExternalDestination,
        resolvedTarget: ResolvedDestinationTarget,
        bookmarks: any ApplicationBookmarking
    ) {
        self.ownerID = ownerID
        self.destination = destination
        self.destinationID = destination.id
        self.resolvedTarget = resolvedTarget
        self.launchTarget = resolvedTarget.publicLaunchTarget
        self.bookmarks = bookmarks
    }

    /// Releases retained bookmark access without opening the destination. Safe to call repeatedly.
    public func cancel() {
        guard state == .ready else { return }
        state = .cancelled
        releaseSecurityScopeIfNeeded()
    }

    fileprivate func claim(for ownerID: UUID) throws -> ResolvedDestinationTarget {
        guard self.ownerID == ownerID else {
            throw DestinationRoutingError.preparedTargetBelongsToDifferentRouter
        }
        guard state == .ready else {
            throw DestinationRoutingError.preparedTargetAlreadyConsumed
        }
        state = .consumed
        return resolvedTarget
    }

    fileprivate func finish() {
        releaseSecurityScopeIfNeeded()
    }

    private func releaseSecurityScopeIfNeeded() {
        guard !releasedSecurityScope else { return }
        releasedSecurityScope = true
        if case let .desktop(_, bookmark?) = resolvedTarget {
            bookmarks.stopAccessing(bookmark)
        }
    }

    deinit {
        if !releasedSecurityScope,
           case let .desktop(_, bookmark?) = resolvedTarget
        {
            bookmarks.stopAccessing(bookmark)
        }
    }
}

/// Resolves a verified destination before touching the clipboard, then copies and opens exactly
/// that target. It never injects text, submits a prompt, or silently changes from desktop to web.
@MainActor
public final class DestinationRouter {
    private let routerID = UUID()
    private let pasteboard: any PasteboardWriting
    private let catalog: DestinationApplicationCatalog
    private let opener: any ExternalURLOpening

    public init(
        pasteboard: any PasteboardWriting = SystemPasteboardWriter(),
        applications: any ApplicationLocating = WorkspaceApplicationLocator(),
        metadataInspector: any ApplicationMetadataInspecting = SystemApplicationMetadataInspector(),
        preferences: any DestinationApplicationPreferenceProviding =
            UserDefaultsDestinationApplicationPreferences(),
        bookmarks: any ApplicationBookmarking = SecurityScopedApplicationBookmarkStore(),
        opener: any ExternalURLOpening = WorkspaceExternalURLOpener()
    ) {
        self.pasteboard = pasteboard
        self.catalog = DestinationApplicationCatalog(
            applications: applications,
            metadataInspector: metadataInspector,
            preferences: preferences,
            bookmarks: bookmarks
        )
        self.opener = opener
    }

    public func route(
        _ content: ClipContent,
        to destination: ExternalDestination
    ) async throws -> DestinationRouteReceipt {
        guard !content.text.isEmpty else { throw DestinationRoutingError.emptyContent }

        // Preflight first. In particular, an ambiguous desktop selection must not overwrite the
        // user's clipboard and then fail before opening anything.
        let preparedTarget = try prepareDestination(destination)
        defer { preparedTarget.cancel() }

        guard pasteboard.writeForRouting(content.text) else {
            throw DestinationRoutingError.clipboardWriteFailed
        }
        return try await openPreparedTarget(preparedTarget)
    }

    /// Resolves and retains one exact destination before a privacy-aware component places
    /// plaintext on the pasteboard. Vault should call this first, then Secure Paste, then
    /// `openPreparedTarget(_:)`. Call `cancel()` if Secure Paste fails.
    public func prepareDestination(
        _ destination: ExternalDestination
    ) throws -> PreparedDestinationTarget {
        try catalog.prepareTarget(ownerID: routerID, for: destination)
    }

    /// Opens only the desktop URL or web URL captured by `prepareDestination(_:)`. It never
    /// re-resolves applications and never changes from a failed desktop launch to the web.
    public func openPreparedTarget(
        _ preparedTarget: PreparedDestinationTarget
    ) async throws -> DestinationRouteReceipt {
        let target = try preparedTarget.claim(for: routerID)
        defer { preparedTarget.finish() }
        return try await open(target, for: preparedTarget.destination)
    }

    /// Opens a destination after another privacy-aware component has prepared the clipboard.
    /// Compatibility only: Vault must use the two-phase prepared-target API so destination
    /// resolution happens before Secure Paste writes plaintext.
    @available(
        *,
        deprecated,
        message: "Call prepareDestination before writing, then openPreparedTarget."
    )
    public func openPreparedContent(
        in destination: ExternalDestination
    ) async throws -> DestinationRouteReceipt {
        let preparedTarget = try prepareDestination(destination)
        defer { preparedTarget.cancel() }
        return try await openPreparedTarget(preparedTarget)
    }

    private func open(
        _ target: ResolvedDestinationTarget,
        for destination: ExternalDestination
    ) async throws -> DestinationRouteReceipt {
        switch target {
        case let .desktop(application, _):
            guard await opener.openApplication(at: application.url) else {
                // A failed installed-app launch is not permission to send the user to the web.
                throw DestinationRoutingError.destinationCouldNotOpen(destination.id)
            }
            return DestinationRouteReceipt(
                destination: destination.id,
                target: .desktopApplication(
                    product: application.product,
                    bundleIdentifier: application.bundleIdentifier
                )
            )
        case let .web(url):
            guard opener.openWebURL(url) else {
                throw DestinationRoutingError.destinationCouldNotOpen(destination.id)
            }
            return DestinationRouteReceipt(destination: destination.id, target: .web(url))
        case .copyOnly:
            return DestinationRouteReceipt(destination: destination.id, target: .copyOnly)
        }
    }
}
