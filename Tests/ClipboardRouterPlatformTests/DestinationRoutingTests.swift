import AppKit
import ClipboardRouterCore
import XCTest
@testable import ClipboardRouterPlatform

@MainActor
final class DestinationRoutingTests: XCTestCase {
    func testInstalledApplicationIsSelectedByVerifiedProductIdentity() async throws {
        let appURL = URL(fileURLWithPath: "/Applications/ChatGPT.app")
        let environment = FakeApplicationEnvironment(installations: [
            .official(url: appURL, bundleIdentifier: "com.openai.chat", productName: "ChatGPT")
        ])
        let pasteboard = FakePasteboardWriter()
        let opener = FakeExternalURLOpener()
        let router = makeRouter(
            pasteboard: pasteboard,
            environment: environment,
            opener: opener
        )

        let receipt = try await router.route(
            try ClipContent.detect(text: "Explain this"),
            to: DestinationRegistry.chatGPT
        )

        XCTAssertEqual(pasteboard.writtenTexts, ["Explain this"])
        XCTAssertEqual(
            environment.requestedBundleIdentifiers,
            ["com.openai.chat", "com.openai.codex"]
        )
        XCTAssertEqual(opener.applicationURLs, [appURL])
        XCTAssertTrue(opener.webURLs.isEmpty)
        XCTAssertEqual(
            receipt.target,
            .desktopApplication(product: .chatGPT, bundleIdentifier: "com.openai.chat")
        )
        XCTAssertEqual(receipt.userMessage, "Copied — paste in ChatGPT desktop.")
    }

    func testObservedCodexBundleCollisionRoutesChatGPTByProductMetadata() async throws {
        let appURL = URL(fileURLWithPath: "/Applications/ChatGPT.app")
        let environment = FakeApplicationEnvironment(installations: [
            .official(
                url: appURL,
                bundleIdentifier: "com.openai.codex",
                productName: "ChatGPT"
            )
        ])
        let opener = FakeExternalURLOpener()
        let router = makeRouter(environment: environment, opener: opener)

        let receipt = try await router.route(
            try ClipContent.detect(text: "route to the actual product"),
            to: DestinationRegistry.chatGPT
        )

        XCTAssertEqual(opener.applicationURLs, [appURL])
        XCTAssertEqual(
            receipt.target,
            .desktopApplication(product: .chatGPT, bundleIdentifier: "com.openai.codex")
        )
    }

    func testChatGPTBuildWithCodexBundleIsNotMisidentifiedAsCodex() async throws {
        let appURL = URL(fileURLWithPath: "/Applications/Codex.app")
        let environment = FakeApplicationEnvironment(installations: [
            .official(
                url: appURL,
                bundleIdentifier: "com.openai.codex",
                productName: "ChatGPT"
            )
        ])
        let pasteboard = FakePasteboardWriter()
        let opener = FakeExternalURLOpener()
        let router = makeRouter(
            pasteboard: pasteboard,
            environment: environment,
            opener: opener
        )

        let receipt = try await router.route(
            try ClipContent.detect(text: "copy only"),
            to: DestinationRegistry.codex
        )

        XCTAssertEqual(pasteboard.writtenTexts, ["copy only"])
        XCTAssertTrue(opener.applicationURLs.isEmpty)
        XCTAssertTrue(opener.webURLs.isEmpty)
        XCTAssertEqual(receipt.target, .copyOnly)
        XCTAssertEqual(
            receipt.userMessage,
            "Copied. Codex desktop was not found; paste manually."
        )
    }

    func testActualCodexProductMetadataCanUseCollidingBundleIdentifier() async throws {
        let appURL = URL(fileURLWithPath: "/Applications/Codex.app")
        let environment = FakeApplicationEnvironment(installations: [
            .official(
                url: appURL,
                bundleIdentifier: "com.openai.codex",
                productName: "Codex"
            )
        ])
        let opener = FakeExternalURLOpener()
        let router = makeRouter(environment: environment, opener: opener)

        let receipt = try await router.route(
            try ClipContent.detect(text: "review this"),
            to: DestinationRegistry.codex
        )

        XCTAssertEqual(opener.applicationURLs, [appURL])
        XCTAssertEqual(
            receipt.target,
            .desktopApplication(product: .codex, bundleIdentifier: "com.openai.codex")
        )
    }

    func testMatchingBundleAndNameWithWrongTeamIsRejected() async throws {
        let spoofURL = URL(fileURLWithPath: "/Applications/NotChatGPT.app")
        let environment = FakeApplicationEnvironment(installations: [
            FakeInstallation(
                url: spoofURL,
                bundleIdentifier: "com.openai.chat",
                productName: "ChatGPT",
                signature: .valid(teamIdentifier: "NOT-OPENAI")
            )
        ])
        let opener = FakeExternalURLOpener()
        let router = makeRouter(environment: environment, opener: opener)

        let receipt = try await router.route(
            try ClipContent.detect(text: "do not open spoof"),
            to: DestinationRegistry.chatGPT
        )

        XCTAssertTrue(opener.applicationURLs.isEmpty)
        XCTAssertEqual(opener.webURLs, [URL(string: "https://chatgpt.com/")!])
        XCTAssertEqual(receipt.target, .web(URL(string: "https://chatgpt.com/")!))
    }

    func testMissingApplicationFallsBackToOrdinaryWebPageWithoutPrefill() async throws {
        let opener = FakeExternalURLOpener()
        let router = makeRouter(environment: FakeApplicationEnvironment(), opener: opener)

        let receipt = try await router.route(
            try ClipContent.detect(text: "market research"),
            to: DestinationRegistry.claude
        )

        XCTAssertEqual(opener.webURLs, [URL(string: "https://claude.ai/new")!])
        XCTAssertEqual(receipt.target, .web(URL(string: "https://claude.ai/new")!))
        XCTAssertFalse(opener.webURLs[0].absoluteString.contains("market"))
        XCTAssertEqual(receipt.userMessage, "Copied — paste in Claude on the web.")
    }

    func testPreparedClipboardPathOpensWithoutWritingAgain() async throws {
        let pasteboard = FakePasteboardWriter()
        let opener = FakeExternalURLOpener()
        let router = makeRouter(
            pasteboard: pasteboard,
            environment: FakeApplicationEnvironment(),
            opener: opener
        )

        let preparedTarget = try router.prepareDestination(DestinationRegistry.claude)
        let receipt = try await router.openPreparedTarget(preparedTarget)

        XCTAssertTrue(pasteboard.writtenTexts.isEmpty)
        XCTAssertEqual(receipt.target, .web(URL(string: "https://claude.ai/new")!))
    }

    func testPreparedTargetRetainsExactBookmarkUntilOpenedWithoutReresolving() async throws {
        let first = URL(fileURLWithPath: "/Applications/Codex.app")
        let second = URL(fileURLWithPath: "/Users/test/Applications/Codex Beta.app")
        let environment = FakeApplicationEnvironment(installations: [
            .official(url: first, bundleIdentifier: "com.openai.codex", productName: "Codex"),
            .official(url: second, bundleIdentifier: "com.openai.codex", productName: "Codex"),
        ])
        let preferences = FakeDestinationPreferences()
        let bookmarks = FakeApplicationBookmarkStore()
        let opener = FakeExternalURLOpener()
        let router = makeRouter(
            environment: environment,
            preferences: preferences,
            bookmarks: bookmarks,
            opener: opener
        )
        preferences.setSelectedApplicationBookmarkData(
            try bookmarks.bookmarkData(forApplicationAt: second),
            for: .codex
        )

        let preparedTarget = try router.prepareDestination(DestinationRegistry.codex)

        XCTAssertEqual(
            preparedTarget.launchTarget,
            .desktopApplication(product: .codex, bundleIdentifier: "com.openai.codex")
        )
        XCTAssertTrue(bookmarks.stoppedURLs.isEmpty)
        XCTAssertTrue(opener.applicationURLs.isEmpty)

        // Changing the stored selection after preflight must not change the retained capability.
        preferences.setSelectedApplicationBookmarkData(
            try bookmarks.bookmarkData(forApplicationAt: first),
            for: .codex
        )
        let receipt = try await router.openPreparedTarget(preparedTarget)

        XCTAssertEqual(opener.applicationURLs, [second.standardizedFileURL])
        XCTAssertTrue(opener.webURLs.isEmpty)
        XCTAssertEqual(receipt.target, preparedTarget.launchTarget)
        XCTAssertEqual(bookmarks.stoppedURLs, [second.standardizedFileURL])
    }

    func testCancellingPreparedTargetReleasesBookmarkAndPreventsOpen() async throws {
        let appURL = URL(fileURLWithPath: "/Applications/Codex.app")
        let environment = FakeApplicationEnvironment(installations: [
            .official(url: appURL, bundleIdentifier: "com.openai.codex", productName: "Codex")
        ])
        let preferences = FakeDestinationPreferences()
        let bookmarks = FakeApplicationBookmarkStore()
        let opener = FakeExternalURLOpener()
        let router = makeRouter(
            environment: environment,
            preferences: preferences,
            bookmarks: bookmarks,
            opener: opener
        )
        preferences.setSelectedApplicationBookmarkData(
            try bookmarks.bookmarkData(forApplicationAt: appURL),
            for: .codex
        )
        let preparedTarget = try router.prepareDestination(DestinationRegistry.codex)

        preparedTarget.cancel()
        preparedTarget.cancel()

        XCTAssertEqual(bookmarks.stoppedURLs, [appURL.standardizedFileURL])
        do {
            _ = try await router.openPreparedTarget(preparedTarget)
            XCTFail("Expected preparedTargetAlreadyConsumed")
        } catch {
            XCTAssertEqual(error as? DestinationRoutingError, .preparedTargetAlreadyConsumed)
        }
        XCTAssertTrue(opener.applicationURLs.isEmpty)
        XCTAssertEqual(bookmarks.stoppedURLs, [appURL.standardizedFileURL])
    }

    func testPreparedTargetCannotBeOpenedByDifferentRouter() async throws {
        let opener = FakeExternalURLOpener()
        let environment = FakeApplicationEnvironment()
        let firstRouter = makeRouter(environment: environment, opener: opener)
        let secondRouter = makeRouter(environment: environment, opener: opener)
        let preparedTarget = try firstRouter.prepareDestination(DestinationRegistry.claude)

        do {
            _ = try await secondRouter.openPreparedTarget(preparedTarget)
            XCTFail("Expected preparedTargetBelongsToDifferentRouter")
        } catch {
            XCTAssertEqual(
                error as? DestinationRoutingError,
                .preparedTargetBelongsToDifferentRouter
            )
        }
        XCTAssertTrue(opener.webURLs.isEmpty)

        _ = try await firstRouter.openPreparedTarget(preparedTarget)
        XCTAssertEqual(opener.webURLs, [URL(string: "https://claude.ai/new")!])
    }

    func testPreparedDesktopLaunchFailureDoesNotFallBackToWebAndReleasesBookmark() async throws {
        let appURL = URL(fileURLWithPath: "/Applications/ChatGPT.app")
        let environment = FakeApplicationEnvironment(installations: [
            .official(url: appURL, bundleIdentifier: "com.openai.chat", productName: "ChatGPT")
        ])
        let preferences = FakeDestinationPreferences()
        let bookmarks = FakeApplicationBookmarkStore()
        let opener = FakeExternalURLOpener(applicationOpenResult: false)
        let router = makeRouter(
            environment: environment,
            preferences: preferences,
            bookmarks: bookmarks,
            opener: opener
        )
        preferences.setSelectedApplicationBookmarkData(
            try bookmarks.bookmarkData(forApplicationAt: appURL),
            for: .chatGPT
        )
        let preparedTarget = try router.prepareDestination(DestinationRegistry.chatGPT)

        do {
            _ = try await router.openPreparedTarget(preparedTarget)
            XCTFail("Expected destinationCouldNotOpen")
        } catch {
            XCTAssertEqual(error as? DestinationRoutingError, .destinationCouldNotOpen(.chatGPT))
        }

        XCTAssertEqual(opener.applicationURLs, [appURL.standardizedFileURL])
        XCTAssertTrue(opener.webURLs.isEmpty)
        XCTAssertEqual(bookmarks.stoppedURLs, [appURL.standardizedFileURL])
    }

    func testSystemWriterCommitsTextAndOriginMarkerAsOneItem() {
        _ = NSApplication.shared
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let writer = SystemPasteboardWriter(pasteboard: pasteboard)

        XCTAssertTrue(writer.writeForRouting("route me"))
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 1)
        XCTAssertEqual(pasteboard.string(forType: .string), "route me")
        XCTAssertEqual(
            pasteboard.string(
                forType: NSPasteboard.PasteboardType(ClipboardRouterPasteboardType.appOrigin)
            ),
            "1"
        )
    }

    func testInstalledApplicationLaunchFailureNeverFallsBackToWeb() async throws {
        let appURL = URL(fileURLWithPath: "/Applications/ChatGPT.app")
        let environment = FakeApplicationEnvironment(installations: [
            .official(url: appURL, bundleIdentifier: "com.openai.chat", productName: "ChatGPT")
        ])
        let opener = FakeExternalURLOpener(applicationOpenResult: false)
        let router = makeRouter(environment: environment, opener: opener)

        do {
            _ = try await router.route(
                try ClipContent.detect(text: "already copied"),
                to: DestinationRegistry.chatGPT
            )
            XCTFail("Expected destinationCouldNotOpen")
        } catch {
            XCTAssertEqual(error as? DestinationRoutingError, .destinationCouldNotOpen(.chatGPT))
        }

        XCTAssertEqual(opener.applicationURLs, [appURL])
        XCTAssertTrue(opener.webURLs.isEmpty)
    }

    func testClipboardFailureDoesNotOpenResolvedDestination() async throws {
        let opener = FakeExternalURLOpener()
        let router = makeRouter(
            pasteboard: FakePasteboardWriter(result: false),
            environment: FakeApplicationEnvironment(),
            opener: opener
        )

        do {
            _ = try await router.route(
                try ClipContent.detect(text: "cannot copy"),
                to: DestinationRegistry.chatGPT
            )
            XCTFail("Expected clipboardWriteFailed")
        } catch {
            XCTAssertEqual(error as? DestinationRoutingError, .clipboardWriteFailed)
        }
        XCTAssertTrue(opener.applicationURLs.isEmpty)
        XCTAssertTrue(opener.webURLs.isEmpty)
    }

    func testWebFailureReportsCopiedButUnableToOpen() async throws {
        let opener = FakeExternalURLOpener(webOpenResult: false)
        let router = makeRouter(environment: FakeApplicationEnvironment(), opener: opener)

        do {
            _ = try await router.route(
                try ClipContent.detect(text: "already copied"),
                to: DestinationRegistry.chatGPT
            )
            XCTFail("Expected destinationCouldNotOpen")
        } catch {
            XCTAssertEqual(error as? DestinationRoutingError, .destinationCouldNotOpen(.chatGPT))
        }
    }

    func testAmbiguousApplicationsAreResolvedBeforeClipboardWrite() async throws {
        let first = URL(fileURLWithPath: "/Applications/Codex.app")
        let second = URL(fileURLWithPath: "/Users/test/Applications/Codex Beta.app")
        let environment = FakeApplicationEnvironment(installations: [
            .official(url: first, bundleIdentifier: "com.openai.codex", productName: "Codex"),
            .official(url: second, bundleIdentifier: "com.openai.codex", productName: "Codex"),
        ])
        let pasteboard = FakePasteboardWriter()
        let preferences = FakeDestinationPreferences()
        let bookmarks = FakeApplicationBookmarkStore()
        let opener = FakeExternalURLOpener()
        let router = makeRouter(
            pasteboard: pasteboard,
            environment: environment,
            preferences: preferences,
            bookmarks: bookmarks,
            opener: opener
        )

        do {
            _ = try await router.route(
                try ClipContent.detect(text: "choose exact install"),
                to: DestinationRegistry.codex
            )
            XCTFail("Expected applicationSelectionRequired")
        } catch {
            XCTAssertEqual(error as? DestinationRoutingError, .applicationSelectionRequired(.codex))
        }
        XCTAssertTrue(pasteboard.writtenTexts.isEmpty)
        XCTAssertTrue(opener.applicationURLs.isEmpty)

        let bookmark = try bookmarks.bookmarkData(forApplicationAt: second)
        preferences.setSelectedApplicationBookmarkData(bookmark, for: .codex)
        _ = try await router.route(
            try ClipContent.detect(text: "chosen install"),
            to: DestinationRegistry.codex
        )
        XCTAssertEqual(opener.applicationURLs, [second.standardizedFileURL])
    }

    func testCatalogChooseApplicationValidatesAndPersistsBookmarkOutsideLaunchServices() throws {
        let appURL = URL(fileURLWithPath: "/Volumes/Tools/ChatGPT.app")
        let environment = FakeApplicationEnvironment(metadataOnly: [
            .official(
                url: appURL,
                bundleIdentifier: "com.openai.codex",
                productName: "ChatGPT"
            )
        ])
        let preferences = FakeDestinationPreferences()
        let bookmarks = FakeApplicationBookmarkStore()
        let catalog = DestinationApplicationCatalog(
            applications: environment,
            metadataInspector: environment,
            preferences: preferences,
            bookmarks: bookmarks
        )

        let selected = try catalog.chooseApplication(
            at: appURL,
            for: DestinationRegistry.chatGPT
        )

        XCTAssertEqual(selected.url, appURL)
        XCTAssertNotNil(preferences.selectedApplicationBookmarkData(for: .chatGPT))
        XCTAssertEqual(catalog.selectedApplicationURL(for: DestinationRegistry.chatGPT), appURL)
        XCTAssertEqual(bookmarks.stoppedURLs, [appURL])
    }

    func testCatalogRejectsManualChoiceWithWrongProductMetadata() throws {
        let appURL = URL(fileURLWithPath: "/Applications/Codex.app")
        let environment = FakeApplicationEnvironment(metadataOnly: [
            .official(
                url: appURL,
                bundleIdentifier: "com.openai.codex",
                productName: "ChatGPT"
            )
        ])
        let catalog = DestinationApplicationCatalog(
            applications: environment,
            metadataInspector: environment,
            preferences: FakeDestinationPreferences(),
            bookmarks: FakeApplicationBookmarkStore()
        )

        XCTAssertThrowsError(
            try catalog.chooseApplication(at: appURL, for: DestinationRegistry.codex)
        ) { error in
            XCTAssertEqual(
                error as? DestinationApplicationCatalogError,
                .applicationIsNotRecognized(.codex)
            )
        }
    }

    func testUserDefaultsPreferencesStoreBookmarkDataRatherThanPath() {
        let suiteName = "DestinationRoutingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = UserDefaultsDestinationApplicationPreferences(
            defaults: defaults,
            keyPrefix: "test.bookmark."
        )
        let bookmark = Data([0x01, 0x02, 0x03])

        preferences.setSelectedApplicationBookmarkData(bookmark, for: .chatGPT)

        XCTAssertEqual(preferences.selectedApplicationBookmarkData(for: .chatGPT), bookmark)
        XCTAssertNil(defaults.string(forKey: "test.bookmark.chatGPT"))
    }

    private func makeRouter(
        pasteboard: FakePasteboardWriter = FakePasteboardWriter(),
        environment: FakeApplicationEnvironment,
        preferences: FakeDestinationPreferences = FakeDestinationPreferences(),
        bookmarks: FakeApplicationBookmarkStore = FakeApplicationBookmarkStore(),
        opener: FakeExternalURLOpener
    ) -> DestinationRouter {
        DestinationRouter(
            pasteboard: pasteboard,
            applications: environment,
            metadataInspector: environment,
            preferences: preferences,
            bookmarks: bookmarks,
            opener: opener
        )
    }
}

@MainActor
private final class FakePasteboardWriter: PasteboardWriting {
    let result: Bool
    var writtenTexts: [String] = []

    init(result: Bool = true) {
        self.result = result
    }

    func writeForRouting(_ text: String) -> Bool {
        writtenTexts.append(text)
        return result
    }
}

private struct FakeInstallation {
    let url: URL
    let bundleIdentifier: String
    let productName: String
    let signature: ApplicationSignatureValidation

    static func official(
        url: URL,
        bundleIdentifier: String,
        productName: String
    ) -> FakeInstallation {
        let teamIdentifier = bundleIdentifier.hasPrefix("com.anthropic.")
            ? "Q6L2SF6YDW"
            : "2DC432GLL2"
        return FakeInstallation(
            url: url,
            bundleIdentifier: bundleIdentifier,
            productName: productName,
            signature: .valid(teamIdentifier: teamIdentifier)
        )
    }
}

@MainActor
private final class FakeApplicationEnvironment: ApplicationLocating, ApplicationMetadataInspecting {
    private let urlsByBundleIdentifier: [String: [URL]]
    private let metadataByPath: [String: InstalledApplicationMetadata]
    var requestedBundleIdentifiers: [String] = []

    init(installations: [FakeInstallation] = []) {
        self.urlsByBundleIdentifier = Dictionary(
            grouping: installations,
            by: \.bundleIdentifier
        ).mapValues { $0.map(\.url) }
        self.metadataByPath = Self.metadataByPath(installations)
    }

    init(metadataOnly: [FakeInstallation]) {
        self.urlsByBundleIdentifier = [:]
        self.metadataByPath = Self.metadataByPath(metadataOnly)
    }

    func applicationURLs(forBundleIdentifier bundleIdentifier: String) -> [URL] {
        requestedBundleIdentifiers.append(bundleIdentifier)
        return urlsByBundleIdentifier[bundleIdentifier] ?? []
    }

    func metadata(forApplicationAt url: URL) -> InstalledApplicationMetadata? {
        metadataByPath[url.standardizedFileURL.path]
    }

    private static func metadataByPath(
        _ installations: [FakeInstallation]
    ) -> [String: InstalledApplicationMetadata] {
        Dictionary(uniqueKeysWithValues: installations.map { installation in
            (
                installation.url.standardizedFileURL.path,
                InstalledApplicationMetadata(
                    url: installation.url,
                    bundleIdentifier: installation.bundleIdentifier,
                    bundleName: installation.productName,
                    displayName: installation.productName,
                    executableName: installation.productName,
                    signature: installation.signature
                )
            )
        })
    }
}

private final class FakeDestinationPreferences: DestinationApplicationPreferenceProviding {
    private var bookmarks: [ExternalDestination.ID: Data] = [:]

    func selectedApplicationBookmarkData(for destination: ExternalDestination.ID) -> Data? {
        bookmarks[destination]
    }

    func setSelectedApplicationBookmarkData(
        _ bookmarkData: Data?,
        for destination: ExternalDestination.ID
    ) {
        bookmarks[destination] = bookmarkData
    }
}

private final class FakeApplicationBookmarkStore: ApplicationBookmarking {
    var stoppedURLs: [URL] = []

    func bookmarkData(forApplicationAt url: URL) throws -> Data {
        Data(url.standardizedFileURL.path.utf8)
    }

    func resolveApplicationBookmark(_ data: Data) throws -> ResolvedApplicationBookmark {
        guard let path = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return ResolvedApplicationBookmark(
            url: URL(fileURLWithPath: path),
            isStale: false,
            isAccessingSecurityScopedResource: true
        )
    }

    func stopAccessing(_ bookmark: ResolvedApplicationBookmark) {
        if bookmark.isAccessingSecurityScopedResource {
            stoppedURLs.append(bookmark.url)
        }
    }
}

@MainActor
private final class FakeExternalURLOpener: ExternalURLOpening {
    let applicationOpenResult: Bool
    let webOpenResult: Bool
    var applicationURLs: [URL] = []
    var webURLs: [URL] = []

    init(applicationOpenResult: Bool = true, webOpenResult: Bool = true) {
        self.applicationOpenResult = applicationOpenResult
        self.webOpenResult = webOpenResult
    }

    func openApplication(at url: URL) async -> Bool {
        applicationURLs.append(url)
        return applicationOpenResult
    }

    func openWebURL(_ url: URL) -> Bool {
        webURLs.append(url)
        return webOpenResult
    }
}
