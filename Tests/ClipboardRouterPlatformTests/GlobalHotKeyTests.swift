import Carbon
import XCTest
@testable import ClipboardRouterPlatform

final class GlobalHotKeyTests: XCTestCase {
    func testEveryPersistableChoiceHasAUniqueDescriptorAndLabel() {
        let choices = GlobalHotKeyChoice.allCases

        XCTAssertEqual(Set(choices.map(\.rawValue)).count, choices.count)
        XCTAssertEqual(Set(choices.map(\.displayName)).count, choices.count)
        XCTAssertEqual(
            Set(choices.map { "\($0.descriptor.keyCode):\($0.descriptor.modifiers)" }).count,
            choices.count
        )
    }

    func testDefaultChoiceMatchesDocumentedCommandShiftV() {
        XCTAssertEqual(GlobalHotKeyChoice.commandShiftV.displayName, "⌘⇧V")
        XCTAssertEqual(
            GlobalHotKeyChoice.commandShiftV.descriptor,
            .showClipboardRouter
        )
        XCTAssertEqual(
            GlobalHotKeyChoice.commandShiftV.descriptor.modifiers,
            UInt32(cmdKey | shiftKey)
        )
    }

    func testCommandRegistrationIdentifiersAreUniqueAndStable() {
        XCTAssertEqual(GlobalHotKeyRegistrationID.showClipboardRouter.rawValue, 1)
        XCTAssertEqual(GlobalHotKeyRegistrationID.createNote.rawValue, 2)
        XCTAssertEqual(GlobalHotKeyRegistrationID.insertPalette.rawValue, 3)
        XCTAssertEqual(Set([
            GlobalHotKeyRegistrationID.showClipboardRouter,
            GlobalHotKeyRegistrationID.createNote,
            GlobalHotKeyRegistrationID.insertPalette,
        ]).count, 3)
    }
}
