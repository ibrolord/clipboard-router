import AppKit
import ClipboardRouterCore
import ClipboardRouterPlatform
import ClipboardRouterSecurity
import Foundation

/// An opt-in, package-only fixture used by the external Accessibility acceptance runner.
///
/// The fixture is deliberately gated twice: the process must have the dedicated acceptance
/// bundle identifier and it must receive the explicit `--ui-acceptance` argument. A production
/// app can therefore never enter this path because of an inherited environment variable alone.
@MainActor
enum UIAcceptanceRuntime {
    static let bundleIdentifier = "com.clipboardrouter.ClipboardRouter.uiacceptance"
    static let enableArgument = "--clipboard-router-ui-acceptance"
    static let runIDArgument = "--ui-acceptance-run-id"
    static let fixtureHistoryCount = 1_001
    static let livePreviewLoadedFixtureID = fixtureUUID(index: 2)
    static let livePreviewOfflineFixtureID = fixtureUUID(index: 3)
    static let livePreviewBlockedPrivateFixtureID = fixtureUUID(index: 4)
    static let livePreviewLoadedURL = "https://preview.clipboardrouter.test/loaded"
    static let livePreviewOfflineURL = "https://preview.clipboardrouter.test/offline"
    static let livePreviewBlockedPrivateURL = "https://127.0.0.1/private"
    private static let initializedDefaultsKey = "uiAcceptanceFixtureInitialized.v1"

    struct Configuration: Equatable {
        let runID: String
        let defaultsSuiteName: String
        let supportDirectory: URL
    }

    static func configuration(
        bundleIdentifier observedBundleIdentifier: String? = Bundle.main.bundleIdentifier,
        arguments: [String] = ProcessInfo.processInfo.arguments,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> Configuration? {
        guard observedBundleIdentifier == bundleIdentifier,
              arguments.contains(enableArgument),
              let runIDIndex = arguments.firstIndex(of: runIDArgument),
              arguments.indices.contains(runIDIndex + 1)
        else { return nil }

        let runID = arguments[runIDIndex + 1]
        guard isSafeRunID(runID) else { return nil }
        let suiteName = "\(bundleIdentifier).\(runID)"
        let root = temporaryDirectory
            .appendingPathComponent("ClipboardRouterUIAcceptance", isDirectory: true)
            .appendingPathComponent(runID, isDirectory: true)
        return Configuration(
            runID: runID,
            defaultsSuiteName: suiteName,
            supportDirectory: root
        )
    }

    static func makeModelIfEnabled(
        bundleIdentifier observedBundleIdentifier: String? = Bundle.main.bundleIdentifier,
        arguments: [String] = ProcessInfo.processInfo.arguments,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> AppModel? {
        guard observedBundleIdentifier == bundleIdentifier else { return nil }
        guard let configuration = configuration(
            bundleIdentifier: observedBundleIdentifier,
            arguments: arguments,
            temporaryDirectory: temporaryDirectory
        ), let model = makeModel(configuration: configuration, menuBarClipLimit: 1_000)
        else {
            // The dedicated acceptance executable must never fall through to AppModel's
            // production Application Support path when its gate or isolated storage fails.
            return makeFailClosedModel(temporaryDirectory: temporaryDirectory)
        }
        return model
    }

    /// Creates the same isolated model used by the packaged acceptance app without requiring
    /// the process-level opt-in gate. This is intentionally internal so native visual tests can
    /// render real app views with deterministic state and no Keychain, General-pasteboard,
    /// hot-key, login-item, location, or Accessibility side effects.
    static func makeModel(
        configuration: Configuration,
        menuBarClipLimit: Int = AppModel.defaultMenuBarClipLimit
    ) -> AppModel? {
        guard AppModel.menuBarClipLimitRange.contains(menuBarClipLimit),
              let defaults = UserDefaults(suiteName: configuration.defaultsSuiteName)
        else { return nil }

        do {
            try prepareIsolatedPersistence(
                configuration: configuration,
                defaults: defaults,
                menuBarClipLimit: menuBarClipLimit
            )
        } catch {
            return nil
        }

        let catalog = DestinationApplicationCatalog(
            preferences: UserDefaultsDestinationApplicationPreferences(defaults: defaults)
        )
        let isolatedPasteboard = pasteboard(for: configuration)
        let assetStore = FileClipAssetStore(
            rootURL: configuration.supportDirectory
                .appendingPathComponent("clip-assets", isDirectory: true)
        )
        return AppModel(
            defaults: defaults,
            destinationCatalog: catalog,
            hostedAssistantCredentialStore: UIAcceptanceHostedAssistantCredentialStore(),
            liveLinkPreviewClient: UIAcceptanceLiveLinkPreviewClient(),
            pasteboardReader: SystemPasteboardReader(pasteboard: isolatedPasteboard),
            pasteboardWriter: SystemPasteboardWriter(pasteboard: isolatedPasteboard),
            typedPasteboardWriter: TypedSystemPasteboardWriter(
                pasteboard: isolatedPasteboard,
                assetStore: assetStore
            ),
            hotKey: UIAcceptanceHotKeyRegistrar(),
            launchAtLoginService: UIAcceptanceLaunchAtLoginService(),
            captureContextProvider: UIAcceptanceCaptureContextProvider(),
            textExpansionAccessibility: UIAcceptanceTextExpansionAccessibility(),
            textExpansionEvents: UIAcceptanceTextExpansionEvents(),
            supportDirectory: configuration.supportDirectory
        )
    }

    /// A deterministic, run-scoped named pasteboard exercises the production writers without
    /// replacing the user's General pasteboard. Its name is derivable from the safe run id, so an
    /// out-of-process acceptance check can inspect the app-origin marker and representations.
    static func pasteboard(for configuration: Configuration) -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name(
            "\(bundleIdentifier).pasteboard.\(configuration.runID)"
        ))
    }

    static func fixtureSnapshot(referenceDate: Date = Date(timeIntervalSince1970: 2_000_000_000))
        -> ClipboardLibrarySnapshot
    {
        let history = (1...fixtureHistoryCount).map { index in
            let content = try! ClipContent.detect(text: fixtureText(index: index))
            return HistoryItem(
                id: fixtureUUID(index: index),
                content: content,
                createdAt: referenceDate.addingTimeInterval(TimeInterval(-index)),
                sourceApplicationBundleIdentifier: "com.clipboardrouter.fixture.source",
                pasteboardTypeIdentifiers: ["public.utf8-plain-text"]
            )
        }
        let note = try! SavedClip(
            id: fixtureUUID(index: 9_001),
            kind: .note,
            name: "Acceptance Editable Note",
            content: ClipContent.detect(text: "Acceptance note body"),
            createdAt: referenceDate,
            pinnedAt: referenceDate,
            tags: ["acceptance"],
            sourceApplicationBundleIdentifier: "com.clipboardrouter.fixture.source"
        )
        return ClipboardLibrarySnapshot(
            history: history,
            savedClips: [note],
            settings: ClipboardLibrarySettings(
                capturePolicy: CapturePolicy(isCaptureEnabled: false),
                retentionPolicy: .unlimited,
                maximumHistoryItemCount: 10_000,
                isSecretDetectionEnabled: false
            )
        )
    }

    static func fixtureText(index: Int) -> String {
        switch index {
        case 1:
            return "Email Sarah at sarah@example.com tomorrow at 2 PM — acceptance clip 0001"
        case 2:
            return livePreviewLoadedURL
        case 3:
            return livePreviewOfflineURL
        case 4:
            return livePreviewBlockedPrivateURL
        default:
            return String(format: "Acceptance clip %04d", index)
        }
    }

    static func fixtureUUID(index: Int) -> UUID {
        precondition((0...999_999_999_999).contains(index))
        return UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!
    }

    static func fixtureReviewFlow() -> ClipFlow {
        try! ClipFlow(
            id: fixtureUUID(index: 9_101),
            name: "Acceptance Review Flow",
            trigger: .manual,
            entityFilter: .any,
            steps: [
                .addTags(id: fixtureUUID(index: 9_102), tags: ["acceptance-reviewed"]),
                .createTaskDraft(
                    id: fixtureUUID(index: 9_103),
                    titleTemplate: "Follow up: {title}",
                    dueInDays: 2
                ),
            ]
        )
    }

    private static func isSafeRunID(_ value: String) -> Bool {
        (1...64).contains(value.utf8.count)
            && value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    /// Seeds only a never-opened run directory. AppModel then uses its normal SQLite persistence
    /// and one-time legacy import, so subsequent launches prove the same local durability path as
    /// production while remaining entirely below the run-specific temporary root.
    private static func prepareIsolatedPersistence(
        configuration: Configuration,
        defaults: UserDefaults,
        menuBarClipLimit: Int
    ) throws {
        try FileManager.default.createDirectory(
            at: configuration.supportDirectory,
            withIntermediateDirectories: true
        )

        let sqliteURL = configuration.supportDirectory.appendingPathComponent("library.sqlite3")
        let seedURL = configuration.supportDirectory.appendingPathComponent("library.json")
        if !FileManager.default.fileExists(atPath: sqliteURL.path),
           !FileManager.default.fileExists(atPath: seedURL.path)
        {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(fixtureSnapshot())
            try data.write(to: seedURL, options: [.atomic])
        }

        guard !defaults.bool(forKey: initializedDefaultsKey) else { return }
        defaults.set(true, forKey: "hasCompletedOnboarding.v1")
        defaults.set(menuBarClipLimit, forKey: "menuBarClipLimit.v1")
        defaults.set("acceptance-capture-context", forKey: "captureContextInstallationID.v1")
        defaults.set("acceptance-license-device", forKey: "directLicenseDeviceID.v1")
        defaults.set(
            "00000000-0000-0000-0000-000000009101",
            forKey: "productMetricsInstallationID.v1"
        )
        defaults.set("acceptance-sync-device", forKey: "savedLibrarySyncDeviceID.v1")
        defaults.set(
            try JSONEncoder().encode([fixtureReviewFlow()]),
            forKey: "clipFlows.v1"
        )
        defaults.set(true, forKey: initializedDefaultsKey)
    }

    static func makeFailClosedModel(
        temporaryDirectory: URL,
        pasteboard injectedPasteboard: NSPasteboard? = nil
    ) -> AppModel {
        let processID = ProcessInfo.processInfo.processIdentifier
        let defaultsName = "\(bundleIdentifier).fail-closed.\(processID)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defaults.set(false, forKey: "hasCompletedOnboarding.v1")
        let supportDirectory = temporaryDirectory
            .appendingPathComponent("ClipboardRouterUIAcceptance", isDirectory: true)
            .appendingPathComponent("fail-closed", isDirectory: true)
        let pasteboard = injectedPasteboard ?? NSPasteboard(name: NSPasteboard.Name(
            "\(bundleIdentifier).pasteboard.fail-closed.\(processID)"
        ))
        let assetStore = FileClipAssetStore(
            rootURL: supportDirectory.appendingPathComponent("clip-assets", isDirectory: true)
        )
        let emptyCaptureOff = ClipboardLibrarySnapshot(settings: ClipboardLibrarySettings(
            capturePolicy: CapturePolicy(isCaptureEnabled: false)
        ))
        return AppModel(
            defaults: defaults,
            destinationCatalog: DestinationApplicationCatalog(
                preferences: UserDefaultsDestinationApplicationPreferences(defaults: defaults)
            ),
            hostedAssistantCredentialStore: UIAcceptanceHostedAssistantCredentialStore(),
            liveLinkPreviewClient: UIAcceptanceLiveLinkPreviewClient(),
            pasteboardReader: SystemPasteboardReader(pasteboard: pasteboard),
            pasteboardWriter: SystemPasteboardWriter(pasteboard: pasteboard),
            typedPasteboardWriter: TypedSystemPasteboardWriter(
                pasteboard: pasteboard,
                assetStore: assetStore
            ),
            hotKey: UIAcceptanceHotKeyRegistrar(),
            launchAtLoginService: UIAcceptanceLaunchAtLoginService(),
            captureContextProvider: UIAcceptanceCaptureContextProvider(),
            textExpansionAccessibility: UIAcceptanceTextExpansionAccessibility(),
            textExpansionEvents: UIAcceptanceTextExpansionEvents(),
            supportDirectory: supportDirectory,
            libraryPersistence: InMemoryClipboardLibraryStore(snapshot: emptyCaptureOff)
        )
    }
}

/// A package-acceptance-only preview client. Every result is resolved from an exact fixture URL;
/// unknown URLs fail closed, and this type has no networking dependency or fallback.
private actor UIAcceptanceLiveLinkPreviewClient: LiveLinkPreviewFetching {
    private static let fetchedAt = Date(timeIntervalSince1970: 2_000_000_123)

    func preview(for url: URL, refresh: Bool) async throws -> LiveLinkPreviewMetadata {
        switch url.absoluteString {
        case UIAcceptanceRuntime.livePreviewLoadedURL:
            return LiveLinkPreviewMetadata(
                sourceURL: url,
                title: refresh ? "Acceptance Preview Refreshed" : "Acceptance Preview Loaded",
                siteName: "Clipboard Router Acceptance",
                summary: refresh
                    ? "Deterministic refreshed metadata from the packaged acceptance client. No network request was made."
                    : "Deterministic metadata from the packaged acceptance client. No network request was made.",
                fetchedAt: Self.fetchedAt
            )
        case UIAcceptanceRuntime.livePreviewOfflineURL:
            throw LiveLinkPreviewError.offline
        default:
            throw LiveLinkPreviewError.invalidResponse
        }
    }

    func removeCachedPreview(for url: URL) async {}
    func clearCache() async {}
}

@MainActor
private final class UIAcceptanceHotKeyRegistrar: GlobalHotKeyRegistering {
    func register(
        _ descriptor: GlobalHotKeyDescriptor,
        handler: @escaping @MainActor () -> Void
    ) throws {}

    func register(
        id: GlobalHotKeyRegistrationID,
        descriptor: GlobalHotKeyDescriptor,
        handler: @escaping @MainActor () -> Void
    ) throws {}

    func unregister() {}
    func unregister(id: GlobalHotKeyRegistrationID) {}
}

@MainActor
private struct UIAcceptanceLaunchAtLoginService: LaunchAtLoginServicing {
    var state: LaunchAtLoginState { .unavailable }
    func register() throws {}
    func unregister() throws {}
    func openSystemSettings() {}
}

@MainActor
private final class UIAcceptanceCaptureContextProvider: CaptureContextProviding {
    var deviceContext: DeviceCaptureContext {
        DeviceCaptureContext(label: "Acceptance Mac", operatingSystem: "Acceptance macOS")
    }
    var locationAuthorization: CaptureLocationAuthorization { .denied }
    var cachedCoarseLocation: CoarseLocationContext? { nil }
    var cachedLocationDate: Date? { nil }

    func requestLocationPermissionAndRefresh(at date: Date) async throws -> CoarseLocationContext {
        throw CaptureContextProviderError.locationPermissionDenied
    }

    func refreshLocation(at date: Date) async throws -> CoarseLocationContext {
        throw CaptureContextProviderError.locationPermissionDenied
    }

    func currentCoarseLocation(at date: Date) -> CoarseLocationContext? { nil }
    func clearLocation() {}
}

private struct UIAcceptanceHostedAssistantCredentialStore: HostedAssistantCredentialStoring {
    func loadAPIKey() throws -> String? { nil }
    func saveAPIKey(_ apiKey: String) throws {}
    func deleteAPIKey() throws {}
}

@MainActor
private final class UIAcceptanceTextExpansionAccessibility:
    TextExpansionAccessibilityControlling
{
    func access(promptIfNeeded: Bool) -> PasteAutomationAccess { .permissionRequired }
    func focusedTarget() -> TextExpansionFocus? { nil }
    func replaceCharactersBeforeCursor(
        _ count: Int,
        with replacement: String,
        focus: TextExpansionFocus
    ) -> TextExpansionMutationReceipt? { nil }
    func undo(_ receipt: TextExpansionMutationReceipt) -> Bool { false }
}

@MainActor
private final class UIAcceptanceTextExpansionEvents: TextExpansionEventMonitoring {
    func start(handler: @escaping @MainActor (Character, Date) -> Void) -> Bool { false }
    func stop() {}
}
