import ClipboardRouterCore
import Foundation
import XCTest
@testable import ClipboardRouterPlatform

@MainActor
final class CopyAndOpenActionTests: XCTestCase {
    func testValidSignatureIsVerifiedBeforeClipboardMutationAndApplicationOpen() async {
        // Arrange
        let url = URL(fileURLWithPath: "/Applications/Sales.app")
        let events = ActionEventRecorder()
        let executor = makeExecutor(
            url: url,
            signature: .valid(teamIdentifier: "TEAM123"),
            bundleIdentifier: "com.example.sales",
            events: events
        )

        // Act
        let result = await copyAndOpenResult(
            executor,
            clipText: "Lead details",
            url: url,
            recorder: events
        )

        // Assert
        XCTAssertEqual(
            result,
            .success(
                receipt: .openedApplication(name: "Sales"),
                events: [
                    .inspected(url.standardizedFileURL),
                    .wrote("Lead details"),
                    .opened(url.standardizedFileURL),
                ]
            )
        )
    }

    func testValidPlatformSignatureWithoutTeamIdentifierCanOpenWhenSelectionAlsoHasNoTeam() async {
        // Arrange
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        let events = ActionEventRecorder()
        let executor = makeExecutor(
            url: url,
            signature: .valid(teamIdentifier: nil),
            bundleIdentifier: "com.apple.Terminal",
            events: events
        )

        // Act
        let result = await copyAndOpenResult(
            executor,
            clipText: "Build output",
            url: url,
            recorder: events,
            expectedBundleIdentifier: "com.apple.Terminal",
            expectedTeamIdentifier: nil
        )

        // Assert
        XCTAssertEqual(
            result,
            .success(
                receipt: .openedApplication(name: "Sales"),
                events: [
                    .inspected(url.standardizedFileURL),
                    .wrote("Build output"),
                    .opened(url.standardizedFileURL),
                ]
            )
        )
    }

    func testInvalidSignatureRejectsTargetBeforeClipboardMutation() async {
        // Arrange
        let url = URL(fileURLWithPath: "/Applications/Unsigned.app")
        let events = ActionEventRecorder()
        let executor = makeExecutor(
            url: url,
            signature: .invalid,
            bundleIdentifier: "com.example.unsigned",
            events: events
        )

        // Act
        let result = await copyAndOpenResult(
            executor,
            clipText: "Secret",
            url: url,
            recorder: events
        )

        // Assert
        XCTAssertEqual(
            result,
            .failure(
                error: .untrustedApplication,
                events: [.inspected(url.standardizedFileURL)]
            )
        )
    }

    func testMissingBundleIdentifierRejectsTargetBeforeClipboardMutation() async {
        // Arrange
        let url = URL(fileURLWithPath: "/Applications/NoIdentifier.app")
        let events = ActionEventRecorder()
        let executor = makeExecutor(
            url: url,
            signature: .valid(teamIdentifier: nil),
            bundleIdentifier: nil,
            events: events
        )

        // Act
        let result = await copyAndOpenResult(
            executor,
            clipText: "Secret",
            url: url,
            recorder: events
        )

        // Assert
        XCTAssertEqual(
            result,
            .failure(
                error: .untrustedApplication,
                events: [.inspected(url.standardizedFileURL)]
            )
        )
    }

    func testExpectedBundleIdentifierMismatchRejectsTargetBeforeClipboardMutation() async {
        // Arrange
        let url = URL(fileURLWithPath: "/Applications/Sales.app")
        let events = ActionEventRecorder()
        let executor = makeExecutor(
            url: url,
            signature: .valid(teamIdentifier: "TEAM123"),
            bundleIdentifier: "com.example.sales",
            events: events
        )

        // Act
        let result = await copyAndOpenResult(
            executor,
            clipText: "Secret",
            url: url,
            recorder: events,
            expectedBundleIdentifier: "com.example.replaced"
        )

        // Assert
        XCTAssertEqual(
            result,
            .failure(
                error: .untrustedApplication,
                events: [.inspected(url.standardizedFileURL)]
            )
        )
    }

    func testExpectedTeamIdentifierMismatchRejectsTargetBeforeClipboardMutation() async {
        // Arrange
        let url = URL(fileURLWithPath: "/Applications/Sales.app")
        let events = ActionEventRecorder()
        let executor = makeExecutor(
            url: url,
            signature: .valid(teamIdentifier: "TEAM123"),
            bundleIdentifier: "com.example.sales",
            events: events
        )

        // Act
        let result = await copyAndOpenResult(
            executor,
            clipText: "Secret",
            url: url,
            recorder: events,
            expectedTeamIdentifier: "OTHERTEAM"
        )

        // Assert
        XCTAssertEqual(
            result,
            .failure(
                error: .untrustedApplication,
                events: [.inspected(url.standardizedFileURL)]
            )
        )
    }

    func testNonApplicationURLIsRejectedBeforeInspectionOrClipboardMutation() async {
        // Arrange
        let url = URL(fileURLWithPath: "/Applications/tool.command")
        let events = ActionEventRecorder()
        let executor = makeExecutor(
            url: url,
            signature: .valid(teamIdentifier: "TEAM123"),
            bundleIdentifier: "com.example.tool",
            events: events
        )

        // Act
        let result = await copyAndOpenResult(
            executor,
            clipText: "Secret",
            url: url,
            recorder: events
        )

        // Assert
        XCTAssertEqual(result, .failure(error: .untrustedApplication, events: []))
    }

    func testEmptyClipFailsBeforeApplicationInspectionOrClipboardMutation() async {
        // Arrange
        let url = URL(fileURLWithPath: "/Applications/Sales.app")
        let events = ActionEventRecorder()
        let executor = makeExecutor(
            url: url,
            signature: .valid(teamIdentifier: "TEAM123"),
            bundleIdentifier: "com.example.sales",
            events: events
        )

        // Act
        let result = await copyAndOpenResult(executor, clipText: "", url: url, recorder: events)

        // Assert
        XCTAssertEqual(result, .failure(error: .clipboardWriteFailed, events: []))
    }

    func testOpenFailureReportsThatClipboardWasAlreadyMutated() async {
        // Arrange
        let url = URL(fileURLWithPath: "/Applications/Sales.app")
        let events = ActionEventRecorder()
        let executor = makeExecutor(
            url: url,
            signature: .valid(teamIdentifier: "TEAM123"),
            bundleIdentifier: "com.example.sales",
            events: events,
            applicationOpenResult: false
        )

        // Act
        let result = await copyAndOpenResult(
            executor,
            clipText: "Lead details",
            url: url,
            recorder: events
        )

        // Assert
        XCTAssertEqual(
            result,
            .failure(
                error: .applicationCouldNotOpenAfterCopy("Sales"),
                events: [
                    .inspected(url.standardizedFileURL),
                    .wrote("Lead details"),
                    .opened(url.standardizedFileURL),
                ]
            )
        )
    }
}

@MainActor
private func makeExecutor(
    url: URL,
    signature: ApplicationSignatureValidation,
    bundleIdentifier: String?,
    events: ActionEventRecorder,
    applicationOpenResult: Bool = true
) -> ClipActionExecutor {
    let metadata = InstalledApplicationMetadata(
        url: url,
        bundleIdentifier: bundleIdentifier,
        bundleName: "Sales",
        displayName: nil,
        executableName: "Sales",
        signature: signature
    )
    return ClipActionExecutor(
        opener: RecordingOpener(events: events, result: applicationOpenResult),
        pasteboard: RecordingPasteboard(events: events),
        bookmarks: UnusedBookmarks(),
        metadataInspector: RecordingMetadataInspector(events: events, metadata: metadata)
    )
}

@MainActor
private func copyAndOpenResult(
    _ executor: ClipActionExecutor,
    clipText: String,
    url: URL,
    recorder: ActionEventRecorder,
    expectedBundleIdentifier: String = "com.example.sales",
    expectedTeamIdentifier: String? = "TEAM123"
) async -> CopyAndOpenResult {
    do {
        let receipt = try await executor.copyAndOpen(
            clipText: clipText,
            applicationURL: url,
            expectedBundleIdentifier: expectedBundleIdentifier,
            expectedTeamIdentifier: expectedTeamIdentifier
        )
        return .success(receipt: receipt, events: recorder.events)
    } catch let error as ClipActionExecutionError {
        return .failure(error: error, events: recorder.events)
    } catch {
        return .unexpectedError(String(describing: error), events: recorder.events)
    }
}

private enum ActionEvent: Equatable {
    case inspected(URL)
    case wrote(String)
    case opened(URL)
}

private enum CopyAndOpenResult: Equatable {
    case success(receipt: ClipActionExecutionReceipt, events: [ActionEvent])
    case failure(error: ClipActionExecutionError, events: [ActionEvent])
    case unexpectedError(String, events: [ActionEvent])
}

@MainActor
private final class ActionEventRecorder {
    var events: [ActionEvent] = []
}

@MainActor
private final class RecordingMetadataInspector: ApplicationMetadataInspecting {
    let events: ActionEventRecorder
    let metadata: InstalledApplicationMetadata?

    init(events: ActionEventRecorder, metadata: InstalledApplicationMetadata?) {
        self.events = events
        self.metadata = metadata
    }

    func metadata(forApplicationAt url: URL) -> InstalledApplicationMetadata? {
        events.events.append(.inspected(url.standardizedFileURL))
        return metadata
    }
}

@MainActor
private final class RecordingPasteboard: PasteboardWriting {
    let events: ActionEventRecorder

    init(events: ActionEventRecorder) {
        self.events = events
    }

    func writeForRouting(_ text: String) -> Bool {
        events.events.append(.wrote(text))
        return true
    }
}

@MainActor
private final class RecordingOpener: ExternalURLOpening {
    let events: ActionEventRecorder
    let result: Bool

    init(events: ActionEventRecorder, result: Bool) {
        self.events = events
        self.result = result
    }

    func openApplication(at url: URL) async -> Bool {
        events.events.append(.opened(url.standardizedFileURL))
        return result
    }

    func openWebURL(_ url: URL) -> Bool {
        false
    }
}

private final class UnusedBookmarks: ApplicationBookmarking {
    func bookmarkData(forApplicationAt url: URL) throws -> Data {
        XCTFail("copyAndOpen must not create a bookmark")
        return Data()
    }

    func resolveApplicationBookmark(_ data: Data) throws -> ResolvedApplicationBookmark {
        XCTFail("copyAndOpen must not resolve a bookmark")
        throw CocoaError(.featureUnsupported)
    }

    func stopAccessing(_ bookmark: ResolvedApplicationBookmark) {
        XCTFail("copyAndOpen must not stop bookmark access")
    }
}
