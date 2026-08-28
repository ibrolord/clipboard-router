import AppKit
import ClipboardRouterCore
import ClipboardRouterPlatform
import XCTest
@testable import ClipboardRouterApp

@MainActor
final class UIAcceptanceRuntimeTests: XCTestCase {
    func testConfigurationRequiresExactBundleIdentifierAndExplicitFlag() {
        let temp = URL(fileURLWithPath: "/tmp/ui-acceptance-tests", isDirectory: true)
        XCTAssertNil(UIAcceptanceRuntime.configuration(
            bundleIdentifier: "com.clipboardrouter.ClipboardRouter",
            arguments: ["ClipboardRouter", "--clipboard-router-ui-acceptance", "--ui-acceptance-run-id", "run-1"],
            temporaryDirectory: temp
        ))
        XCTAssertNil(UIAcceptanceRuntime.configuration(
            bundleIdentifier: UIAcceptanceRuntime.bundleIdentifier,
            arguments: ["ClipboardRouter"],
            temporaryDirectory: temp
        ))

        let configuration = UIAcceptanceRuntime.configuration(
            bundleIdentifier: UIAcceptanceRuntime.bundleIdentifier,
            arguments: ["ClipboardRouter", "--clipboard-router-ui-acceptance", "--ui-acceptance-run-id", "run-1"],
            temporaryDirectory: temp
        )
        XCTAssertEqual(configuration?.runID, "run-1")
        XCTAssertEqual(
            configuration?.supportDirectory.path,
            "/tmp/ui-acceptance-tests/ClipboardRouterUIAcceptance/run-1"
        )
    }

    func testConfigurationRejectsUnsafeOrMissingRunID() {
        let bundleID = UIAcceptanceRuntime.bundleIdentifier
        XCTAssertNil(UIAcceptanceRuntime.configuration(
            bundleIdentifier: bundleID,
            arguments: ["ClipboardRouter", UIAcceptanceRuntime.enableArgument, "--ui-acceptance-run-id"],
            temporaryDirectory: URL(fileURLWithPath: "/tmp")
        ))
        XCTAssertNil(UIAcceptanceRuntime.configuration(
            bundleIdentifier: bundleID,
            arguments: ["ClipboardRouter", UIAcceptanceRuntime.enableArgument, "--ui-acceptance-run-id", "../escape"],
            temporaryDirectory: URL(fileURLWithPath: "/tmp")
        ))
    }

    func testProductionBundleDoesNotConstructAnAcceptanceModel() {
        XCTAssertNil(UIAcceptanceRuntime.makeModelIfEnabled(
            bundleIdentifier: "com.clipboardrouter.ClipboardRouter",
            arguments: ["ClipboardRouter"],
            temporaryDirectory: FileManager.default.temporaryDirectory
        ))
    }

    func testAcceptanceBundleWithoutExplicitGateFailsClosedAwayFromProductionData() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardRouterUIAcceptanceFailClosedTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let model = try XCTUnwrap(UIAcceptanceRuntime.makeModelIfEnabled(
            bundleIdentifier: UIAcceptanceRuntime.bundleIdentifier,
            arguments: ["ClipboardRouter"],
            temporaryDirectory: temporaryDirectory
        ))
        await model.start()

        XCTAssertTrue(model.isReady)
        XCTAssertTrue(model.snapshot.history.isEmpty)
        XCTAssertTrue(model.snapshot.savedClips.isEmpty)
        XCTAssertFalse(model.isCaptureEnabled)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: temporaryDirectory
                .appendingPathComponent("ClipboardRouterUIAcceptance", isDirectory: true)
                .appendingPathComponent("fail-closed", isDirectory: true)
                .appendingPathComponent("library.sqlite3")
                .path
        ))
    }

    func testFailClosedAcceptanceMonitorUsesOnlyItsInjectedNamedPasteboard() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardRouterUIAcceptanceFailClosedReaderTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(
            "com.clipboardrouter.uiacceptance.fail-closed-reader.\(UUID().uuidString)"
        ))
        pasteboard.clearContents()

        let model = UIAcceptanceRuntime.makeFailClosedModel(
            temporaryDirectory: temporaryDirectory,
            pasteboard: pasteboard
        )
        await model.start()
        model.completeOnboarding()
        model.toggleCapture()
        let captureEnabled = await waitUntil { model.isCaptureEnabled }
        XCTAssertTrue(captureEnabled)

        let canary = "fail-closed named pasteboard \(UUID().uuidString)"
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString(canary, forType: .string))
        let captured = await waitUntil(timeout: .seconds(2)) {
            model.snapshot.history.contains(where: { $0.content.text == canary })
        }
        XCTAssertTrue(captured)
    }

    func testFixtureHasOneThousandOneDeterministicHistoryRowsAndCaptureOff() {
        let referenceDate = Date(timeIntervalSince1970: 2_000_000_000)
        let snapshot = UIAcceptanceRuntime.fixtureSnapshot(referenceDate: referenceDate)

        XCTAssertEqual(snapshot.history.count, 1_001)
        XCTAssertEqual(snapshot.history.first?.id, UIAcceptanceRuntime.fixtureUUID(index: 1))
        XCTAssertEqual(snapshot.history.last?.id, UIAcceptanceRuntime.fixtureUUID(index: 1_001))
        XCTAssertEqual(snapshot.history.first?.content.text, UIAcceptanceRuntime.fixtureText(index: 1))
        XCTAssertEqual(snapshot.history.last?.content.text, "Acceptance clip 1001")
        XCTAssertEqual(
            snapshot.history.first(where: { $0.id == UIAcceptanceRuntime.livePreviewLoadedFixtureID })?.content.text,
            UIAcceptanceRuntime.livePreviewLoadedURL
        )
        XCTAssertEqual(
            snapshot.history.first(where: { $0.id == UIAcceptanceRuntime.livePreviewOfflineFixtureID })?.content.text,
            UIAcceptanceRuntime.livePreviewOfflineURL
        )
        XCTAssertEqual(
            snapshot.history.first(where: { $0.id == UIAcceptanceRuntime.livePreviewBlockedPrivateFixtureID })?.content.text,
            UIAcceptanceRuntime.livePreviewBlockedPrivateURL
        )
        XCTAssertFalse(snapshot.settings.capturePolicy.isCaptureEnabled)
        XCTAssertEqual(snapshot.settings.retentionPolicy, .unlimited)
        XCTAssertEqual(snapshot.savedClips.map(\.name), ["Acceptance Editable Note"])
        XCTAssertTrue(snapshot.savedClips[0].isPinned)
    }

    func testFixtureReviewFlowHasStableAcceptanceName() {
        XCTAssertEqual(UIAcceptanceRuntime.fixtureReviewFlow().name, "Acceptance Review Flow")
    }

    func testFixtureReviewFlowContainsTwoReviewedSteps() {
        XCTAssertEqual(UIAcceptanceRuntime.fixtureReviewFlow().steps.count, 2)
    }

    func testAcceptanceModelLoadsFixtureReviewFlowFromIsolatedDefaults() throws {
        let configuration = try makeConfiguration()
        defer { cleanUp(configuration) }

        let model = UIAcceptanceRuntime.makeModel(configuration: configuration)

        XCTAssertEqual(model?.clipFlows.map(\.name), ["Acceptance Review Flow"])
    }

    func testAcceptanceReviewFlowIsApplicableToPinnedFixtureNote() async throws {
        let configuration = try makeConfiguration()
        defer { cleanUp(configuration) }
        let model = UIAcceptanceRuntime.makeModel(configuration: configuration)

        await model?.start()
        let applicableFlowNames = model?.menuBarPinnedClips.first.map {
            model?.applicableFlows(for: $0).map(\.name) ?? []
        } ?? []

        XCTAssertEqual(applicableFlowNames, ["Acceptance Review Flow"])
    }

    func testAcceptanceReviewFlowPersistsFollowUpNoteAfterExecution() async throws {
        let configuration = try makeConfiguration()
        defer { cleanUp(configuration) }
        let model = try XCTUnwrap(UIAcceptanceRuntime.makeModel(configuration: configuration))
        await model.start()
        model.selectLibrarySection(.allSaved)

        let source = try XCTUnwrap(
            model.snapshot.savedClips.first(where: {
                $0.id == UIAcceptanceRuntime.fixtureUUID(index: 9_001)
            })
        )
        let presented = try XCTUnwrap(
            model.clipsForSelectedSection.first(where: { $0.id == source.id })
        )
        let flow = UIAcceptanceRuntime.fixtureReviewFlow()
        model.requestFlowRun(flow, for: presented)
        let reviewAppeared = await waitUntil(timeout: .seconds(2)) {
            model.pendingFlowReview != nil
        }
        XCTAssertTrue(reviewAppeared)
        let request = try XCTUnwrap(model.pendingFlowReview)
        let executed = await model.executeFlow(request)
        XCTAssertTrue(executed)
        try? await Task.sleep(for: .seconds(2))

        XCTAssertTrue(
            model.snapshot.savedClips.contains(where: {
                $0.kind == .note && $0.name == "Follow up: Acceptance Editable Note"
            }),
            "status=\(model.statusMessage ?? "nil") error=\(model.errorMessage ?? "nil")"
        )
        model.selectLibrarySection(.smartView(.notes))
        XCTAssertTrue(
            model.clipsForSelectedSection.contains(where: {
                $0.title == "Follow up: Acceptance Editable Note"
            }),
            "generated follow-up note must remain discoverable in the Notes presentation"
        )
    }

    func testAcceptanceModelUsesProductionSQLiteInItsExactRunDirectory() async throws {
        let configuration = try makeConfiguration()
        defer { cleanUp(configuration) }

        let model = try XCTUnwrap(UIAcceptanceRuntime.makeModel(configuration: configuration))
        await model.start()

        XCTAssertTrue(model.isReady)
        XCTAssertEqual(model.snapshot.history.count, UIAcceptanceRuntime.fixtureHistoryCount)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: configuration.supportDirectory
                .appendingPathComponent("library.sqlite3")
                .path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: configuration.supportDirectory
                .appendingPathComponent("library.v1.migrated.json")
                .path
        ))
    }

    func testAcceptanceLibraryAndPreferencesSurviveModelRelaunch() async throws {
        let configuration = try makeConfiguration()
        defer { cleanUp(configuration) }

        var firstModel: AppModel? = try XCTUnwrap(
            UIAcceptanceRuntime.makeModel(configuration: configuration)
        )
        await firstModel?.start()
        firstModel?.setMenuBarClipLimit(73)
        let created = await firstModel?.createNoteFromEditor(
            title: "Relaunch proof note",
            body: "Persisted by the acceptance artifact's SQLite library.",
            folderID: nil
        )
        XCTAssertEqual(created, true)
        XCTAssertEqual(
            firstModel?.snapshot.savedClips.filter { $0.name == "Relaunch proof note" }.count,
            1
        )
        firstModel = nil

        let relaunchedModel = try XCTUnwrap(
            UIAcceptanceRuntime.makeModel(configuration: configuration)
        )
        await relaunchedModel.start()

        XCTAssertEqual(relaunchedModel.menuBarClipLimit, 73)
        XCTAssertEqual(relaunchedModel.snapshot.history.count, UIAcceptanceRuntime.fixtureHistoryCount)
        XCTAssertEqual(
            relaunchedModel.snapshot.savedClips.filter { $0.name == "Relaunch proof note" }.count,
            1
        )
    }

    func testAcceptanceCopyUsesTypedProductionWriterOnRunNamedPasteboard() async throws {
        let configuration = try makeConfiguration()
        defer { cleanUp(configuration) }
        let pasteboard = UIAcceptanceRuntime.pasteboard(for: configuration)
        pasteboard.clearContents()
        let generalChangeCount = NSPasteboard.general.changeCount

        let model = try XCTUnwrap(UIAcceptanceRuntime.makeModel(configuration: configuration))
        await model.start()
        let clip = try XCTUnwrap(model.menuBarRecentClips.first)
        model.copy(clip)

        let copied = await waitUntil {
            pasteboard.string(forType: .string) == clip.content.text
        }
        XCTAssertTrue(
            copied,
            "status=\(model.statusMessage ?? "nil") error=\(model.errorMessage ?? "nil")"
        )
        XCTAssertEqual(
            pasteboard.string(forType: NSPasteboard.PasteboardType(
                ClipboardRouterPasteboardType.appOrigin
            )),
            "1"
        )
        XCTAssertEqual(
            pasteboard.types?.map(\.rawValue).contains(NSPasteboard.PasteboardType.string.rawValue),
            true
        )
        XCTAssertEqual(NSPasteboard.general.changeCount, generalChangeCount)
    }

    func testAcceptanceLivePreviewFixturesAreDeterministicAndNeverNeedNetwork() async throws {
        let configuration = try makeConfiguration()
        defer { cleanUp(configuration) }
        let model = try XCTUnwrap(UIAcceptanceRuntime.makeModel(configuration: configuration))
        await model.start()

        let loadedClip = try XCTUnwrap(model.clipsForSelectedSection.first {
            $0.id == UIAcceptanceRuntime.livePreviewLoadedFixtureID
        })
        let offlineClip = try XCTUnwrap(model.clipsForSelectedSection.first {
            $0.id == UIAcceptanceRuntime.livePreviewOfflineFixtureID
        })
        let blockedClip = try XCTUnwrap(model.clipsForSelectedSection.first {
            $0.id == UIAcceptanceRuntime.livePreviewBlockedPrivateFixtureID
        })

        XCTAssertEqual(model.liveLinkPreviewState(for: loadedClip), .idle)
        await model.loadLiveLinkPreview(for: loadedClip)
        guard case let .loaded(metadata) = model.liveLinkPreviewState(for: loadedClip) else {
            return XCTFail("Expected the loaded fixture to use deterministic metadata")
        }
        XCTAssertEqual(metadata.sourceURL.absoluteString, UIAcceptanceRuntime.livePreviewLoadedURL)
        XCTAssertEqual(metadata.title, "Acceptance Preview Loaded")
        XCTAssertEqual(metadata.siteName, "Clipboard Router Acceptance")
        XCTAssertEqual(metadata.fetchedAt, Date(timeIntervalSince1970: 2_000_000_123))

        await model.loadLiveLinkPreview(for: loadedClip, refresh: true)
        guard case let .loaded(refreshed) = model.liveLinkPreviewState(for: loadedClip) else {
            return XCTFail("Expected the loaded fixture to refresh deterministically")
        }
        XCTAssertEqual(refreshed.title, "Acceptance Preview Refreshed")
        XCTAssertTrue(refreshed.summary?.contains("No network request was made") == true)

        await model.clearLiveLinkPreview(for: loadedClip)
        XCTAssertEqual(model.liveLinkPreviewState(for: loadedClip), .idle)

        await model.loadLiveLinkPreview(for: offlineClip)
        guard case let .offline(message) = model.liveLinkPreviewState(for: offlineClip) else {
            return XCTFail("Expected the offline fixture to surface an offline state")
        }
        XCTAssertEqual(message, LiveLinkPreviewError.offline.localizedDescription)

        XCTAssertFalse(model.canLoadLiveLinkPreview(for: blockedClip))
        guard case let .blocked(message) = model.liveLinkPreviewState(for: blockedClip) else {
            return XCTFail("Expected the private-address fixture to be blocked before fetching")
        }
        XCTAssertEqual(message, LiveLinkPreviewError.localNetworkAddress.localizedDescription)
    }

    private func makeConfiguration() throws -> UIAcceptanceRuntime.Configuration {
        let runID = "test-\(UUID().uuidString.lowercased())"
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardRouterUIAcceptanceRuntimeTests", isDirectory: true)
            .appendingPathComponent(runID, isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        return UIAcceptanceRuntime.Configuration(
            runID: runID,
            defaultsSuiteName: "\(UIAcceptanceRuntime.bundleIdentifier).tests.\(runID)",
            supportDirectory: root
        )
    }

    private func cleanUp(_ configuration: UIAcceptanceRuntime.Configuration) {
        UserDefaults.standard.removePersistentDomain(forName: configuration.defaultsSuiteName)
        try? FileManager.default.removeItem(at: configuration.supportDirectory)
        UIAcceptanceRuntime.pasteboard(for: configuration).clearContents()
    }

    private func waitUntil(
        timeout: Duration = .seconds(3),
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}
