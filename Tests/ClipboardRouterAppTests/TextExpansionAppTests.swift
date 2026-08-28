import ClipboardRouterCore
import ClipboardRouterPlatform
import XCTest
@testable import ClipboardRouterApp

@MainActor
final class TextExpansionAppTests: XCTestCase {
    func testTextExpansionIsOffByDefaultAndDoesNotStartMonitor() async throws {
        let events = AppExpansionEvents()
        let model = try makeModel(events: events, saved: [], aliases: [], enabled: false)

        await model.start()

        XCTAssertEqual(
            AppExpansionStatus(enabled: model.isTextExpansionEnabled, starts: events.startCount),
            AppExpansionStatus(enabled: false, starts: 0)
        )
    }

    func testPersistedSensitiveAliasNeverExpands() async throws {
        let content = try ClipContent.detect(
            text: "sk-proj-abcdefghijklmnopqrstuvwxyz1234567890"
        )
        let saved = try SavedClip(name: "Secret", content: content, createdAt: Date())
        let alias = try InsertAlias(name: "Secret", abbreviation: "secret", savedClipID: saved.id)
        let events = AppExpansionEvents()
        let accessibility = AppExpansionAccessibility()
        let model = try makeModel(
            accessibility: accessibility,
            events: events,
            saved: [saved],
            aliases: [alias],
            enabled: true
        )
        await model.start()

        events.type(";secret ")

        XCTAssertEqual(accessibility.mutationCount, 0)
    }

    private func makeModel(
        accessibility: AppExpansionAccessibility = AppExpansionAccessibility(),
        events: AppExpansionEvents,
        saved: [SavedClip],
        aliases: [InsertAlias],
        enabled: Bool
    ) throws -> AppModel {
        let suite = "TextExpansionAppTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(try JSONEncoder().encode(aliases), forKey: "insertAliases.v1")
        defaults.set(enabled, forKey: "textExpansionEnabled.v1")
        return AppModel(
            defaults: defaults,
            hotKey: AppExpansionHotKey(),
            textExpansionAccessibility: accessibility,
            textExpansionEvents: events,
            supportDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(
                "TextExpansionAppTests-\(UUID())",
                isDirectory: true
            ),
            libraryPersistence: InMemoryClipboardLibraryStore(
                snapshot: ClipboardLibrarySnapshot(savedClips: saved)
            )
        )
    }
}

private struct AppExpansionStatus: Equatable {
    let enabled: Bool
    let starts: Int
}

@MainActor
private final class AppExpansionAccessibility: TextExpansionAccessibilityControlling {
    private(set) var mutationCount = 0
    func access(promptIfNeeded _: Bool) -> PasteAutomationAccess { .trusted }
    func focusedTarget() -> TextExpansionFocus? {
        TextExpansionFocus(
            processIdentifier: 42,
            bundleIdentifier: "com.example.Editor",
            role: "AXTextArea",
            identity: "editor"
        )
    }
    func replaceCharactersBeforeCursor(
        _: Int,
        with replacement: String,
        focus: TextExpansionFocus
    ) -> TextExpansionMutationReceipt? {
        mutationCount += 1
        return TextExpansionMutationReceipt(
            focusIdentity: focus.identity,
            insertionLocation: 0,
            insertedUTF16Length: replacement.utf16.count,
            originalText: ""
        )
    }
    func undo(_: TextExpansionMutationReceipt) -> Bool { true }
}

@MainActor
private final class AppExpansionEvents: TextExpansionEventMonitoring {
    private var handler: (@MainActor (Character, Date) -> Void)?
    private(set) var startCount = 0
    func start(handler: @escaping @MainActor (Character, Date) -> Void) -> Bool {
        startCount += 1
        self.handler = handler
        return true
    }
    func stop() { handler = nil }
    func type(_ text: String) {
        for character in text { handler?(character, Date()) }
    }
}

@MainActor
private final class AppExpansionHotKey: GlobalHotKeyRegistering {
    func register(
        _: GlobalHotKeyDescriptor,
        handler _: @escaping @MainActor () -> Void
    ) throws {}
    func unregister() {}
}
