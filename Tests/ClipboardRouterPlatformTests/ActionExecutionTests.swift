import ClipboardRouterCore
import XCTest
@testable import ClipboardRouterPlatform

@MainActor
final class ActionExecutionTests: XCTestCase {
    func testWebAndEmailActionsOpenValidatedDraftTargetsWithoutClipboardWrites() async throws {
        let opener = ActionFakeOpener()
        let pasteboard = ActionFakePasteboard()
        let executor = ClipActionExecutor(opener: opener, pasteboard: pasteboard)
        let web = DetectedClipEntity(
            kind: .webURL,
            displayValue: "https://example.com",
            normalizedValue: "https://example.com",
            utf16Range: NSRange(location: 0, length: 19)
        )
        let email = DetectedClipEntity(
            kind: .emailAddress,
            displayValue: "sam@example.com",
            normalizedValue: "sam@example.com",
            utf16Range: NSRange(location: 0, length: 15)
        )

        let webReceipt = try await executor.perform(web)
        let emailReceipt = try await executor.perform(email)
        XCTAssertEqual(webReceipt, .openedLink(host: "example.com"))
        XCTAssertEqual(
            emailReceipt,
            .openedEmailDraft(recipient: "sam@example.com")
        )
        XCTAssertEqual(
            opener.webURLs.map(\.absoluteString),
            ["https://example.com", "mailto:sam@example.com"]
        )
        XCTAssertTrue(pasteboard.texts.isEmpty)
    }

    func testUnsafeLinkAndHeaderInjectionFailClosed() async {
        let opener = ActionFakeOpener()
        let executor = ClipActionExecutor(opener: opener)
        let credentialed = DetectedClipEntity(
            kind: .webURL,
            displayValue: "unsafe",
            normalizedValue: "https://user:pass@example.com",
            utf16Range: NSRange(location: 0, length: 6)
        )
        let injected = DetectedClipEntity(
            kind: .emailAddress,
            displayValue: "unsafe",
            normalizedValue: "sam@example.com\r\nbcc:evil@example.com",
            utf16Range: NSRange(location: 0, length: 6)
        )

        await XCTAssertThrowsErrorAsync { _ = try await executor.perform(credentialed) }
        await XCTAssertThrowsErrorAsync { _ = try await executor.perform(injected) }
        XCTAssertTrue(opener.webURLs.isEmpty)
    }

    func testURLAutomationDoesNotRewriteClipboard() async throws {
        let opener = ActionFakeOpener()
        let pasteboard = ActionFakePasteboard()
        let executor = ClipActionExecutor(opener: opener, pasteboard: pasteboard)
        let automation = try ClipAutomation(
            name: "Search portal",
            target: .webURLTemplate("https://example.com/search?q={clip}")
        )

        let receipt = try await executor.run(automation, clipText: "Acme & Sons", entities: [])

        XCTAssertEqual(receipt, .openedAutomationURL(host: "example.com"))
        XCTAssertEqual(opener.webURLs.first?.absoluteString, "https://example.com/search?q=Acme%20%26%20Sons")
        XCTAssertTrue(pasteboard.texts.isEmpty)
    }
}

@MainActor
private final class ActionFakeOpener: ExternalURLOpening {
    var webURLs: [URL] = []
    var applicationURLs: [URL] = []

    func openApplication(at url: URL) async -> Bool {
        applicationURLs.append(url)
        return true
    }

    func openWebURL(_ url: URL) -> Bool {
        webURLs.append(url)
        return true
    }
}

@MainActor
private final class ActionFakePasteboard: PasteboardWriting {
    var texts: [String] = []

    func writeForRouting(_ text: String) -> Bool {
        texts.append(text)
        return true
    }
}

@MainActor
private func XCTAssertThrowsErrorAsync<T>(
    _ expression: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {}
}
