import Foundation
import XCTest
@testable import ClipboardRouterCore

final class DeveloperEditionCoreTests: XCTestCase {
    func testRecognizerClassifiesCodeLogsErrorsAndStackTracesDeterministically() {
        let recognizer = DeveloperContentRecognizer()

        let code = recognizer.analyze("""
        ```swift
        import Foundation
        struct Example {
            let value = 1
        }
        ```
        """)
        XCTAssertEqual(code.kind, .sourceCode)
        XCTAssertEqual(code.languageHint, "swift")
        XCTAssertTrue(code.signals.contains(.fencedCodeBlock))

        let unlabelledFence = recognizer.analyze("""
        ```
        let value = 42
        ```
        """)
        XCTAssertEqual(unlabelledFence.kind, .sourceCode)
        XCTAssertTrue(unlabelledFence.signals.contains(.fencedCodeBlock))

        let log = recognizer.analyze("""
        2026-08-14T12:00:00Z INFO server started
        2026-08-14T12:00:01Z DEBUG accepted request
        """)
        XCTAssertEqual(log.kind, .log)
        XCTAssertTrue(log.signals.contains(.logTimestamp))
        XCTAssertTrue(log.signals.contains(.logLevel))

        let error = recognizer.analyze("compile error: cannot find value in scope")
        XCTAssertEqual(error.kind, .error)
        XCTAssertTrue(error.signals.contains(.errorDiagnostic))

        let traceText = """
        Traceback (most recent call last):
          File "worker.py", line 8, in run
          File "main.py", line 2, in main
        ValueError: invalid input
        """
        let firstTrace = recognizer.analyze(traceText)
        XCTAssertEqual(firstTrace.kind, .stackTrace)
        XCTAssertEqual(firstTrace.languageHint, "python")
        XCTAssertEqual(firstTrace, recognizer.analyze(traceText))
    }

    func testRecognizerBoundsInputWithoutSplittingUnicode() {
        let input = String(repeating: "🧪", count: DeveloperContentRecognizer.maximumInputUTF8Bytes)
        let analysis = DeveloperContentRecognizer().analyze(input)

        XCTAssertTrue(analysis.inputWasTruncated)
        XCTAssertEqual(analysis.kind, .plainText)
    }

    func testRecognizerClassifiesOnlyExplicitCommandSignalsAsCommands() {
        let recognizer = DeveloperContentRecognizer()
        let shebang = recognizer.analyze("#!/usr/bin/env bash\nset -euo pipefail\necho ready")
        let prompt = recognizer.analyze("❯ swift test\nBuilding for debugging")
        let prose = recognizer.analyze("Run swift test before opening a pull request.")

        XCTAssertEqual(shebang.kind, .command)
        XCTAssertEqual(shebang.languageHint, "shell")
        XCTAssertTrue(shebang.signals.contains(.shebang))
        XCTAssertEqual(prompt.kind, .command)
        XCTAssertTrue(prompt.signals.contains(.shellPrompt))
        XCTAssertEqual(prose.kind, .plainText)
    }

    func testDeveloperTransformsAreLocalDeterministicAndBounded() throws {
        let pretty = try SafeTextTransformer.apply(
            .prettyJSON,
            to: #"{"z":1,"a":{"b":true}}"#
        )
        XCTAssertEqual(
            pretty,
            """
            {
              "a" : {
                "b" : true
              },
              "z" : 1
            }
            """
        )
        XCTAssertEqual(
            try SafeTextTransformer.apply(.stripANSI, to: "\u{001B}[31mfailed\u{001B}[0m ok"),
            "failed ok"
        )
        XCTAssertEqual(
            try SafeTextTransformer.apply(.stripANSI, to: "\u{001B}]0;title\u{0007}body"),
            "body"
        )
        XCTAssertEqual(
            try SafeTextTransformer.apply(.urlDecode, to: "hello%20world%2Fswift+value"),
            "hello world/swift+value"
        )
        XCTAssertThrowsError(try SafeTextTransformer.apply(.prettyJSON, to: "not json")) {
            XCTAssertEqual($0 as? SafeTextTransformError, .invalidJSON)
        }
        XCTAssertThrowsError(try SafeTextTransformer.apply(.urlDecode, to: "%ZZ")) {
            XCTAssertEqual($0 as? SafeTextTransformError, .invalidPercentEncoding)
        }

        let oversized = String(
            repeating: "x",
            count: SafeTextTransformer.maximumDeveloperTransformUTF8Bytes + 1
        )
        XCTAssertThrowsError(try SafeTextTransformer.apply(.stripANSI, to: oversized)) {
            XCTAssertEqual(
                $0 as? SafeTextTransformError,
                .developerTransformInputTooLarge(
                    actual: oversized.utf8.count,
                    maximum: SafeTextTransformer.maximumDeveloperTransformUTF8Bytes
                )
            )
        }
        let compactArray = "[" + String(repeating: "0,", count: 220_000) + "0]"
        XCTAssertLessThan(
            compactArray.utf8.count,
            SafeTextTransformer.maximumDeveloperTransformUTF8Bytes
        )
        XCTAssertThrowsError(try SafeTextTransformer.apply(.prettyJSON, to: compactArray)) {
            guard case .developerTransformOutputTooLarge = $0 as? SafeTextTransformError else {
                return XCTFail("Unexpected error: \($0)")
            }
        }
        XCTAssertEqual(try SafeTextTransformer.apply(.trim, to: oversized), oversized)
    }

    func testDebugBundleBuildsFromContextPackWithProblemStatementAndStableRendering() throws {
        let itemID = UUID(uuidString: "00000000-0000-0000-0000-000000000042")!
        let packID = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!
        let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let item = try ContextPackItem(
            id: itemID,
            title: "Server failure",
            textRepresentation: "2026-08-14T12:00:00Z ERROR request failed",
            capturedAt: capturedAt,
            sourceApplication: "Terminal"
        )
        let pack = try ContextPack(id: packID, name: "Incident", items: [item])
        let project = try DeveloperProjectContext(
            name: "Payments API",
            rootLabel: "payments-api",
            branch: "fix/timeout",
            language: "Swift",
            runtime: "Swift 6"
        )

        let bundle = try DebugBundleBuilder().build(
            project: project,
            from: pack,
            problemStatement: "Requests time out after reconnect.\nThe client never recovers.",
            generatedAt: capturedAt
        )
        let markdown = try DebugBundleRenderer().renderMarkdown(bundle)

        XCTAssertEqual(bundle.id, packID)
        XCTAssertEqual(bundle.sourceContextPackID, packID)
        XCTAssertEqual(bundle.items.map(\.id), [itemID])
        XCTAssertEqual(bundle.items.first?.analysis.kind, .log)
        XCTAssertTrue(markdown.contains("## Problem"))
        XCTAssertTrue(markdown.contains("""
        ```text
        Requests time out after reconnect.
        The client never recovers.
        ```
        """))
        XCTAssertTrue(markdown.contains("```text"))
        XCTAssertEqual(markdown, try DebugBundleRenderer().renderMarkdown(bundle))

        let encoded = try DebugBundleRenderer().renderJSON(bundle)
        let decoded = try JSONDecoder.iso8601.decode(DebugBundle.self, from: encoded)
        XCTAssertEqual(decoded, bundle)
    }

    func testDebugBundleLegacyDecodeDefaultsProblemStatementToNil() throws {
        let item = try ContextPackItem(id: UUID(), title: "Input", textRepresentation: "plain")
        let pack = try ContextPack(name: "Inputs", items: [item])
        let bundle = try DebugBundleBuilder().build(
            project: DeveloperProjectContext(name: "Project"),
            from: pack,
            generatedAt: Date(timeIntervalSince1970: 10)
        )
        let encoded = try DebugBundleRenderer().renderJSON(bundle)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "problemStatement")
        let legacy = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder.iso8601.decode(DebugBundle.self, from: legacy)

        XCTAssertNil(decoded.problemStatement)
    }

    func testDebugBundleRejectsUnsafeOrOversizedProblemStatement() throws {
        let item = try ContextPackItem(id: UUID(), title: "Input", textRepresentation: "plain")
        let pack = try ContextPack(name: "Inputs", items: [item])
        let project = try DeveloperProjectContext(name: "Project")

        XCTAssertThrowsError(
            try DebugBundleBuilder().build(
                project: project,
                from: pack,
                problemStatement: "line one\rline two"
            )
        ) {
            XCTAssertEqual($0 as? DebugBundleError, .invalidProblemStatement)
        }
        XCTAssertThrowsError(
            try DebugBundleBuilder().build(
                project: project,
                from: pack,
                problemStatement: "line one\0line two"
            )
        ) {
            XCTAssertEqual($0 as? DebugBundleError, .invalidProblemStatement)
        }
        XCTAssertThrowsError(
            try DebugBundleBuilder().build(
                project: project,
                from: pack,
                problemStatement: String(repeating: "x", count: 2_049)
            )
        ) {
            XCTAssertEqual($0 as? DebugBundleError, .invalidProblemStatement)
        }
    }

    func testDebugBundleMarkdownCannotBeRestructuredByReviewedMetadata() throws {
        let item = try ContextPackItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000042")!,
            title: "Failure\n## Forged item",
            textRepresentation: "plain",
            sourceApplication: "Terminal\n## Forged source",
            metadata: ["detail\n## Forged key": "<!--\n## Hidden section"]
        )
        let pack = try ContextPack(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000099")!,
            name: "Incident\n# Forged collection",
            items: [item]
        )
        let bundle = try DebugBundleBuilder().build(
            project: DeveloperProjectContext(name: "Payments #1"),
            from: pack,
            problemStatement: "Observed failure\n## This remains problem text",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let markdown = try DebugBundleRenderer().renderMarkdown(bundle)

        XCTAssertEqual(
            markdown,
            """
            # Debug Bundle: Payments \\#1

            - Generated: `2023-11-14T22:13:20.000Z`
            - Source collection: Incident \\# Forged collection
            - Items: 1

            ## Problem

            ```text
            Observed failure
            ## This remains problem text
            ```

            ## 1. Failure \\#\\# Forged item

            - Recognition: `plainText` (70%)
            - Source application: Terminal \\#\\# Forged source
            - detail \\#\\# Forged key: \\<\\!\\-\\- \\#\\# Hidden section

            ```text
            plain
            ```
            """ + "\n"
        )
        let encoded = try DebugBundleRenderer().renderJSON(bundle)
        XCTAssertEqual(try JSONDecoder.iso8601.decode(DebugBundle.self, from: encoded), bundle)
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
