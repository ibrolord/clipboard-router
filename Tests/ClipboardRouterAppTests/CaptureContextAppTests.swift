import ClipboardRouterCore
import ClipboardRouterPlatform
import Foundation
import XCTest
@testable import ClipboardRouterApp

@MainActor
final class CaptureContextAppTests: XCTestCase {
    func testOrdinaryCaptureAttachesSeparatelyConsentedContextAndMakesItSearchable() async throws {
        let location = try CoarseLocationContext(label: "Toronto, ON", geohash: "dpz83")
        let provider = StubCaptureContextProvider(
            authorization: .authorized,
            coarseLocation: location
        )
        let settings = ClipboardLibrarySettings(
            isDeviceContextEnabled: true,
            isLocationContextEnabled: true
        )
        let model = makeModel(
            provider: provider,
            snapshot: ClipboardLibrarySnapshot(settings: settings)
        )
        await model.start()

        model.capture(draft(text: "Context searchable clip"))
        let captured = await waitUntil { model.snapshot.history.count == 1 }
        XCTAssertTrue(captured)
        let item = try XCTUnwrap(model.snapshot.history.first)
        XCTAssertEqual(item.captureContext?.deviceLabel, "Test Mac")
        XCTAssertEqual(item.captureContext?.operatingSystem, "macOS Test")
        XCTAssertEqual(item.captureContext?.coarseLocation, location)
        XCTAssertNotNil(item.originatingDeviceIdentifier)

        model.searchText = "device:Test"
        model.updateSearch()
        let foundByDevice = await waitUntil { model.searchResults.first?.id == item.id }
        XCTAssertTrue(foundByDevice)
        model.searchText = "location:Toronto"
        model.updateSearch()
        let foundByLocation = await waitUntil { model.searchResults.first?.id == item.id }
        XCTAssertTrue(foundByLocation)
    }

    func testPrivateSessionNeverReceivesOptionalContext() async throws {
        let provider = StubCaptureContextProvider(
            authorization: .authorized,
            coarseLocation: try CoarseLocationContext(label: "Toronto, ON", geohash: "dpz83")
        )
        let model = makeModel(
            provider: provider,
            snapshot: ClipboardLibrarySnapshot(settings: ClipboardLibrarySettings(
                isDeviceContextEnabled: true,
                isLocationContextEnabled: true
            ))
        )
        await model.start()
        model.startPrivateSession()
        let started = await waitUntil { model.isPrivateSessionActive }
        XCTAssertTrue(started)

        model.capture(draft(text: "Private context must stay absent"))
        let captured = await waitUntil { model.privateSessionClips.count == 1 }
        XCTAssertTrue(captured)
        let clip = try XCTUnwrap(model.privateSessionClips.first)
        XCTAssertNil(clip.captureContext?.deviceLabel)
        XCTAssertNil(clip.captureContext?.operatingSystem)
        XCTAssertNil(clip.captureContext?.coarseLocation)
        XCTAssertTrue(model.snapshot.history.isEmpty)
    }

    func testDeniedLocationLeavesOrdinaryCaptureWorking() async throws {
        let provider = StubCaptureContextProvider(
            authorization: .denied,
            permissionError: .locationPermissionDenied
        )
        let model = makeModel(
            provider: provider,
            snapshot: ClipboardLibrarySnapshot(settings: ClipboardLibrarySettings(
                isLocationContextEnabled: true
            ))
        )
        await model.start()

        model.requestCaptureLocationPermissionAndRefresh()
        let denied = await waitUntil { model.statusMessage?.contains("denied") == true }
        XCTAssertTrue(denied)
        model.capture(draft(text: "Capture survives denied location"))
        let captured = await waitUntil { model.snapshot.history.count == 1 }
        XCTAssertTrue(captured)
        XCTAssertNil(model.snapshot.history.first?.captureContext?.coarseLocation)
        XCTAssertTrue(model.isCaptureEnabled)
    }

    private func makeModel(
        provider: StubCaptureContextProvider,
        snapshot: ClipboardLibrarySnapshot
    ) -> AppModel {
        let suite = "CaptureContextAppTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return AppModel(
            defaults: defaults,
            hotKey: CaptureContextHotKeyRegistrar(),
            captureContextProvider: provider,
            supportDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("CaptureContextAppTests-\(UUID().uuidString)"),
            libraryPersistence: InMemoryClipboardLibraryStore(snapshot: snapshot)
        )
    }

    private func draft(text: String) -> PasteboardCaptureDraft {
        PasteboardCaptureDraft(
            changeCount: 1,
            typeIdentifiers: ["public.utf8-plain-text"],
            plainText: text,
            source: PasteboardCaptureSource(
                applicationBundleIdentifier: "com.example.Source",
                applicationName: "Source"
            )
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
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

@MainActor
private final class StubCaptureContextProvider: CaptureContextProviding {
    let deviceContext = DeviceCaptureContext(label: "Test Mac", operatingSystem: "macOS Test")
    var locationAuthorization: CaptureLocationAuthorization
    var cachedCoarseLocation: CoarseLocationContext?
    var cachedLocationDate: Date?
    let permissionError: CaptureContextProviderError?

    init(
        authorization: CaptureLocationAuthorization,
        coarseLocation: CoarseLocationContext? = nil,
        permissionError: CaptureContextProviderError? = nil
    ) {
        locationAuthorization = authorization
        cachedCoarseLocation = coarseLocation
        cachedLocationDate = coarseLocation == nil ? nil : Date()
        self.permissionError = permissionError
    }

    func requestLocationPermissionAndRefresh(at date: Date) async throws -> CoarseLocationContext {
        if let permissionError { throw permissionError }
        return try XCTUnwrap(cachedCoarseLocation)
    }

    func refreshLocation(at date: Date) async throws -> CoarseLocationContext {
        if let permissionError { throw permissionError }
        return try XCTUnwrap(cachedCoarseLocation)
    }

    func currentCoarseLocation(at date: Date) -> CoarseLocationContext? {
        cachedCoarseLocation
    }

    func clearLocation() {
        cachedCoarseLocation = nil
        cachedLocationDate = nil
    }
}

@MainActor
private final class CaptureContextHotKeyRegistrar: GlobalHotKeyRegistering {
    func register(
        _ descriptor: GlobalHotKeyDescriptor,
        handler: @escaping @MainActor () -> Void
    ) throws {}

    func unregister() {}
}
