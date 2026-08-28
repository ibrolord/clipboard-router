import ClipboardRouterCore
import Foundation
import XCTest
@testable import ClipboardRouterCLI

final class ClipboardRouterCLITests: XCTestCase {
    func testArgumentParserKeepsCLIWithinExplicitLocalInputs() throws {
        XCTAssertEqual(try CLIArgumentParser.parse(["--help"]), .help)
        XCTAssertEqual(
            try CLIArgumentParser.parse(["analyze", "--format", "text", "input.log"]),
            .analyze(format: .text, inputPath: "input.log")
        )
        XCTAssertEqual(
            try CLIArgumentParser.parse(["transform", "strip-ansi"]),
            .transform(transform: .stripANSI, inputPath: nil)
        )

        guard case let .bundle(project, root, branch, language, runtime, problem, format, paths) =
            try CLIArgumentParser.parse([
                "bundle", "--project", "Router", "--problem", "Build fails",
                "--branch", "main", "--format", "json", "one.log", "two.swift",
            ])
        else { return XCTFail("Expected bundle command") }
        XCTAssertEqual(project, "Router")
        XCTAssertNil(root)
        XCTAssertEqual(branch, "main")
        XCTAssertNil(language)
        XCTAssertNil(runtime)
        XCTAssertEqual(problem, "Build fails")
        XCTAssertEqual(format, .json)
        XCTAssertEqual(paths, ["one.log", "two.swift"])
    }

    func testHelpReturnsUsageWithoutReadingInput() throws {
        var didReadInput = false
        let output = try CLIApplication().run(arguments: ["--help"], readInput: { _ in
            didReadInput = true
            return "unused"
        })

        XCTAssertFalse(didReadInput)
        XCTAssertEqual(output, CLIArgumentParser.usage + "\n")
    }

    func testAnalyzeAndTransformUseInjectedInputOnly() throws {
        var requestedPaths: [String?] = []
        let analyze = try CLIApplication().run(
            arguments: ["analyze", "--format", "json", "failure.log"],
            readInput: { path in
                requestedPaths.append(path)
                return "2026-08-14T12:00:00Z ERROR request failed"
            }
        )
        let analysis = try JSONDecoder().decode(
            DeveloperContentAnalysis.self,
            from: Data(analyze.utf8)
        )
        XCTAssertEqual(analysis.kind, .log)
        XCTAssertEqual(requestedPaths.compactMap { $0 }, ["failure.log"])

        let transformed = try CLIApplication().run(
            arguments: ["transform", "url-decode"],
            readInput: { path in
                XCTAssertNil(path)
                return "https%3A%2F%2Fexample.com%2Fa%20b"
            }
        )
        XCTAssertEqual(transformed, "https://example.com/a b")
    }

    func testExplicitStandardInputSentinelIsForwardedForAnalyze() throws {
        var receivedPath: String?
        let output = try CLIApplication().run(
            arguments: ["analyze", "--format", "text", "-"],
            readInput: { path in
                receivedPath = path
                return "fatal error: connection refused"
            }
        )

        XCTAssertEqual(receivedPath, "-")
        XCTAssertTrue(output.contains("kind: error"))
    }

    func testBundleRejectsDuplicateStandardInputSentinels() throws {
        XCTAssertThrowsError(
            try CLIApplication().run(
                arguments: ["bundle", "--project", "Example", "-", "-"],
                readInput: { _ in "ordinary input" }
            )
        ) { error in
            XCTAssertEqual(error as? CLIError, .duplicateStandardInput)
        }
    }

    func testBundleBuildsReviewedLocalValueFromExplicitFiles() throws {
        let contents = [
            "one.log": "2026-08-14T12:00:00Z INFO started",
            "two.swift": "import Foundation\nfunc run() {}",
        ]
        let output = try CLIApplication().run(
            arguments: [
                "bundle", "--project", "Router", "--problem", "Startup fails",
                "--language", "Swift", "--format", "json", "one.log", "two.swift",
            ],
            readInput: { path in
                guard let path, let value = contents[path] else {
                    throw CLIError.cannotRead(path ?? "stdin", "unexpected input")
                }
                return value
            }
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let bundle = try decoder.decode(DebugBundle.self, from: Data(output.utf8))

        XCTAssertEqual(bundle.project.name, "Router")
        XCTAssertEqual(bundle.problemStatement, "Startup fails")
        XCTAssertEqual(bundle.items.map(\.source.title), ["one.log", "two.swift"])
        XCTAssertEqual(bundle.items.map(\.analysis.kind), [.log, .sourceCode])
    }

    func testCLIRejectsMissingProjectUnknownOptionsAndOversizedInput() throws {
        XCTAssertThrowsError(
            try CLIApplication().run(arguments: ["bundle"], readInput: { _ in "input" })
        ) {
            XCTAssertEqual($0 as? CLIError, .missingProject)
        }
        XCTAssertThrowsError(
            try CLIApplication().run(
                arguments: ["analyze", "--network"],
                readInput: { _ in "input" }
            )
        ) {
            XCTAssertEqual($0 as? CLIError, .unknownOption("--network"))
        }
        let oversized = String(repeating: "x", count: BoundedCLIInput.maximumUTF8Bytes + 1)
        XCTAssertThrowsError(
            try CLIApplication().run(arguments: ["analyze"], readInput: { _ in oversized })
        ) {
            XCTAssertEqual(
                $0 as? CLIError,
                .inputTooLarge(
                    actual: oversized.utf8.count,
                    maximum: BoundedCLIInput.maximumUTF8Bytes
                )
            )
        }
    }

    func testCLIBlocksSensitiveInputWithSanitizedDedicatedError() {
        let secret = "sk-proj-abcdefghijklmnopqrstuvwxyz012345"

        XCTAssertThrowsError(
            try CLIApplication().run(
                arguments: ["bundle", "--project", "Router"],
                readInput: { _ in secret }
            )
        ) { error in
            XCTAssertEqual(error as? CLIError, .sensitiveContentBlocked)
            XCTAssertEqual(
                error.localizedDescription,
                "Sensitive content was detected. No output was produced."
            )
            XCTAssertFalse(error.localizedDescription.contains("sk-proj"))
            XCTAssertFalse(error.localizedDescription.lowercased().contains("api"))
        }
    }

    func testCLIBlocksSensitiveArgumentsBeforeParserErrorsCanEchoThem() {
        let secret = "sk-proj-abcdefghijklmnopqrstuvwxyz012345"

        XCTAssertThrowsError(
            try CLIApplication().run(
                arguments: ["transform", secret],
                readInput: { _ in "ordinary input" }
            )
        ) { error in
            XCTAssertEqual(error as? CLIError, .sensitiveContentBlocked)
            XCTAssertFalse(error.localizedDescription.contains(secret))
        }
    }
}
