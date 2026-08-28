import AppKit
import ClipboardRouterCore
import ClipboardRouterPlatform
import ClipboardRouterSecurity
import CryptoKit
import SwiftUI
import XCTest
@testable import ClipboardRouterApp

/// Marketing screenshot capture for the website — real SwiftUI product surfaces, rendered
/// entirely from isolated fictional fixtures.
///
/// This renders the same production views as `SurfaceVisualEvidenceTests` (`NSHostingView`
/// off-screen, `cacheDisplay`; never a desktop/window capture) but at 2x pixel density and with
/// larger source windows suited to website crops. It shares no state, hash gate, or scenario list
/// with the existing visual-acceptance renderer.
///
/// Every model here uses the same deterministic fixture identifiers as `UIAcceptanceRuntime`,
/// an isolated named
/// `NSPasteboard`, a run-scoped temporary support directory, run-scoped `UserDefaults`, and — for
/// the Vault capture — an in-memory Vault store with a stub authenticator. `NSPasteboard.general`
/// is never written to; it is read only as a non-mutating `changeCount` guard.
///
/// Set `CLIPBOARD_ROUTER_MARKETING_EVIDENCE_DIR` to persist the four PNGs, `manifest.json`, and
/// `sha256.txt`. Without it, this test still runs (into a throwaway temporary directory) so `swift
/// test` alone never emits marketing evidence by accident.
@MainActor
final class MarketingCaptureTests: XCTestCase {
    private enum CaptureError: Error {
        case failedPrivacyInvariant(String)
        case invalidEvidenceDestination(String)
    }

    private static let libraryFixtureItems: [(text: String, sourceBundleID: String)] = [
        ("Ship the onboarding flow before Friday's review.", "com.apple.Notes"),
        ("https://docs.example.com/product/clipboard-workflows", "com.apple.Safari"),
        ("npm run typecheck && npm run test", "com.apple.Terminal"),
        ("Draft the release notes from the approved checklist.", "com.apple.Notes"),
        ("SELECT status, count(*) FROM tasks GROUP BY status;", "com.apple.dt.Xcode"),
        ("Turn these meeting notes into a launch checklist.", "com.apple.Notes"),
        ("https://github.com/example/clipboard-router/issues/42", "com.apple.Safari"),
        ("Remember to update the privacy copy before launch.", "com.apple.Notes"),
        ("curl https://api.example.com/v1/health", "com.apple.Terminal"),
        ("Use local-only processing for sensitive research.", "com.apple.Notes"),
        ("Follow up on the design review with the final mock.", "com.apple.Notes"),
        ("Clipboard Router keeps copied work ready across apps.", "com.apple.Notes"),
    ]

    private static func marketingReviewFlow() -> ClipFlow {
        try! ClipFlow(
            id: UIAcceptanceRuntime.fixtureUUID(index: 9_201),
            name: "Review and file product notes",
            trigger: .manual,
            entityFilter: .any,
            steps: [
                .addTags(id: UIAcceptanceRuntime.fixtureUUID(index: 9_202), tags: ["reviewed"]),
                .createTaskDraft(
                    id: UIAcceptanceRuntime.fixtureUUID(index: 9_203),
                    titleTemplate: "Follow up: {title}",
                    dueInDays: 2
                ),
            ]
        )
    }

    /// Every string this test allows onto a rendered surface. Populated as fixtures are built and
    /// checked against what the models actually expose before any pixel is captured — a
    /// data-level provenance check, not OCR.
    private var fixtureAllowlist: Set<String> = []
    private let captureRunID: String = {
        let requested = ProcessInfo.processInfo.environment["CLIPBOARD_ROUTER_MARKETING_RUN_ID"]
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        if let requested,
           (1...64).contains(requested.utf8.count),
           requested.unicodeScalars.allSatisfy(allowedCharacters.contains)
        {
            return requested
        }
        return UUID().uuidString.lowercased()
    }()

    private struct Viewport {
        let width: CGFloat
        let height: CGFloat
    }

    private struct ModelFixture {
        let model: AppModel
        let supportDirectory: URL
        let defaultsSuiteName: String
        let pasteboard: NSPasteboard
    }

    private struct Anchor: Codable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }

    private struct Capture: Codable {
        let name: String
        let file: String
        let logicalWidth: Int
        let logicalHeight: Int
        let scale: Int
        let pixelWidth: Int
        let pixelHeight: Int
        let anchors: [String: Anchor]
        let sha256: String
    }

    private struct Manifest: Codable {
        let schemaVersion: Int
        let renderedAt: String
        let renderer: String
        let appearance: String
        let captures: [Capture]
    }

    func testRenderMarketingScreenshots() async throws {
        let destination = try evidenceDestination()
        let stagingDirectory = destination.url.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.url.lastPathComponent).staging-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: stagingDirectory)
            if !destination.shouldPersist {
                try? FileManager.default.removeItem(at: destination.url)
            }
        }
        let generalPasteboardChangeCountBefore = NSPasteboard.general.changeCount

        var captures: [Capture] = []
        captures.append(try await renderLibraryCapture(into: stagingDirectory))
        captures.append(try await renderActionsCapture(into: stagingDirectory))
        captures.append(try await renderPrivateSessionCapture(into: stagingDirectory))
        captures.append(try await renderVaultCapture(into: stagingDirectory))

        do {
            try require(captures.count == 4, "Expected four marketing captures")
            try require(
                Set(captures.map(\.sha256)).count == 4,
                "Every capture must be visually distinct"
            )
            for capture in captures {
                guard let full = capture.anchors["full"] else {
                    throw CaptureError.failedPrivacyInvariant(
                        "\(capture.name) must include a full-frame crop anchor"
                    )
                }
                try require(
                    full.width == Double(capture.pixelWidth)
                        && full.height == Double(capture.pixelHeight),
                    "\(capture.name) full-frame anchor must use image pixel coordinates"
                )
                for (anchorName, anchor) in capture.anchors {
                    try require(
                        anchor.x >= 0 && anchor.y >= 0
                            && anchor.width >= 0 && anchor.height >= 0
                            && anchor.x + anchor.width <= Double(capture.pixelWidth)
                            && anchor.y + anchor.height <= Double(capture.pixelHeight),
                        "\(capture.name) anchor \(anchorName) must stay within image bounds"
                    )
                }
            }
            try require(
                NSPasteboard.general.changeCount == generalPasteboardChangeCountBefore,
                "Marketing capture must never mutate the real General pasteboard"
            )
        } catch {
            for capture in captures {
                try? FileManager.default.removeItem(
                    at: stagingDirectory.appendingPathComponent(capture.file)
                )
            }
            throw error
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let manifest = Manifest(
            schemaVersion: 1,
            renderedAt: formatter.string(from: Date()),
            renderer: "NSHostingView.cacheDisplay 2x (marketing; app-only, no desktop capture)",
            appearance: "NSAppearance.Name.darkAqua",
            captures: captures
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestData = try encoder.encode(manifest)
        let manifestURL = stagingDirectory.appendingPathComponent("manifest.json")
        try manifestData.write(to: manifestURL, options: .atomic)

        let checksumEntries = captures.map { "\($0.sha256)  \($0.file)" } + [
            "\(sha256(manifestData))  \(manifestURL.lastPathComponent)"
        ]
        try (checksumEntries.joined(separator: "\n") + "\n").write(
            to: stagingDirectory.appendingPathComponent("sha256.txt"),
            atomically: true,
            encoding: .utf8
        )

        if FileManager.default.fileExists(atPath: destination.url.path) {
            try FileManager.default.removeItem(at: destination.url)
        }
        try FileManager.default.moveItem(at: stagingDirectory, to: destination.url)
    }

    // MARK: - Scenario 1: Library

    private func renderLibraryCapture(into outputDirectory: URL) async throws -> Capture {
        let runID = scenarioRunID("library")
        let fixture = try await makeLibraryModel(runID: runID)
        let model = fixture.model
        for item in model.snapshot.history.prefix(50) {
            fixtureAllowlist.insert(item.content.text)
        }
        if let selectedClip = model.clipsForSelectedSection.first {
            model.setSelectedClipIDs([selectedClip.id])
            fixtureAllowlist.insert(selectedClip.title)
        }
        try assertPrivacyInvariants(
            for: model,
            expectedRunID: runID,
            expectedSupportDirectory: fixture.supportDirectory,
            expectedDefaultsSuiteName: fixture.defaultsSuiteName,
            expectedPasteboard: fixture.pasteboard
        )

        return try render(
            name: "capture-library",
            fileName: "capture-library.png",
            view: AnyView(MainWindowView(model: model)),
            viewport: Viewport(width: 1_440, height: 900),
            into: outputDirectory
        )
    }

    // MARK: - Scenario 2: Actions

    private func renderActionsCapture(into outputDirectory: URL) async throws -> Capture {
        let runID = scenarioRunID("actions")
        let fixture = try await makeLibraryModel(runID: runID)
        let model = fixture.model
        model.selectLibrarySection(.workflows)
        fixtureAllowlist.insert(Self.marketingReviewFlow().name)
        try assertPrivacyInvariants(
            for: model,
            expectedRunID: runID,
            expectedSupportDirectory: fixture.supportDirectory,
            expectedDefaultsSuiteName: fixture.defaultsSuiteName,
            expectedPasteboard: fixture.pasteboard
        )

        return try render(
            name: "capture-actions",
            fileName: "capture-actions.png",
            view: AnyView(MainWindowView(model: model)),
            viewport: Viewport(width: 1_440, height: 900),
            into: outputDirectory
        )
    }

    // MARK: - Scenario 3: Private Session

    private func renderPrivateSessionCapture(into outputDirectory: URL) async throws -> Capture {
        let runID = scenarioRunID("private-session")
        let fixture = try await makeLibraryModel(runID: runID)
        let model = fixture.model

        if !model.isCaptureEnabled {
            model.toggleCapture()
        }
        let captureEnabled = await waitUntil { model.isCaptureEnabled }
        try require(captureEnabled, "Fixture-only capture toggle did not take effect")

        model.startPrivateSession()
        let sessionActive = await waitUntil { model.isPrivateSessionActive }
        try require(sessionActive, "Private Session fixture did not start")
        try require(model.selectedSection == .privateSession, "Private Session view was not selected")
        try require(model.privateSessionClips.isEmpty, "Private Session fixture must start empty")

        try assertPrivacyInvariants(
            for: model,
            expectedRunID: runID,
            expectedSupportDirectory: fixture.supportDirectory,
            expectedDefaultsSuiteName: fixture.defaultsSuiteName,
            expectedPasteboard: fixture.pasteboard
        )

        return try render(
            name: "capture-private-session",
            fileName: "capture-private-session.png",
            view: AnyView(MainWindowView(model: model)),
            viewport: Viewport(width: 1_440, height: 900),
            into: outputDirectory
        )
    }

    // MARK: - Scenario 4: Vault

    private func renderVaultCapture(into outputDirectory: URL) async throws -> Capture {
        let vaultStore = InMemoryVaultStore()
        let vaultAssets = InMemoryVaultEncryptedAssetStore()
        let keyProvider = InMemoryVaultKeyProvider()
        let seedingSession = VaultSession(
            authenticator: StubVaultAuthenticator(),
            keyProvider: keyProvider
        )
        let seedingVault = try await VaultLibrary.open(
            store: vaultStore,
            session: seedingSession,
            assetStore: vaultAssets
        )
        try await seedingSession.unlock()
        let fixtureItemNames = [
            "Quarterly planning notes",
            "Launch-day recovery checklist",
            "Draft partnership terms",
        ]
        for (index, name) in fixtureItemNames.enumerated() {
            let content = try ClipContent.detect(text: name)
            let item = try VaultItem(
                id: UIAcceptanceRuntime.fixtureUUID(index: 9_500 + index),
                name: name,
                content: content,
                createdAt: Date(timeIntervalSince1970: 1_750_000_000)
                    .addingTimeInterval(-Double(index + 1) * 86_400)
            )
            _ = try await seedingVault.add(item)
            fixtureAllowlist.insert(name)
        }
        await seedingSession.lock()

        let runID = scenarioRunID("vault")
        let temporaryDirectory = FileManager.default.temporaryDirectory
        let supportDirectory = temporaryDirectory
            .appendingPathComponent("ClipboardRouterMarketingCapture", isDirectory: true)
            .appendingPathComponent(runID, isDirectory: true)
        try? FileManager.default.removeItem(at: supportDirectory)
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        let defaultsSuiteName = "\(UIAcceptanceRuntime.bundleIdentifier).marketing-capture.\(runID)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        defaults.set(true, forKey: "hasCompletedOnboarding.v1")

        let isolatedPasteboard = NSPasteboard(name: NSPasteboard.Name(
            "\(UIAcceptanceRuntime.bundleIdentifier).marketing-capture.pasteboard.\(runID)"
        ))
        let assetStore = FileClipAssetStore(
            rootURL: supportDirectory.appendingPathComponent("clip-assets", isDirectory: true)
        )
        let modelSession = VaultSession(
            authenticator: StubVaultAuthenticator(),
            keyProvider: keyProvider
        )
        let model = AppModel(
            defaults: defaults,
            hostedAssistantCredentialStore: UIAcceptanceCaptureFixtureCredentialStore(),
            liveLinkPreviewClient: UIAcceptanceCaptureFixtureLinkPreviewClient(),
            pasteboardReader: SystemPasteboardReader(pasteboard: isolatedPasteboard),
            pasteboardWriter: SystemPasteboardWriter(pasteboard: isolatedPasteboard),
            typedPasteboardWriter: TypedSystemPasteboardWriter(
                pasteboard: isolatedPasteboard,
                assetStore: assetStore
            ),
            pasteboardAccessStateProvider: { .allowed },
            hotKey: UIAcceptanceCaptureFixtureHotKey(),
            launchAtLoginService: UIAcceptanceCaptureFixtureLaunchAtLoginService(),
            captureContextProvider: UIAcceptanceCaptureFixtureContextProvider(),
            textExpansionAccessibility: UIAcceptanceCaptureFixtureTextExpansionAccessibility(),
            textExpansionEvents: UIAcceptanceCaptureFixtureTextExpansionEvents(),
            supportDirectory: supportDirectory,
            vaultSession: modelSession,
            vaultStore: vaultStore,
            vaultAssetStore: vaultAssets,
            libraryPersistence: InMemoryClipboardLibraryStore(
                snapshot: ClipboardLibrarySnapshot(
                    settings: ClipboardLibrarySettings(capturePolicy: CapturePolicy(isCaptureEnabled: false))
                )
            )
        )
        await model.start()
        try require(model.isReady, "Vault fixture model did not become ready")

        model.unlockVault()
        let unlocked = await waitUntil(timeout: .seconds(3)) {
            model.isVaultUnlocked && model.vaultSummaries.count == fixtureItemNames.count
        }
        try require(unlocked, "Fictional Vault fixture did not unlock and enumerate")
        model.selectLibrarySection(.vault)
        model.selectVaultItem(id: nil)

        try assertPrivacyInvariants(
            for: model,
            expectedRunID: runID,
            expectedSupportDirectory: supportDirectory,
            expectedDefaultsSuiteName: defaultsSuiteName,
            expectedPasteboard: isolatedPasteboard,
            expectedVaultStore: vaultStore
        )

        return try render(
            name: "capture-vault",
            fileName: "capture-vault.png",
            view: AnyView(MainWindowView(model: model)),
            viewport: Viewport(width: 1_440, height: 900),
            into: outputDirectory
        )
    }

    // MARK: - Shared model construction

    private func makeLibraryModel(runID: String) async throws -> ModelFixture {
        let suiteName = "\(UIAcceptanceRuntime.bundleIdentifier).marketing-capture.\(runID)"
        let supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardRouterMarketingCapture", isDirectory: true)
            .appendingPathComponent(runID, isDirectory: true)
        try? FileManager.default.removeItem(at: supportDirectory)
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(true, forKey: "hasCompletedOnboarding.v1")

        let referenceDate = Date(timeIntervalSince1970: 1_750_000_000)
        let history = try Self.libraryFixtureItems.enumerated().map { index, fixture in
            HistoryItem(
                id: UIAcceptanceRuntime.fixtureUUID(index: 8_000 + index),
                content: try ClipContent.detect(text: fixture.text),
                createdAt: referenceDate.addingTimeInterval(TimeInterval(-index * 60)),
                sourceApplicationBundleIdentifier: fixture.sourceBundleID,
                pasteboardTypeIdentifiers: ["public.utf8-plain-text"]
            )
        }
        let snapshot = ClipboardLibrarySnapshot(
            history: history,
            settings: ClipboardLibrarySettings(
                capturePolicy: CapturePolicy(isCaptureEnabled: false),
                retentionPolicy: .unlimited,
                maximumHistoryItemCount: 10_000,
                isSecretDetectionEnabled: false
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        defaults.set(try encoder.encode([Self.marketingReviewFlow()]), forKey: "clipFlows.v1")

        let isolatedPasteboard = NSPasteboard(name: NSPasteboard.Name(
            "\(UIAcceptanceRuntime.bundleIdentifier).marketing-capture.pasteboard.\(runID)"
        ))
        let assetStore = FileClipAssetStore(
            rootURL: supportDirectory.appendingPathComponent("clip-assets", isDirectory: true)
        )
        let model = AppModel(
            defaults: defaults,
            hostedAssistantCredentialStore: UIAcceptanceCaptureFixtureCredentialStore(),
            liveLinkPreviewClient: UIAcceptanceCaptureFixtureLinkPreviewClient(),
            pasteboardReader: SystemPasteboardReader(pasteboard: isolatedPasteboard),
            pasteboardWriter: SystemPasteboardWriter(pasteboard: isolatedPasteboard),
            typedPasteboardWriter: TypedSystemPasteboardWriter(
                pasteboard: isolatedPasteboard,
                assetStore: assetStore
            ),
            pasteboardAccessStateProvider: { .allowed },
            hotKey: UIAcceptanceCaptureFixtureHotKey(),
            launchAtLoginService: UIAcceptanceCaptureFixtureLaunchAtLoginService(),
            captureContextProvider: UIAcceptanceCaptureFixtureContextProvider(),
            textExpansionAccessibility: UIAcceptanceCaptureFixtureTextExpansionAccessibility(),
            textExpansionEvents: UIAcceptanceCaptureFixtureTextExpansionEvents(),
            supportDirectory: supportDirectory,
            libraryPersistence: InMemoryClipboardLibraryStore(snapshot: snapshot)
        )

        await model.start()
        try require(model.isReady, "Library fixture model did not become ready")
        try require(
            model.snapshot.history.count == Self.libraryFixtureItems.count,
            "Library fixture did not load every fictional history item"
        )
        fixtureAllowlist.formUnion(Self.libraryFixtureItems.map(\.text))
        return ModelFixture(
            model: model,
            supportDirectory: supportDirectory,
            defaultsSuiteName: suiteName,
            pasteboard: isolatedPasteboard
        )
    }

    // MARK: - Privacy assertions (requirement 7)

    /// Executable, non-OCR privacy assertions: the named pasteboard is not General, storage is
    /// under the temporary directory (never a real Application Support path), defaults are
    /// run-scoped, the Vault (when present) is in-memory, and every string this scenario put on
    /// screen belongs to the explicit fixture allowlist.
    private func assertPrivacyInvariants(
        for model: AppModel,
        expectedRunID: String,
        expectedSupportDirectory: URL? = nil,
        expectedDefaultsSuiteName: String? = nil,
        expectedPasteboard: NSPasteboard? = nil,
        expectedVaultStore: (any VaultStore)? = nil
    ) throws {
        let supportDirectory = expectedSupportDirectory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardRouterMarketingCapture", isDirectory: true)
            .appendingPathComponent(expectedRunID, isDirectory: true)
        let standardizedSupport = supportDirectory.standardizedFileURL.path
        let standardizedTemp = FileManager.default.temporaryDirectory.standardizedFileURL.path
        try require(
            standardizedSupport.hasPrefix(standardizedTemp),
            "Support directory must stay under the temporary directory, got \(standardizedSupport)"
        )

        let realApplicationSupportCandidates = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )
        for realDirectory in realApplicationSupportCandidates {
            try require(
                !standardizedSupport.hasPrefix(realDirectory.standardizedFileURL.path),
                "Marketing capture must never write under the real Application Support path"
            )
        }

        if let expectedDefaultsSuiteName {
            try require(
                expectedDefaultsSuiteName.contains(expectedRunID),
                "Defaults suite must contain the isolated run identifier"
            )
            try require(
                expectedDefaultsSuiteName != "NSGlobalDomain",
                "Marketing capture must never use global defaults"
            )
        }

        if let expectedPasteboard {
            try require(
                expectedPasteboard.name != NSPasteboard.Name.general,
                "Marketing capture must never use the General pasteboard"
            )
            try require(
                expectedPasteboard.name.rawValue.contains(expectedRunID),
                "Named pasteboard must contain the isolated run identifier"
            )
        }

        if let expectedVaultStore {
            try require(
                expectedVaultStore is InMemoryVaultStore,
                "Vault fixtures must use an in-memory store, never a disk-backed vault"
            )
        }

        let displayedStrings = model.snapshot.history.map(\.content.text)
            + model.snapshot.savedClips.map(\.content.text)
            + model.privateSessionClips.map(\.content.text)
            + model.vaultSummaries.map(\.name)
        for text in displayedStrings {
            try require(
                fixtureAllowlist.contains(text),
                "Non-fixture string reached a rendered surface: \(text)"
            )
        }
    }

    private func require(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        guard condition() else {
            XCTFail(message)
            throw CaptureError.failedPrivacyInvariant(message)
        }
    }

    // MARK: - Rendering

    private func render(
        name: String,
        fileName: String,
        view: AnyView,
        viewport: Viewport,
        into outputDirectory: URL,
        scale: Int = 2
    ) throws -> Capture {
        let size = CGSize(width: viewport.width, height: viewport.height)
        let root = view
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .dark)
        let hostingView = NSHostingView(rootView: AnyView(root))
        hostingView.appearance = NSAppearance(named: .darkAqua)
        hostingView.frame = NSRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: 120, y: 120), size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hostingView
        settle(window: window, hostingView: hostingView)

        XCTAssertEqual(hostingView.bounds.width, size.width, accuracy: 0.01)
        XCTAssertEqual(hostingView.bounds.height, size.height, accuracy: 0.01)

        let anchors = anchorRects(in: hostingView, size: size, scale: scale)
        let bitmap = try bitmapImage(of: hostingView, size: size, scale: scale)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            XCTFail("Could not encode \(name) PNG")
            throw CocoaError(.fileWriteUnknown)
        }
        let imageURL = outputDirectory.appendingPathComponent(fileName)
        try png.write(to: imageURL, options: .atomic)

        window.contentView = nil
        window.close()

        return Capture(
            name: name,
            file: fileName,
            logicalWidth: Int(size.width),
            logicalHeight: Int(size.height),
            scale: scale,
            pixelWidth: bitmap.pixelsWide,
            pixelHeight: bitmap.pixelsHigh,
            anchors: anchors,
            sha256: sha256(png)
        )
    }

    /// Named rectangles (in image pixel space, origin top-left) useful for later web crops: the
    /// full frame, the navigation sidebar, and the remaining content pane.
    private func anchorRects(in hostingView: NSView, size: CGSize, scale: Int) -> [String: Anchor] {
        let pixelScale = Double(scale)
        var anchors: [String: Anchor] = [
            "full": Anchor(
                x: 0,
                y: 0,
                width: Double(size.width) * pixelScale,
                height: Double(size.height) * pixelScale
            ),
        ]
        let scrollViews = descendants(of: hostingView).compactMap { $0 as? NSScrollView }.filter {
            !$0.isHidden && $0.convert($0.bounds, to: hostingView).intersects(hostingView.bounds)
        }
        let scrollFrames: [CGRect] = scrollViews.map { $0.convert($0.bounds, to: hostingView) }
        let sidebarCandidates: [CGRect] = scrollFrames.filter { $0.minX < 60 && $0.width < 300 }
        guard let sidebarScrollView = sidebarCandidates.max(by: { $0.height < $1.height }) else {
            return anchors
        }
        anchors["sidebar"] = Anchor(
            x: Double(sidebarScrollView.minX) * pixelScale,
            y: Double(size.height - sidebarScrollView.maxY) * pixelScale,
            width: Double(sidebarScrollView.width) * pixelScale,
            height: Double(sidebarScrollView.height) * pixelScale
        )
        let contentMinX = sidebarScrollView.maxX
        anchors["content"] = Anchor(
            x: Double(contentMinX) * pixelScale,
            y: 0,
            width: Double(max(0, size.width - contentMinX)) * pixelScale,
            height: Double(size.height) * pixelScale
        )
        return anchors
    }

    private func descendants(of root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap(descendants(of:))
    }

    private func settle(window: NSWindow, hostingView: NSView) {
        for _ in 0..<3 {
            window.layoutIfNeeded()
            hostingView.layoutSubtreeIfNeeded()
            let deadline = Date().addingTimeInterval(0.08)
            while RunLoop.main.run(mode: .default, before: deadline), Date() < deadline {}
        }
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
    }

    private func bitmapImage(of view: NSView, size: CGSize, scale: Int) throws -> NSBitmapImageRep {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width) * scale,
            pixelsHigh: Int(size.height) * scale,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [],
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw CocoaError(.coderInvalidValue)
        }
        bitmap.size = size
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    private func scenarioRunID(_ scenario: String) -> String {
        "marketing-\(captureRunID)-\(scenario)"
    }

    private func evidenceDestination() throws -> (url: URL, shouldPersist: Bool) {
        let environment = ProcessInfo.processInfo.environment
        if let requested = environment["CLIPBOARD_ROUTER_MARKETING_EVIDENCE_DIR"],
           !requested.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return (try validatedPersistentEvidenceDestination(requested), true)
        }
        return (
            FileManager.default.temporaryDirectory.appendingPathComponent(
                "ClipboardRouterMarketingCaptureEvidence-\(UUID().uuidString)",
                isDirectory: true
            ),
            false
        )
    }

    /// The persistent capture test replaces its destination atomically, so keep that destructive
    /// operation confined to one validated, non-symlinked child of the repository artifact root.
    private func validatedPersistentEvidenceDestination(_ requested: String) throws -> URL {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let artifactsRoot = repositoryRoot.appendingPathComponent(".artifacts", isDirectory: true)
        let allowedRoot = artifactsRoot.appendingPathComponent(
            "marketing-capture",
            isDirectory: true
        )
        for directory in [artifactsRoot, allowedRoot] {
            if FileManager.default.fileExists(atPath: directory.path) {
                let values = try directory.resourceValues(forKeys: [.isSymbolicLinkKey])
                guard values.isSymbolicLink != true else {
                    throw CaptureError.invalidEvidenceDestination(requested)
                }
            } else {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: false
                )
            }
        }
        let resolvedAllowedRoot = allowedRoot.resolvingSymlinksInPath()
        guard resolvedAllowedRoot.path.hasPrefix(repositoryRoot.path + "/") else {
            throw CaptureError.invalidEvidenceDestination(requested)
        }

        let destination = URL(fileURLWithPath: requested, isDirectory: true).standardizedFileURL
        let runID = destination.lastPathComponent
        let allowedRunIDCharacters = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "_-")
        )
        guard (1...64).contains(runID.utf8.count),
              runID.unicodeScalars.allSatisfy(allowedRunIDCharacters.contains),
              destination.deletingLastPathComponent().standardizedFileURL.path
                == resolvedAllowedRoot.path
        else {
            throw CaptureError.invalidEvidenceDestination(requested)
        }

        if FileManager.default.fileExists(atPath: destination.path) {
            let values = try destination.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw CaptureError.invalidEvidenceDestination(requested)
            }
        }
        return destination
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

// MARK: - Fixture-only collaborators for the directly constructed Vault model

private struct UIAcceptanceCaptureFixtureCredentialStore: HostedAssistantCredentialStoring {
    func loadAPIKey() throws -> String? { nil }
    func saveAPIKey(_ apiKey: String) throws {}
    func deleteAPIKey() throws {}
}

private actor UIAcceptanceCaptureFixtureLinkPreviewClient: LiveLinkPreviewFetching {
    func preview(for url: URL, refresh: Bool) async throws -> LiveLinkPreviewMetadata {
        throw LiveLinkPreviewError.invalidResponse
    }
    func removeCachedPreview(for url: URL) async {}
    func clearCache() async {}
}

@MainActor
private final class UIAcceptanceCaptureFixtureHotKey: GlobalHotKeyRegistering {
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
private struct UIAcceptanceCaptureFixtureLaunchAtLoginService: LaunchAtLoginServicing {
    var state: LaunchAtLoginState { .unavailable }
    func register() throws {}
    func unregister() throws {}
    func openSystemSettings() {}
}

@MainActor
private final class UIAcceptanceCaptureFixtureContextProvider: CaptureContextProviding {
    var deviceContext: DeviceCaptureContext {
        DeviceCaptureContext(label: "Marketing Fixture Mac", operatingSystem: "Marketing Fixture macOS")
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

@MainActor
private final class UIAcceptanceCaptureFixtureTextExpansionAccessibility: TextExpansionAccessibilityControlling {
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
private final class UIAcceptanceCaptureFixtureTextExpansionEvents: TextExpansionEventMonitoring {
    func start(handler: @escaping @MainActor (Character, Date) -> Void) -> Bool { false }
    func stop() {}
}
