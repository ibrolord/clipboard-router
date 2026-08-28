import ClipboardRouterPlatform
import XCTest

@MainActor
final class AdvancedClipActionTests: XCTestCase {
    func testOnDeviceAIRejectsEmptyAndOversizedPromptsBeforeModelAccess() async {
        let processor = OnDeviceClipAIProcessor()

        await XCTAssertThrowsErrorAsync {
            _ = try await processor.respond(context: "account context", prompt: "   ")
        } verify: { error in
            XCTAssertEqual(error as? OnDeviceAIError, .emptyPrompt)
        }

        let oversized = String(
            repeating: "a",
            count: OnDeviceClipAIProcessor.maximumPromptUTF8Bytes + 1
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await processor.respond(context: "account context", prompt: oversized)
        } verify: { error in
            XCTAssertEqual(error as? OnDeviceAIError, .inputTooLarge)
        }
    }
}

@MainActor
private func XCTAssertThrowsErrorAsync<T>(
    _ expression: () async throws -> T,
    verify: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {
        verify(error)
    }
}
