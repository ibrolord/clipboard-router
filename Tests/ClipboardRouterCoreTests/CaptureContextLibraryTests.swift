import Foundation
import XCTest
@testable import ClipboardRouterCore

final class CaptureContextLibraryTests: XCTestCase {
    func testDeviceAndLocationConsentAreSeparateAndOffByDefault() async throws {
        let library = try ClipboardLibrary()
        var snapshot = await library.snapshot()
        XCTAssertFalse(snapshot.settings.effectiveDeviceContextEnabled)
        XCTAssertFalse(snapshot.settings.effectiveLocationContextEnabled)

        try await library.setDeviceContextEnabled(true)
        snapshot = await library.snapshot()
        XCTAssertTrue(snapshot.settings.effectiveDeviceContextEnabled)
        XCTAssertFalse(snapshot.settings.effectiveLocationContextEnabled)

        try await library.setLocationContextEnabled(true)
        snapshot = await library.snapshot()
        XCTAssertTrue(snapshot.settings.effectiveDeviceContextEnabled)
        XCTAssertTrue(snapshot.settings.effectiveLocationContextEnabled)
    }

    func testDeleteCapturedContextIsAtomicAndPreservesSourceMetadata() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let sourceContext = ClipCaptureContext(
            sourceApplicationName: "Safari",
            sourceURL: "https://example.com/a",
            sourceDomain: "example.com",
            deviceLabel: "Work Mac",
            operatingSystem: "macOS",
            coarseLocation: try CoarseLocationContext(label: "Toronto, ON", geohash: "dpz83")
        )
        let history = HistoryItem(
            content: try ClipContent.detect(text: "History context"),
            createdAt: now,
            originatingDeviceIdentifier: "installation-id",
            captureContext: sourceContext
        )
        let saved = try SavedClip(
            name: "Saved context",
            content: ClipContent.detect(text: "Saved context"),
            createdAt: now,
            originatingDeviceIdentifier: "installation-id",
            captureContext: sourceContext
        )
        let library = try ClipboardLibrary(snapshot: ClipboardLibrarySnapshot(
            history: [history],
            savedClips: [saved]
        ))

        let result = try await library.deleteCapturedContext(
            device: true,
            location: true,
            at: now.addingTimeInterval(5)
        )
        let snapshot = await library.snapshot()

        XCTAssertEqual(result, CaptureContextDeletionResult(historyItemCount: 1, savedClipCount: 1))
        XCTAssertNil(snapshot.history[0].originatingDeviceIdentifier)
        XCTAssertNil(snapshot.history[0].captureContext?.deviceLabel)
        XCTAssertNil(snapshot.history[0].captureContext?.operatingSystem)
        XCTAssertNil(snapshot.history[0].captureContext?.coarseLocation)
        XCTAssertEqual(snapshot.history[0].captureContext?.sourceApplicationName, "Safari")
        XCTAssertEqual(snapshot.history[0].captureContext?.sourceDomain, "example.com")
        XCTAssertNil(snapshot.savedClips[0].originatingDeviceIdentifier)
        XCTAssertEqual(snapshot.savedClips[0].captureContext?.sourceURL, "https://example.com/a")
        XCTAssertEqual(snapshot.pendingSavedLibraryMutations.map(\.id), [saved.id])
    }
}
