import ClipboardRouterCore
import ClipboardRouterPlatform
import XCTest
@testable import ClipboardRouterApp

@MainActor
final class LiveLinkPreviewAppTests: XCTestCase {
    func testAccessibilityContractHasStableIdentifiersAndStateValues() {
        XCTAssertEqual(LiveLinkPreviewAccessibility.cardIdentifier, "uiAcceptance.livePreview.card")
        XCTAssertEqual(LiveLinkPreviewAccessibility.stateIdentifier, "uiAcceptance.livePreview.state")
        XCTAssertEqual(LiveLinkPreviewAccessibility.loadIdentifier, "uiAcceptance.livePreview.load")
        XCTAssertEqual(LiveLinkPreviewAccessibility.removeIdentifier, "uiAcceptance.livePreview.remove")
        XCTAssertEqual(LiveLinkPreviewAccessibility.refreshIdentifier, "uiAcceptance.livePreview.refresh")
        XCTAssertEqual(LiveLinkPreviewAccessibility.stateValue(for: .idle), "idle")
        XCTAssertEqual(LiveLinkPreviewAccessibility.stateValue(for: .loading), "loading")
        XCTAssertEqual(
            LiveLinkPreviewAccessibility.stateValue(for: .loaded(LiveLinkPreviewMetadata(
                sourceURL: URL(string: "https://example.com")!,
                title: "Example"
            ))),
            "loaded"
        )
        XCTAssertEqual(LiveLinkPreviewAccessibility.stateValue(for: .blocked("blocked")), "blocked")
        XCTAssertEqual(LiveLinkPreviewAccessibility.stateValue(for: .offline("offline")), "offline")
        XCTAssertEqual(LiveLinkPreviewAccessibility.stateValue(for: .failed("failed")), "failed")
    }

    func testEligibleLinkLoadsOnlyOnExplicitRequestWithoutMutatingClip() async throws {
        let content = try ClipContent.detect(text: "https://example.com/article")
        let history = HistoryItem(content: content, createdAt: Date())
        let client = StubLiveLinkPreviewClient(metadata: LiveLinkPreviewMetadata(
            sourceURL: try XCTUnwrap(URL(string: content.text)),
            title: "Fetched title",
            summary: "Fetched summary"
        ))
        let model = try makeModel(history: [history], client: client)
        await model.start()
        let clip = try XCTUnwrap(model.clipsForSelectedSection.first)
        let originalSnapshot = model.snapshot

        XCTAssertEqual(model.liveLinkPreviewState(for: clip), .idle)
        let initialCallCount = await client.previewCallCount()
        XCTAssertEqual(initialCallCount, 0)

        await model.loadLiveLinkPreview(for: clip)

        guard case let .loaded(metadata) = model.liveLinkPreviewState(for: clip) else {
            return XCTFail("Expected loaded live preview metadata")
        }
        XCTAssertEqual(metadata.title, "Fetched title")
        let loadedCallCount = await client.previewCallCount()
        XCTAssertEqual(loadedCallCount, 1)
        XCTAssertEqual(model.snapshot, originalSnapshot)
        XCTAssertEqual(model.clipsForSelectedSection.first?.content, content)
    }

    func testPrivateSensitiveAndNonHTTPSClipsAreBlockedWithoutCallingClient() async throws {
        let secretURL = try ClipContent.detect(
            text: "https://example.com/?token=sk-proj-abcdefghijklmnopqrstuvwxyz123456"
        )
        let httpURL = try ClipContent.detect(text: "http://example.com/article")
        let histories = [
            HistoryItem(content: secretURL, createdAt: Date()),
            HistoryItem(content: httpURL, createdAt: Date().addingTimeInterval(-1)),
        ]
        let client = StubLiveLinkPreviewClient(metadata: LiveLinkPreviewMetadata(
            sourceURL: try XCTUnwrap(URL(string: "https://example.com")),
            title: "Should not load"
        ))
        let model = try makeModel(history: histories, client: client)
        await model.start()

        for clip in model.clipsForSelectedSection {
            await model.loadLiveLinkPreview(for: clip)
            guard case .blocked = model.liveLinkPreviewState(for: clip) else {
                return XCTFail("Expected ordinary unsafe item to be blocked")
            }
        }
        let privateClip = PresentedClip(
            id: UUID(),
            title: "Private",
            content: try ClipContent.detect(text: "https://example.com/private"),
            date: Date(),
            sourceBundleIdentifier: nil,
            origin: .privateSession
        )
        await model.loadLiveLinkPreview(for: privateClip)
        guard case .blocked = model.liveLinkPreviewState(for: privateClip) else {
            return XCTFail("Expected Private Session item to be blocked")
        }
        let blockedCallCount = await client.previewCallCount()
        XCTAssertEqual(blockedCallCount, 0)
    }

    func testOfflineStateAndClearCacheAreVisible() async throws {
        let history = HistoryItem(
            content: try ClipContent.detect(text: "https://example.com/offline"),
            createdAt: Date()
        )
        let client = StubLiveLinkPreviewClient(error: .offline)
        let model = try makeModel(history: [history], client: client)
        await model.start()
        let clip = try XCTUnwrap(model.clipsForSelectedSection.first)

        await model.loadLiveLinkPreview(for: clip)
        guard case .offline = model.liveLinkPreviewState(for: clip) else {
            return XCTFail("Expected an offline state")
        }

        await model.clearLiveLinkPreviewCache()
        XCTAssertEqual(model.liveLinkPreviewState(for: clip), .idle)
        let clearCallCount = await client.clearCallCount()
        XCTAssertEqual(clearCallCount, 1)
    }

    private func makeModel(
        history: [HistoryItem],
        client: any LiveLinkPreviewFetching
    ) throws -> AppModel {
        let suite = "LiveLinkPreviewAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveLinkPreviewAppTests-\(UUID().uuidString)", isDirectory: true)
        return AppModel(
            defaults: defaults,
            liveLinkPreviewClient: client,
            hotKey: PreviewFakeHotKeyRegistrar(),
            supportDirectory: directory,
            libraryPersistence: InMemoryClipboardLibraryStore(
                snapshot: ClipboardLibrarySnapshot(history: history)
            )
        )
    }
}

private actor StubLiveLinkPreviewClient: LiveLinkPreviewFetching {
    private let metadata: LiveLinkPreviewMetadata?
    private let error: LiveLinkPreviewError?
    private var previews = 0
    private var clears = 0

    init(metadata: LiveLinkPreviewMetadata) {
        self.metadata = metadata
        self.error = nil
    }

    init(error: LiveLinkPreviewError) {
        self.metadata = nil
        self.error = error
    }

    func preview(for url: URL, refresh: Bool) async throws -> LiveLinkPreviewMetadata {
        previews += 1
        if let error { throw error }
        return metadata!
    }

    func removeCachedPreview(for url: URL) async { clears += 1 }
    func clearCache() async { clears += 1 }
    func previewCallCount() -> Int { previews }
    func clearCallCount() -> Int { clears }
}

@MainActor
private final class PreviewFakeHotKeyRegistrar: GlobalHotKeyRegistering {
    func register(
        _ descriptor: GlobalHotKeyDescriptor,
        handler: @escaping @MainActor () -> Void
    ) throws {}

    func unregister() {}
}
