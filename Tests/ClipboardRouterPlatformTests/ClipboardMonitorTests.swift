import ClipboardRouterCore
import XCTest
@testable import ClipboardRouterPlatform

@MainActor
final class ClipboardMonitorTests: XCTestCase {
    func testStartBaselinesExistingPasteboardAndUses350MillisecondPolling() throws {
        let pasteboard = FakePasteboardReader(
            PasteboardSnapshot(changeCount: 7, text: "existing", typeIdentifiers: [])
        )
        let scheduler = FakeRepeatingScheduler()
        var captures: [CaptureCandidate] = []
        let monitor = ClipboardMonitor(
            pasteboard: pasteboard,
            applications: FakeFrontmostApplicationProvider(),
            scheduler: scheduler,
            configuration: { ClipboardMonitorConfiguration() },
            onCapture: { captures.append($0) }
        )

        monitor.start()
        scheduler.fire()

        let interval = try XCTUnwrap(scheduler.scheduledInterval)
        XCTAssertEqual(interval, 0.35, accuracy: 0.000_1)
        XCTAssertTrue(captures.isEmpty)
        XCTAssertEqual(pasteboard.stringReadCount, 0)
    }

    func testChangedPlainTextIsCapturedWithSourceAndTypes() throws {
        let pasteboard = FakePasteboardReader(
            PasteboardSnapshot(changeCount: 1, text: "old", typeIdentifiers: ["public.utf8-plain-text"])
        )
        let applications = FakeFrontmostApplicationProvider(bundleIdentifier: "com.example.editor")
        var captures: [CaptureCandidate] = []
        let monitor = ClipboardMonitor(
            pasteboard: pasteboard,
            applications: applications,
            scheduler: FakeRepeatingScheduler(),
            configuration: { ClipboardMonitorConfiguration() },
            onCapture: { captures.append($0) }
        )
        monitor.start()

        pasteboard.value = PasteboardSnapshot(
            changeCount: 2,
            text: "https://example.com/path",
            typeIdentifiers: ["public.utf8-plain-text"]
        )
        monitor.pollNow()

        XCTAssertEqual(captures.count, 1)
        XCTAssertEqual(captures[0].content.type, .url)
        XCTAssertEqual(captures[0].sourceApplicationBundleIdentifier, "com.example.editor")
        XCTAssertEqual(captures[0].pasteboardTypeIdentifiers, ["public.utf8-plain-text"])
        XCTAssertEqual(pasteboard.stringReadCount, 1)
    }

    func testPausedAndExcludedChangesAreConsumedAndNeverCapturedLater() {
        let pasteboard = FakePasteboardReader(
            PasteboardSnapshot(changeCount: 0, text: nil, typeIdentifiers: [])
        )
        let applications = FakeFrontmostApplicationProvider(bundleIdentifier: "com.example.private")
        let configuration = FakeMonitorConfiguration(
            value: ClipboardMonitorConfiguration(isCaptureEnabled: false)
        )
        var captures: [CaptureCandidate] = []
        let monitor = ClipboardMonitor(
            pasteboard: pasteboard,
            applications: applications,
            scheduler: FakeRepeatingScheduler(),
            configuration: { configuration.value },
            onCapture: { captures.append($0) }
        )
        monitor.start()

        pasteboard.value = PasteboardSnapshot(changeCount: 1, text: "paused secret", typeIdentifiers: [])
        monitor.pollNow()
        configuration.value.isCaptureEnabled = true
        monitor.pollNow()
        XCTAssertTrue(captures.isEmpty)
        XCTAssertEqual(pasteboard.stringReadCount, 0)

        configuration.value.excludedApplicationBundleIdentifiers = ["COM.EXAMPLE.PRIVATE"]
        pasteboard.value = PasteboardSnapshot(changeCount: 2, text: "excluded secret", typeIdentifiers: [])
        monitor.pollNow()
        configuration.value.excludedApplicationBundleIdentifiers = []
        monitor.pollNow()
        XCTAssertTrue(captures.isEmpty)
        XCTAssertEqual(pasteboard.stringReadCount, 0)
    }

    func testExcludedAppDeactivationConsumesCopyBeforeFastAppSwitch() {
        let pasteboard = FakePasteboardReader(
            PasteboardSnapshot(changeCount: 0, text: nil, typeIdentifiers: [])
        )
        let applications = FakeFrontmostApplicationProvider(bundleIdentifier: "com.example.private")
        var captures: [CaptureCandidate] = []
        let monitor = ClipboardMonitor(
            pasteboard: pasteboard,
            applications: applications,
            scheduler: FakeRepeatingScheduler(),
            configuration: {
                ClipboardMonitorConfiguration(
                    excludedApplicationBundleIdentifiers: ["com.example.private"]
                )
            },
            onCapture: { captures.append($0) }
        )
        monitor.start()
        monitor.applicationDidActivate(bundleIdentifier: "com.example.private")
        pasteboard.value = PasteboardSnapshot(
            changeCount: 1,
            text: "excluded copy before switching",
            typeIdentifiers: ["public.utf8-plain-text"]
        )

        monitor.applicationDidDeactivate(bundleIdentifier: "com.example.private")
        applications.bundleIdentifier = "com.example.editor"
        monitor.pollNow()

        XCTAssertTrue(captures.isEmpty)
        XCTAssertEqual(pasteboard.stringReadCount, 0)
    }

    func testExcludedAppWithoutCopyDoesNotConsumeAllowedCopyMadeBeforeSwitch() throws {
        let pasteboard = FakePasteboardReader(
            PasteboardSnapshot(changeCount: 0, text: nil, typeIdentifiers: [])
        )
        let applications = FakeFrontmostApplicationProvider(bundleIdentifier: "com.example.editor")
        var captures: [CaptureCandidate] = []
        let monitor = ClipboardMonitor(
            pasteboard: pasteboard,
            applications: applications,
            scheduler: FakeRepeatingScheduler(),
            configuration: {
                ClipboardMonitorConfiguration(
                    excludedApplicationBundleIdentifiers: ["com.example.private"]
                )
            },
            onCapture: { captures.append($0) }
        )
        monitor.start()
        pasteboard.value = PasteboardSnapshot(
            changeCount: 1,
            text: "allowed copy before switching",
            typeIdentifiers: ["public.utf8-plain-text"]
        )

        applications.bundleIdentifier = "com.example.private"
        monitor.applicationDidActivate(bundleIdentifier: "com.example.private")
        monitor.pollNow()
        monitor.applicationDidDeactivate(bundleIdentifier: "com.example.private")
        applications.bundleIdentifier = "com.example.other-editor"
        monitor.applicationDidActivate(bundleIdentifier: "com.example.other-editor")
        monitor.pollNow()

        let capture = try XCTUnwrap(captures.first)
        XCTAssertEqual(captures.count, 1)
        XCTAssertEqual(capture.content.text, "allowed copy before switching")
        XCTAssertEqual(pasteboard.stringReadCount, 1)
    }

    func testConcealedTransientAndAppOriginatedChangesAreRejected() {
        let pasteboard = FakePasteboardReader(
            PasteboardSnapshot(changeCount: 0, text: nil, typeIdentifiers: [])
        )
        var captures: [CaptureCandidate] = []
        let monitor = ClipboardMonitor(
            pasteboard: pasteboard,
            applications: FakeFrontmostApplicationProvider(),
            scheduler: FakeRepeatingScheduler(),
            configuration: { ClipboardMonitorConfiguration() },
            onCapture: { captures.append($0) }
        )
        monitor.start()

        let ignoredTypes = [
            PasteboardSemanticType.concealed,
            PasteboardSemanticType.transient,
            PasteboardSemanticType.automaticallyGenerated,
            ClipboardRouterPasteboardType.appOrigin,
        ]
        for (offset, type) in ignoredTypes.enumerated() {
            pasteboard.value = PasteboardSnapshot(
                changeCount: offset + 1,
                text: "sensitive \(offset)",
                typeIdentifiers: [type]
            )
            monitor.pollNow()
        }

        XCTAssertTrue(captures.isEmpty)
        XCTAssertEqual(pasteboard.stringReadCount, 0)
    }

    func testPayloadReadRejectsPasteboardChangeAfterMetadataCheck() {
        let pasteboard = FakePasteboardReader(
            PasteboardSnapshot(changeCount: 0, text: nil, typeIdentifiers: [])
        )
        var captures: [CaptureCandidate] = []
        let monitor = ClipboardMonitor(
            pasteboard: pasteboard,
            applications: FakeFrontmostApplicationProvider(),
            scheduler: FakeRepeatingScheduler(),
            configuration: { ClipboardMonitorConfiguration() },
            onCapture: { captures.append($0) }
        )
        monitor.start()
        pasteboard.value = PasteboardSnapshot(
            changeCount: 1,
            text: "apparently safe",
            typeIdentifiers: ["public.utf8-plain-text"]
        )
        pasteboard.valueWhenStringIsRead = PasteboardSnapshot(
            changeCount: 2,
            text: "new concealed secret",
            typeIdentifiers: [PasteboardSemanticType.concealed]
        )

        monitor.pollNow()
        monitor.pollNow()

        XCTAssertTrue(captures.isEmpty)
        XCTAssertEqual(pasteboard.stringReadCount, 1)
    }

    func testStopCancelsSchedulerAndRestartCreatesFreshBaseline() {
        let pasteboard = FakePasteboardReader(
            PasteboardSnapshot(changeCount: 4, text: "first", typeIdentifiers: [])
        )
        let scheduler = FakeRepeatingScheduler()
        var captures: [CaptureCandidate] = []
        let monitor = ClipboardMonitor(
            pasteboard: pasteboard,
            applications: FakeFrontmostApplicationProvider(),
            scheduler: scheduler,
            configuration: { ClipboardMonitorConfiguration() },
            onCapture: { captures.append($0) }
        )

        monitor.start()
        monitor.stop()
        XCTAssertEqual(scheduler.cancelCount, 1)

        pasteboard.value = PasteboardSnapshot(changeCount: 5, text: "while stopped", typeIdentifiers: [])
        monitor.pollNow()
        monitor.start()
        monitor.pollNow()
        XCTAssertTrue(captures.isEmpty)
    }
}

@MainActor
private final class FakePasteboardReader: PasteboardSnapshotReading {
    var value: PasteboardSnapshot
    var valueWhenStringIsRead: PasteboardSnapshot?
    private(set) var stringReadCount = 0

    init(_ value: PasteboardSnapshot) {
        self.value = value
    }

    func metadataSnapshot() -> PasteboardSnapshot {
        PasteboardSnapshot(
            changeCount: value.changeCount,
            text: nil,
            typeIdentifiers: value.typeIdentifiers
        )
    }

    func stringValue(ifChangeCountIs expectedChangeCount: Int) -> String? {
        stringReadCount += 1
        let countBeforeRead = value.changeCount
        if let replacement = valueWhenStringIsRead {
            value = replacement
            valueWhenStringIsRead = nil
        }
        let result = value.text
        guard countBeforeRead == expectedChangeCount,
              value.changeCount == expectedChangeCount
        else { return nil }
        return result
    }
}

@MainActor
private final class FakeFrontmostApplicationProvider: FrontmostApplicationProviding {
    var bundleIdentifier: String?

    init(bundleIdentifier: String? = nil) {
        self.bundleIdentifier = bundleIdentifier
    }

    var frontmostBundleIdentifier: String? { bundleIdentifier }
}

@MainActor
private final class FakeRepeatingScheduler: RepeatingScheduling {
    var scheduledInterval: TimeInterval?
    var cancelCount = 0
    private var action: (@MainActor () -> Void)?

    func schedule(every interval: TimeInterval, _ action: @escaping @MainActor () -> Void) {
        scheduledInterval = interval
        self.action = action
    }

    func cancel() {
        cancelCount += 1
        action = nil
    }

    func fire() {
        action?()
    }
}

@MainActor
private final class FakeMonitorConfiguration {
    var value: ClipboardMonitorConfiguration

    init(value: ClipboardMonitorConfiguration) {
        self.value = value
    }
}
