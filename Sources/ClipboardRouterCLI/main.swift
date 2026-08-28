import ClipboardRouterCore
import ClipboardRouterSecurity
import Darwin
import Foundation

enum CLIOutputFormat: String, Equatable {
    case text
    case json
    case markdown
}

enum CLICommand: Equatable {
    case help
    case version
    case analyze(format: CLIOutputFormat, inputPath: String?)
    case transform(transform: SafeTextTransform, inputPath: String?)
    case bundle(
        project: String,
        rootLabel: String?,
        branch: String?,
        language: String?,
        runtime: String?,
        problem: String?,
        format: CLIOutputFormat,
        inputPaths: [String]
    )
}

enum CLIArgumentParser {
    static func parse(_ arguments: [String]) throws -> CLICommand {
        guard let command = arguments.first else { throw CLIError.usage(Self.usage) }
        switch command {
        case "analyze":
            return try parseAnalyze(Array(arguments.dropFirst()))
        case "transform":
            return try parseTransform(Array(arguments.dropFirst()))
        case "bundle":
            return try parseBundle(Array(arguments.dropFirst()))
        case "help", "--help", "-h":
            return .help
        case "--version", "version":
            return .version
        default:
            throw CLIError.usage("Unknown command.\n\n\(Self.usage)")
        }
    }

    static let usage = """
    Usage:
      cr analyze [--format text|json] [FILE|-]
      cr transform <pretty-json|strip-ansi|url-decode> [FILE|-]
      cr bundle --project NAME [--problem TEXT] [--root-label LABEL]
                [--branch BRANCH] [--language LANGUAGE] [--runtime RUNTIME]
                [--format markdown|json] [FILE|- ...]

    Input defaults to stdin. All processing is local; cr does not access the Clipboard Router
    database, pasteboard, Vault, sync, network, or other processes.
    """

    private static func parseAnalyze(_ arguments: [String]) throws -> CLICommand {
        var format = CLIOutputFormat.json
        var paths: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--format" {
                let value = try optionValue(arguments, index: &index, option: argument)
                guard let parsed = CLIOutputFormat(rawValue: value), parsed == .text || parsed == .json
                else { throw CLIError.invalidOption("--format", value) }
                format = parsed
            } else if argument.hasPrefix("--") {
                throw CLIError.unknownOption(argument)
            } else {
                paths.append(argument)
            }
            index += 1
        }
        guard paths.count <= 1 else { throw CLIError.tooManyInputs }
        return .analyze(format: format, inputPath: paths.first)
    }

    private static func parseTransform(_ arguments: [String]) throws -> CLICommand {
        guard let name = arguments.first else { throw CLIError.missingTransform }
        let transform: SafeTextTransform
        switch name {
        case "pretty-json": transform = .prettyJSON
        case "strip-ansi": transform = .stripANSI
        case "url-decode": transform = .urlDecode
        default: throw CLIError.invalidTransform(name)
        }
        let paths = Array(arguments.dropFirst())
        guard !paths.contains(where: { $0.hasPrefix("--") }) else {
            throw CLIError.unknownOption(paths.first(where: { $0.hasPrefix("--") })!)
        }
        guard paths.count <= 1 else { throw CLIError.tooManyInputs }
        return .transform(transform: transform, inputPath: paths.first)
    }

    private static func parseBundle(_ arguments: [String]) throws -> CLICommand {
        var project: String?
        var rootLabel: String?
        var branch: String?
        var language: String?
        var runtime: String?
        var problem: String?
        var format = CLIOutputFormat.markdown
        var paths: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--project":
                project = try optionValue(arguments, index: &index, option: argument)
            case "--root-label":
                rootLabel = try optionValue(arguments, index: &index, option: argument)
            case "--branch":
                branch = try optionValue(arguments, index: &index, option: argument)
            case "--language":
                language = try optionValue(arguments, index: &index, option: argument)
            case "--runtime":
                runtime = try optionValue(arguments, index: &index, option: argument)
            case "--problem":
                problem = try optionValue(arguments, index: &index, option: argument)
            case "--format":
                let value = try optionValue(arguments, index: &index, option: argument)
                guard let parsed = CLIOutputFormat(rawValue: value), parsed == .markdown || parsed == .json
                else { throw CLIError.invalidOption("--format", value) }
                format = parsed
            default:
                if argument.hasPrefix("--") { throw CLIError.unknownOption(argument) }
                paths.append(argument)
            }
            index += 1
        }
        guard let project else { throw CLIError.missingProject }
        guard paths.filter({ $0 == "-" }).count <= 1 else {
            throw CLIError.duplicateStandardInput
        }
        return .bundle(
            project: project,
            rootLabel: rootLabel,
            branch: branch,
            language: language,
            runtime: runtime,
            problem: problem,
            format: format,
            inputPaths: paths
        )
    }

    private static func optionValue(
        _ arguments: [String],
        index: inout Int,
        option: String
    ) throws -> String {
        let valueIndex = index + 1
        guard valueIndex < arguments.count else { throw CLIError.missingOptionValue(option) }
        index = valueIndex
        return arguments[valueIndex]
    }
}

struct CLIApplication {
    typealias InputReader = (_ path: String?) throws -> String

    private let secretDetector: SecretDetector

    init(secretDetector: SecretDetector = SecretDetector()) {
        self.secretDetector = secretDetector
    }

    func run(arguments: [String], readInput: InputReader) throws -> String {
        try requireNoSensitiveContent(arguments)
        switch try CLIArgumentParser.parse(arguments) {
        case .help:
            return CLIArgumentParser.usage + "\n"
        case .version:
            return CLIReleaseInfo.displayVersion() + "\n"

        case let .analyze(format, inputPath):
            let input = try validatedInput(readInput(inputPath))
            try requireNoSensitiveContent([input])
            let analysis = DeveloperContentRecognizer().analyze(input)
            let output: String
            switch format {
            case .json:
                output = try jsonString(analysis)
            case .text:
                var lines = [
                    "kind: \(analysis.kind.rawValue)",
                    "confidence: \(analysis.confidence)",
                    "lines: \(analysis.analyzedLineCount)",
                    "truncated: \(analysis.inputWasTruncated)",
                ]
                if let language = analysis.languageHint { lines.append("language: \(language)") }
                if !analysis.signals.isEmpty {
                    lines.append("signals: \(analysis.signals.map(\.rawValue).joined(separator: ","))")
                }
                output = lines.joined(separator: "\n") + "\n"
            case .markdown:
                throw CLIError.invalidOption("--format", format.rawValue)
            }
            try requireNoSensitiveContent([output])
            return output

        case let .transform(transform, inputPath):
            let input = try validatedInput(readInput(inputPath))
            try requireNoSensitiveContent([input])
            let output = try SafeTextTransformer.apply(transform, to: input)
            try requireNoSensitiveContent([output])
            return output

        case let .bundle(
            project,
            rootLabel,
            branch,
            language,
            runtime,
            problem,
            format,
            inputPaths
        ):
            let inputs: [(title: String, text: String)]
            if inputPaths.isEmpty {
                inputs = [("stdin", try validatedInput(readInput(nil)))]
            } else {
                inputs = try inputPaths.map { path in
                    let title = path == "-" ? "stdin" : URL(fileURLWithPath: path).lastPathComponent
                    return (title, try validatedInput(readInput(path == "-" ? nil : path)))
                }
            }
            try requireNoSensitiveContent(
                inputs.map(\.text) + [project, rootLabel, branch, language, runtime, problem].compactMap { $0 }
            )
            var pack = try ContextPack(name: "Debug Bundle Inputs")
            for input in inputs {
                try pack.append(
                    ContextPackItem(
                        id: UUID(),
                        title: input.title,
                        textRepresentation: input.text
                    )
                )
            }
            let context = try DeveloperProjectContext(
                name: project,
                rootLabel: rootLabel,
                branch: branch,
                language: language,
                runtime: runtime
            )
            let bundle = try DebugBundleBuilder().build(
                project: context,
                from: pack,
                problemStatement: problem
            )
            let renderer = DebugBundleRenderer()
            let output: String
            switch format {
            case .markdown:
                output = try renderer.renderMarkdown(bundle)
            case .json:
                guard let value = String(data: try renderer.renderJSON(bundle), encoding: .utf8) else {
                    throw CLIError.invalidUTF8
                }
                output = value + "\n"
            case .text:
                throw CLIError.invalidOption("--format", format.rawValue)
            }
            try requireNoSensitiveContent([output])
            return output
        }
    }

    private func validatedInput(_ value: String) throws -> String {
        let count = value.utf8.count
        guard count <= BoundedCLIInput.maximumUTF8Bytes else {
            throw CLIError.inputTooLarge(actual: count, maximum: BoundedCLIInput.maximumUTF8Bytes)
        }
        return value
    }

    private func jsonString<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard let result = String(data: data, encoding: .utf8) else { throw CLIError.invalidUTF8 }
        return result + "\n"
    }

    private func requireNoSensitiveContent(_ values: [String]) throws {
        guard values.allSatisfy({ !secretDetector.scan(text: $0).containsSecret }) else {
            throw CLIError.sensitiveContentBlocked
        }
    }
}

private enum CLIReleaseInfo {
    static func displayVersion() -> String {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let file = executable
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/cr.version")
        guard let data = try? Data(contentsOf: file), data.count <= 128,
              let raw = String(data: data, encoding: .utf8)
        else { return "cr development" }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(
            of: #"^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.-]+)? \([1-9][0-9]*\)$"#,
            options: .regularExpression
        ) != nil else { return "cr development" }
        return "cr \(value)"
    }
}

enum BoundedCLIInput {
    static let maximumUTF8Bytes = ContextPackLimits.default.maximumItemUTF8Bytes

    static func read(path: String?) throws -> String {
        let maximumRead = maximumUTF8Bytes + 1
        let data: Data
        if let path, path != "-" {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            let handle: FileHandle
            do {
                handle = try FileHandle(forReadingFrom: url)
            } catch {
                throw CLIError.cannotRead(path, error.localizedDescription)
            }
            defer { try? handle.close() }
            do {
                data = try handle.read(upToCount: maximumRead) ?? Data()
            } catch {
                throw CLIError.cannotRead(path, error.localizedDescription)
            }
        } else {
            data = try FileHandle.standardInput.read(upToCount: maximumRead) ?? Data()
        }
        guard data.count <= maximumUTF8Bytes else {
            throw CLIError.inputTooLarge(actual: data.count, maximum: maximumUTF8Bytes)
        }
        guard let value = String(data: data, encoding: .utf8) else { throw CLIError.invalidUTF8 }
        return value
    }
}

enum CLIError: Error, Equatable, LocalizedError {
    case usage(String)
    case unknownOption(String)
    case invalidOption(String, String)
    case missingOptionValue(String)
    case missingTransform
    case invalidTransform(String)
    case missingProject
    case tooManyInputs
    case duplicateStandardInput
    case inputTooLarge(actual: Int, maximum: Int)
    case invalidUTF8
    case cannotRead(String, String)
    case sensitiveContentBlocked

    var errorDescription: String? {
        switch self {
        case let .usage(message): message
        case .unknownOption: "Unknown option."
        case .invalidOption: "An option has an invalid value."
        case .missingOptionValue: "An option is missing its value."
        case .missingTransform: "Choose pretty-json, strip-ansi, or url-decode."
        case .invalidTransform: "Unknown transform."
        case .missingProject: "bundle requires --project NAME."
        case .tooManyInputs: "This command accepts at most one input file."
        case .duplicateStandardInput: "Standard input can be used only once."
        case let .inputTooLarge(actual, maximum):
            "Input is \(actual) bytes; the limit is \(maximum) bytes."
        case .invalidUTF8: "Input must be valid UTF-8 text."
        case .cannotRead: "Cannot read the requested input."
        case .sensitiveContentBlocked:
            "Sensitive content was detected. No output was produced."
        }
    }
}

@main
enum CRMain {
    static func main() {
        do {
            let output = try CLIApplication().run(
                arguments: Array(CommandLine.arguments.dropFirst()),
                readInput: BoundedCLIInput.read(path:)
            )
            FileHandle.standardOutput.write(Data(output.utf8))
        } catch let error as CLIError {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            switch error {
            case .sensitiveContentBlocked:
                exit(5)
            case .usage, .unknownOption, .invalidOption, .missingOptionValue,
                 .missingTransform, .invalidTransform, .missingProject, .tooManyInputs,
                 .duplicateStandardInput:
                exit(2)
            default:
                exit(1)
            }
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
