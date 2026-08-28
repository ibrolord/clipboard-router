import ClipboardRouterCore
import ClipboardRouterPlatform
import XCTest

@MainActor
final class TextExpansionControllerTests: XCTestCase {
    func testPermissionRequiredDoesNotStartEventMonitoring() {
        let accessibility = FakeExpansionAccessibility(access: .permissionRequired)
        let events = FakeExpansionEvents()
        let controller = makeController(accessibility: accessibility, events: events)

        controller.start(promptIfNeeded: true)

        XCTAssertEqual(
            ControllerObservation(status: controller.status, starts: events.startCount),
            ControllerObservation(status: .permissionRequired, starts: 0)
        )
    }

    func testExactAliasExpansionUsesAXMutationWithoutClipboard() {
        let accessibility = FakeExpansionAccessibility(access: .trusted)
        let events = FakeExpansionEvents()
        let controller = makeController(accessibility: accessibility, events: events)
        controller.start()

        events.type(";hello ")

        XCTAssertEqual(
            accessibility.mutations,
            [FakeMutation(count: 7, replacement: "world ")]
        )
    }

    func testEscapeImmediatelyAfterExpansionRestoresAlias() {
        let accessibility = FakeExpansionAccessibility(access: .trusted)
        let events = FakeExpansionEvents()
        let controller = makeController(accessibility: accessibility, events: events)
        controller.start()
        events.type(";hello ")

        events.type("\u{1b}")

        XCTAssertEqual(accessibility.undoneText, ";hello ")
    }

    func testDeniedFocusFailsClosedAndClearsPartialToken() {
        let accessibility = FakeExpansionAccessibility(access: .trusted)
        let events = FakeExpansionEvents()
        var allowed = false
        let controller = makeController(
            accessibility: accessibility,
            events: events,
            isAllowed: { _ in allowed }
        )
        controller.start()
        events.type(";hel")
        allowed = true

        events.type("lo ")

        XCTAssertEqual(accessibility.mutations.count, 0)
    }

    private func makeController(
        accessibility: FakeExpansionAccessibility,
        events: FakeExpansionEvents,
        isAllowed: @escaping (TextExpansionFocus) -> Bool = { _ in true }
    ) -> TextExpansionController {
        TextExpansionController(
            accessibility: accessibility,
            events: events,
            definitions: {
                [TextExpansionDefinition(
                    aliasID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                    trigger: ";hello",
                    replacement: "world"
                )]
            },
            isAllowed: isAllowed
        )
    }
}

private struct ControllerObservation: Equatable {
    let status: TextExpansionAccessStatus
    let starts: Int
}

private struct FakeMutation: Equatable {
    let count: Int
    let replacement: String
}

@MainActor
private final class FakeExpansionAccessibility: TextExpansionAccessibilityControlling {
    var accessValue: PasteAutomationAccess
    var focus = TextExpansionFocus(
        processIdentifier: 42,
        bundleIdentifier: "com.example.Editor",
        role: "AXTextArea",
        identity: "42:editor"
    )
    private(set) var mutations: [FakeMutation] = []
    private(set) var undoneText: String?

    init(access: PasteAutomationAccess) { accessValue = access }

    func access(promptIfNeeded _: Bool) -> PasteAutomationAccess { accessValue }
    func focusedTarget() -> TextExpansionFocus? { focus }

    func replaceCharactersBeforeCursor(
        _ count: Int,
        with replacement: String,
        focus: TextExpansionFocus
    ) -> TextExpansionMutationReceipt? {
        mutations.append(FakeMutation(count: count, replacement: replacement))
        return TextExpansionMutationReceipt(
            focusIdentity: focus.identity,
            insertionLocation: 10,
            insertedUTF16Length: replacement.utf16.count,
            originalText: ""
        )
    }

    func undo(_ receipt: TextExpansionMutationReceipt) -> Bool {
        undoneText = receipt.originalText
        return true
    }
}

@MainActor
private final class FakeExpansionEvents: TextExpansionEventMonitoring {
    private var handler: (@MainActor (Character, Date) -> Void)?
    private(set) var startCount = 0

    func start(handler: @escaping @MainActor (Character, Date) -> Void) -> Bool {
        startCount += 1
        self.handler = handler
        return true
    }

    func stop() { handler = nil }

    func type(_ text: String) {
        var date = Date(timeIntervalSince1970: 100)
        for character in text {
            handler?(character, date)
            date.addTimeInterval(0.01)
        }
    }
}
