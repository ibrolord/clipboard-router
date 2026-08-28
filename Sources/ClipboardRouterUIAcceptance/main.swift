import AppKit
import ApplicationServices
import CoreGraphics
import CryptoKit
import Foundation

private enum AcceptanceExit: Int32 {
    case success = 0
    case incomplete = 2
    case failure = 1
    case permissionUnavailable = 77
    /// A `--diagnostic-mode` probe completed without throwing. This is a bounded, single-probe
    /// AppKit/AX diagnostic run, not a full acceptance pass: zero of the real acceptance cases
    /// (menu, library, persistence-across-relaunch, etc.) executed. It must never share exit 0
    /// with `.success`, so a script that only checks for a zero exit code (rather than reading
    /// the printed label) cannot mistake a diagnostic probe for a green acceptance run.
    case diagnosticOnly = 78
}

private struct AcceptanceFailure: Error, CustomStringConvertible {
    let description: String
    let isEnvironmental: Bool

    init(description: String, isEnvironmental: Bool = false) {
        self.description = description
        self.isEnvironmental = isEnvironmental
    }
}

/// A single, testable gate for "is this AcceptanceFailure allowed to be reported as a
/// non-failing boundary case instead of a hard failure?" `runInventoryBoundary` and
/// `recordRelaunchBoundary` both delegate to this so the rule lives in exactly one place.
///
/// The only failures ever constructed with `isEnvironmental: true` are genuine external/OS-level
/// conditions the runner cannot control (Accessibility permission revoked or unavailable mid-run).
/// Every other AcceptanceFailure — a timed-out UI assertion, a missing element, a wrong persisted
/// value, a crash — describes something the product or the automation got wrong, and must fail
/// the run loudly rather than being silently downgraded to `boundaryCases`/`incomplete`.
private enum AcceptanceBoundaryPolicy {
    static func isDeclaredBoundary(_ name: String) -> Bool {
        ExternalAcceptanceBoundary.cases.contains(name)
            || NonMutatingPackagedBoundary.cases.contains(name)
    }

    static func permitsBoundary(_ failure: AcceptanceFailure, named name: String) -> Bool {
        // Environmental failures must propagate as exit 77 so the wrapper can distinguish a
        // locked/revoked session from a product failure. Only explicitly declared external or
        // non-mutating cases may be recorded as a non-failing boundary.
        !failure.isEnvironmental && isDeclaredBoundary(name)
    }
}

/// A locked screen, a fast-user-switched-away session, or a loginwindow/non-console context
/// (e.g. an SSH shell with no attached window server session) cannot present a MenuBarExtra:
/// AX presses on the status item either never land or land in the wrong session. Detect that
/// up front so it is classified as an environmental skip (exit 77), matching the existing
/// Accessibility-permission skip, rather than surfacing as a product failure once AX waits
/// time out deep inside the run.
private enum SessionAvailability: Equatable {
    case available
    case noConsoleSession
    case sessionNotOnConsole
    case screenLocked

    var reason: String {
        switch self {
        case .available:
            return ""
        case .noConsoleSession:
            return "No active console (window server) session is available for cr-ui-acceptance. "
                + "This looks like loginwindow or a non-interactive context (for example, an SSH "
                + "session). MenuBarExtra presentation requires an unlocked interactive session."
        case .sessionNotOnConsole:
            return "The current session is not the active console session (for example, after a "
                + "fast user switch). MenuBarExtra presentation requires an unlocked interactive "
                + "session."
        case .screenLocked:
            return "The screen is locked. MenuBarExtra presentation requires an unlocked "
                + "interactive session."
        }
    }

    static func classify(sessionDictionary: [String: Any]?) -> SessionAvailability {
        guard let sessionDictionary else { return .noConsoleSession }
        guard sessionDictionary[kCGSessionOnConsoleKey as String] as? Bool == true else {
            return .sessionNotOnConsole
        }
        guard sessionDictionary["CGSSessionScreenIsLocked"] as? Bool != true else {
            return .screenLocked
        }
        return .available
    }

    static func current() -> SessionAvailability {
        classify(sessionDictionary: CGSessionCopyCurrentDictionary() as? [String: Any])
    }
}

@main
private enum ClipboardRouterUIAcceptance {
    static func main() {
        do {
            if CommandLine.arguments.contains("--self-test-parser") {
                try RunnerArguments.runSelfTests()
                // Deliberately not "PASS": this only exercises pure parsing/classification logic
                // in-process. It runs zero UI acceptance cases against a packaged app and must
                // never be mistaken for (or grepped as) a full acceptance pass.
                print("SELF-TEST OK — NOT ACCEPTANCE (runner unit self-tests only, no app launched)")
                Foundation.exit(AcceptanceExit.success.rawValue)
            }
            let sessionAvailability = SessionAvailability.current()
            guard sessionAvailability == .available else {
                skip(sessionAvailability.reason)
            }
            guard AXIsProcessTrusted() else {
                skip("Accessibility permission is unavailable for cr-ui-acceptance. No prompt was requested.")
            }

            if CommandLine.arguments.contains("--preflight") {
                // Deliberately not "PASS": this only confirms the console session and
                // Accessibility permission are available before a real run. No acceptance
                // cases execute here.
                print("PREFLIGHT OK — NOT ACCEPTANCE (environment check only, no app launched)")
                Foundation.exit(AcceptanceExit.success.rawValue)
            }

            let arguments = try RunnerArguments.parse(CommandLine.arguments)
            let runner = AcceptanceRunner(arguments: arguments)
            let result = try runner.run()
            switch result {
            case .success:
                print("PASS packaged-ui-acceptance")
            case .incomplete:
                FileHandle.standardError.write(
                    Data("INCOMPLETE packaged-ui-acceptance; see report.json boundaryCases\n".utf8)
                )
            default:
                break
            }
            Foundation.exit(result.rawValue)
        } catch let failure as AcceptanceFailure {
            let prefix = failure.isEnvironmental ? "SKIP" : "FAIL"
            FileHandle.standardError.write(Data("\(prefix) \(failure)\n".utf8))
            Foundation.exit(
                failure.isEnvironmental
                    ? AcceptanceExit.permissionUnavailable.rawValue
                    : AcceptanceExit.failure.rawValue
            )
        } catch {
            FileHandle.standardError.write(Data("FAIL \(error)\n".utf8))
            Foundation.exit(AcceptanceExit.failure.rawValue)
        }
    }

    private static func skip(_ reason: String) -> Never {
        FileHandle.standardError.write(Data("SKIP \(reason)\n".utf8))
        Foundation.exit(AcceptanceExit.permissionUnavailable.rawValue)
    }
}

private struct RunnerArguments {
    let applicationURL: URL
    let runID: String
    let evidenceDirectory: URL
    let diagnosticMode: AcceptanceDiagnosticMode?

    static func parse(_ arguments: [String]) throws -> Self {
        guard let appIndex = arguments.firstIndex(of: "--app"),
              arguments.indices.contains(appIndex + 1)
        else { throw AcceptanceFailure(description: "usage: cr-ui-acceptance --app PATH [--run-id ID]") }
        let applicationURL = URL(fileURLWithPath: arguments[appIndex + 1]).standardizedFileURL
        guard applicationURL.pathExtension == "app" else {
            throw AcceptanceFailure(description: "--app must name a .app bundle")
        }
        let runID: String
        if let runIndex = arguments.firstIndex(of: "--run-id") {
            guard arguments.indices.contains(runIndex + 1) else {
                throw AcceptanceFailure(description: "--run-id requires a value")
            }
            runID = arguments[runIndex + 1]
        } else {
            runID = UUID().uuidString.lowercased()
        }
        guard (1...64).contains(runID.utf8.count),
              runID.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        else { throw AcceptanceFailure(description: "--run-id contains unsafe characters") }
        let evidenceDirectory: URL
        if let evidenceIndex = arguments.firstIndex(of: "--evidence-directory") {
            guard arguments.indices.contains(evidenceIndex + 1) else {
                throw AcceptanceFailure(description: "--evidence-directory requires a value")
            }
            evidenceDirectory = URL(fileURLWithPath: arguments[evidenceIndex + 1], isDirectory: true)
                .standardizedFileURL
        } else {
            evidenceDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("ClipboardRouterUIAcceptanceEvidence", isDirectory: true)
                .appendingPathComponent(runID, isDirectory: true)
        }
        let diagnosticMode: AcceptanceDiagnosticMode?
        if let diagnosticIndex = arguments.firstIndex(of: "--diagnostic-mode") {
            guard arguments.indices.contains(diagnosticIndex + 1) else {
                throw AcceptanceFailure(description: "--diagnostic-mode requires a value")
            }
            guard let parsed = AcceptanceDiagnosticMode(rawValue: arguments[diagnosticIndex + 1]) else {
                throw AcceptanceFailure(
                    description: "--diagnostic-mode must be one of: \(AcceptanceDiagnosticMode.allCases.map(\.rawValue).joined(separator: ", "))"
                )
            }
            diagnosticMode = parsed
        } else {
            diagnosticMode = nil
        }
        return Self(
            applicationURL: applicationURL,
            runID: runID,
            evidenceDirectory: evidenceDirectory,
            diagnosticMode: diagnosticMode
        )
    }

    static func runSelfTests() throws {
        let executable = "cr-ui-acceptance"
        _ = try parse([
            executable,
            "--app", "/tmp/ClipboardRouter.app",
            "--run-id", "run-1",
            "--evidence-directory", "/tmp/evidence",
            "--diagnostic-mode", AcceptanceDiagnosticMode.menuOpenOnly.rawValue,
        ])
        for malformed in [
            [executable, "--app", "/tmp/ClipboardRouter.app", "--run-id"],
            [executable, "--app", "/tmp/ClipboardRouter.app", "--evidence-directory"],
            [executable, "--app", "/tmp/ClipboardRouter.app", "--diagnostic-mode"],
        ] {
            do {
                _ = try parse(malformed)
                throw AcceptanceFailure(description: "parser accepted a missing explicit option value")
            } catch let failure as AcceptanceFailure {
                guard failure.description.contains("requires a value") else { throw failure }
            }
        }

        let ordinaryApplicationMenu = StatusItemCandidate(
            role: kAXMenuBarItemRole as String,
            subrole: nil,
            title: "Clipboard Router",
            label: nil,
            value: nil,
            actions: [kAXPressAction as String]
        )
        let actualStatusExtra = StatusItemCandidate(
            role: kAXMenuBarItemRole as String,
            subrole: "AXMenuExtra",
            title: nil,
            label: "Clipboard Router, paused",
            value: nil,
            actions: [kAXPressAction as String]
        )
        guard !ordinaryApplicationMenu.isClipboardRouterStatusItem,
              actualStatusExtra.isClipboardRouterStatusItem
        else {
            throw AcceptanceFailure(description: "status-item selector confused the app menu with AXMenuExtra")
        }

        let notesLabel = LibraryFilterCandidate(
            role: kAXStaticTextRole as String,
            title: "Notes",
            label: nil,
            value: "2"
        )
        let notesFilter = LibraryFilterCandidate(
            role: kAXRadioButtonRole as String,
            title: "Notes",
            label: nil,
            value: "1"
        )
        guard !notesLabel.matches(title: "Notes"),
              notesFilter.matches(title: "Notes")
        else {
            throw AcceptanceFailure(description: "Library filter selector confused a label with a radio button")
        }

        guard AppConsolePolicy.forbiddenDiagnostic(
            in: "WARNING: Application performed a reentrant operation in its NSTableView delegate."
        ) != nil else {
            throw AcceptanceFailure(description: "console policy missed the NSTableView reentrancy diagnostic")
        }
        guard AppConsolePolicy.forbiddenDiagnostic(in: "Clipboard Router started") == nil else {
            throw AcceptanceFailure(description: "console policy rejected benign packaged-app output")
        }
        guard AcceptanceStartupReadiness.markerCount(
            in: Data("before\nUI_ACCEPTANCE_READY\nafter\n".utf8)
        ) == 1,
        AcceptanceStartupReadiness.markerCount(
            in: Data("UI_ACCEPTANCE_READY_TOO_EARLY\nnot UI_ACCEPTANCE_READY\n".utf8)
        ) == 0
        else {
            throw AcceptanceFailure(description: "startup-readiness parser accepted a non-exact marker")
        }
        guard SessionAvailability.classify(sessionDictionary: nil) == .noConsoleSession,
              SessionAvailability.classify(
                sessionDictionary: [kCGSessionOnConsoleKey as String: false]
              ) == .sessionNotOnConsole,
              SessionAvailability.classify(
                sessionDictionary: [:]
              ) == .sessionNotOnConsole,
              SessionAvailability.classify(sessionDictionary: [
                kCGSessionOnConsoleKey as String: true,
                "CGSSessionScreenIsLocked": true,
              ]) == .screenLocked,
              SessionAvailability.classify(sessionDictionary: [
                kCGSessionOnConsoleKey as String: true,
                "CGSSessionScreenIsLocked": false,
              ]) == .available,
              SessionAvailability.classify(sessionDictionary: [
                kCGSessionOnConsoleKey as String: true,
              ]) == .available
        else {
            throw AcceptanceFailure(description: "session availability classifier misclassified a synthetic session dictionary")
        }
        guard !ExternalAcceptanceBoundary.cases.isEmpty,
              Set(ExternalAcceptanceBoundary.cases).count == ExternalAcceptanceBoundary.cases.count
        else {
            throw AcceptanceFailure(description: "external acceptance boundaries are missing or duplicated")
        }
        guard !AcceptanceBoundaryPolicy.permitsBoundary(
            AcceptanceFailure(description: "Accessibility permission was revoked during the run", isEnvironmental: true),
            named: "hosted-ai-send-requires-provider-credential-and-network"
        ),
        !AcceptanceBoundaryPolicy.permitsBoundary(
            AcceptanceFailure(description: "Library did not reopen after controlled relaunch"),
            named: "sales-workspace-and-handoff"
        ),
        !AcceptanceBoundaryPolicy.permitsBoundary(
            AcceptanceFailure(description: "packaged app emitted forbidden AppKit diagnostic: reentrant operation"),
            named: "debug-bundle-save-and-project-review"
        ),
        !AcceptanceBoundaryPolicy.permitsBoundary(
            AcceptanceFailure(description: "sales workspace did not survive process relaunch"),
            named: "sales-workspace-and-handoff"
        ),
        AcceptanceBoundaryPolicy.permitsBoundary(
            AcceptanceFailure(description: "external provider unavailable"),
            named: "hosted-ai-send-requires-provider-credential-and-network"
        )
        else {
            throw AcceptanceFailure(
                description: "AcceptanceBoundaryPolicy let a product-caused failure be downgraded to a boundary, "
                    + "or rejected a genuine environmental failure"
            )
        }
        guard !NonMutatingPackagedBoundary.cases.isEmpty,
              Set(NonMutatingPackagedBoundary.cases).count
                == NonMutatingPackagedBoundary.cases.count
        else {
            throw AcceptanceFailure(description: "non-mutating packaged boundaries are missing or duplicated")
        }

        // Regression guard for the ten packaged-workflow failures that actually happened during
        // local acceptance runs (schema-v3 inventory boundaries plus their controlled-relaunch
        // follow-ups). None of these are external or non-mutating-presentation cases, so none may
        // ever be added to ExternalAcceptanceBoundary or NonMutatingPackagedBoundary — doing so
        // would let a real product regression be silently swallowed as a non-failing boundary
        // instead of failing the run. If this guard ever fires, someone declared one of these
        // names as a boundary; revert that change rather than adjusting this list.
        let historicalLocalWorkflowFailureNames = [
            "custom-flow-follow-up-note",
            "custom-flow-follow-up-relaunch",
            "custom-flow-definition-relaunch",
            "automatic-organization",
            "automatic-organization-relaunch",
            "sales-workspace-and-handoff",
            "sales-workspace-relaunch",
            "three-row-bulk-actions",
            "debug-bundle-save-and-project-review",
            "debug-bundle-relaunch",
        ]
        guard historicalLocalWorkflowFailureNames.count == 10,
              Set(historicalLocalWorkflowFailureNames).count == 10,
              historicalLocalWorkflowFailureNames.allSatisfy({ !AcceptanceBoundaryPolicy.isDeclaredBoundary($0) })
        else {
            throw AcceptanceFailure(
                description: "a historical local workflow failure name is missing, duplicated, or has been "
                    + "declared as an acceptance boundary: \(historicalLocalWorkflowFailureNames)"
            )
        }

        let markdown = """
        # Acceptance Account

        Exported: 2026-08-15T12:00:00Z
        Items: 1
        Omitted: 0

        ## Acceptance Account

        ### Acceptance Editable Note

        Body

        - Tags: acceptance, sales-ready
        """
        let markdownSummary = try HandoffEvidenceParser.parseMarkdown(markdown)
        guard markdownSummary.rootTitle == "Acceptance Account",
              markdownSummary.itemCount == 1,
              markdownSummary.omittedCount == 0,
              markdownSummary.recordTitles == ["Acceptance Editable Note"]
        else {
            throw AcceptanceFailure(description: "Markdown handoff parser lost its exact summary")
        }

        let csv = """
        schema_version,item_id,kind,title,body,folder_path,tags\r
        1,00000000-0000-0000-0000-000000009001,note,"Acceptance, \"\"Editable\"\" Note","line 1
        line 2",Acceptance Account,acceptance|sales-ready\r
        """
        let csvRecords = try HandoffEvidenceParser.parseCSV(csv)
        guard csvRecords.count == 1,
              csvRecords[0]["title"] == "Acceptance, \"Editable\" Note",
              csvRecords[0]["body"] == "line 1\nline 2",
              csvRecords[0]["folder_path"] == "Acceptance Account"
        else {
            throw AcceptanceFailure(
                description: "CSV handoff parser mishandled quoting or CRLF: \(csvRecords)"
            )
        }

        let json = Data("""
        {"schemaVersion":1,"rootFolderPath":"Acceptance Account","records":[{"title":"Acceptance Editable Note","folderPath":"Acceptance Account","tags":["acceptance","sales-ready"]}],"omissions":[]}
        """.utf8)
        let jsonSummary = try HandoffEvidenceParser.parseJSON(json)
        guard jsonSummary.rootTitle == "Acceptance Account",
              jsonSummary.itemCount == 1,
              jsonSummary.omittedCount == 0,
              jsonSummary.recordTitles == ["Acceptance Editable Note"]
        else {
            throw AcceptanceFailure(description: "JSON handoff parser lost its exact summary")
        }

        var selection = BulkSelectionProgress(requiredCount: 3)
        try selection.record(identifier: "row-a")
        try selection.record(identifier: "row-b")
        try selection.record(identifier: "row-c")
        guard selection.provesSelection(observedCount: 3),
              !selection.provesSelection(observedCount: 2)
        else {
            throw AcceptanceFailure(description: "bulk-selection state machine accepted an incomplete selection")
        }
        do {
            try selection.record(identifier: "row-a")
            throw AcceptanceFailure(description: "bulk-selection state machine accepted a duplicate row")
        } catch let failure as AcceptanceFailure {
            guard failure.description.contains("duplicate") else { throw failure }
        }

        let inventory = try ClipActionInventoryEvidence.parse(
            "index=0|id=useAI|group=0|order=10|enabled=true|reason=none|presentation=persistentContinuation;"
                + "index=1|id=moveToVault|group=1|order=120|enabled=false|reason=Vault\\|locked|presentation=persistentContinuation"
        )
        guard inventory.map(\.id) == ["useAI", "moveToVault"],
              inventory[1].disabledReason == "Vault|locked",
              ClipActionInventoryEvidence.provesCanonicalOrder(inventory)
        else {
            throw AcceptanceFailure(description: "clip-action inventory parser lost order or escaped reasons")
        }

        guard SettingsClipLimitAXState(
            fieldValue: "1000",
            stepperValue: "1000"
        ).provesCommitted(expected: 1_000),
        !SettingsClipLimitAXState(
            fieldValue: "1000\u{2028}",
            stepperValue: "100"
        ).provesCommitted(expected: 1_000),
        !SettingsClipLimitAXState(
            fieldValue: "1000",
            stepperValue: "100"
        ).provesCommitted(expected: 1_000)
        else {
            throw AcceptanceFailure(
                description: "Settings clip-limit proof accepted an uncommitted draft"
            )
        }

        let appURL = URL(fileURLWithPath: "/tmp/ClipboardRouter-UIAcceptance.app")
        let applicationTile = DockApplicationItemCandidate(
            subrole: "AXApplicationDockItem",
            url: appURL,
            actions: [kAXPressAction as String]
        )
        let minimizedWindowTile = DockApplicationItemCandidate(
            subrole: "AXMinimizedWindowDockItem",
            url: nil,
            actions: [kAXPressAction as String]
        )
        let staleApplicationTile = DockApplicationItemCandidate(
            subrole: "AXApplicationDockItem",
            url: URL(fileURLWithPath: "/tmp/stale/ClipboardRouter-UIAcceptance.app"),
            actions: [kAXPressAction as String]
        )
        guard applicationTile.matches(applicationURL: appURL),
              !minimizedWindowTile.matches(applicationURL: appURL),
              !staleApplicationTile.matches(applicationURL: appURL)
        else {
            throw AcceptanceFailure(description: "Dock selector did not isolate the exact application tile")
        }
        guard DockMinimizedWindowItemCandidate(
            subrole: "AXMinimizedWindowDockItem",
            title: "Clipboard Router",
            actions: [kAXPressAction as String]
        ).matchesLibrary,
        !DockMinimizedWindowItemCandidate(
            subrole: "AXApplicationDockItem",
            title: "Clipboard Router",
            actions: [kAXPressAction as String]
        ).matchesLibrary
        else {
            throw AcceptanceFailure(description: "Dock selector did not isolate the minimized Library tile")
        }

        try AXTree.runTraversalSelfTests()

        // Round-trip AutoOrganizeTagList against AutomaticOrganizationAccessibility.suggestionValue's
        // encoding for tags containing the comma separator, the outer pipe delimiter, a literal
        // backslash, and a newline — individually and combined alongside an unescaped tag.
        let suggestionValue = "rule=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
            + "|clip=11111111-2222-3333-4444-555555555555"
            + "|confidence=100|undo=false"
            + #"|tags=a\,b\|c\\d\ne,plain"#
            + "|status=none|error=none"
        guard AutoOrganizeTagList.rawField("clip", in: suggestionValue)
            == "11111111-2222-3333-4444-555555555555",
            let rawTags = AutoOrganizeTagList.rawField("tags", in: suggestionValue)
        else {
            throw AcceptanceFailure(description: "AutoOrganizeTagList field lookup lost a sibling field")
        }
        guard AutoOrganizeTagList.decode(rawTags) == ["a,b|c\\d\ne", "plain"] else {
            throw AcceptanceFailure(
                description: "AutoOrganizeTagList did not round-trip comma/pipe/backslash/newline tags"
            )
        }
        guard AutoOrganizeTagList.decode("") == [] else {
            throw AcceptanceFailure(description: "AutoOrganizeTagList misread an empty tag list as one blank tag")
        }
        // An escaped pipe inside tags= must not be misread as the boundary ending the field early.
        let pipeOnlyValue = #"rule=r|clip=c|confidence=1|undo=false|tags=a\|b|status=none|error=none"#
        guard AutoOrganizeTagList.rawField("tags", in: pipeOnlyValue).map(AutoOrganizeTagList.decode)
            == ["a|b"],
            AutoOrganizeTagList.rawField("status", in: pipeOnlyValue) == "none"
        else {
            throw AcceptanceFailure(description: "AutoOrganizeTagList let an escaped pipe truncate the tags field")
        }
    }
}

private struct DockApplicationItemCandidate {
    let subrole: String?
    let url: URL?
    let actions: [String]

    func matches(applicationURL: URL) -> Bool {
        guard subrole == "AXApplicationDockItem",
              actions.contains(kAXPressAction as String),
              let url
        else { return false }
        return url.standardizedFileURL.resolvingSymlinksInPath()
            == applicationURL.standardizedFileURL.resolvingSymlinksInPath()
    }
}

private struct DockMinimizedWindowItemCandidate {
    let subrole: String?
    let title: String?
    let actions: [String]

    var matchesLibrary: Bool {
        subrole == "AXMinimizedWindowDockItem"
            && title == "Clipboard Router"
            && actions.contains(kAXPressAction as String)
    }
}

/// Bounded probes for determining whether AppKit diagnostics originate in product
/// presentation or in the acceptance runner's accessibility traversal. These modes
/// never alter product behavior and are intentionally unavailable in the app target.
private enum AcceptanceDiagnosticMode: String, CaseIterable {
    case menuOpenOnly = "menu-open-only"
    case openLibraryOnly = "open-library-only"
    case newNoteVisibleNoSheetQuery = "new-note-visible-no-sheet-query"
    case newNoteHiddenNoSheetQuery = "new-note-hidden-no-sheet-query"
    case newNoteSheetRootsQuery = "new-note-sheet-roots-query"
    case newNoteExactIdentifierQuery = "new-note-exact-identifier-query"
    case libraryEditTrace = "library-edit-trace"
    case libraryEditAfterContinuationsTrace = "library-edit-after-continuations-trace"
    case libraryLifecycleTrace = "library-lifecycle-trace"
    case settingsClipLimitTrace = "settings-clip-limit-trace"
    case projectCreateTrace = "project-create-trace"
    case projectLifecycleTrace = "project-lifecycle-trace"
}

private struct StatusItemCandidate {
    let role: String?
    let subrole: String?
    let title: String?
    let label: String?
    let value: String?
    let actions: [String]

    var isClipboardRouterStatusItem: Bool {
        let isStatusExtra = role == "AXMenuExtra"
            || subrole == "AXMenuExtra"
            || subrole == "AXStatusItem"
        guard isStatusExtra, actions.contains(kAXPressAction as String) else { return false }
        let text = [title, label, value]
            .compactMap { $0 }
            .joined(separator: " ")
        return text == "Clipboard Router"
            || text.hasPrefix("Clipboard Router,")
    }
}

private struct LibraryFilterCandidate {
    let role: String?
    let title: String?
    let label: String?
    let value: String?

    func matches(title expectedTitle: String) -> Bool {
        guard role == kAXRadioButtonRole as String else { return false }
        return title == expectedTitle || label == expectedTitle || value == expectedTitle
    }
}

/// A text field can expose an AXValue before SwiftUI propagates its draft into AppModel.
/// The adjacent native incrementor exposes the committed model value, so acceptance only
/// treats the edit as complete when both fresh accessibility elements agree exactly.
private struct SettingsClipLimitAXState {
    let fieldValue: String?
    let stepperValue: String?

    func provesCommitted(expected: Int) -> Bool {
        let expectedValue = String(expected)
        return fieldValue == expectedValue && stepperValue == expectedValue
    }
}

private enum AppConsolePolicy {
    static let forbiddenDiagnostics = [
        "reentrant operation in its NSTableView delegate",
    ]

    static func forbiddenDiagnostic(in console: String) -> String? {
        forbiddenDiagnostics.first { console.localizedCaseInsensitiveContains($0) }
    }
}

private enum AcceptanceStartupReadiness {
    static let marker = "UI_ACCEPTANCE_READY"

    static func markerCount(in data: Data) -> Int {
        String(decoding: data, as: UTF8.self)
            .components(separatedBy: .newlines)
            .filter { $0 == marker }
            .count
    }
}

private struct HandoffEvidenceSummary: Equatable {
    let rootTitle: String
    let itemCount: Int
    let omittedCount: Int
    let recordTitles: [String]
}

private enum HandoffEvidenceParser {
    static func parseMarkdown(_ text: String) throws -> HandoffEvidenceSummary {
        let lines = text.components(separatedBy: .newlines)
        guard let rootLine = lines.first(where: { $0.hasPrefix("# ") }),
              let itemLine = lines.first(where: { $0.hasPrefix("Items: ") }),
              let omissionLine = lines.first(where: { $0.hasPrefix("Omitted: ") }),
              let itemCount = Int(itemLine.dropFirst("Items: ".count)),
              let omittedCount = Int(omissionLine.dropFirst("Omitted: ".count))
        else {
            throw AcceptanceFailure(description: "handoff Markdown is missing its parseable summary")
        }
        return HandoffEvidenceSummary(
            rootTitle: String(rootLine.dropFirst(2)),
            itemCount: itemCount,
            omittedCount: omittedCount,
            recordTitles: lines.compactMap { line in
                line.hasPrefix("### ") ? String(line.dropFirst(4)) : nil
            }
        )
    }

    static func parseCSV(_ text: String) throws -> [[String: String]] {
        let rows = try csvRows(text)
        guard let header = rows.first, !header.isEmpty else {
            throw AcceptanceFailure(description: "handoff CSV has no header")
        }
        guard rows.count > 1 else {
            throw AcceptanceFailure(description: "handoff CSV has no data rows: \(rows)")
        }
        return try rows.dropFirst().map { row in
            guard row.count == header.count else {
                throw AcceptanceFailure(
                    description: "handoff CSV row has \(row.count) cells; expected \(header.count)"
                )
            }
            return Dictionary(uniqueKeysWithValues: zip(header, row))
        }
    }

    static func parseJSON(_ data: Data) throws -> HandoffEvidenceSummary {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rootTitle = object["rootFolderPath"] as? String,
              let records = object["records"] as? [[String: Any]],
              let omissions = object["omissions"] as? [[String: Any]],
              records.allSatisfy({ $0["title"] is String })
        else {
            throw AcceptanceFailure(description: "handoff JSON has no parseable projection")
        }
        return HandoffEvidenceSummary(
            rootTitle: rootTitle,
            itemCount: records.count,
            omittedCount: omissions.count,
            recordTitles: records.compactMap { $0["title"] as? String }
        )
    }

    private static func csvRows(_ text: String) throws -> [[String]] {
        // Iterate Unicode scalars rather than grapheme clusters. Swift treats CRLF as one
        // Character, while RFC-style CSV requires CR and LF to be recognized separately.
        let characters = Array(text.unicodeScalars)
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var index = 0
        var inQuotes = false
        while index < characters.count {
            let character = characters[index]
            if inQuotes {
                if character == "\"" {
                    if index + 1 < characters.count, characters[index + 1] == "\"" {
                        field.append("\"")
                        index += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.unicodeScalars.append(character)
                }
            } else {
                switch character {
                case "\"":
                    guard field.isEmpty else {
                        throw AcceptanceFailure(description: "handoff CSV contains an unexpected quote")
                    }
                    inQuotes = true
                case ",":
                    row.append(field)
                    field = ""
                case "\r", "\n":
                    row.append(field)
                    field = ""
                    if !row.allSatisfy(\.isEmpty) { rows.append(row) }
                    row = []
                    if character == "\r", index + 1 < characters.count,
                       characters[index + 1] == "\n" {
                        index += 1
                    }
                default:
                    field.unicodeScalars.append(character)
                }
            }
            index += 1
        }
        guard !inQuotes else {
            throw AcceptanceFailure(description: "handoff CSV contains an unterminated quoted field")
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }
}

private struct BulkSelectionProgress {
    let requiredCount: Int
    private(set) var identifiers: [String] = []

    mutating func record(identifier: String) throws {
        guard !identifiers.contains(identifier) else {
            throw AcceptanceFailure(description: "bulk-selection state machine received duplicate row \(identifier)")
        }
        identifiers.append(identifier)
    }

    func provesSelection(observedCount: Int) -> Bool {
        identifiers.count == requiredCount
            && Set(identifiers).count == requiredCount
            && observedCount == requiredCount
    }
}

private struct ClipActionInventoryItem: Equatable {
    let index: Int
    let id: String
    let group: Int
    let order: Int
    let isEnabled: Bool
    let disabledReason: String
}

private enum ClipActionInventoryEvidence {
    static func parse(_ value: String) throws -> [ClipActionInventoryItem] {
        try splitEscaped(value, separator: ";").filter { !$0.isEmpty }.map { descriptor in
            let fields = try Dictionary(uniqueKeysWithValues: splitEscaped(descriptor, separator: "|").map {
                guard let equals = $0.firstIndex(of: "=") else {
                    throw AcceptanceFailure(description: "clip-action inventory field has no equals sign")
                }
                return (
                    String($0[..<equals]),
                    decodeComponent(String($0[$0.index(after: equals)...]))
                )
            })
            guard let index = fields["index"].flatMap(Int.init),
                  let id = fields["id"],
                  let group = fields["group"].flatMap(Int.init),
                  let order = fields["order"].flatMap(Int.init),
                  let enabled = fields["enabled"].flatMap(Bool.init),
                  let reason = fields["reason"]
            else { throw AcceptanceFailure(description: "clip-action inventory descriptor is incomplete") }
            return ClipActionInventoryItem(
                index: index,
                id: id,
                group: group,
                order: order,
                isEnabled: enabled,
                disabledReason: reason
            )
        }
    }

    static func provesCanonicalOrder(_ items: [ClipActionInventoryItem]) -> Bool {
        items.enumerated().allSatisfy { $0.offset == $0.element.index }
            && zip(items, items.dropFirst()).allSatisfy {
                ($0.group, $0.order, $0.id) <= ($1.group, $1.order, $1.id)
            }
    }

    private static func splitEscaped(_ value: String, separator: Character) throws -> [String] {
        var result: [String] = []
        var current = ""
        var escaped = false
        for character in value {
            if escaped {
                current.append("\\")
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == separator {
                result.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        guard !escaped else {
            throw AcceptanceFailure(description: "clip-action inventory ends with an escape")
        }
        result.append(current)
        return result
    }

    private static func decodeComponent(_ value: String) -> String {
        var result = ""
        var escaped = false
        for character in value {
            if escaped {
                result.append(character == "n" ? "\n" : character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                result.append(character)
            }
        }
        if escaped { result.append("\\") }
        return result
    }
}

/// Mirrors `AutomaticOrganizationAccessibility.suggestionValue`'s pipe-delimited,
/// backslash-escaped encoding (`Sources/ClipboardRouterApp/AutomaticOrganizationView.swift`) so
/// the runner can read a `tags=` field back out exactly — including tags that themselves contain
/// the delimiter characters (`,`, `|`, `\`) or a newline. Kept independent of that app target:
/// this executable is a black-box AX client and does not link against ClipboardRouterApp.
private enum AutoOrganizeTagList {
    /// Returns the raw (still-escaped) value of `key=` within a pipe-delimited accessibility
    /// value, respecting `\|` so an escaped pipe inside a field cannot be misread as the
    /// boundary that ends the field early.
    static func rawField(_ key: String, in value: String) -> String? {
        for segment in splitEscaped(value, separator: "|") {
            guard segment.hasPrefix("\(key)=") else { continue }
            return String(segment.dropFirst(key.count + 1))
        }
        return nil
    }

    /// Decodes a raw `tags=` value into its individual tags, undoing both the comma separator
    /// escaping and the per-tag backslash/pipe/newline escaping.
    static func decode(_ rawTags: String) -> [String] {
        guard !rawTags.isEmpty else { return [] }
        return splitEscaped(rawTags, separator: ",").map(decodeComponent)
    }

    private static func splitEscaped(_ value: String, separator: Character) -> [String] {
        var result: [String] = []
        var current = ""
        var escaped = false
        for character in value {
            if escaped {
                current.append("\\")
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == separator {
                result.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        if escaped { current.append("\\") }
        result.append(current)
        return result
    }

    private static func decodeComponent(_ value: String) -> String {
        var result = ""
        var escaped = false
        for character in value {
            if escaped {
                result.append(character == "n" ? "\n" : character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                result.append(character)
            }
        }
        if escaped { result.append("\\") }
        return result
    }
}

/// Local packaged acceptance deliberately stops before actions that need a real account,
/// provider, permission decision, or encrypted store. Keeping those boundaries in the report
/// prevents a green UI-continuation run from being misreported as a live integration pass.
private enum ExternalAcceptanceBoundary {
    static let cases = [
        "calendar-event-commit-requires-calendar-tcc",
        "contact-commit-requires-contacts-tcc",
        "hosted-ai-send-requires-provider-credential-and-network",
        "crm-write-requires-oauth-and-provider-account",
        "vault-commit-requires-keychain-backed-vault",
        "share-completion-requires-user-selected-system-provider",
    ]
}

private enum NonMutatingPackagedBoundary {
    static let cases = [
        "new-folder-presentation-cancel-only",
        // The menu continuation proves presentation/cancel only; full Project creation and
        // activation is independently committed by the Project workspace acceptance journey.
        "menu-new-project-persistent-continuation-cancel",
        "shortcut-editor-presentation-cancel-only",
        "flow-review-presentation-cancel-only",
        "export-save-panel-presentation-cancel-only",
    ]
}

private final class ProcessConsoleCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var captured = Data()
    private var activePipe: Pipe?

    func makePipe() -> Pipe {
        let pipe = Pipe()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            self?.append(chunk)
            FileHandle.standardError.write(chunk)
        }
        lock.withLock { activePipe = pipe }
        return pipe
    }

    func stopMirroring() {
        lock.withLock {
            activePipe?.fileHandleForReading.readabilityHandler = nil
            activePipe = nil
        }
    }

    func snapshot() -> Data {
        lock.withLock { captured }
    }

    func acceptanceReadyMarkerCount() -> Int {
        lock.withLock {
            AcceptanceStartupReadiness.markerCount(in: captured)
        }
    }

    private func append(_ data: Data) {
        lock.withLock { captured.append(data) }
    }
}

private struct AXElementIdentity: Hashable {
    let element: AXUIElement

    static func == (lhs: Self, rhs: Self) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(element))
    }
}

private final class AcceptanceRunner {
    private let arguments: RunnerArguments
    private let evidence: EvidenceRecorder
    private let consoleCapture = ProcessConsoleCapture()
    private var process: Process?
    private var caseStartedAt = Date()
    private var cachedLibraryWindow: AXUIElement?

    init(arguments: RunnerArguments) {
        self.arguments = arguments
        self.evidence = EvidenceRecorder(
            directory: arguments.evidenceDirectory,
            runID: arguments.runID,
            applicationURL: arguments.applicationURL
        )
    }

    deinit {
        consoleCapture.stopMirroring()
        if process?.isRunning == true { process?.terminate() }
    }

    func run() throws -> AcceptanceExit {
        let bundle = try requiredBundle()
        guard bundle.bundleIdentifier == "com.clipboardrouter.ClipboardRouter.uiacceptance" else {
            throw AcceptanceFailure(
                description: "acceptance app has unexpected bundle id \(bundle.bundleIdentifier ?? "nil")"
            )
        }
        let readyMarkerBaseline = consoleCapture.acceptanceReadyMarkerCount()
        let launchStartedAt = Date()
        let launched = try launch(bundle: bundle)
        defer {
            consoleCapture.stopMirroring()
            if let activeProcess = process, activeProcess.isRunning {
                activeProcess.terminate()
                activeProcess.waitUntilExit()
            }
        }

        let appRoot = AXUIElementCreateApplication(launched.processIdentifier)
        do {
            try waitForAcceptanceReadiness(
                afterMarkerCount: readyMarkerBaseline,
                startedAt: launchStartedAt,
                phase: "initial-launch"
            )
            try waitUntil(timeout: 15, failure: "acceptance application did not expose its AX tree") {
                AXTree.first(in: currentApplicationRoots(), where: {
                    $0.role == kAXApplicationRole as String
                }) != nil
            }

            try requireInteractiveSession(phase: "status-item discovery")
            let statusItem = try waitForStatusItem(applicationRoot: appRoot, timeout: 15)
            if let diagnosticMode = arguments.diagnosticMode {
                try runDiagnostic(
                    diagnosticMode,
                    statusItem: statusItem,
                    appRoot: appRoot
                )
                try evidence.finish(
                    outcome: "diagnostic-complete",
                    error: nil,
                    roots: evidenceRoots(),
                    appConsole: consoleCapture.snapshot()
                )
                // Deliberately not "PASS": this is a single bounded probe, not a full acceptance
                // run, and must not be greppable as one nor share exit 0 with a real pass.
                print("DIAGNOSTIC \(diagnosticMode.rawValue) COMPLETE — NOT ACCEPTANCE (0 of the full acceptance cases ran)")
                return .diagnosticOnly
            }
            try requireInteractiveSession(phase: "menu presentation")
            try openMenu(statusItem: statusItem, appRoot: appRoot)
            try pass("status-item-discovery-and-press")

            try requireInteractiveSession(phase: "menu inventory")
            try verifyThousandItemMenu(appRoot: appRoot)
            try verifyRunScopedPasteboard(statusItem: statusItem, appRoot: appRoot)
            try verifySettingsFromMenu(statusItem: statusItem, appRoot: appRoot)
            try verifyMenuContinuationJourneys(statusItem: statusItem, appRoot: appRoot)
            try verifyLibraryJourneys(statusItem: statusItem, appRoot: appRoot)
            try verifyExpandedLocalInventory(statusItem: statusItem, appRoot: appRoot)
            try verifyLibraryWindowLifecycle(statusItem: statusItem, appRoot: appRoot)
            try verifyPersistenceAcrossRelaunch(bundle: bundle)
            try assertConsoleHasNoForbiddenDiagnostics()
            let outcome = evidence.hasBoundaries ? "incomplete" : "passed"
            try evidence.finish(
                outcome: outcome,
                error: evidence.boundarySummary,
                roots: evidenceRoots(),
                appConsole: consoleCapture.snapshot()
            )
            return outcome == "incomplete" ? .incomplete : .success
        } catch let failure as AcceptanceFailure where failure.isEnvironmental {
            consoleCapture.stopMirroring()
            try? evidence.finish(
                outcome: "skipped",
                error: failure.description,
                roots: evidenceRoots(),
                appConsole: consoleCapture.snapshot()
            )
            throw failure
        } catch {
            consoleCapture.stopMirroring()
            try? evidence.finish(
                outcome: "failed",
                error: String(describing: error),
                roots: evidenceRoots(),
                appConsole: consoleCapture.snapshot()
            )
            throw error
        }
    }

    private func pass(_ name: String) throws {
        let completedAt = Date()
        evidence.recordPass(
            name,
            durationMilliseconds: max(0, Int(completedAt.timeIntervalSince(caseStartedAt) * 1_000))
        )
        caseStartedAt = completedAt
        try assertConsoleHasNoForbiddenDiagnostics()
        print("PASS \(name)")
    }

    private func requireInteractiveSession(phase: String) throws {
        let availability = SessionAvailability.current()
        guard availability == .available else {
            throw AcceptanceFailure(
                description: "interactive session became unavailable during \(phase): \(availability.reason)",
                isEnvironmental: true
            )
        }
    }

    private func recordRelaunchBoundary(
        name: String,
        failure: AcceptanceFailure,
        prerequisite: String?
    ) throws {
        // Only a genuine external/environmental boundary (AcceptanceBoundaryPolicy) may be
        // recorded as non-failing. Everything else — including a "forbidden AppKit diagnostic"
        // crash signature and any ordinary AX assertion timeout — is a real product or
        // automation bug and must propagate as a hard failure, never a silent boundary/incomplete.
        guard AcceptanceBoundaryPolicy.permitsBoundary(failure, named: name) else { throw failure }
        let detail: String
        if let prerequisite, evidence.hasBoundary(named: prerequisite) {
            detail = "not independently proven because \(prerequisite) was already bounded: \(failure.description)"
        } else {
            detail = failure.description
        }
        try evidence.recordBoundary(name: name, error: detail)
        print("BOUNDARY \(name): \(detail)")
    }

    private func assertConsoleHasNoForbiddenDiagnostics() throws {
        let console = String(decoding: consoleCapture.snapshot(), as: UTF8.self)
        if let diagnostic = AppConsolePolicy.forbiddenDiagnostic(in: console) {
            throw AcceptanceFailure(
                description: "packaged app emitted forbidden AppKit diagnostic: \(diagnostic)"
            )
        }
    }

    private func waitForAcceptanceReadiness(
        afterMarkerCount baseline: Int,
        startedAt: Date,
        phase: String
    ) throws {
        do {
            try waitUntil(
                timeout: 30,
                failure: "acceptance application never reported a ready AppModel during \(phase)"
            ) {
                consoleCapture.acceptanceReadyMarkerCount() > baseline
            }
        } catch {
            evidence.recordStartupReadiness(
                phase: phase,
                durationMilliseconds: max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
            )
            throw error
        }
        let elapsedMilliseconds = max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
        evidence.recordStartupReadiness(
            phase: phase,
            durationMilliseconds: elapsedMilliseconds
        )
        print("READY \(phase) \(elapsedMilliseconds)ms")
    }

    private func runDiagnostic(
        _ mode: AcceptanceDiagnosticMode,
        statusItem: AXUIElement,
        appRoot: AXUIElement
    ) throws {
        diagnosticCheckpoint("status-item-discovered")

        let libraryWasVisible = !currentLibraryRoots().isEmpty
        evidence.recordDiagnosticObservation(
            name: "library-visible-before-note",
            value: libraryWasVisible ? "true" : "false"
        )
        diagnosticCheckpoint("library-visibility-queried")

        if mode == .libraryEditTrace || mode == .libraryEditAfterContinuationsTrace {
            if mode == .libraryEditAfterContinuationsTrace {
                try openMenu(statusItem: statusItem, appRoot: appRoot)
                try press(
                    identifier: "uiAcceptance.menu.openLibrary",
                    in: currentApplicationRoots(),
                    failure: "Open Library is missing while preparing continuation state"
                )
                try waitUntil(timeout: 10, failure: "Library did not open before continuations") {
                    !currentLibraryRoots().isEmpty
                }
                diagnosticCheckpoint("library-open-before-continuations")
                try verifyMenuContinuationJourneys(statusItem: statusItem, appRoot: appRoot)
                diagnosticCheckpoint("menu-continuations-complete")
            }
            try runLibraryEditDiagnostic(statusItem: statusItem, appRoot: appRoot)
            return
        }

        if mode == .projectCreateTrace || mode == .projectLifecycleTrace {
            try openMenu(statusItem: statusItem, appRoot: appRoot)
            try press(
                identifier: "uiAcceptance.menu.openLibrary",
                in: currentApplicationRoots(),
                failure: "Open Library is missing before Project trace"
            )
            try waitUntil(timeout: 10, failure: "Library did not open before Project trace") {
                !currentLibraryRoots().isEmpty
            }
            try verifyDeveloperProjectCreateAndActivate()
            if mode == .projectLifecycleTrace {
                try verifyLibraryWindowLifecycle(statusItem: statusItem, appRoot: appRoot)
            }
            return
        }

        if mode == .libraryLifecycleTrace {
            try runLibraryLifecycleDiagnostic(statusItem: statusItem, appRoot: appRoot)
            return
        }

        if mode == .settingsClipLimitTrace {
            try runSettingsClipLimitDiagnostic(statusItem: statusItem, appRoot: appRoot)
            return
        }

        if mode == .newNoteVisibleNoSheetQuery, !libraryWasVisible {
            try openMenu(statusItem: statusItem, appRoot: appRoot)
            try press(
                identifier: "uiAcceptance.menu.openLibrary",
                in: currentApplicationRoots(),
                failure: "Open Library is missing while preparing visible-Library probe"
            )
            try waitUntil(timeout: 10, failure: "Library did not open for visible-Library probe") {
                !currentLibraryRoots().isEmpty
            }
            // Establish a clean console boundary after the persistent window has completed
            // its initial list layout, before presenting the continuation sheet.
            RunLoop.current.run(until: Date().addingTimeInterval(2))
            diagnosticCheckpoint("library-visible-and-settled-before-note")
        } else if mode == .newNoteHiddenNoSheetQuery, libraryWasVisible {
            try closeLibraryWindow()
            diagnosticCheckpoint("library-closed-before-note")
        }

        try openMenu(statusItem: statusItem, appRoot: appRoot)
        diagnosticCheckpoint("menu-opened")
        guard mode != .menuOpenOnly else {
            RunLoop.current.run(until: Date().addingTimeInterval(2))
            diagnosticCheckpoint("menu-open-idle-two-seconds")
            return
        }

        if mode == .openLibraryOnly {
            let openLibrary = try requiredElement(
                in: currentApplicationRoots(),
                identifier: "uiAcceptance.menu.openLibrary",
                failure: "Open Library is missing from menu bar"
            )
            diagnosticCheckpoint("open-library-control-resolved")
            try AXTree.perform(kAXPressAction as String, on: openLibrary)
            RunLoop.current.run(until: Date().addingTimeInterval(4))
            let libraryBecameVisible = !currentLibraryRoots().isEmpty
            evidence.recordDiagnosticObservation(
                name: "library-visible-after-open",
                value: libraryBecameVisible ? "true" : "false"
            )
            diagnosticCheckpoint("library-opened-four-seconds-no-sheet")
            guard libraryBecameVisible else {
                throw AcceptanceFailure(
                    description: "Open Library did not create a persistent Library window"
                )
            }
            return
        }

        let newNote = try requiredElement(
            in: currentApplicationRoots(),
            identifier: "uiAcceptance.menu.newNote",
            failure: "New Note is missing from menu bar"
        )
        diagnosticCheckpoint("new-note-control-resolved")
        try AXTree.perform(kAXPressAction as String, on: newNote)

        // Deliberately make no AX call while SwiftUI dismisses MenuBarExtra and publishes
        // the persistent continuation. If the diagnostic appears here, product presentation
        // is responsible. If it first appears below, the named AX query is responsible.
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        diagnosticCheckpoint("new-note-presented-two-seconds-no-ax-query")

        switch mode {
        case .menuOpenOnly, .openLibraryOnly, .newNoteVisibleNoSheetQuery,
             .newNoteHiddenNoSheetQuery, .libraryEditTrace,
             .libraryEditAfterContinuationsTrace, .libraryLifecycleTrace,
             .settingsClipLimitTrace, .projectCreateTrace, .projectLifecycleTrace:
            return

        case .newNoteSheetRootsQuery:
            let sheetRoots = currentSheetRoots()
            evidence.recordDiagnosticObservation(
                name: "sheet-root-count",
                value: String(sheetRoots.count)
            )
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            diagnosticCheckpoint("sheet-roots-queried")

        case .newNoteExactIdentifierQuery:
            let sheetRoots = currentSheetRoots()
            evidence.recordDiagnosticObservation(
                name: "sheet-root-count",
                value: String(sheetRoots.count)
            )
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            diagnosticCheckpoint("sheet-roots-queried")
            let title = AXTree.first(
                in: sheetRoots,
                identifier: "uiAcceptance.noteEditor.title"
            )
            evidence.recordDiagnosticObservation(
                name: "note-title-found",
                value: title == nil ? "false" : "true"
            )
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            diagnosticCheckpoint("exact-note-title-identifier-queried")
        }
    }

    private func runSettingsClipLimitDiagnostic(
        statusItem: AXUIElement,
        appRoot: AXUIElement
    ) throws {
        try openSettingsFromMenu(statusItem: statusItem, appRoot: appRoot)
        diagnosticCheckpoint("settings-opened")
        for expected in [1, 100, 1_000] {
            try setSettingsClipLimitDraft(expected)
            diagnosticCheckpoint("settings-clip-limit-\(expected)-draft-rendered")
            try closeSettings(appRoot: appRoot)
            try verifyRenderedMenuLimit(expected, statusItem: statusItem, appRoot: appRoot)
            diagnosticCheckpoint("menu-clip-limit-\(expected)-rendered")
            try openSettingsFromMenu(statusItem: statusItem, appRoot: appRoot)
            try waitForPersistedSettingsClipLimit(expected)
            let state = settingsClipLimitAXState()
            evidence.recordDiagnosticObservation(
                name: "settings-clip-limit-\(expected)-persisted",
                value: "field=\(state.fieldValue ?? "missing"),stepper=\(state.stepperValue ?? "missing")"
            )
            diagnosticCheckpoint("settings-clip-limit-\(expected)-persisted")
        }
        try closeSettings(appRoot: appRoot)
    }

    private func runLibraryLifecycleDiagnostic(
        statusItem: AXUIElement,
        appRoot: AXUIElement
    ) throws {
        try openMenu(statusItem: statusItem, appRoot: appRoot)
        try press(
            identifier: "uiAcceptance.menu.openLibrary",
            in: currentApplicationRoots(),
            failure: "Open Library is missing from menu bar"
        )
        try waitUntil(timeout: 10, failure: "Library did not open") {
            !currentLibraryRoots().isEmpty
        }
        recordDockDiagnostic("library-open")

        let library = try requiredLibraryWindow(
            failure: "Library window disappeared before lifecycle diagnostic"
        )
        guard let minimizeButton = AXTree.first(in: [library], where: { node in
            node.subrole == "AXMinimizeButton"
        }) else {
            throw AcceptanceFailure(description: "Library window has no minimize button")
        }
        try AXTree.perform(kAXPressAction as String, on: minimizeButton)
        try waitUntil(timeout: 5, failure: "Library window did not minimize") {
            guard let current = currentLibraryRoots().first else { return false }
            return AXTree.boolean(kAXMinimizedAttribute as String, current) == true
        }
        recordDockDiagnostic("library-minimized")
        try pressDockMinimizedLibraryItem()
        try waitUntil(timeout: 10, failure: "Dock activation did not restore the minimized Library") {
            guard let current = currentLibraryRoots().first else { return false }
            return AXTree.boolean(kAXMinimizedAttribute as String, current) != true
        }
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        recordDockDiagnostic("library-restored-settled")

        try closeLibraryWindow()
        recordDockDiagnostic("library-closed")
        try activateFinderBeforeDockReopen()
        try pressDockApplicationItem()
        try waitUntil(timeout: 10, failure: "Dock activation did not recreate the closed Library") {
            !currentLibraryRoots().isEmpty
        }
        recordDockDiagnostic("library-recreated")
    }

    private func recordDockDiagnostic(_ name: String) {
        let matchingItem = currentDockApplicationItem()
        evidence.recordDiagnosticObservation(
            name: "dock-\(name)",
            value: matchingItem.map {
                "present-actions=\(AXTree.actionNames($0).sorted().joined(separator: ","))"
            } ?? "missing"
        )
        diagnosticCheckpoint("dock-\(name)")
    }

    private func runLibraryEditDiagnostic(
        statusItem: AXUIElement,
        appRoot: AXUIElement
    ) throws {
        try openMenu(statusItem: statusItem, appRoot: appRoot)
        try press(
            identifier: "uiAcceptance.menu.openLibrary",
            in: currentApplicationRoots(),
            failure: "Open Library is missing from menu bar"
        )
        try waitUntil(timeout: 10, failure: "Library did not open") {
            !currentLibraryRoots().isEmpty
        }
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        diagnosticCheckpoint("library-open-and-settled")

        let historyDestination = try requiredElement(
            in: currentLibraryRoots(),
            identifier: "uiAcceptance.library.history",
            failure: "Library has no accessible History destination"
        )
        try AXTree.activateSelectableElement(historyDestination)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        diagnosticCheckpoint("history-pressed-no-followup-query")

        let librarySearch = try requiredElement(
            in: currentLibraryRoots(),
            identifier: "uiAcceptance.library.search",
            failure: "Library search field is missing"
        )
        diagnosticCheckpoint("search-resolved")
        try activateAcceptanceApplication()
        try AXTree.setFocused(true, on: librarySearch)
        diagnosticCheckpoint("search-focused")
        try AXTree.setValue("sarah@example.com", on: librarySearch)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        diagnosticCheckpoint("search-value-set-no-followup-query")
        try AXTree.pressReturn()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        diagnosticCheckpoint("search-return-pressed-no-followup-query")

        let firstRowID = "uiAcceptance.library.clip.00000000-0000-0000-0000-000000000001"
        let secondRowID = "uiAcceptance.library.clip.00000000-0000-0000-0000-000000000002"
        try waitUntil(timeout: 8, failure: "Library did not filter to the first fixture clip") {
            AXTree.first(in: currentLibraryRoots(), identifier: firstRowID) != nil
                && AXTree.first(in: currentLibraryRoots(), identifier: secondRowID) == nil
        }
        diagnosticCheckpoint("filtered-row-queried")
        let firstRowMarker = try requiredElement(
            in: currentLibraryRoots(),
            identifier: firstRowID,
            failure: "first fixture clip is missing in Library"
        )
        diagnosticCheckpoint("first-row-resolved")
        try activateAcceptanceApplication()
        try AXTree.activateSelectableElement(firstRowMarker)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        diagnosticCheckpoint("first-row-activated-no-followup-query")

        try waitUntil(timeout: 5, failure: "first fixture clip did not become selected") {
            AXTree.first(
                in: currentLibraryRoots(),
                identifier: "uiAcceptance.library.selected.00000000-0000-0000-0000-000000000001"
            ) != nil
        }
        diagnosticCheckpoint("selected-state-queried")
        _ = try requiredElement(
            in: currentLibraryRoots(),
            identifier: "uiAcceptance.library.more",
            failure: "Library More menu did not appear"
        )
        diagnosticCheckpoint("more-resolved")
        try press(
            identifier: "uiAcceptance.library.more",
            in: currentLibraryRoots(),
            failure: "Library More menu is missing"
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        diagnosticCheckpoint("more-pressed-no-menu-query")
        try press(
            title: "Edit a Saved Copy…",
            in: [AXUIElementCreateSystemWide()] + currentApplicationRoots(),
            failure: "Library More menu is missing Edit a Saved Copy"
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        diagnosticCheckpoint("edit-pressed-no-sheet-query")
        try waitUntil(timeout: 8, failure: "Edit Clip sheet did not open") {
            AXTree.first(
                in: currentSheetRoots(),
                identifier: "uiAcceptance.clipEditor.title"
            ) != nil
        }
        diagnosticCheckpoint("edit-sheet-queried")
        try press(
            title: "Cancel",
            in: currentSheetRoots(),
            failure: "Edit Clip has no Cancel button"
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        diagnosticCheckpoint("edit-cancel-pressed-no-followup-query")
    }

    private func diagnosticCheckpoint(_ name: String) {
        let console = consoleCapture.snapshot()
        let consoleText = String(decoding: console, as: UTF8.self)
        let diagnostic = AppConsolePolicy.forbiddenDiagnostic(in: consoleText)
        evidence.recordDiagnosticCheckpoint(
            name: name,
            consoleByteCount: console.count,
            forbiddenDiagnostic: diagnostic
        )
        print(
            "DIAGNOSTIC \(name) consoleBytes=\(console.count) forbidden=\(diagnostic ?? "none")"
        )
    }

    private func openMenu(statusItem: AXUIElement, appRoot: AXUIElement) throws {
        if !currentMenuRoots().isEmpty {
            return
        }
        try activateFinderForStatusItem()
        // An accepted AXPress can begin opening the SwiftUI MenuBarExtra before its 1,000-row
        // searchable subtree is published. A second semantic press during that interval toggles
        // the transient window closed and creates a false failure. Reacquire and press the exact
        // process-owned item once, then give the menu one bounded materialization window.
        let target = try waitForMenuClosedAndReady(timeout: 3)
        try AXTree.revealMenuBar(near: target)
        guard let revealedTarget = currentStatusItem() else {
            throw AcceptanceFailure(description: "status item disappeared after revealing the menu bar")
        }
        try AXTree.perform(kAXPressAction as String, on: revealedTarget)
        let semanticDeadline = Date().addingTimeInterval(20)
        repeat {
            if !currentMenuRoots().isEmpty {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < semanticDeadline

        // Some macOS builds acknowledge AXPress without presenting the transient window. Only
        // after the single semantic attempt has had its full observation budget, perform one
        // physical click on a freshly reacquired item and observe once more. There is never a
        // second semantic press, so a slowly materializing menu cannot be toggled closed.
        let clickTarget = try waitForMenuClosedAndReady(timeout: 3)
        evidence.recordDiagnosticObservation(
            name: "status-item-semantic-press-without-presentation",
            value: "processItem=\(AXTree.frameDescription(clickTarget)); actions=\(AXTree.actionNames(clickTarget).joined(separator: ",")); falling back to exact-frame SystemUIServer item when available"
        )
        try AXTree.revealMenuBar(near: clickTarget)
        guard let revealedClickTarget = currentStatusItem() else {
            throw AcceptanceFailure(description: "status item disappeared before physical click")
        }
        let physicalTarget = matchingSystemStatusItem(for: revealedClickTarget) ?? revealedClickTarget
        evidence.recordDiagnosticObservation(
            name: "status-item-physical-click-target",
            value: "\(AXTree.frameDescription(physicalTarget)); systemMatch=\(matchingSystemStatusItem(for: revealedClickTarget) != nil)"
        )
        try AXTree.clickCenter(of: physicalTarget)
        let clickDeadline = Date().addingTimeInterval(10)
        repeat {
            if !currentMenuRoots().isEmpty {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < clickDeadline

        // A full semantic observation window plus an exact physical click both proved no menu
        // exists, so one final freshly reacquired semantic press cannot double-toggle a delayed
        // presentation. This covers macOS occasionally dropping the first status-item event
        // after a previous MenuBarExtra order-out.
        let retryTarget = try waitForMenuClosedAndReady(timeout: 3)
        try AXTree.revealMenuBar(near: retryTarget)
        guard let revealedRetryTarget = currentStatusItem() else {
            throw AcceptanceFailure(description: "status item disappeared before the final semantic retry")
        }
        try AXTree.perform(kAXPressAction as String, on: revealedRetryTarget)
        let retryDeadline = Date().addingTimeInterval(20)
        repeat {
            if !currentMenuRoots().isEmpty { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < retryDeadline
        throw AcceptanceFailure(description: "status item press did not open the menu-bar window")
    }

    private func closeMenu(statusItem: AXUIElement, appRoot: AXUIElement) throws {
        guard !currentMenuRoots().isEmpty else {
            _ = try waitForMenuClosedAndReady(timeout: 3)
            return
        }
        guard let target = currentStatusItem() else {
            throw AcceptanceFailure(description: "status item disappeared while closing the menu-bar window")
        }
        try AXTree.perform(kAXPressAction as String, on: target)
        _ = try waitForMenuClosedAndReady(timeout: 5)
    }

    /// A missing menu search field is not sufficient evidence that MenuBarExtra has finished
    /// closing. Require two consecutive fresh observations of the exact status item in a closed,
    /// actionable state before another semantic press can be issued.
    private func waitForMenuClosedAndReady(timeout: TimeInterval) throws -> AXUIElement {
        var consecutiveClosedObservations = 0
        var readyItem: AXUIElement?
        try waitUntil(
            timeout: timeout,
            failure: "menu-bar status item did not settle after closing"
        ) {
            guard currentMenuRoots().isEmpty,
            let candidate = currentStatusItem(),
            AXTree.boolean(kAXExpandedAttribute as String, candidate) != true,
            AXTree.boolean(kAXEnabledAttribute as String, candidate) != false,
            AXTree.actionNames(candidate).contains(kAXPressAction as String)
            else {
                consecutiveClosedObservations = 0
                readyItem = nil
                return false
            }
            consecutiveClosedObservations += 1
            readyItem = candidate
            return consecutiveClosedObservations >= 2
        }
        return readyItem!
    }

    /// SwiftUI republishes the MenuBarExtra accessibility subtree while the 1,000-item feed
    /// filters, restores, and scrolls. Any `AXUIElement` root captured before one of those
    /// republishes is dead, and querying a dead root yields no descendants. Resolving roots
    /// freshly for every observation is therefore mandatory, and an empty root set must never
    /// satisfy a predicate — otherwise a negative assertion such as "the filtered row is gone"
    /// would pass vacuously against a subtree that is merely mid-republish.
    private func waitForMenuFeed(
        timeout: TimeInterval,
        failure: String,
        condition: ([AXUIElement]) -> Bool
    ) throws {
        do {
            try waitUntil(timeout: timeout, failure: failure) {
                let roots = currentMenuRoots()
                guard !roots.isEmpty else { return false }
                return condition(roots)
            }
        } catch let error as AcceptanceFailure {
            guard currentMenuRoots().isEmpty else { throw error }
            throw AcceptanceFailure(
                description: "menu-bar window disappeared during the 1,000-item journey before: \(failure)"
            )
        }
    }

    /// Resolves the live menu subtree for an assertion that is evaluated outside `waitUntil`.
    /// Never returns an empty root set, so callers cannot assert against a dead subtree.
    private func requireLiveMenuRoots(_ failure: String) throws -> [AXUIElement] {
        var roots: [AXUIElement] = []
        try waitUntil(timeout: 5, failure: failure) {
            roots = currentMenuRoots()
            return !roots.isEmpty
        }
        return roots
    }

    private func verifyThousandItemMenu(appRoot: AXUIElement) throws {
        let menuRoots = try requireLiveMenuRoots("menu closed before the 1,000-item journey began")
        let search = try requiredElement(
            in: menuRoots,
            identifier: "uiAcceptance.menu.search",
            failure: "menu search field is missing"
        )
        // Activating the accessory process can dismiss its transient MenuBarExtra when another
        // app owns a full-screen Space. The AX field is already actionable in the open menu, so
        // focus and edit it in place without changing application activation.
        try AXTree.setFocused(true, on: search)
        try AXTree.setValue("Acceptance clip 1001", on: search)
        try AXTree.pressReturn()
        try waitForMenuFeed(timeout: 3, failure: "menu search field did not accept fixture query") { roots in
            guard let currentSearch = AXTree.first(
                in: roots,
                identifier: "uiAcceptance.menu.search"
            ) else { return false }
            return AXTree.string(kAXValueAttribute as String, currentSearch)
                == "Acceptance clip 1001"
        }
        let searchedID = "uiAcceptance.menu.copy.00000000-0000-0000-0000-000000001001"
        try waitForMenuFeed(timeout: 8, failure: "fixture row 1001 was not reachable through menu search") { roots in
            AXTree.first(in: roots, identifier: searchedID) != nil
        }
        let currentSearch = try requiredElement(
            in: try requireLiveMenuRoots("menu search field disappeared after filtering"),
            identifier: "uiAcceptance.menu.search",
            failure: "menu search field disappeared after filtering"
        )
        try AXTree.setFocused(true, on: currentSearch)
        try AXTree.setValue("", on: currentSearch)
        try waitForMenuFeed(timeout: 3, failure: "menu search field did not clear") { roots in
            guard let refreshedSearch = AXTree.first(
                in: roots,
                identifier: "uiAcceptance.menu.search"
            ) else { return false }
            return AXTree.string(kAXValueAttribute as String, refreshedSearch)?.isEmpty == true
        }
        let pinnedID = "uiAcceptance.menu.copy.00000000-0000-0000-0000-000000009001"
        let firstRecentID = "uiAcceptance.menu.copy.00000000-0000-0000-0000-000000000001"
        // The filtered row must be gone AND both feed anchors present in the *same* observation
        // of the *same* live subtree; evaluating them against separate fetches would let a
        // republish satisfy the negative clause while the positive clauses read a different tree.
        try waitForMenuFeed(timeout: 8, failure: "menu did not restore its configured 1,000-item feed") { roots in
            AXTree.first(in: roots, identifier: searchedID) == nil
                && AXTree.first(in: roots, identifier: pinnedID) != nil
                && AXTree.first(in: roots, identifier: firstRecentID) != nil
        }
        let restoredRoots = try requireLiveMenuRoots(
            "menu-bar window disappeared before the pinned-order assertion"
        )
        guard AXTree.first(in: restoredRoots, identifier: pinnedID) != nil else {
            throw AcceptanceFailure(description: "pinned item was not first in the 1,000-item budget")
        }
        guard AXTree.appearsBefore(
            identifier: pinnedID,
            than: firstRecentID,
            in: restoredRoots
        ) else {
            throw AcceptanceFailure(description: "pinned item did not precede Recent in the AX order")
        }

        // Scroll controls belong to the same republished subtree as the rows, so they are
        // re-resolved from freshly fetched roots on every iteration. Writing to a control
        // captured before a republish silently no-ops and burns the whole scroll budget.
        func verticalScrollBar(in roots: [AXUIElement]) -> AXUIElement? {
            AXTree.first(in: roots, where: { node in
                node.role == kAXScrollBarRole as String
                    && AXTree.string(kAXOrientationAttribute as String, node.element)
                        == kAXVerticalOrientationValue as String
            })
        }
        func scrollArea(in roots: [AXUIElement]) -> AXUIElement? {
            AXTree.first(in: roots, where: { node in
                node.role == kAXScrollAreaRole as String
            })
        }
        let scrollSurfaceRoots = try requireLiveMenuRoots(
            "menu-bar window disappeared before the scroll journey"
        )
        guard verticalScrollBar(in: scrollSurfaceRoots) != nil
            || scrollArea(in: scrollSurfaceRoots) != nil
        else {
            throw AcceptanceFailure(description: "1,000-item menu has no accessible scroll surface")
        }
        let finalVisibleID = "uiAcceptance.menu.copy.00000000-0000-0000-0000-000000000999"
        var reachedFinalItem = false
        for _ in 0 ..< 60 {
            // One fetch per iteration drives both the scroll write and the arrival check, so
            // the row lookup always reads the subtree that was actually scrolled.
            let roots = currentMenuRoots()
            guard !roots.isEmpty else {
                RunLoop.current.run(until: Date().addingTimeInterval(0.15))
                continue
            }
            if let bar = verticalScrollBar(in: roots) {
                try AXTree.setValue(1.0, on: bar)
            }
            // SwiftUI can expose a writable AXScrollBar whose value changes before its lazy
            // rows materialize. Send a real wheel event to the same live menu surface as well.
            if let area = scrollArea(in: roots) {
                try AXTree.scroll(lines: -120, on: area)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            if AXTree.first(in: roots, identifier: finalVisibleID) != nil
                || AXTree.first(in: currentMenuRoots(), identifier: finalVisibleID) != nil {
                reachedFinalItem = true
                break
            }
        }
        guard reachedFinalItem else {
            throw AcceptanceFailure(description: "menu could not scroll to its 1,000th configured item")
        }
        let budgetRoots = try requireLiveMenuRoots(
            "menu-bar window disappeared before the 1,000-item budget assertion"
        )
        for excludedIndex in [1_000, 1_001] {
            let excludedID = String(
                format: "uiAcceptance.menu.copy.00000000-0000-0000-0000-%012d",
                excludedIndex
            )
            guard AXTree.first(in: budgetRoots, identifier: excludedID) == nil else {
                throw AcceptanceFailure(description: "menu exceeded its 1,000-item budget")
            }
        }
        let resetRoots = currentMenuRoots()
        if let bar = verticalScrollBar(in: resetRoots) {
            try AXTree.setValue(0.0, on: bar)
        } else if let area = scrollArea(in: resetRoots) {
            try AXTree.scroll(lines: 2_000, on: area)
        }
        try pass("menu-1000-items-search-and-scroll")
    }

    private func verifyRunScopedPasteboard(
        statusItem: AXUIElement,
        appRoot: AXUIElement
    ) throws {
        try revealFirstMenuClip(appRoot: appRoot)
        let firstClipID = "uiAcceptance.menu.copy.00000000-0000-0000-0000-000000000001"
        let copyButton = try requiredElement(
            in: currentApplicationRoots(),
            identifier: firstClipID,
            failure: "first fixture clip copy action disappeared before pasteboard verification"
        )
        guard let pasteboardName = AXTree.string(kAXValueAttribute as String, copyButton),
              !pasteboardName.isEmpty
        else {
            throw AcceptanceFailure(description: "acceptance copy action did not disclose its run-scoped pasteboard")
        }
        let isolatedPasteboard = NSPasteboard(name: NSPasteboard.Name(pasteboardName))
        let generalChangeCount = NSPasteboard.general.changeCount
        try AXTree.perform(kAXPressAction as String, on: copyButton)
        try waitUntil(timeout: 5, failure: "fixture copy did not reach the run-scoped pasteboard") {
            isolatedPasteboard.string(forType: .string)
                == "Email Sarah at sarah@example.com tomorrow at 2 PM — acceptance clip 0001"
        }
        guard NSPasteboard.general.changeCount == generalChangeCount else {
            throw AcceptanceFailure(description: "acceptance copy unexpectedly changed the user's General pasteboard")
        }
        try closeMenu(statusItem: statusItem, appRoot: appRoot)
        try pass("menu-copy-writes-run-scoped-production-pasteboard")
    }

    private func verifySettingsFromMenu(
        statusItem: AXUIElement,
        appRoot: AXUIElement
    ) throws {
        try openSettingsFromMenu(statusItem: statusItem, appRoot: appRoot)
        _ = try requiredElement(
            in: currentApplicationRoots(),
            identifier: "uiAcceptance.settings.menuBarClipLimit",
            failure: "Settings is missing the menu-bar clip limit field"
        )
        let expectedLimits = [1, 100, 1_000]
        for (index, expected) in expectedLimits.enumerated() {
            try setSettingsClipLimitDraft(expected)
            try closeSettings(appRoot: appRoot)
            try verifyRenderedMenuLimit(
                expected,
                statusItem: statusItem,
                appRoot: appRoot
            )
            try openSettingsFromMenu(statusItem: statusItem, appRoot: appRoot)
            try waitForPersistedSettingsClipLimit(expected)
            if index == expectedLimits.count - 1 { try closeSettings(appRoot: appRoot) }
        }
        try pass("menu-settings-entry-and-1-100-1000-limits")
    }

    /// Set a fresh field value and prove the rendered draft exactly matches before closing.
    /// The product deliberately commits on disappearance as well as Return/focus loss, so the
    /// caller closes Settings, verifies the rendered menu budget, and reopens Settings to prove
    /// both model persistence surfaces. This avoids treating a stale field AXValue as success.
    private func setSettingsClipLimitDraft(_ expected: Int) throws {
        let field = try requiredElement(
            in: currentApplicationRoots(),
            identifier: "uiAcceptance.settings.menuBarClipLimit",
            failure: "Settings lost the menu-bar clip limit field"
        )
        try activateAcceptanceApplication()
        try AXTree.setFocused(true, on: field)
        try AXTree.setValue(String(expected), on: field)
        try waitUntil(timeout: 3, failure: "clip limit draft did not accept \(expected)") {
            guard let currentField = AXTree.first(
                in: currentApplicationRoots(),
                identifier: "uiAcceptance.settings.menuBarClipLimit"
            ) else { return false }
            return AXTree.string(kAXValueAttribute as String, currentField) == String(expected)
        }
    }

    private func waitForPersistedSettingsClipLimit(_ expected: Int) throws {
        try waitUntil(timeout: 5, failure: "clip limit did not commit \(expected)") {
            settingsClipLimitAXState().provesCommitted(expected: expected)
        }
    }

    private func settingsClipLimitAXState() -> SettingsClipLimitAXState {
        let roots = currentApplicationRoots()
        let field = AXTree.first(
            in: roots,
            identifier: "uiAcceptance.settings.menuBarClipLimit"
        )
        let stepper = AXTree.first(in: roots, title: "Adjust clips shown")
        return SettingsClipLimitAXState(
            fieldValue: field.flatMap { AXTree.string(kAXValueAttribute as String, $0) },
            stepperValue: stepper.flatMap { AXTree.string(kAXValueAttribute as String, $0) }
        )
    }

    private func activateAcceptanceApplication() throws {
        guard let process,
              let application = NSRunningApplication(processIdentifier: process.processIdentifier),
              application.activate(options: [.activateAllWindows])
        else {
            throw AcceptanceFailure(description: "could not activate the acceptance application")
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }

    private func openSettingsFromMenu(
        statusItem: AXUIElement,
        appRoot: AXUIElement
    ) throws {
        try openMenu(statusItem: statusItem, appRoot: appRoot)
        try press(
            identifier: "uiAcceptance.menu.controls",
            in: currentApplicationRoots(),
            failure: "menu settings control is missing"
        )
        try press(
            title: "Settings…",
            in: [AXUIElementCreateSystemWide()] + currentApplicationRoots(),
            failure: "menu settings control did not expose Settings"
        )
        try waitUntil(timeout: 10, failure: "Settings from menu bar did not open") {
            settingsWindow() != nil
        }
    }

    private func closeSettings(appRoot: AXUIElement) throws {
        guard let window = settingsWindow(),
              let closeButton = AXTree.first(in: [window], where: { node in
                node.subrole == "AXCloseButton"
              })
        else {
            throw AcceptanceFailure(description: "Settings window has no close button")
        }
        try AXTree.perform(kAXPressAction as String, on: closeButton)
        try waitUntil(timeout: 5, failure: "Settings window did not close") {
            settingsWindow() == nil
        }
    }

    private func verifyRenderedMenuLimit(
        _ limit: Int,
        statusItem: AXUIElement,
        appRoot: AXUIElement
    ) throws {
        try openMenu(statusItem: statusItem, appRoot: appRoot)
        let includedIndex = limit == 1 ? 9_001 : limit - 1
        let excludedIndex = limit == 1 ? 1 : limit
        let includedID = String(
            format: "uiAcceptance.menu.copy.00000000-0000-0000-0000-%012d",
            includedIndex
        )
        let excludedID = String(
            format: "uiAcceptance.menu.copy.00000000-0000-0000-0000-%012d",
            excludedIndex
        )
        if limit > 1 {
            let scrollBar = menuVerticalScrollBar()
            let scrollArea = menuScrollArea()
            guard scrollBar != nil || scrollArea != nil else {
                throw AcceptanceFailure(description: "menu limit \(limit) has no accessible scroll surface")
            }
            for _ in 0 ..< 30 {
                if let scrollBar {
                    try AXTree.setValue(1.0, on: scrollBar)
                } else if let scrollArea {
                    try AXTree.scroll(lines: -2_000, on: scrollArea)
                }
                RunLoop.current.run(until: Date().addingTimeInterval(0.15))
                if AXTree.first(in: currentMenuRoots(), identifier: includedID) != nil { break }
            }
        }
        try waitUntil(timeout: 8, failure: "menu limit \(limit) did not render its final item") {
            AXTree.first(in: currentMenuRoots(), identifier: includedID) != nil
        }
        guard AXTree.first(in: currentMenuRoots(), identifier: excludedID) == nil else {
            throw AcceptanceFailure(description: "menu limit \(limit) rendered an item beyond its budget")
        }
        try closeMenu(statusItem: statusItem, appRoot: appRoot)
    }

    private func verifyMenuContinuationJourneys(
        statusItem: AXUIElement,
        appRoot: AXUIElement
    ) throws {
        try openMenu(statusItem: statusItem, appRoot: appRoot)
        try press(
            identifier: "uiAcceptance.menu.newNote",
            in: currentApplicationRoots(),
            failure: "New Note is missing from menu bar"
        )
        try waitUntil(timeout: 10, failure: "New Note did not survive menu dismissal") {
            AXTree.first(
                in: currentSheetRoots(),
                identifier: "uiAcceptance.noteEditor.title"
            ) != nil
        }
        try assertConsoleHasNoForbiddenDiagnostics()
        let noteTitle = try requiredElement(
            in: currentSheetRoots(),
            identifier: "uiAcceptance.noteEditor.title",
            failure: "New Note title field is missing"
        )
        try activateAcceptanceApplication()
        try AXTree.setFocused(true, on: noteTitle)
        try AXTree.setValue("Acceptance Created Note", on: noteTitle)
        let noteBody = try requiredElement(
            in: currentSheetRoots(),
            identifier: "uiAcceptance.noteEditor.body",
            failure: "New Note body field is missing"
        )
        try AXTree.setFocused(true, on: noteBody)
        try AXTree.setValue("Created through the packaged menu continuation.", on: noteBody)
        let noteSave = try waitForEnabledElement(
            identifier: "uiAcceptance.noteEditor.save",
            in: currentSheetRoots,
            timeout: 5,
            failure: "New Note create action did not become enabled after editing"
        )
        try AXTree.perform(kAXPressAction as String, on: noteSave)
        try waitUntil(timeout: 8, failure: "New Note did not save and dismiss") {
            AXTree.first(
                in: currentSheetRoots(),
                identifier: "uiAcceptance.noteEditor.title"
            ) == nil
        }
        try waitUntil(timeout: 8, failure: "created note did not appear in Library") {
            AXTree.first(in: currentLibraryRoots(), title: "Acceptance Created Note") != nil
        }
        try pass("menu-new-note-persistent-continuation-and-save")

        // Saving from the dedicated continuation intentionally reveals Library. Close that
        // verified destination before returning to the status item so the next journey tests
        // the menu-bar surface itself instead of depending on AppKit's active regular-window
        // menu transition.
        try closeLibraryWindow()

        try openMenu(statusItem: statusItem, appRoot: appRoot)
        try revealFirstMenuClip(appRoot: appRoot)
        try press(
            identifier: "uiAcceptance.menu.more.00000000-0000-0000-0000-000000000001",
            in: currentApplicationRoots(),
            failure: "first menu clip has no More actions control"
        )
        try press(
            title: "Edit a Saved Copy…",
            in: [AXUIElementCreateSystemWide()] + currentApplicationRoots(),
            failure: "menu clip actions are missing Edit a Saved Copy"
        )
        try waitUntil(timeout: 10, failure: "Edit Clip did not survive menu dismissal") {
            AXTree.first(
                in: currentSheetRoots(),
                identifier: "uiAcceptance.clipEditor.title"
            ) != nil
        }
        let clipTitle = try requiredElement(
            in: currentSheetRoots(),
            identifier: "uiAcceptance.clipEditor.title",
            failure: "Edit Clip title field is missing"
        )
        try activateAcceptanceApplication()
        try AXTree.setFocused(true, on: clipTitle)
        try AXTree.setValue("Acceptance Edited Saved Copy", on: clipTitle)
        let clipBody = try requiredElement(
            in: currentSheetRoots(),
            identifier: "uiAcceptance.clipEditor.body",
            failure: "Edit Clip body field is missing"
        )
        try AXTree.setFocused(true, on: clipBody)
        try AXTree.setValue("Edited through the packaged menu continuation.", on: clipBody)
        let clipSave = try waitForEnabledElement(
            identifier: "uiAcceptance.clipEditor.save",
            in: currentSheetRoots,
            timeout: 5,
            failure: "Edit Clip save action did not become enabled after editing"
        )
        try AXTree.perform(kAXPressAction as String, on: clipSave)
        try waitUntil(timeout: 8, failure: "Edit Clip did not save and dismiss") {
            AXTree.first(
                in: currentSheetRoots(),
                identifier: "uiAcceptance.clipEditor.title"
            ) == nil
        }
        try waitUntil(timeout: 8, failure: "edited saved copy did not appear in Library") {
            AXTree.first(in: currentLibraryRoots(), title: "Acceptance Edited Saved Copy") != nil
        }
        try pass("menu-edit-clip-persistent-continuation-and-save")

        try closeLibraryWindow()

        try openMenu(statusItem: statusItem, appRoot: appRoot)
        try revealFirstMenuClip(appRoot: appRoot)
        try press(
            identifier: "uiAcceptance.menu.useAI.00000000-0000-0000-0000-000000000001",
            in: currentApplicationRoots(),
            failure: "Use AI is missing from the first menu clip"
        )
        try waitUntil(timeout: 10, failure: "Use AI did not survive menu dismissal") {
            AXTree.first(
                in: currentSheetRoots(),
                identifier: "uiAcceptance.assistant.prompt"
            ) != nil
        }
        for title in ["Ask", "Extract details", "Rewrite", "Format", "Draft follow-up", "Research"] {
            guard AXTree.first(in: currentSheetRoots(), title: title) != nil else {
                throw AcceptanceFailure(description: "Assistant preset is missing: \(title)")
            }
        }
        guard AXTree.first(in: currentSheetRoots(), identifier: "uiAcceptance.assistant.prompt") != nil else {
            throw AcceptanceFailure(description: "Assistant prompt composer is missing")
        }
        let rewrite = try requiredElement(
            in: currentSheetRoots(),
            title: "Rewrite",
            failure: "Assistant Rewrite preset is not actionable"
        )
        try AXTree.performAllowingObservedGenericFailure(
            kAXPressAction as String,
            on: rewrite
        )
        let prompt = try requiredElement(
            in: currentSheetRoots(),
            identifier: "uiAcceptance.assistant.prompt",
            failure: "Assistant prompt composer disappeared after selecting Rewrite"
        )
        try waitUntil(timeout: 3, failure: "Rewrite did not populate the prompt without sending") {
            AXTree.string(kAXValueAttribute as String, prompt)
                == "Rewrite this clip for clarity while preserving its meaning."
        }
        let closeAssistant = try requiredElement(
            in: currentSheetRoots(),
            title: "Close Assistant",
            failure: "Assistant has no close control"
        )
        try AXTree.performAllowingObservedGenericFailure(
            kAXPressAction as String,
            on: closeAssistant
        )
        try waitUntil(timeout: 5, failure: "Assistant close control did not dismiss the sheet") {
            AXTree.first(
                in: currentSheetRoots(),
                identifier: "uiAcceptance.assistant.prompt"
            ) == nil
        }
        try pass("menu-ai-persistent-continuation-rewrite-without-send")

        try verifyNewFolderContinuation(statusItem: statusItem, appRoot: appRoot)
        try verifyShortcutContinuation(statusItem: statusItem, appRoot: appRoot)
        try verifyDeveloperProjectContinuation(statusItem: statusItem, appRoot: appRoot)
        try verifyCalendarReviewContinuation(statusItem: statusItem, appRoot: appRoot)
        try verifyFlowReviewContinuation(statusItem: statusItem, appRoot: appRoot)
        try verifyExportPanelContinuation(statusItem: statusItem, appRoot: appRoot)
    }

    private func verifyNewFolderContinuation(
        statusItem: AXUIElement,
        appRoot: AXUIElement
    ) throws {
        try openMoreActions(
            clipIndex: 1,
            statusItem: statusItem,
            appRoot: appRoot,
            revealRecentClip: true
        )
        try press(
            title: "Save to Folder",
            in: [AXUIElementCreateSystemWide()] + currentApplicationRoots(),
            failure: "history clip is missing Save to Folder"
        )
        try press(
            title: "New Folder…",
            in: [AXUIElementCreateSystemWide()] + currentApplicationRoots(),
            failure: "Save to Folder is missing New Folder"
        )
        try waitForSheet(title: "New Folder", failure: "New Folder did not survive menu dismissal")
        try press(title: "Cancel", in: currentSheetRoots(), failure: "New Folder has no Cancel button")
        try waitForSheetDismissal(title: "New Folder", failure: "New Folder did not cancel")
        try pass("menu-new-folder-persistent-continuation-cancel")
    }

    private func verifyShortcutContinuation(
        statusItem: AXUIElement,
        appRoot: AXUIElement
    ) throws {
        try openMoreActions(
            clipIndex: 9_001,
            statusItem: statusItem,
            appRoot: appRoot,
            revealRecentClip: false
        )
        try press(
            title: "Set Shortcut…",
            in: [AXUIElementCreateSystemWide()] + currentApplicationRoots(),
            failure: "saved note is missing Set Shortcut"
        )
        try waitForSheet(title: "Set Shortcut", failure: "Set Shortcut did not survive menu dismissal")
        try press(title: "Cancel", in: currentSheetRoots(), failure: "Set Shortcut has no Cancel button")
        try waitForSheetDismissal(title: "Set Shortcut", failure: "Set Shortcut did not cancel")
        try pass("menu-shortcut-persistent-continuation-cancel")
    }

    private func verifyDeveloperProjectContinuation(
        statusItem: AXUIElement,
        appRoot: AXUIElement
    ) throws {
        try openMoreActions(
            clipIndex: 1,
            statusItem: statusItem,
            appRoot: appRoot,
            revealRecentClip: true
        )
        for (title, failure) in [
            ("Clip Tools", "history clip is missing Clip Tools"),
            ("Add to Project", "Clip Tools is missing Add to Project"),
            ("New Project…", "Add to Project is missing New Project"),
        ] {
            try press(
                title: title,
                in: [AXUIElementCreateSystemWide()] + currentApplicationRoots(),
                failure: failure
            )
        }
        try waitForSheet(title: "New Project", failure: "New Project did not survive menu dismissal")
        try press(title: "Cancel", in: currentSheetRoots(), failure: "New Project has no Cancel button")
        try waitForSheetDismissal(title: "New Project", failure: "New Project did not cancel")
        try pass("menu-new-project-persistent-continuation-cancel")
    }

    private func verifyCalendarReviewContinuation(
        statusItem: AXUIElement,
        appRoot: AXUIElement
    ) throws {
        try openMoreActions(
            clipIndex: 1,
            statusItem: statusItem,
            appRoot: appRoot,
            revealRecentClip: true
        )
        try press(
            title: "Quick Actions",
            in: [AXUIElementCreateSystemWide()] + currentApplicationRoots(),
            failure: "dated clip is missing Quick Actions"
        )
        try press(
            title: "Add to Calendar…",
            in: [AXUIElementCreateSystemWide()] + currentApplicationRoots(),
            failure: "dated clip is missing Add to Calendar"
        )
        try waitForSheet(title: "Add to Calendar", failure: "Calendar review did not survive menu dismissal")
        try press(title: "Cancel", in: currentSheetRoots(), failure: "Calendar review has no Cancel button")
        try waitForSheetDismissal(title: "Add to Calendar", failure: "Calendar review did not cancel")
        try pass("menu-calendar-review-persistent-continuation-cancel-before-tcc")
    }

    private func verifyFlowReviewContinuation(
        statusItem: AXUIElement,
        appRoot: AXUIElement
    ) throws {
        try openMoreActions(
            clipIndex: 9_001,
            statusItem: statusItem,
            appRoot: appRoot,
            revealRecentClip: false
        )
        try press(
            title: "Actions",
            in: [AXUIElementCreateSystemWide()] + currentApplicationRoots(),
            failure: "saved note is missing Actions"
        )
        try press(
            title: "Acceptance Review Flow",
            in: [AXUIElementCreateSystemWide()] + currentApplicationRoots(),
            failure: "acceptance fixture flow is missing from Actions"
        )
        try waitForSheet(title: "Run custom action?", failure: "flow review did not survive menu dismissal")
        try press(title: "Cancel", in: currentSheetRoots(), failure: "flow review has no Cancel button")
        try waitForSheetDismissal(title: "Run custom action?", failure: "flow review did not cancel")
        try pass("menu-flow-review-persistent-continuation-cancel")
    }

    private func verifyExportPanelContinuation(
        statusItem: AXUIElement,
        appRoot: AXUIElement
    ) throws {
        try openMoreActions(
            clipIndex: 1,
            statusItem: statusItem,
            appRoot: appRoot,
            revealRecentClip: true
        )
        try press(
            title: "Export Clip…",
            in: [AXUIElementCreateSystemWide()] + currentApplicationRoots(),
            failure: "ordinary history clip is missing Export Clip"
        )
        // NSSavePanel does not surface its `title` string through the accessibility
        // tree on current macOS (the window is titled-style but renders no title
        // text), so a window-title match against "Export Clip" can never succeed
        // even when a real panel is on screen. Detect presentation by the panel's
        // own Cancel/prompt buttons instead, which is what we press below anyway.
        try waitUntil(timeout: 10, failure: "Export Clip did not present its system save panel") {
            nativeExportSavePanelPresent()
        }
        try press(
            title: "Cancel",
            in: currentApplicationRoots(),
            failure: "Export Clip system panel has no Cancel button"
        )
        try waitUntil(timeout: 5, failure: "Export Clip system panel did not cancel") {
            !nativeExportSavePanelPresent()
        }
        try pass("menu-export-system-panel-presentation-and-cancel")
    }

    /// A real `NSSavePanel` presented from `exportOrdinaryClip` always pairs a
    /// "Cancel" button with a prompt button matching `panel.prompt` ("Export").
    /// That pairing is a native save-panel signature the app's own SwiftUI
    /// sheets never reproduce, so it distinguishes a genuine system panel
    /// without relying on the (unrendered) window title.
    private func nativeExportSavePanelPresent() -> Bool {
        let roots = currentApplicationRoots()
        return AXTree.first(in: roots, title: "Cancel") != nil
            && AXTree.first(in: roots, title: "Export") != nil
    }

    private func openMoreActions(
        clipIndex: Int,
        statusItem: AXUIElement,
        appRoot: AXUIElement,
        revealRecentClip: Bool
    ) throws {
        try openMenu(statusItem: statusItem, appRoot: appRoot)
        if revealRecentClip { try revealFirstMenuClip(appRoot: appRoot) }
        if clipIndex == 9_001 {
            let roots = try requireLiveMenuRoots(
                "menu-bar window disappeared before locating the pinned acceptance note"
            )
            let search = try requiredElement(
                in: roots,
                identifier: "uiAcceptance.menu.search",
                failure: "menu search disappeared before locating the pinned acceptance note"
            )
            try AXTree.setFocused(true, on: search)
            try AXTree.setValue("Acceptance Editable Note", on: search)
            try AXTree.pressReturn()
            try waitForMenuFeed(
                timeout: 8,
                failure: "pinned acceptance note did not appear in menu search"
            ) { roots in
                AXTree.first(
                    in: roots,
                    identifier: "uiAcceptance.menu.copy.00000000-0000-0000-0000-000000009001"
                ) != nil
            }
        }
        let menuRoots = try requireLiveMenuRoots(
            "menu-bar window disappeared before opening More for clip \(clipIndex)"
        )
        let identifier = String(
            format: "uiAcceptance.menu.more.00000000-0000-0000-0000-%012d",
            clipIndex
        )
        try press(
            identifier: identifier,
            in: menuRoots,
            failure: "clip \(clipIndex) has no More actions control"
        )
    }

    private func waitForSheet(title: String, failure: String) throws {
        try waitUntil(timeout: 10, failure: failure) {
            AXTree.first(in: currentSheetRoots(), title: title) != nil
        }
    }

    private func waitForSheetDismissal(title: String, failure: String) throws {
        try waitUntil(timeout: 5, failure: failure) {
            AXTree.first(in: currentSheetRoots(), title: title) == nil
        }
    }

    private func revealFirstMenuClip(appRoot: AXUIElement) throws {
        let firstClipIdentifier = "uiAcceptance.menu.copy.00000000-0000-0000-0000-000000000001"
        if AXTree.first(in: currentMenuRoots(), identifier: firstClipIdentifier) != nil {
            return
        }
        // After prior journeys the virtualized menu can reopen at its old scroll position without
        // exposing a writable scroll bar. Use the product's real search control to reveal the
        // deterministic fixture before falling back to scrolling.
        let searchRoots = try requireLiveMenuRoots("menu closed while locating clip 1")
        let search = AXTree.first(
            in: searchRoots,
            identifier: "uiAcceptance.menu.search"
        )
        if let search {
            try AXTree.setFocused(true, on: search)
            try AXTree.setValue("Acceptance clip 0001", on: search)
            try AXTree.pressReturn()
            let searchDeadline = Date().addingTimeInterval(5)
            repeat {
                if AXTree.first(in: currentMenuRoots(), identifier: firstClipIdentifier) != nil { return }
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            } while Date() < searchDeadline
            if let refreshedSearch = AXTree.first(
                in: currentMenuRoots(),
                identifier: "uiAcceptance.menu.search"
            ) {
                try AXTree.setValue("", on: refreshedSearch)
            }
        }
        guard !currentMenuRoots().isEmpty else {
            throw AcceptanceFailure(description: "menu closed while locating clip 1")
        }
        for _ in 0 ..< 30 {
            let roots = currentMenuRoots()
            guard !roots.isEmpty else {
                RunLoop.current.run(until: Date().addingTimeInterval(0.15))
                continue
            }
            if AXTree.first(in: roots, identifier: firstClipIdentifier) != nil { return }
            let scrollBar = AXTree.first(in: roots, where: { node in
                node.role == kAXScrollBarRole as String
                    && AXTree.string(kAXOrientationAttribute as String, node.element)
                        == kAXVerticalOrientationValue as String
            })
            let scrollArea = AXTree.first(in: roots, where: { node in
                node.role == kAXScrollAreaRole as String
            })
            guard scrollBar != nil || scrollArea != nil else {
                RunLoop.current.run(until: Date().addingTimeInterval(0.15))
                continue
            }
            if let scrollBar {
                try AXTree.setValue(0.0, on: scrollBar)
            }
            if let scrollArea {
                try AXTree.scroll(lines: 2_000, on: scrollArea)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            if AXTree.first(in: currentMenuRoots(), identifier: firstClipIdentifier) != nil { return }
        }
        try waitUntil(timeout: 8, failure: "menu did not scroll back to clip 1") {
            AXTree.first(in: currentMenuRoots(), identifier: firstClipIdentifier) != nil
        }
    }

    private func menuVerticalScrollBar() -> AXUIElement? {
        AXTree.first(in: currentMenuRoots(), where: { node in
            node.role == kAXScrollBarRole as String
                && AXTree.string(kAXOrientationAttribute as String, node.element)
                    == kAXVerticalOrientationValue as String
        })
    }

    private func menuScrollArea() -> AXUIElement? {
        AXTree.first(in: currentMenuRoots(), where: { node in
            node.role == kAXScrollAreaRole as String
        })
    }

    /// Retained continuation and Library windows can keep offscreen MenuBarExtra descendants in
    /// the app's AX tree. Prefer AX's front-to-back window order and require the menu's unique
    /// search anchor. MenuBarExtra is not consistently reported as AXFocusedWindow on macOS, so
    /// focused-window-only lookup would reject a genuinely open menu.
    private func currentMenuRoots() -> [AXUIElement] {
        guard let applicationRoot = currentApplicationRoots().first else { return [] }
        return Array(AXTree.windowRoots(in: applicationRoot).lazy.filter { window in
            // A retained Library/Settings/continuation window can expose thousands of
            // descendants while the menu is closed. The transient menu is the only
            // candidate we need here; exclude known persistent hosts before traversal.
            let identifier = AXTree.string(kAXIdentifierAttribute as String, window)
            let title = AXTree.string(kAXTitleAttribute as String, window)
            guard identifier != "library",
                  identifier != "com_apple_SwiftUI_Settings_window",
                  identifier != "uiAcceptance.menuBarContinuation.window",
                  title != "Clipboard Router",
                  title != "Clipboard Router Settings" else { return false }
            return AXTree.boolean(kAXMinimizedAttribute as String, window) != true
                && AXTree.firstLibraryControl(
                    in: [window],
                    identifier: "uiAcceptance.menu.search"
                ) != nil
        }.prefix(1))
    }

    private func verifyLibraryJourneys(
        statusItem: AXUIElement,
        appRoot: AXUIElement
    ) throws {
        try openMenu(statusItem: statusItem, appRoot: appRoot)
        try press(
            identifier: "uiAcceptance.menu.openLibrary",
            in: currentApplicationRoots(),
            failure: "Open Library is missing from menu bar"
        )
        try waitUntil(timeout: 10, failure: "Open Library did not expose a persistent Library window") {
            !currentLibraryRoots().isEmpty
        }
        for title in ["Actions", "Auto Organize", "Projects"] {
            guard AXTree.first(in: currentLibraryRoots(), title: title) != nil else {
                throw AcceptanceFailure(description: "Library sidebar entry is missing: \(title)")
            }
        }
        try pass("library-desktop-window-and-sidebar")

        let firstRowID = "uiAcceptance.library.clip.00000000-0000-0000-0000-000000000001"
        let historyDestination = try requiredElement(
            in: currentLibraryRoots(),
            identifier: "uiAcceptance.library.history",
            failure: "Library has no accessible History destination"
        )
        try AXTree.activateSelectableElement(historyDestination)
        let librarySearch = try requiredElement(
            in: currentLibraryRoots(),
            identifier: "uiAcceptance.library.search",
            failure: "Library search field is missing"
        )
        try activateAcceptanceApplication()
        try AXTree.setFocused(true, on: librarySearch)
        try AXTree.setValue("sarah@example.com", on: librarySearch)
        try AXTree.pressReturn()
        let secondRowID = "uiAcceptance.library.clip.00000000-0000-0000-0000-000000000002"
        try waitUntil(timeout: 8, failure: "Library did not filter to the first fixture clip") {
            AXTree.first(in: currentLibraryRoots(), identifier: firstRowID) != nil
                && AXTree.first(in: currentLibraryRoots(), identifier: secondRowID) == nil
        }
        let firstRowMarker = try requiredElement(
            in: currentLibraryRoots(),
            identifier: firstRowID,
            failure: "first fixture clip is missing in Library"
        )
        try activateAcceptanceApplication()
        try AXTree.activateSelectableElement(firstRowMarker)
        try waitUntil(timeout: 5, failure: "first fixture clip did not become selected") {
            AXTree.first(
                in: currentLibraryRoots(),
                identifier: "uiAcceptance.library.selected.00000000-0000-0000-0000-000000000001"
            ) != nil
        }
        _ = try requiredElement(
            in: currentLibraryRoots(),
            identifier: "uiAcceptance.library.more",
            failure: "Library More menu did not appear for the selected fixture clip"
        )
        try press(
            identifier: "uiAcceptance.library.more",
            in: currentLibraryRoots(),
            failure: "Library More menu is missing"
        )
        try press(
            title: "Edit a Saved Copy…",
            in: [AXUIElementCreateSystemWide()] + currentApplicationRoots(),
            failure: "Library More menu is missing Edit a Saved Copy"
        )
        try waitUntil(timeout: 8, failure: "Edit Clip sheet did not open") {
            AXTree.first(
                in: currentSheetRoots(),
                identifier: "uiAcceptance.clipEditor.title"
            ) != nil
        }
        try press(
            title: "Cancel",
            in: currentSheetRoots(),
            failure: "Edit Clip has no Cancel button"
        )
        try pass("library-edit-clip")

        try press(
            identifier: "uiAcceptance.library.more",
            in: currentLibraryRoots(),
            failure: "Library More menu did not reopen"
        )
        try press(
            title: "Copy & Open…",
            in: [AXUIElementCreateSystemWide()] + currentApplicationRoots(),
            failure: "Library More menu is missing Copy & Open"
        )
        try waitUntil(timeout: 12, failure: "Copy & Open did not present the app browser") {
            AXTree.first(in: currentLibraryRoots(), title: "Copy & Open in App") != nil
        }
        guard AXTree.first(in: currentLibraryRoots(), title: "Search installed applications") != nil else {
            throw AcceptanceFailure(description: "app browser search field is missing")
        }
        try press(title: "Cancel", in: currentLibraryRoots(), failure: "app browser has no Cancel button")
        try pass("library-app-browser")

        try press(
            identifier: "uiAcceptance.library.openSettings",
            in: currentLibraryRoots(),
            failure: "Library sidebar Settings entry is missing"
        )
        try waitUntil(timeout: 10, failure: "Library Settings entry did not open Settings") {
            settingsWindow() != nil
        }
        let limit = try requiredElement(
            in: currentApplicationRoots(),
            identifier: "uiAcceptance.settings.menuBarClipLimit",
            failure: "Settings is missing the menu-bar clip limit field"
        )
        guard AXTree.string(kAXValueAttribute as String, limit) == "1000" else {
            throw AcceptanceFailure(description: "menu-bar clip limit did not render the fixture value 1000")
        }
        try pass("library-settings-entry-and-1000-limit")
    }

    private func verifyExpandedLocalInventory(
        statusItem: AXUIElement,
        appRoot: AXUIElement
    ) throws {
        if settingsWindow() != nil { try closeSettings(appRoot: appRoot) }
        try verifyRenderedActionParity(statusItem: statusItem, appRoot: appRoot)
        try verifyAssistantPresetsAndLocalBoundary()
        try verifyDeveloperProjectCreateAndActivate()
        try verifyLiveLinkPreviewStates()
        try verifySmartViewsCRUD()
        try runInventoryBoundary("custom-flow-follow-up-note") {
            try verifyCustomFlowValidationCreateRunAndReview()
        }
        try runInventoryBoundary("automatic-organization") {
            try verifyAutomaticOrganizationCRUDApplyAndUndo()
        }
        try runInventoryBoundary("sales-workspace-and-handoff") {
            try verifySalesWorkspaceTagAndHandoff()
        }
        try runInventoryBoundary("three-row-bulk-actions") {
            try verifyThreeRowBulkActions()
        }
        try runInventoryBoundary("debug-bundle-save-and-project-review") {
            try verifyDebugBundleSaveAndProjectReview()
        }
    }

    private func runInventoryBoundary(
        _ name: String,
        operation: () throws -> Void
    ) throws {
        do {
            try operation()
        } catch let failure as AcceptanceFailure {
            // Only a genuine external/environmental boundary (AcceptanceBoundaryPolicy) is
            // recorded as a non-failing boundary case so later independent inventory cases can
            // still run. Any product-caused failure — a wrong UI state, a missing element, a
            // forbidden AppKit diagnostic — is a hard failure and must propagate as one; it must
            // never be downgraded into boundaryCases/incomplete.
            guard AcceptanceBoundaryPolicy.permitsBoundary(failure, named: name) else { throw failure }
            try evidence.recordBoundary(name: name, error: failure.description)
            print("BOUNDARY \(name): \(failure.description)")
            try? AXTree.pressEscape()
        }
    }

    private func verifyRenderedActionParity(
        statusItem: AXUIElement,
        appRoot: AXUIElement
    ) throws {
        let menuBarHistoryActions = [
            "Save to Folder", "Pin & Save", "Edit a Saved Copy…", "Make Note…",
            "Share Clip…", "Export Clip…", "Quick Actions", "Copy & Open…",
            "Send to CRM…", "Clip Tools", "Delete",
        ]
        try openMoreActions(
            clipIndex: 1,
            statusItem: statusItem,
            appRoot: appRoot,
            revealRecentClip: true
        )
        // Opening the More menu is an AppKit transaction. The button press can succeed before
        // SwiftUI has attached the submenu items to the live AX tree, especially after the
        // preceding menu journeys have exercised the same virtualized surface. Wait for the
        // first canonical action before evaluating the complete inventory so a transiently
        // incomplete tree cannot be reported as a product action-parity failure.
        try waitUntil(
            timeout: 5,
            failure: "menu-bar history More menu did not finish rendering"
        ) {
            AXTree.first(
                in: [AXUIElementCreateSystemWide()] + currentApplicationRoots(),
                title: "Save to Folder"
            ) != nil
        }
        for title in ["Show in Library…"] + menuBarHistoryActions {
            guard AXTree.first(
                in: [AXUIElementCreateSystemWide()] + currentApplicationRoots(),
                title: title
            ) != nil else {
                throw AcceptanceFailure(description: "menu-bar history inventory is missing \(title)")
            }
        }
        try AXTree.pressEscape()

        let history = try requiredElement(
            in: currentLibraryRoots(),
            identifier: "uiAcceptance.library.history",
            failure: "Library History destination disappeared before parity verification"
        )
        try AXTree.activateSelectableElement(history)
        let search = try requiredElement(
            in: currentLibraryRoots(),
            identifier: "uiAcceptance.library.search",
            failure: "Library search disappeared before parity verification"
        )
        try AXTree.setFocused(true, on: search)
        try AXTree.setValue("sarah@example.com", on: search)
        try AXTree.pressReturn()
        try waitUntil(timeout: 8, failure: "history fixture did not render before Library parity verification") {
            AXTree.first(
                in: currentLibraryRoots(),
                identifier: "uiAcceptance.library.clip.00000000-0000-0000-0000-000000000001"
            ) != nil
        }
        let row = try requiredElement(
            in: currentLibraryRoots(),
            identifier: "uiAcceptance.library.clip.00000000-0000-0000-0000-000000000001",
            failure: "history fixture disappeared before Library parity verification"
        )
        try AXTree.activateSelectableElement(row)
        let more = try requiredElement(
            in: currentLibraryRoots(),
            identifier: "uiAcceptance.library.more",
            failure: "Library More is missing during parity verification"
        )
        guard let inventoryValue = AXTree.string(kAXValueAttribute as String, more) else {
            throw AcceptanceFailure(description: "Library More did not expose its ordered action inventory")
        }
        let inventory = try ClipActionInventoryEvidence.parse(inventoryValue)
        guard inventory.count >= 8,
              ClipActionInventoryEvidence.provesCanonicalOrder(inventory),
              Set(inventory.map(\.id)).count == inventory.count
        else {
            throw AcceptanceFailure(description: "Library action inventory is duplicated or out of canonical order")
        }
        try AXTree.perform(kAXPressAction as String, on: more)
        let libraryHistoryActions = menuBarHistoryActions.map {
            $0 == "Save to Folder" ? "Save to Folder…" : $0
        }
        try waitUntil(
            timeout: 5,
            failure: "Library history More menu did not finish rendering"
        ) {
            AXTree.first(
                in: [AXUIElementCreateSystemWide()] + currentApplicationRoots(),
                title: "Save to Folder…"
            ) != nil
        }
        for title in libraryHistoryActions {
            guard AXTree.first(
                in: [AXUIElementCreateSystemWide()] + currentApplicationRoots(),
                title: title
            ) != nil else {
                throw AcceptanceFailure(description: "Library history inventory is missing \(title)")
            }
        }
        guard AXTree.first(
            in: [AXUIElementCreateSystemWide()] + currentApplicationRoots(),
            title: "Show in Library…"
        ) == nil else {
            throw AcceptanceFailure(description: "Library context menu duplicated menu-only Show in Library")
        }
        var checkedControls = 0
        var checkedDisabledReason = false
        for descriptor in inventory {
            let identifier = "uiAcceptance.clipAction.libraryInspector.00000000-0000-0000-0000-000000000001.\(descriptor.id)"
            guard let control = AXTree.first(
                in: [AXUIElementCreateSystemWide()] + currentApplicationRoots(),
                identifier: identifier
            ) else { continue }
            guard AXTree.boolean(kAXEnabledAttribute as String, control) == descriptor.isEnabled else {
                throw AcceptanceFailure(description: "Library action \(descriptor.id) AXEnabled disagrees with inventory")
            }
            checkedControls += 1
            if !descriptor.isEnabled, descriptor.disabledReason != "none" {
                let help = AXTree.string(kAXHelpAttribute as String, control) ?? ""
                guard help.contains("enabled=false"), help.contains("reason=") else {
                    throw AcceptanceFailure(description: "disabled Library action \(descriptor.id) omitted its AXHelp reason")
                }
                checkedDisabledReason = true
            }
        }
        guard checkedControls >= 5, checkedDisabledReason else {
            throw AcceptanceFailure(description: "Library action inventory did not expose enough enabled/help contracts")
        }
        try AXTree.pressEscape()
        try pass("menu-library-action-inventory-order-enabled-help-and-parity-history")
    }

    private func verifyAssistantPresetsAndLocalBoundary() throws {
        try press(
            identifier: "uiAcceptance.library.more",
            in: currentLibraryRoots(),
            failure: "Library More disappeared before Assistant preset verification"
        )
        try press(
            // SwiftUI exposes the visual ellipsis as an AXButton titled "Use AI".
            title: "Use AI",
            in: [AXUIElementCreateSystemWide()] + currentApplicationRoots(),
            failure: "Library action inventory has no Use AI continuation"
        )
        try waitUntil(timeout: 8, failure: "Assistant sheet did not open") {
            AXTree.first(in: currentSheetRoots(), where: {
                $0.identifier?.hasPrefix("uiAcceptance.assistant.sheet.") == true
            }) != nil
        }
        let templates = [
            ("quickAnswer", "Answer this question using the attached clip as context: "),
            ("enrich", "Enrich this clip with useful, clearly labeled context. Do not invent facts."),
            ("rewrite", "Rewrite this clip for clarity while preserving its meaning."),
            ("format", "Format this clip into concise, scannable Markdown."),
            ("followUp", "Draft the most useful follow-up. Do not send or claim it was sent."),
            ("research", "Research this topic on the web. Cite the sources you used and label inference."),
        ]
        for (purpose, prompt) in templates {
            let identifier = "uiAcceptance.assistant.preset.\(purpose)"
            let currentPreset = try requiredElement(
                in: currentSheetRoots(),
                identifier: identifier,
                failure: "Assistant omitted preset \(purpose)"
            )
            let currentPrompt = AXTree.first(
                in: currentSheetRoots(),
                identifier: "uiAcceptance.assistant.prompt"
            ).flatMap { AXTree.string(kAXValueAttribute as String, $0) }
            let alreadySelected = AXTree.string(
                kAXValueAttribute as String,
                currentPreset
            ) == "Selected" && currentPrompt == prompt
            if !alreadySelected {
                try press(
                    identifier: identifier,
                    in: currentSheetRoots(),
                    failure: "Assistant omitted preset \(purpose)"
                )
            }
            try waitUntil(timeout: 3, failure: "Assistant preset \(purpose) did not commit") {
                guard let preset = AXTree.first(in: currentSheetRoots(), identifier: identifier),
                      AXTree.string(kAXValueAttribute as String, preset) == "Selected",
                      let field = AXTree.first(
                        in: currentSheetRoots(),
                        identifier: "uiAcceptance.assistant.prompt"
                      )
                else { return false }
                return AXTree.string(kAXValueAttribute as String, field) == prompt
            }
        }
        let cloud = try requiredElement(
            in: currentSheetRoots(),
            title: "Cloud",
            failure: "Assistant engine control omitted Cloud"
        )
        // SwiftUI's segmented Picker publishes the Cloud radio child without a stable
        // AXEnabled attribute on macOS 26. The authoritative boundary is the engine state and
        // the absence of a credential; keep the child lookup as discoverability evidence and
        // avoid treating a missing/optimistic AXEnabled value as configured cloud access.
        _ = cloud
        let engine = try requiredElement(
            in: currentSheetRoots(),
            identifier: "uiAcceptance.assistant.engine",
            failure: "Assistant omitted its engine state"
        )
        guard let engineValue = AXTree.string(kAXValueAttribute as String, engine),
              engineValue.contains("engine=onDevice")
        else { throw AcceptanceFailure(description: "unconfigured Assistant did not remain on the local engine boundary") }
        try press(
            identifier: "uiAcceptance.assistant.close",
            in: currentSheetRoots(),
            failure: "Assistant has no Close action"
        )
        try waitUntil(timeout: 5, failure: "Assistant Close did not cancel the continuation") {
            AXTree.first(in: currentSheetRoots(), where: {
                $0.identifier?.hasPrefix("uiAcceptance.assistant.sheet.") == true
            }) == nil
        }
        try pass("assistant-six-presets-cloud-unconfigured-and-cancel")
    }

    private func verifyDeveloperProjectCreateAndActivate() throws {
        let projectsDestination = try requiredElement(
            in: currentLibraryRoots(),
            identifier: "uiAcceptance.library.projects",
            failure: "Library Projects destination is missing"
        )
        try AXTree.activateSelectableElement(projectsDestination)
        let newProject = AXTree.first(
            in: currentLibraryRoots(),
            identifier: "developerProjects.newProject"
        ) ?? AXTree.first(
            in: currentLibraryRoots(),
            identifier: "uiAcceptance.projects.newProject"
        )
        guard let newProject else {
            throw AcceptanceFailure(description: "Projects workspace has no New Project action")
        }
        try AXTree.perform(kAXPressAction as String, on: newProject)
        try waitUntil(timeout: 8, failure: "New Project sheet did not open from Projects") {
            AXTree.first(in: currentSheetRoots(), identifier: "uiAcceptance.projects.name") != nil
        }
        try setText(
            identifier: "uiAcceptance.projects.name",
            value: "Acceptance Project",
            in: currentSheetRoots,
            failure: "Project name field is missing"
        )
        let repositoryChooser = try requiredElement(
            in: currentSheetRoots(),
            identifier: "uiAcceptance.projects.chooseRepository",
            failure: "New Project has no repository chooser"
        )
        // Ask the control itself to present NSOpenPanel. A coordinate click can be discarded
        // while the newly-created SwiftUI sheet is still becoming key. AppKit may report
        // AXCannotComplete while entering the modal loop, so the authoritative outcome is the
        // bounded observation of the titled panel below.
        try activateAcceptanceApplication()
        let repositoryPressResult = AXTree.performResult(
            kAXPressAction as String,
            on: repositoryChooser
        )
        guard repositoryPressResult == .success
                || repositoryPressResult == .cannotComplete
                || repositoryPressResult == .failure
        else {
            throw AcceptanceFailure(
                description: "repository chooser AXPress failed with \(repositoryPressResult.rawValue)"
            )
        }
        let repositoryURL = try prepareAcceptanceRepository()
        try chooseRepositoryInOpenPanel(repositoryURL)
        let create = try waitForEnabledElement(
            identifier: "uiAcceptance.projects.create",
            in: currentSheetRoots,
            timeout: 8,
            failure: "Create Project did not enable after choosing a repository"
        )
        try AXTree.perform(kAXPressAction as String, on: create)
        try waitUntil(timeout: 12, failure: "created Project did not appear in the Projects workspace") {
            AXTree.first(in: currentLibraryRoots(), title: "Acceptance Project") != nil
        }
        if let makeActive = AXTree.first(
            in: currentLibraryRoots(),
            identifier: "uiAcceptance.projects.makeActive"
        ) {
            try AXTree.perform(kAXPressAction as String, on: makeActive)
        }
        try waitUntil(timeout: 5, failure: "created Project did not become active") {
            AXTree.first(in: currentLibraryRoots(), title: "Active") != nil
                || AXTree.first(in: currentLibraryRoots(), title: "ACTIVE") != nil
        }
        try pass("projects-create-select-and-activate-through-packaged-ui")
    }

    private func verifyLiveLinkPreviewStates() throws {
        try selectHistoryFixture(query: "preview.clipboardrouter.test/loaded", index: 2)
        try waitForLivePreviewState(
            expected: "idle",
            failure: "loaded preview fixture did not start idle"
        )
        try press(
            identifier: "uiAcceptance.livePreview.load",
            in: currentLibraryRoots(),
            failure: "eligible preview has no explicit Load Preview action"
        )
        try waitForLivePreviewState(
            expected: "loaded",
            failure: "eligible preview did not reach deterministic loaded state"
        )
        guard AXTree.first(in: currentLibraryRoots(), title: "Acceptance Preview Loaded") != nil,
              AXTree.first(in: currentLibraryRoots(), title: "Clipboard Router Acceptance") != nil,
              AXTree.first(in: currentLibraryRoots(), where: { node in
                  [node.title, node.label, node.value].compactMap { $0 }.contains {
                      $0.contains("No network request was made")
                  }
              }) != nil
        else {
            throw AcceptanceFailure(description: "loaded preview omitted deterministic metadata proof")
        }
        try press(
            identifier: "uiAcceptance.livePreview.refresh",
            in: currentLibraryRoots(),
            failure: "loaded preview has no Refresh action"
        )
        try waitUntil(timeout: 8, failure: "Refresh did not publish refreshed preview metadata") {
            AXTree.first(in: currentLibraryRoots(), title: "Acceptance Preview Refreshed") != nil
        }
        try press(
            identifier: "uiAcceptance.livePreview.remove",
            in: currentLibraryRoots(),
            failure: "loaded preview has no Remove Preview action"
        )
        try waitForLivePreviewState(
            expected: "idle",
            failure: "Remove Preview did not return the link to idle"
        )

        try selectHistoryFixture(query: "preview.clipboardrouter.test/offline", index: 3)
        try press(
            identifier: "uiAcceptance.livePreview.load",
            in: currentLibraryRoots(),
            failure: "offline preview fixture has no explicit Load Preview action"
        )
        try waitForLivePreviewState(
            expected: "offline",
            failure: "offline preview fixture did not publish its truthful offline state"
        )
        guard AXTree.first(
            in: currentLibraryRoots(),
            title: "You appear to be offline. The stored link is still available."
        ) != nil else {
            throw AcceptanceFailure(description: "offline preview omitted its user-facing explanation")
        }

        try selectHistoryFixture(query: "127.0.0.1/private", index: 4)
        try waitForLivePreviewState(
            expected: "blocked",
            failure: "private-address preview did not fail closed before loading"
        )
        guard AXTree.first(
            in: currentLibraryRoots(),
            title: "Local, private, and link-local addresses cannot be previewed."
        ) != nil else {
            throw AcceptanceFailure(description: "blocked preview omitted its safety explanation")
        }
        if let load = AXTree.first(
            in: currentLibraryRoots(),
            identifier: "uiAcceptance.livePreview.load"
        ), AXTree.boolean(kAXEnabledAttribute as String, load) != false {
            throw AcceptanceFailure(description: "blocked private-address preview remained loadable")
        }
        try pass("live-link-preview-idle-load-refresh-remove-offline-and-blocked")
    }

    private func selectHistoryFixture(query: String, index: Int) throws {
        let history = try requiredLibraryControl(
            in: currentLibraryRoots(),
            identifier: "uiAcceptance.library.history",
            failure: "History destination is missing while selecting preview fixture"
        )
        try AXTree.activateSelectableElement(history)
        let search = try requiredLibraryControl(
            in: currentLibraryRoots(),
            identifier: "uiAcceptance.library.search",
            failure: "Library search is missing while selecting preview fixture"
        )
        try AXTree.setFocused(true, on: search)
        try AXTree.setValue(query, on: search)
        try AXTree.pressReturn()
        let identifier = String(
            format: "uiAcceptance.library.clip.00000000-0000-0000-0000-%012d",
            index
        )
        try waitUntil(timeout: 8, failure: "preview fixture \(index) did not render") {
            AXTree.first(in: currentLibraryRoots(), identifier: identifier) != nil
        }
        let row = try requiredElement(
            in: currentLibraryRoots(),
            identifier: identifier,
            failure: "preview fixture \(index) disappeared before selection"
        )
        try AXTree.activateSelectableElement(row)
        try waitUntil(timeout: 5, failure: "preview fixture \(index) did not become selected") {
            AXTree.first(
                in: currentLibraryRoots(),
                identifier: String(
                    format: "uiAcceptance.library.selected.00000000-0000-0000-0000-%012d",
                    index
                )
            ) != nil
        }
    }

    private func selectSavedFixture(query: String, index: Int) throws {
        let saved = try requiredLibraryControl(
            in: currentLibraryRoots(),
            identifier: "uiAcceptance.library.saved",
            failure: "Saved destination is missing while selecting Auto Organize fixture"
        )
        try AXTree.activateSelectableElement(saved)
        let search = try requiredLibraryControl(
            in: currentLibraryRoots(),
            identifier: "uiAcceptance.library.search",
            failure: "Library search is missing while selecting Auto Organize fixture"
        )
        try AXTree.setFocused(true, on: search)
        try AXTree.setValue(query, on: search)
        try AXTree.pressReturn()
        let identifier = String(
            format: "uiAcceptance.library.clip.00000000-0000-0000-0000-%012d",
            index
        )
        try waitUntil(timeout: 8, failure: "saved Auto Organize fixture did not render") {
            AXTree.first(in: currentLibraryRoots(), identifier: identifier) != nil
        }
        let row = try requiredElement(
            in: currentLibraryRoots(),
            identifier: identifier,
            failure: "saved Auto Organize fixture disappeared before selection"
        )
        try AXTree.activateSelectableElement(row)
        try waitUntil(timeout: 5, failure: "saved Auto Organize fixture did not become selected") {
            AXTree.first(
                in: currentLibraryRoots(),
                identifier: String(
                    format: "uiAcceptance.library.selected.00000000-0000-0000-0000-%012d",
                    index
                )
            ) != nil
        }
    }

    private func requiredLibraryControl(
        in roots: [AXUIElement],
        identifier: String,
        failure: String
    ) throws -> AXUIElement {
        if let element = AXTree.firstLibraryControl(in: roots, identifier: identifier) {
            return element
        }
        // Some macOS AX trees publish the sidebar outline only after the selected
        // workspace has settled. Preserve the full traversal as a bounded fallback
        // for that navigation control; row/table assertions still use the normal path.
        if let element = AXTree.first(in: roots, identifier: identifier) {
            return element
        }
        throw AcceptanceFailure(description: failure)
    }

    private func waitForAXValue(
        identifier: String,
        expected: String,
        failure: String
    ) throws {
        try waitUntil(timeout: 8, failure: failure) {
            guard let state = AXTree.first(in: currentLibraryRoots(), identifier: identifier) else {
                return false
            }
            return AXTree.string(kAXValueAttribute as String, state) == expected
        }
    }

    private func waitForLivePreviewState(expected: String, failure: String) throws {
        try waitUntil(timeout: 8, failure: failure) {
            let roots = currentLibraryRoots()
            if let state = AXTree.first(in: roots, identifier: "uiAcceptance.livePreview.state"),
               AXTree.string(kAXValueAttribute as String, state) == expected {
                return true
            }
            // macOS 26 does not consistently expose accessibilityValue on a SwiftUI
            // container that also contains buttons. Use the rendered, user-visible state
            // as the fallback while retaining the stable identifier when AX provides it.
            switch expected {
            case "idle":
                return AXTree.first(in: roots, title: "No network request has been made.") != nil
                    && AXTree.first(in: roots, identifier: "uiAcceptance.livePreview.load") != nil
            case "loaded":
                return AXTree.first(in: roots, title: "Acceptance Preview Loaded") != nil
            case "offline":
                return AXTree.first(
                    in: roots,
                    title: "You appear to be offline. The stored link is still available."
                ) != nil
            case "blocked":
                return AXTree.first(
                    in: roots,
                    title: "Local, private, and link-local addresses cannot be previewed."
                ) != nil
            default:
                return false
            }
        }
    }

    private func verifySalesWorkspaceTagAndHandoff() throws {
        try press(
            identifier: "uiAcceptance.library.createMenu",
            in: currentLibraryRoots(),
            failure: "Library Keep section has no create menu"
        )
        let menuRoots = [AXUIElementCreateSystemWide()] + currentApplicationRoots()
        do {
            try press(
                identifier: "uiAcceptance.library.newSalesWorkspace",
                in: menuRoots,
                failure: "Library create menu has no New Sales Workspace action"
            )
        } catch let identifierFailure as AcceptanceFailure {
            // Menu AX implementations differ across macOS releases: some retain
            // the SwiftUI identifier on the transient item, others expose only
            // the localized title. Both paths still press the actual menu item.
            do {
                try press(
                    title: "New Sales Workspace…",
                    in: [AXUIElementCreateSystemWide()] + currentApplicationRoots(),
                    failure: identifierFailure.description
                )
            } catch {
                do {
                    try pressTitlePrefix(
                        "New Sales Workspace",
                        failure: identifierFailure.description
                    )
                } catch {
                    let createMenu = try requiredElement(
                        in: currentLibraryRoots(),
                        identifier: "uiAcceptance.library.createMenu",
                        failure: identifierFailure.description
                    )
                    guard let action = AXTree.actionNames(createMenu).first(where: {
                        $0.localizedCaseInsensitiveContains("New Sales Workspace")
                    }) else {
                        throw AcceptanceFailure(
                            description: "Create menu exposes neither a New Sales Workspace item nor accessibility action"
                        )
                    }
                    let result = AXTree.performResult(action, on: createMenu)
                    guard result == .success else {
                        throw AcceptanceFailure(
                            description: "New Sales Workspace accessibility action failed with \(result.rawValue)",
                            isEnvironmental: result == .apiDisabled
                        )
                    }
                }
            }
        }
        try waitUntil(timeout: 8, failure: "New Sales Workspace sheet did not open") {
            AXTree.first(
                in: currentSheetRoots(),
                identifier: "uiAcceptance.sales.workspaceSheet"
            ) != nil
        }
        do {
            try setText(
                identifier: "uiAcceptance.sales.workspaceName",
                value: "Acceptance Account",
                in: currentSheetRoots,
                failure: "Sales workspace name field is missing"
            )
        } catch {
            let nameField = try requiredElement(
                in: currentSheetRoots(),
                title: "Sales workspace name",
                failure: "Sales workspace name field is missing"
            )
            try AXTree.setFocused(true, on: nameField)
            try AXTree.setValue("Acceptance Account", on: nameField)
        }
        let create: AXUIElement
        do {
            create = try waitForEnabledElement(
                identifier: "uiAcceptance.sales.createWorkspace",
                in: currentSheetRoots,
                timeout: 5,
                failure: "Create Workspace did not enable for a valid name"
            )
        } catch {
            create = try requiredElement(
                in: currentSheetRoots(),
                title: "Create Workspace",
                failure: "Create Workspace did not enable for a valid name"
            )
        }
        try AXTree.perform(kAXPressAction as String, on: create)
        cachedLibraryWindow = nil
        try waitUntil(timeout: 8, failure: "created sales workspace did not appear in Library") {
            cachedLibraryWindow = nil
            return AXTree.first(in: currentLibraryRoots(), identifier: "uiAcceptance.folder.Acceptance Account") != nil
                || AXTree.first(in: currentLibraryRoots(), title: "Acceptance Account") != nil
        }

        // Some macOS 26 AX trees omit the sidebar identifier after a newly-created
        // folder becomes selected. Search is global across History and Saved Clips,
        // so keep the current destination when the Saved row is not exposed.
        if let saved = AXTree.first(in: currentLibraryRoots(), identifier: "uiAcceptance.library.saved")
            ?? AXTree.first(in: currentLibraryRoots(), title: "Saved") {
            try AXTree.activateSelectableElement(saved)
        }
        let search = try requiredElement(
            in: currentLibraryRoots(),
            identifier: "uiAcceptance.library.search",
            failure: "Library search is missing before sales handoff setup"
        )
        try AXTree.setFocused(true, on: search)
        try AXTree.setValue("Acceptance Editable Note", on: search)
        try AXTree.pressReturn()
        let noteID = "uiAcceptance.library.clip.00000000-0000-0000-0000-000000009001"
        try waitUntil(timeout: 8, failure: "editable saved note did not render") {
            AXTree.first(in: currentLibraryRoots(), identifier: noteID) != nil
        }
        let note = try requiredElement(
            in: currentLibraryRoots(),
            identifier: noteID,
            failure: "editable saved note disappeared before sales handoff setup"
        )
        try AXTree.activateSelectableElement(note)
        try press(
            identifier: "uiAcceptance.library.more",
            in: currentLibraryRoots(),
            failure: "saved note has no More menu"
        )
        try press(
            title: "Edit Tags…",
            in: [AXUIElementCreateSystemWide()] + currentApplicationRoots(),
            failure: "saved note More menu has no tag editor"
        )
        try waitUntil(timeout: 5, failure: "tag editor did not open") {
            AXTree.first(in: currentSheetRoots(), title: "Edit Tags") != nil
        }
        let tagField = try requiredElement(
            in: currentSheetRoots(),
            title: "Tags separated by commas or new lines",
            failure: "tag editor has no tags field"
        )
        try AXTree.setFocused(true, on: tagField)
        try AXTree.setValue("acceptance, sales-ready", on: tagField)
        try press(
            title: "Save Tags",
            in: currentSheetRoots(),
            failure: "tag editor has no Save Tags action"
        )
        try waitUntil(timeout: 8, failure: "tag editor did not commit and dismiss") {
            AXTree.first(in: currentSheetRoots(), title: "Edit Tags") == nil
        }

        try press(
            identifier: "uiAcceptance.library.more",
            in: currentLibraryRoots(),
            failure: "saved note More menu did not reopen for filing"
        )
        try press(
            title: "Move to Folder",
            in: [AXUIElementCreateSystemWide()] + currentApplicationRoots(),
            failure: "saved note More menu has no Move to Folder submenu"
        )
        try press(
            title: "Acceptance Account",
            in: [AXUIElementCreateSystemWide()] + currentApplicationRoots(),
            failure: "Move to Folder omitted the created sales workspace"
        )
        var workspaceFolder: AXUIElement?
        try waitUntil(timeout: 8, failure: "created sales workspace disappeared after filing") {
            let roots = self.currentLibraryRoots()
            workspaceFolder = AXTree.first(in: roots, identifier: "uiAcceptance.folder.Acceptance Account")
                ?? AXTree.first(in: roots, title: "Acceptance Account")
            return workspaceFolder != nil
        }
        guard let workspaceFolder else {
            throw AcceptanceFailure(description: "created sales workspace disappeared after filing")
        }
        try AXTree.activateSelectableElement(workspaceFolder)
        try waitUntil(timeout: 8, failure: "saved note did not render inside the sales workspace") {
            AXTree.first(in: currentLibraryRoots(), identifier: noteID) != nil
        }

        try activateAcceptanceApplication()
        try AXTree.showContextMenu(of: workspaceFolder)
        do {
            try press(
                title: "Create Research Handoff…",
                in: [AXUIElementCreateSystemWide()] + currentApplicationRoots(),
                failure: "sales workspace has no Create Research Handoff action"
            )
        } catch {
            do {
                try pressTitlePrefix(
                    "Create Research Handoff",
                    failure: "sales workspace has no Create Research Handoff action"
                )
            } catch {
                let actionOwners = [
                    workspaceFolder,
                    AXTree.ancestor(of: workspaceFolder, role: kAXRowRole as String),
                ].compactMap { $0 }
                guard let (actionOwner, action) = actionOwners.lazy.compactMap({ owner in
                    AXTree.actionNames(owner)
                        .first(where: { $0.localizedCaseInsensitiveContains("Create Research Handoff") })
                        .map { (owner, $0) }
                }).first else {
                    throw AcceptanceFailure(description: "sales workspace has no Create Research Handoff action")
                }
                let result = AXTree.performResult(action, on: actionOwner)
                guard result == .success else {
                    throw AcceptanceFailure(description: "Create Research Handoff accessibility action failed with \(result.rawValue)")
                }
            }
        }
        try waitUntil(timeout: 8, failure: "Research Handoff review did not open") {
            AXTree.first(
                in: currentSheetRoots(),
                identifier: "uiAcceptance.sales.handoffReview"
            ) != nil
        }
        let summary = try requiredElement(
            in: currentSheetRoots(),
            identifier: "uiAcceptance.sales.handoffSummary",
            failure: "Research Handoff omitted its ready/omitted summary"
        )
        guard AXTree.string(kAXValueAttribute as String, summary) == "1 ready, 0 omitted" else {
            throw AcceptanceFailure(description: "Research Handoff did not include exactly the filed eligible note")
        }
        for format in ["CSV", "JSON", "Markdown"] {
            try press(
                title: format,
                in: currentSheetRoots(),
                failure: "Research Handoff format picker omitted \(format)"
            )
            try waitUntil(timeout: 3, failure: "Research Handoff did not select \(format)") {
                guard let picker = AXTree.first(
                    in: currentSheetRoots(),
                    identifier: "uiAcceptance.sales.handoffFormat"
                ) else { return false }
                return AXTree.string(kAXValueAttribute as String, picker) == format
            }
        }
        try press(
            identifier: "uiAcceptance.sales.cancelHandoff",
            in: currentSheetRoots(),
            failure: "Research Handoff has no Cancel action"
        )
        try openAcceptanceSalesHandoff()
        let acceptancePasteboard = NSPasteboard(
            name: NSPasteboard.Name(
                "com.clipboardrouter.ClipboardRouter.uiacceptance.pasteboard.\(arguments.runID)"
            )
        )
        let priorChangeCount = acceptancePasteboard.changeCount
        try press(
            identifier: "uiAcceptance.sales.copyHandoff",
            in: currentSheetRoots(),
            failure: "Research Handoff has no Copy Markdown action"
        )
        var copiedMarkdown = ""
        try waitUntil(timeout: 8, failure: "Copy Markdown did not write the run-scoped pasteboard") {
            guard acceptancePasteboard.changeCount != priorChangeCount,
                  let value = acceptancePasteboard.string(forType: .string)
            else { return false }
            copiedMarkdown = value
            guard let summary = try? HandoffEvidenceParser.parseMarkdown(value) else { return false }
            return summary == HandoffEvidenceSummary(
                rootTitle: "Acceptance Account",
                itemCount: 1,
                omittedCount: 0,
                recordTitles: ["Acceptance Editable Note"]
            ) && value.contains("sales-ready")
        }
        let copiedSummary = try HandoffEvidenceParser.parseMarkdown(copiedMarkdown)
        guard copiedSummary.itemCount == copiedSummary.recordTitles.count else {
            throw AcceptanceFailure(description: "copied handoff Markdown count disagrees with its records")
        }

        for (format, extensionName) in [("Markdown", "md"), ("CSV", "csv"), ("JSON", "json")] {
            try exportAndParseAcceptanceSalesHandoff(
                format: format,
                extensionName: extensionName
            )
        }
        try pass("sales-workspace-tag-file-and-parse-markdown-csv-json-handoff")
    }

    private func verifySmartViewsCRUD() throws {
        let firstRow = try createSmartView(
            query: "Acceptance Editable Note",
            name: "Acceptance Saved Notes"
        )
        let firstID = try requiredIdentifier(
            firstRow,
            failure: "created Smart View did not expose its stable UUID identifier"
        )
        let firstUUID = String(firstID.split(separator: ".").last ?? "")

        try openContextMenu(
            identifier: firstID,
            failure: "created Smart View disappeared before edit"
        )
        try press(
            identifier: "uiAcceptance.smartViews.edit.\(firstUUID)",
            in: [AXUIElementCreateSystemWide()] + currentApplicationRoots(),
            failure: "created Smart View has no Edit action"
        )
        try waitUntil(timeout: 5, failure: "Edit Smart View sheet did not open") {
            AXTree.first(
                in: currentSheetRoots(),
                identifier: "uiAcceptance.smartViews.editor"
            ) != nil
        }
        try setText(
            identifier: "uiAcceptance.smartViews.name",
            value: "Acceptance Saved Notes Updated",
            in: currentSheetRoots,
            failure: "Smart View edit name is missing"
        )
        try press(
            identifier: "uiAcceptance.smartViews.pinned",
            in: currentSheetRoots(),
            failure: "Smart View edit has no pin toggle"
        )
        let update = try waitForEnabledElement(
            identifier: "uiAcceptance.smartViews.commit",
            in: currentSheetRoots,
            timeout: 5,
            failure: "Smart View Update did not enable"
        )
        try AXTree.perform(kAXPressAction as String, on: update)
        try waitUntil(timeout: 8, failure: "Smart View edit did not persist") {
            guard let row = AXTree.first(in: currentLibraryRoots(), identifier: firstID),
                  let value = AXTree.string(kAXValueAttribute as String, row)
            else { return false }
            return value.contains("name=Acceptance Saved Notes Updated")
                && value.contains("pinned=true")
        }

        let secondRow = try createSmartView(
            query: "sarah@example.com",
            name: "Acceptance Sarah History"
        )
        let secondID = try requiredIdentifier(
            secondRow,
            failure: "second Smart View did not expose its stable UUID identifier"
        )
        let secondUUID = String(secondID.split(separator: ".").last ?? "")
        // Reordering is intentionally constrained within the pinned/unpinned groups.
        // Pin the second fixture before moving it above the first pinned Smart View.
        try openContextMenu(
            identifier: secondID,
            failure: "second Smart View disappeared before pinning for reorder"
        )
        try press(
            identifier: "uiAcceptance.smartViews.pin.\(secondUUID)",
            in: [AXUIElementCreateSystemWide()] + currentApplicationRoots(),
            failure: "second Smart View has no Pin action"
        )
        try waitUntil(timeout: 8, failure: "second Smart View pin did not persist") {
            guard let row = AXTree.first(in: currentLibraryRoots(), identifier: secondID),
                  let value = AXTree.string(kAXValueAttribute as String, row)
            else { return false }
            return value.contains("pinned=true")
        }
        try openContextMenu(
            identifier: secondID,
            failure: "second Smart View disappeared before reorder"
        )
        try press(
            identifier: "uiAcceptance.smartViews.moveUp.\(secondUUID)",
            in: [AXUIElementCreateSystemWide()] + currentApplicationRoots(),
            failure: "second Smart View has no enabled Move Up action"
        )
        try waitUntil(timeout: 5, failure: "Smart View reorder did not commit") {
            guard let row = AXTree.first(in: currentLibraryRoots(), identifier: secondID),
                  let value = AXTree.string(kAXValueAttribute as String, row)
            else { return false }
            return value.contains("order=0")
        }
        try openContextMenu(
            identifier: secondID,
            failure: "reordered Smart View disappeared before delete"
        )
        do {
            try press(
                identifier: "uiAcceptance.smartViews.delete.\(secondUUID)",
                in: [AXUIElementCreateSystemWide()] + currentApplicationRoots(),
                failure: "reordered Smart View has no Delete action"
            )
        } catch {
            try press(
                title: "Delete Smart View",
                in: [AXUIElementCreateSystemWide()] + currentApplicationRoots(),
                failure: "reordered Smart View has no Delete action"
            )
        }
        try waitUntil(timeout: 8, failure: "Smart View delete did not persist") {
            AXTree.first(in: currentLibraryRoots(), identifier: secondID) == nil
        }

        try pass("smart-view-create-edit-pin-reorder-and-delete")
    }

    private func verifyThreeRowBulkActions() throws {
        let history = try requiredElement(
            in: currentLibraryRoots(),
            identifier: "uiAcceptance.library.history",
            failure: "History destination disappeared before three-row bulk actions"
        )
        try AXTree.activateSelectableElement(history)
        let search = try requiredElement(
            in: currentLibraryRoots(),
            identifier: "uiAcceptance.library.search",
            failure: "Library search disappeared before three-row bulk save"
        )
        try AXTree.setFocused(true, on: search)
        try AXTree.setValue("Acceptance clip 000", on: search)
        try AXTree.pressReturn()
        // Keep the deterministic bulk fixture in the first visible rows. The
        // production Table virtualizes the remaining 1,000 rows, so relying on
        // rows 5–7 would test viewport exposure rather than bulk semantics.
        let historyIDs = (1...3).map {
            String(format: "uiAcceptance.library.clip.00000000-0000-0000-0000-%012d", $0)
        }
        try selectThreeBulkRows(identifiers: historyIDs)
        try openBulkActionsMenu()
        try press(
            identifier: "uiAcceptance.bulk.save",
            in: [AXUIElementCreateSystemWide()] + currentApplicationRoots(),
            failure: "three-row History selection has no Save History action"
        )
        guard let accountDestination = AXTree.first(
            in: [AXUIElementCreateSystemWide()] + currentApplicationRoots(),
            where: { node in
                node.identifier?.hasPrefix("uiAcceptance.bulk.destination.") == true
                    && node.value?.contains("path=Acceptance Account") == true
            }
        ) else {
            throw AcceptanceFailure(description: "Save History destinations omitted Acceptance Account")
        }
        try AXTree.perform(kAXPressAction as String, on: accountDestination)
        try verifyAndDismissBulkResult(action: "Save Selection", success: 3)

        let account = try requiredElement(
            in: currentLibraryRoots(),
            identifier: "uiAcceptance.folder.Acceptance Account",
            failure: "Acceptance Account disappeared after bulk save"
        )
        try AXTree.activateSelectableElement(account)
        let savedTitles = (1...3).map { String(format: "Acceptance clip %04d", $0) }
        try selectThreeBulkRows(titles: savedTitles)
        try openBulkActionsMenu()
        try press(
            identifier: "uiAcceptance.bulk.move",
            in: [AXUIElementCreateSystemWide()] + currentApplicationRoots(),
            failure: "three saved rows have no Move action"
        )
        try waitUntil(timeout: 5, failure: "bulk Move sheet did not open") {
            AXTree.first(in: currentSheetRoots(), identifier: "uiAcceptance.bulk.moveSheet") != nil
        }
        try press(
            identifier: "uiAcceptance.bulk.destination.saved",
            in: currentSheetRoots(),
            failure: "bulk Move sheet omitted Saved (no folder)"
        )
        try verifyAndDismissBulkResult(action: "Move Selection", success: 3)

        try selectSavedBulkRows(titles: savedTitles)
        try openBulkActionsMenu()
        try press(
            identifier: "uiAcceptance.bulk.addTags",
            in: [AXUIElementCreateSystemWide()] + currentApplicationRoots(),
            failure: "bulk actions menu has no Add Tags action"
        )
        try waitUntil(timeout: 5, failure: "bulk Add Tags sheet did not open") {
            AXTree.first(in: currentSheetRoots(), identifier: "uiAcceptance.bulk.tagSheet") != nil
        }
        try setText(
            identifier: "uiAcceptance.bulk.tagField",
            value: "bulk-acceptance",
            in: currentSheetRoots,
            failure: "bulk Add Tags field is missing"
        )
        try press(
            identifier: "uiAcceptance.bulk.tagCommit",
            in: currentSheetRoots(),
            failure: "bulk Add Tags sheet has no commit action"
        )
        try verifyAndDismissBulkResult(action: "Tag Selection", success: 3)

        try selectSavedBulkRows(titles: savedTitles)
        try openBulkActionsMenu()
        try press(
            identifier: "uiAcceptance.bulk.pin",
            in: [AXUIElementCreateSystemWide()] + currentApplicationRoots(),
            failure: "bulk Pin submenu omitted Pin Eligible"
        )
        try verifyAndDismissBulkResult(action: "Pin Selection", success: 3)

        try selectSavedBulkRows(titles: savedTitles)
        try openBulkActionsMenu()
        try press(
            identifier: "uiAcceptance.bulk.unpin",
            in: [AXUIElementCreateSystemWide()] + currentApplicationRoots(),
            failure: "bulk Pin submenu omitted Unpin Eligible"
        )
        try verifyAndDismissBulkResult(action: "Unpin Selection", success: 3)

        try selectSavedBulkRows(titles: savedTitles)
        try openBulkActionsMenu()
        let archiveURL = arguments.evidenceDirectory
            .appendingPathComponent("Selected Clips.clipboardrouterarchive", isDirectory: true)
        guard !FileManager.default.fileExists(atPath: archiveURL.path) else {
            throw AcceptanceFailure(description: "bulk archive evidence destination already exists")
        }
        try press(
            identifier: "uiAcceptance.bulk.export",
            in: [AXUIElementCreateSystemWide()] + currentApplicationRoots(),
            failure: "bulk actions menu has no Export Eligible action"
        )
        try chooseEvidenceDirectoryInSavePanel(
            title: "Export Selected Clips",
            directory: arguments.evidenceDirectory,
            confirmTitle: "Export"
        )
        try waitUntil(timeout: 10, failure: "bulk export did not create its portable archive") {
            FileManager.default.fileExists(atPath: archiveURL.path)
        }
        let manifestURL = archiveURL.appendingPathComponent("manifest.json")
        let manifestData = try Data(contentsOf: manifestURL)
        guard let manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
              manifest["version"] as? Int == 1,
              let entries = manifest["entries"] as? [[String: Any]],
              entries.count == 3,
              Set(entries.compactMap { $0["name"] as? String }) == Set(savedTitles)
        else {
            throw AcceptanceFailure(description: "bulk archive manifest failed version/count/title verification")
        }
        try verifyAndDismissBulkResult(action: "Export Selection", success: 3)

        try selectSavedBulkRows(titles: savedTitles)
        try openBulkActionsMenu()
        try press(
            identifier: "uiAcceptance.bulk.clear",
            in: [AXUIElementCreateSystemWide()] + currentApplicationRoots(),
            failure: "bulk actions menu has no Clear Selection action"
        )
        try waitUntil(timeout: 5, failure: "Clear Selection did not remove the bulk action bar") {
            AXTree.first(in: currentLibraryRoots(), identifier: "uiAcceptance.bulk.selectedCount") == nil
        }
        try pass("bulk-save-move-tag-pin-unpin-export-and-clear-three-row-selection")
    }

    private func selectSavedBulkRows(titles: [String]) throws {
        let saved = try requiredElement(
            in: currentLibraryRoots(),
            identifier: "uiAcceptance.library.saved",
            failure: "Saved destination disappeared during bulk actions"
        )
        try AXTree.activateSelectableElement(saved)
        let search = try requiredElement(
            in: currentLibraryRoots(),
            identifier: "uiAcceptance.library.search",
            failure: "Library search disappeared during bulk actions"
        )
        try AXTree.setFocused(true, on: search)
        try AXTree.setValue("Acceptance clip 000", on: search)
        try AXTree.pressReturn()
        try selectThreeBulkRows(titles: titles)
    }

    private func selectThreeBulkRows(
        identifiers: [String] = [],
        titles: [String] = []
    ) throws {
        let keys = !identifiers.isEmpty ? identifiers : titles
        guard keys.count == 3 else {
            throw AcceptanceFailure(description: "bulk acceptance requires exactly three row keys")
        }
        var progress = BulkSelectionProgress(requiredCount: 3)
        for (index, key) in keys.enumerated() {
            let element: AXUIElement
            if !identifiers.isEmpty {
                var resolved: AXUIElement?
                try waitUntil(timeout: 5, failure: "bulk row \(key) is missing") {
                    resolved = AXTree.first(in: currentLibraryRoots(), identifier: key)
                    return resolved != nil
                }
                element = resolved!
            } else {
                element = try requiredElement(
                    in: currentLibraryRoots(),
                    title: key,
                    failure: "bulk row \(key) is missing"
                )
            }
            try progress.record(identifier: key)
            try AXTree.clickSelectableElement(
                element,
                modifiers: index == 0 ? [] : .maskCommand
            )
            let expectedCount = index + 1
            try waitUntil(timeout: 5, failure: "bulk selection did not advance to \(expectedCount)") {
                guard let count = AXTree.first(
                    in: currentLibraryRoots(),
                    identifier: "uiAcceptance.bulk.selectedCount"
                ), let observed = AXTree.string(kAXValueAttribute as String, count).flatMap(Int.init)
                else { return false }
                return observed == expectedCount
            }
        }
        guard progress.provesSelection(observedCount: 3) else {
            throw AcceptanceFailure(description: "three-row bulk selection chain is incomplete")
        }
    }

    private func openBulkActionsMenu() throws {
        try press(
            identifier: "uiAcceptance.bulk.menu",
            in: currentLibraryRoots(),
            failure: "three-row selection has no bulk actions menu"
        )
    }

    private func verifyAndDismissBulkResult(action: String, success: Int) throws {
        try waitUntil(timeout: 10, failure: "\(action) did not report \(success) exact successes") {
            guard let result = AXTree.first(
                in: currentSheetRoots(),
                identifier: "uiAcceptance.bulk.result"
            ), let value = AXTree.string(kAXValueAttribute as String, result)
            else { return false }
            return value.contains("action=\(action)")
                && value.contains("success=\(success)")
                && value.contains("failure=0")
        }
        try press(
            identifier: "uiAcceptance.bulk.resultDone",
            in: currentSheetRoots(),
            failure: "\(action) result has no Done action"
        )
        try waitUntil(timeout: 5, failure: "\(action) result did not dismiss") {
            AXTree.first(in: currentSheetRoots(), identifier: "uiAcceptance.bulk.result") == nil
        }
    }

    private func createSmartView(query: String, name: String) throws -> AXUIElement {
        let history = try requiredElement(
            in: currentLibraryRoots(),
            identifier: "uiAcceptance.library.history",
            failure: "History destination is missing before Smart View creation"
        )
        try AXTree.activateSelectableElement(history)
        let search = try requiredElement(
            in: currentLibraryRoots(),
            identifier: "uiAcceptance.library.search",
            failure: "Library search is missing before Smart View creation"
        )
        try AXTree.setFocused(true, on: search)
        try AXTree.setValue(query, on: search)
        try AXTree.pressReturn()
        let save = try waitForEnabledElement(
            identifier: "uiAcceptance.smartViews.saveCurrentSearch",
            in: currentLibraryRoots,
            timeout: 5,
            failure: "valid Library search did not enable Save Current Search"
        )
        try AXTree.perform(kAXPressAction as String, on: save)
        try waitUntil(timeout: 5, failure: "Save Smart View sheet did not open") {
            AXTree.first(in: currentSheetRoots(), identifier: "uiAcceptance.smartViews.editor") != nil
        }
        try setText(
            identifier: "uiAcceptance.smartViews.name",
            value: name,
            in: currentSheetRoots,
            failure: "Save Smart View name field is missing"
        )
        let commit = try waitForEnabledElement(
            identifier: "uiAcceptance.smartViews.commit",
            in: currentSheetRoots,
            timeout: 5,
            failure: "Save Smart View did not enable for a valid definition"
        )
        try AXTree.perform(kAXPressAction as String, on: commit)
        var created: AXUIElement?
        try waitUntil(timeout: 8, failure: "created Smart View did not appear in the sidebar") {
            created = AXTree.first(in: currentLibraryRoots(), where: { node in
                node.identifier?.hasPrefix("uiAcceptance.smartViews.row.") == true
                    && node.value?.contains("name=\(name)") == true
            })
            return created != nil
        }
        return created!
    }

    /// The Auto Organize suggestion card publishes a truthful `tags=a,b,c` segment in its
    /// accessibility value for the clip it currently targets (see
    /// `AutomaticOrganizationAccessibility.suggestionValue`). Apply Once / Undo / Always Apply
    /// must be verified against this real mutation, not against picker or receipt-button text
    /// alone. The underlying `uiAcceptance.library.clip.*` row is not reachable here: this
    /// verification runs while the Auto Organize dashboard destination is selected, which does
    /// not render the Library clip table, so a selector rooted on that row could never see it.
    ///
    /// Returns `nil` when no suggestion node is published yet, when every matching node's AX
    /// value read came back nil or empty (both are legitimate "not ready" states — a timing
    /// window during a SwiftUI tree republish counts as the latter), or when parseable nodes
    /// exist but none names the expected fixture clip in its `clip=` field. That last case
    /// matters as much as the others: falling back to another clip's tags would let an undo
    /// check false-pass by observing a stale duplicate's state instead of the real one. All
    /// three are states callers should keep polling for via `waitUntil`, not fail on. Throws
    /// only when at least one matching node's AX value *was* read successfully (non-nil,
    /// non-empty) but none of the readable values carry a parseable `tags=` segment, since that
    /// indicates a real schema break rather than a timing window and must not be silently read
    /// as an absent/false tag set.
    ///
    /// When more than one node matches (duplicates can appear transiently while SwiftUI
    /// reconciles the tree), only the node whose `clip=` field names the expected fixture clip
    /// is trusted — never a duplicate targeting a different clip.
    private func fixtureNoteTags(
        in roots: [AXUIElement],
        expectedClipID: String = "00000000-0000-0000-0000-000000009001"
    ) throws -> Set<String>? {
        // SwiftUI does not consistently expose a container's custom AXValue on macOS 26. The
        // suggestion card therefore publishes a clip-specific child contract as well; prefer it
        // because the identifier itself binds the observed tags to the exact fixture clip.
        let tagIdentifier = "uiAcceptance.autoOrganize.suggestion.tags.\(expectedClipID)"
        let tagNodes = AXTree.all(in: roots, identifier: tagIdentifier)
        if let tagNode = tagNodes.first {
            if let value = AXTree.string(kAXValueAttribute as String, tagNode), !value.isEmpty,
               let rawTags = AutoOrganizeTagList.rawField("tags", in: value) {
                return Set(AutoOrganizeTagList.decode(rawTags))
            }
            if let title = AXTree.string(kAXTitleAttribute as String, tagNode),
               title.hasPrefix("Tags:") {
                let rawTags = title.dropFirst("Tags:".count).trimmingCharacters(in: .whitespaces)
                return rawTags == "none"
                    ? []
                    : Set(rawTags.split(separator: ",").map {
                        $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#"))
                    })
            }
        }

        let matches = AXTree.all(in: roots, identifier: "uiAcceptance.autoOrganize.suggestion")
        guard !matches.isEmpty else { return nil }

        var readableValues: [String] = []
        var parsed: [(clipID: String?, tags: Set<String>)] = []
        for match in matches {
            guard let value = AXTree.string(kAXValueAttribute as String, match), !value.isEmpty else { continue }
            readableValues.append(value)
            guard let rawTags = AutoOrganizeTagList.rawField("tags", in: value) else { continue }
            let clipID = AutoOrganizeTagList.rawField("clip", in: value)
            parsed.append((clipID: clipID, tags: Set(AutoOrganizeTagList.decode(rawTags))))
        }

        if let correlated = parsed.first(where: { $0.clipID == expectedClipID }) {
            return correlated.tags
        }
        if !parsed.isEmpty { return nil }
        guard !readableValues.isEmpty else { return nil }
        throw AcceptanceFailure(
            description: "Auto Organize suggestion published no tags= segment in its accessibility "
                + "value (checked \(matches.count) matching node(s)): \(readableValues)"
        )
    }

    private func verifyAutomaticOrganizationCRUDApplyAndUndo() throws {
        let auto = try requiredElement(
            in: currentLibraryRoots(),
            identifier: "uiAcceptance.library.autoOrganize",
            failure: "Library Auto Organize destination is missing"
        )
        try AXTree.activateSelectableElement(auto)
        let firstRow = try createAutomaticOrganizationRule(
            name: "Acceptance Auto",
            matchKind: "Words or phrases",
            matchValue: "Acceptance",
            tags: "auto-ready"
        )
        let firstID = try requiredIdentifier(
            firstRow,
            failure: "created Auto Organize rule did not expose its UUID identifier"
        )
        let firstUUID = String(firstID.split(separator: ".").last ?? "")
        // The flow journey creates a newer follow-up note. Choose the deterministic
        // seeded note whose searchable body contains the literal matcher.
        try press(
            identifier: "uiAcceptance.autoOrganize.previewClip",
            in: currentLibraryRoots(),
            failure: "Auto Organize preview picker is missing"
        )
        try press(
            title: "Acceptance Editable Note",
            in: [AXUIElementCreateSystemWide()] + currentApplicationRoots(),
            failure: "Auto Organize preview picker omitted the seeded Acceptance note"
        )
        try waitUntil(timeout: 8, failure: "matching Auto Organize rule did not publish a suggestion") {
            AXTree.first(
                in: currentLibraryRoots(),
                identifier: "uiAcceptance.autoOrganize.suggestion"
            ) != nil
        }
        try press(
            identifier: "uiAcceptance.autoOrganize.applyOnce",
            in: currentLibraryRoots(),
            failure: "Auto Organize suggestion has no Apply Once action"
        )
        try waitUntil(timeout: 8, failure: "Apply Once did not publish an undo receipt") {
            return AXTree.first(
                in: currentLibraryRoots(),
                identifier: "uiAcceptance.autoOrganize.suggestion"
            ) != nil && AXTree.first(
                in: currentLibraryRoots(),
                identifier: "uiAcceptance.autoOrganize.undo"
            ) != nil
        }
        try waitUntil(
            timeout: 8,
            failure: "Apply Once did not truthfully add the auto-ready tag to the fixture clip"
        ) {
            try fixtureNoteTags(in: currentLibraryRoots())?.contains("auto-ready") == true
        }
        try press(
            identifier: "uiAcceptance.autoOrganize.undo",
            in: currentLibraryRoots(),
            failure: "Auto Organize receipt has no Undo action"
        )
        try waitUntil(timeout: 8, failure: "Auto Organize Undo did not clear its receipt") {
            return AXTree.first(
                in: currentLibraryRoots(),
                identifier: "uiAcceptance.autoOrganize.suggestion"
            ) != nil && AXTree.first(
                in: currentLibraryRoots(),
                identifier: "uiAcceptance.autoOrganize.undo"
            ) == nil
        }
        try waitUntil(
            timeout: 8,
            failure: "Undo did not truthfully remove the auto-ready tag from the fixture clip"
        ) {
            try fixtureNoteTags(in: currentLibraryRoots())?.contains("auto-ready") == false
        }

        try press(
            identifier: "uiAcceptance.autoOrganize.edit.\(firstUUID)",
            in: currentLibraryRoots(),
            failure: "created Auto Organize rule has no Edit action"
        )
        try waitUntil(timeout: 5, failure: "Edit Organization Rule sheet did not open") {
            AXTree.first(in: currentSheetRoots(), identifier: "uiAcceptance.autoOrganize.editor") != nil
        }
        try setText(
            identifier: "uiAcceptance.autoOrganize.ruleName",
            value: "Acceptance Auto Updated",
            in: currentSheetRoots,
            failure: "Auto Organize edit name is missing"
        )
        let matchPicker = try requiredElement(
            in: currentSheetRoots(),
            identifier: "uiAcceptance.autoOrganize.matchKind",
            failure: "Auto Organize edit lost its Safe regex picker"
        )
        // AXValue is read-only for this native SwiftUI popup on macOS 26. Invoke the explicit
        // accessibility action exposed by the real Match control, then verify the bound state.
        guard let safeRegexAction = AXTree.actionNames(matchPicker).first(where: {
            $0.localizedCaseInsensitiveContains("Safe regex")
        }) else {
            throw AcceptanceFailure(
                description: "Auto Organize match picker does not expose Select Safe regex"
            )
        }
        let safeRegexResult = AXTree.performResult(safeRegexAction, on: matchPicker)
        guard safeRegexResult == .success else {
            throw AcceptanceFailure(
                description: "Auto Organize Select Safe regex action failed with \(safeRegexResult.rawValue)",
                isEnvironmental: safeRegexResult == .apiDisabled
            )
        }
        try waitUntil(timeout: 4, failure: "Auto Organize match picker did not select Safe regex") {
            guard let refreshed = AXTree.first(
                in: currentSheetRoots(),
                identifier: "uiAcceptance.autoOrganize.matchKind"
            ) else { return false }
            return AXTree.string(kAXValueAttribute as String, refreshed) == "Safe regex"
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        try setText(
            identifier: "uiAcceptance.autoOrganize.matchValue",
            value: #"\bAcceptance\b"#,
            in: currentSheetRoots,
            failure: "Auto Organize safe regex field is missing"
        )
        try waitUntil(timeout: 4, failure: "Auto Organize editor did not publish safe-regex state") {
            guard let matchKind = AXTree.first(
                in: currentSheetRoots(),
                identifier: "uiAcceptance.autoOrganize.matchKind"
            ), let matchValue = AXTree.first(
                in: currentSheetRoots(),
                identifier: "uiAcceptance.autoOrganize.matchValue"
            ) else { return false }
            return AXTree.string(kAXValueAttribute as String, matchKind) == "Safe regex"
                && AXTree.string(kAXValueAttribute as String, matchValue) == #"\bAcceptance\b"#
        }
        try press(
            identifier: "uiAcceptance.autoOrganize.saveRule",
            in: currentSheetRoots(),
            failure: "Auto Organize edit has no Save Changes action"
        )
        try waitUntil(timeout: 8, failure: "Auto Organize edit did not persist") {
            return AXTree.first(in: currentLibraryRoots(), identifier: firstID) != nil
                && AXTree.first(in: currentLibraryRoots(), title: "Acceptance Auto Updated") != nil
        }

        let secondRow = try createAutomaticOrganizationRule(
            name: "Acceptance Auto Temporary",
            matchKind: "Content type",
            matchValue: nil,
            tags: "temporary"
        )
        let secondID = try requiredIdentifier(
            secondRow,
            failure: "second Auto Organize rule did not expose its UUID identifier"
        )
        let secondUUID = String(secondID.split(separator: ".").last ?? "")
        try press(
            identifier: "uiAcceptance.autoOrganize.moveUp.\(secondUUID)",
            in: currentLibraryRoots(),
            failure: "second Auto Organize rule has no enabled Move Up action"
        )
        try waitUntil(timeout: 5, failure: "Auto Organize reorder did not persist") {
            return AXTree.appearsBefore(
                identifier: secondID,
                than: firstID,
                in: currentLibraryRoots()
            )
        }
        try press(
            identifier: "uiAcceptance.autoOrganize.delete.\(secondUUID)",
            in: currentLibraryRoots(),
            failure: "temporary Auto Organize rule has no Delete action"
        )
        try waitUntil(timeout: 8, failure: "Auto Organize delete did not persist") {
            AXTree.first(in: currentLibraryRoots(), identifier: secondID) == nil
        }

        try waitUntil(timeout: 8, failure: "safe-regex Auto Organize rule did not publish a suggestion") {
            guard let suggestion = AXTree.first(
                in: currentLibraryRoots(),
                identifier: "uiAcceptance.autoOrganize.suggestion"
            ) else { return false }
            return AXTree.first(in: [suggestion], title: "Acceptance Auto Updated") != nil
                && AXTree.first(
                    in: currentLibraryRoots(),
                    identifier: "uiAcceptance.autoOrganize.undo"
                ) == nil
        }
        try press(
            identifier: "uiAcceptance.autoOrganize.alwaysApply",
            in: currentLibraryRoots(),
            failure: "Auto Organize suggestion has no Always Apply action"
        )
        try waitUntil(timeout: 8, failure: "Always Apply did not persist automatic behavior") {
            return AXTree.first(in: currentLibraryRoots(), identifier: firstID) != nil
                && pickerOptionIsSelected(
                    identifier: "uiAcceptance.autoOrganize.behavior.\(firstUUID)",
                    title: "Always Apply",
                    in: currentLibraryRoots()
                )
        }
        // The suggestion card disappears after Always Apply. Reopen the actual saved fixture
        // row and verify its production row contract instead of reading a stale suggestion node.
        try selectSavedFixture(query: "Acceptance Editable Note", index: 9001)
        try waitUntil(
            timeout: 8,
            failure: "Always Apply did not truthfully add the auto-ready tag to the fixture clip"
        ) {
            guard let row = AXTree.first(
                in: currentLibraryRoots(),
                identifier: "uiAcceptance.library.clip.00000000-0000-0000-0000-000000009001"
            ), let value = AXTree.string(kAXValueAttribute as String, row) else { return false }
            guard let rawTags = value.split(separator: "=", maxSplits: 1).dropFirst().first else {
                return false
            }
            return rawTags.split(separator: ",", omittingEmptySubsequences: true)
                .map(String.init)
                .contains("auto-ready")
        }

        let autoDestination = try requiredLibraryControl(
            in: currentLibraryRoots(),
            identifier: "uiAcceptance.library.autoOrganize",
            failure: "Auto Organize destination disappeared after saved-row verification"
        )
        try AXTree.activateSelectableElement(autoDestination)
        try waitUntil(timeout: 8, failure: "Auto Organize rule list did not return after saved-row verification") {
            AXTree.first(in: currentLibraryRoots(), identifier: firstID) != nil
        }
        let behaviorPicker = try requiredElement(
            in: currentLibraryRoots(),
            identifier: "uiAcceptance.autoOrganize.behavior.\(firstUUID)",
            failure: "Always Apply rule has no way to return to Suggest"
        )
        if let suggestAction = AXTree.actionNames(behaviorPicker).first(where: {
            $0.localizedCaseInsensitiveContains("Select Suggest")
        }) {
            let suggestResult = AXTree.performResult(suggestAction, on: behaviorPicker)
            guard suggestResult == .success else {
                throw AcceptanceFailure(
                    description: "Select Suggest action failed with \(suggestResult.rawValue)",
                    isEnvironmental: suggestResult == .apiDisabled
                )
            }
        } else {
            try selectSegmentOption(
                identifier: "uiAcceptance.autoOrganize.behavior.\(firstUUID)",
                title: "Suggest",
                in: currentLibraryRoots,
                failure: "Always Apply rule has no way to return to Suggest"
            )
        }
        try waitUntil(timeout: 8, failure: "Auto Organize rule did not return to Suggest") {
            return AXTree.first(in: currentLibraryRoots(), identifier: firstID) != nil
                && pickerOptionIsSelected(
                    identifier: "uiAcceptance.autoOrganize.behavior.\(firstUUID)",
                    title: "Suggest",
                    in: currentLibraryRoots()
                )
                && AXTree.first(
                    in: currentLibraryRoots(),
                    identifier: "uiAcceptance.autoOrganize.neverSuggest"
                ) != nil
        }
        try press(
            identifier: "uiAcceptance.autoOrganize.neverSuggest",
            in: currentLibraryRoots(),
            failure: "Auto Organize suggestion has no Never Suggest action"
        )
        try waitUntil(timeout: 8, failure: "Never Suggest did not persist suppression") {
            return AXTree.first(in: currentLibraryRoots(), identifier: firstID) != nil
                && AXTree.first(
                    in: currentLibraryRoots(),
                    identifier: "uiAcceptance.autoOrganize.enable.\(firstUUID)"
                ).flatMap { AXTree.string(kAXValueAttribute as String, $0) } == "0"
                && pickerOptionIsSelected(
                    identifier: "uiAcceptance.autoOrganize.behavior.\(firstUUID)",
                    title: "Suggest",
                    in: currentLibraryRoots()
                )
        }
        try pass("auto-organize-literal-edit-safe-regex-apply-undo-always-never-and-crud")
    }

    private func verifyCustomFlowValidationCreateRunAndReview() throws {
        let actions = try requiredElement(
            in: currentLibraryRoots(),
            identifier: "uiAcceptance.library.actions",
            failure: "Library Actions destination is missing before Custom Action creation"
        )
        try AXTree.activateSelectableElement(actions)
        try press(
            title: "Custom Actions",
            in: currentLibraryRoots(),
            failure: "Actions workspace has no Custom Actions segment"
        )
        try press(
            identifier: "uiAcceptance.actions.newFlow",
            in: currentLibraryRoots(),
            failure: "Actions workspace has no Create Custom Action control"
        )
        try waitUntil(timeout: 8, failure: "Create Custom Action sheet did not open") {
            AXTree.first(in: currentSheetRoots(), identifier: "uiAcceptance.flow.editor") != nil
        }
        try setText(
            identifier: "uiAcceptance.flow.name",
            value: "Acceptance Local Flow",
            in: currentSheetRoots,
            failure: "Custom Action name field is missing"
        )
        try choosePickerOption(
            identifier: "uiAcceptance.flow.filter",
            title: "Custom words or pattern",
            in: currentSheetRoots,
            failure: "Custom Action filter picker is missing"
        )
        try setText(
            identifier: "uiAcceptance.customMatcher.pattern",
            value: "Acceptance",
            in: currentSheetRoots,
            failure: "Custom Action literal matcher field is missing"
        )
        try setText(
            identifier: "uiAcceptance.flow.tags",
            value: "flow-acceptance",
            in: currentSheetRoots,
            failure: "Custom Action tag step is missing"
        )
        try press(
            identifier: "uiAcceptance.flow.createTask",
            in: currentSheetRoots(),
            failure: "Custom Action has no follow-up note step toggle"
        )
        try setText(
            identifier: "uiAcceptance.flow.taskTitle",
            value: "Follow up: {title}",
            in: currentSheetRoots,
            failure: "Custom Action follow-up note title is missing"
        )
        let commit = try waitForEnabledElement(
            identifier: "uiAcceptance.flow.commit",
            in: currentSheetRoots,
            timeout: 8,
            failure: "literal local Custom Action did not become ready to save"
        )
        guard AXTree.string(kAXValueAttribute as String, commit) == "Ready" else {
            throw AcceptanceFailure(description: "literal local Custom Action commit did not publish Ready")
        }
        try AXTree.perform(kAXPressAction as String, on: commit)
        var flowRow: AXUIElement?
        try waitUntil(timeout: 8, failure: "saved Custom Action did not appear in Actions") {
            guard let title = AXTree.first(in: currentLibraryRoots(), title: "Acceptance Local Flow") else {
                return false
            }
            flowRow = AXTree.ancestor(
                of: title,
                identifierPrefix: "uiAcceptance.actions.flowRow."
            )
            return flowRow != nil
        }
        let flowRowID = try requiredIdentifier(
            flowRow!,
            failure: "saved Custom Action did not expose its stable UUID identifier"
        )
        let flowUUID = String(flowRowID.split(separator: ".").last ?? "")
        try press(
            identifier: "uiAcceptance.actions.flowEdit.\(flowUUID)",
            in: currentLibraryRoots(),
            failure: "literal Custom Action has no Edit action"
        )
        try waitUntil(timeout: 8, failure: "Edit Custom Action sheet did not open") {
            AXTree.first(in: currentSheetRoots(), identifier: "uiAcceptance.flow.editor") != nil
        }
        guard let literalMode = AXTree.first(
            in: currentSheetRoots(),
            identifier: "uiAcceptance.customMatcher.mode"
        ), AXTree.string(kAXValueAttribute as String, literalMode) == "Words or phrases",
        let literalPattern = AXTree.first(
            in: currentSheetRoots(),
            identifier: "uiAcceptance.customMatcher.pattern"
        ), AXTree.string(kAXValueAttribute as String, literalPattern) == "Acceptance"
        else {
            throw AcceptanceFailure(description: "literal Custom Action did not reopen with its committed matcher")
        }
        try press(
            title: "Regular expression",
            in: currentSheetRoots(),
            failure: "Custom Action edit omitted Regular expression"
        )
        try waitUntil(timeout: 3, failure: "Custom Action edit did not select Regular expression") {
            guard let mode = AXTree.first(
                in: currentSheetRoots(),
                identifier: "uiAcceptance.customMatcher.mode"
            ) else { return false }
            return AXTree.string(kAXValueAttribute as String, mode) == "Regular expression"
        }
        try setText(
            identifier: "uiAcceptance.customMatcher.pattern",
            value: "(a+)+",
            in: currentSheetRoots,
            failure: "Custom Action regex field is missing during edit"
        )
        let unsafeError = "Use a valid bounded regular expression with at most one variable repetition and no lookarounds, backreferences, or nested quantifiers."
        try waitUntil(timeout: 5, failure: "unsafe nested-quantifier regex was not rejected during edit") {
            guard let error = AXTree.first(
                in: currentSheetRoots(),
                identifier: "uiAcceptance.customMatcher.error"
            ), let editCommit = AXTree.first(
                in: currentSheetRoots(),
                identifier: "uiAcceptance.flow.commit"
            ) else { return false }
            return AXTree.string(kAXValueAttribute as String, error) == unsafeError
                && AXTree.string(kAXValueAttribute as String, editCommit) == "Unavailable"
        }
        try setText(
            identifier: "uiAcceptance.customMatcher.pattern",
            value: #"\bAcceptance\b"#,
            in: currentSheetRoots,
            failure: "Custom Action edit did not accept a safe regex"
        )
        let editCommit = try waitForEnabledElement(
            identifier: "uiAcceptance.flow.commit",
            in: currentSheetRoots,
            timeout: 8,
            failure: "safe regex Custom Action edit did not become ready"
        )
        guard AXTree.string(kAXValueAttribute as String, editCommit) == "Ready" else {
            throw AcceptanceFailure(description: "safe regex Custom Action edit did not publish Ready")
        }
        try AXTree.perform(kAXPressAction as String, on: editCommit)
        try waitUntil(timeout: 8, failure: "safe regex Custom Action edit did not persist") {
            guard AXTree.first(in: currentLibraryRoots(), identifier: flowRowID) != nil,
                  AXTree.first(
                      in: currentLibraryRoots(),
                      title: #"Matches /\bAcceptance\b/ · 2 steps · manual"#
                  ) != nil
            else { return false }
            return AXTree.first(in: currentLibraryRoots(), title: "Enabled") != nil
        }

        let saved = try requiredElement(
            in: currentLibraryRoots(),
            identifier: "uiAcceptance.library.saved",
            failure: "Saved destination disappeared before running Custom Action"
        )
        try AXTree.activateSelectableElement(saved)
        let search = try requiredElement(
            in: currentLibraryRoots(),
            identifier: "uiAcceptance.library.search",
            failure: "Library search disappeared before running Custom Action"
        )
        try AXTree.setFocused(true, on: search)
        try AXTree.setValue("Acceptance Editable Note", on: search)
        try AXTree.pressReturn()
        let noteID = "uiAcceptance.library.clip.00000000-0000-0000-0000-000000009001"
        try waitUntil(timeout: 8, failure: "saved note did not render before Custom Action run") {
            AXTree.first(in: currentLibraryRoots(), identifier: noteID) != nil
        }
        let note = try requiredElement(
            in: currentLibraryRoots(),
            identifier: noteID,
            failure: "saved note disappeared before Custom Action run"
        )
        try AXTree.activateSelectableElement(note)
        try press(
            identifier: "uiAcceptance.library.more",
            in: currentLibraryRoots(),
            failure: "saved note has no More menu for Custom Action"
        )
        try press(
            title: "Run Custom Action",
            in: [AXUIElementCreateSystemWide()] + currentApplicationRoots(),
            failure: "saved note More menu has no Run Custom Action submenu"
        )
        try press(
            title: "Acceptance Local Flow",
            in: [AXUIElementCreateSystemWide()] + currentApplicationRoots(),
            failure: "Run Custom Action omitted the saved local flow"
        )
        var review: AXUIElement?
        try waitUntil(timeout: 8, failure: "Custom Action review sheet did not open") {
            review = AXTree.first(in: currentSheetRoots(), where: { node in
                node.identifier?.hasPrefix("uiAcceptance.flow.review.") == true
            })
            return review != nil
        }
        let reviewID = try requiredIdentifier(
            review!,
            failure: "Custom Action review did not expose its run UUID"
        )
        let runUUID = String(reviewID.split(separator: ".").last ?? "")
        for expectedStep in ["flow-acceptance", "Follow up: {title}"] {
            guard AXTree.first(in: currentSheetRoots(), where: { node in
                node.identifier?.hasPrefix("uiAcceptance.flow.reviewStep.") == true
                    && node.value?.contains(expectedStep) == true
            }) != nil else {
                throw AcceptanceFailure(description: "Custom Action review omitted step \(expectedStep)")
            }
        }
        try press(
            identifier: "uiAcceptance.flow.reviewRun.\(runUUID)",
            in: currentSheetRoots(),
            failure: "Custom Action review has no Run action"
        )
        try waitUntil(timeout: 12, failure: "Custom Action run did not complete and dismiss") {
            AXTree.first(in: currentSheetRoots(), identifier: reviewID) == nil
        }
        try AXTree.activateSelectableElement(saved)
        let refreshedSearch = try requiredElement(
            in: currentLibraryRoots(),
            identifier: "uiAcceptance.library.search",
            failure: "Library search did not return after Custom Action run"
        )
        try AXTree.setFocused(true, on: refreshedSearch)
        try AXTree.setValue("tag:flow-acceptance", on: refreshedSearch)
        try AXTree.pressReturn()
        try waitUntil(timeout: 8, failure: "Custom Action tag step did not persist on the saved note") {
            AXTree.first(in: currentLibraryRoots(), identifier: noteID) != nil
        }
        // Verify the durable result in the canonical Saved surface. The Notes smart view is
        // intentionally a derived navigation projection and can still be completing its
        // deferred sidebar selection while the flow's persistence is already committed.
        let savedDestination = try requiredElement(
            in: currentLibraryRoots(),
            identifier: "uiAcceptance.library.saved",
            failure: "Saved destination disappeared after Custom Action run"
        )
        try AXTree.activateSelectableElement(savedDestination)
        let savedSearch = try requiredElement(
            in: currentLibraryRoots(),
            identifier: "uiAcceptance.library.search",
            failure: "Library search disappeared before follow-up note verification"
        )
        try AXTree.setFocused(true, on: savedSearch)
        try AXTree.setValue("", on: savedSearch)
        try AXTree.pressReturn()
        try waitUntil(timeout: 12, failure: "Custom Action follow-up note did not render after its run") {
            let roots = currentLibraryRoots()
            return AXTree.firstClipTitle(
                in: roots,
                title: "Follow up: Acceptance Editable Note"
            ) != nil || AXTree.snapshot(roots: roots).contains("Follow up: Acceptance Editable Note,")
        }
        guard AXTree.first(in: currentLibraryRoots(), identifier: flowRowID) == nil else {
            // The Actions row must not bleed into an ordinary saved-result surface.
            throw AcceptanceFailure(description: "Actions workspace remained overlaid after returning to Saved")
        }
        try pass("custom-flow-literal-create-edit-unsafe-rejection-safe-regex-review-and-run")
    }

    private func createAutomaticOrganizationRule(
        name: String,
        matchKind: String,
        matchValue: String?,
        tags: String
    ) throws -> AXUIElement {
        try press(
            identifier: "uiAcceptance.autoOrganize.newRule",
            in: currentLibraryRoots(),
            failure: "Auto Organize dashboard has no New Rule action"
        )
        try waitUntil(timeout: 5, failure: "New Organization Rule sheet did not open") {
            AXTree.first(in: currentSheetRoots(), identifier: "uiAcceptance.autoOrganize.editor") != nil
        }
        try setText(
            identifier: "uiAcceptance.autoOrganize.ruleName",
            value: name,
            in: currentSheetRoots,
            failure: "Organization Rule name field is missing"
        )
        try choosePickerOption(
            identifier: "uiAcceptance.autoOrganize.matchKind",
            title: matchKind,
            in: currentSheetRoots,
            failure: "Organization Rule match picker is missing"
        )
        if let matchValue {
            try setText(
                identifier: "uiAcceptance.autoOrganize.matchValue",
                value: matchValue,
                in: currentSheetRoots,
                failure: "Organization Rule match value is missing"
            )
        }
        try setText(
            identifier: "uiAcceptance.autoOrganize.tags",
            value: tags,
            in: currentSheetRoots,
            failure: "Organization Rule tags field is missing"
        )
        try press(
            identifier: "uiAcceptance.autoOrganize.saveRule",
            in: currentSheetRoots(),
            failure: "Organization Rule has no Create Rule action"
        )
        var created: AXUIElement?
        try waitUntil(timeout: 8, failure: "created Auto Organize rule did not appear") {
            guard let title = AXTree.first(in: currentLibraryRoots(), title: name) else {
                return false
            }
            created = AXTree.ancestor(
                of: title,
                identifierPrefix: "uiAcceptance.autoOrganize.row."
            )
            return created != nil
        }
        return created!
    }

    private func requiredIdentifier(
        _ element: AXUIElement,
        failure: String
    ) throws -> String {
        guard let identifier = AXTree.string(kAXIdentifierAttribute as String, element),
              !identifier.isEmpty
        else { throw AcceptanceFailure(description: failure) }
        return identifier
    }

    private func openAcceptanceSalesHandoff() throws {
        try openContextMenu(
            identifier: "uiAcceptance.folder.Acceptance Account",
            failure: "created sales workspace disappeared before reopening handoff review"
        )
        do {
            try press(
                title: "Create Research Handoff…",
                in: [AXUIElementCreateSystemWide()] + currentApplicationRoots(),
                failure: "sales workspace lost Create Research Handoff"
            )
        } catch {
            try pressTitlePrefix(
                "Create Research Handoff",
                failure: "sales workspace lost Create Research Handoff"
            )
        }
        try waitUntil(timeout: 8, failure: "Research Handoff review did not reopen") {
            AXTree.first(
                in: currentSheetRoots(),
                identifier: "uiAcceptance.sales.handoffReview"
            ) != nil
        }
    }

    private func exportAndParseAcceptanceSalesHandoff(
        format: String,
        extensionName: String
    ) throws {
        try openAcceptanceSalesHandoff()
        try press(
            title: format,
            in: currentSheetRoots(),
            failure: "Research Handoff format picker omitted \(format)"
        )
        try waitUntil(timeout: 3, failure: "Research Handoff did not select \(format) for export") {
            guard let picker = AXTree.first(
                in: currentSheetRoots(),
                identifier: "uiAcceptance.sales.handoffFormat"
            ) else { return false }
            return AXTree.string(kAXValueAttribute as String, picker) == format
        }
        let exportURL = arguments.evidenceDirectory
            .appendingPathComponent("Acceptance Account.\(extensionName)", isDirectory: false)
        guard !FileManager.default.fileExists(atPath: exportURL.path) else {
            throw AcceptanceFailure(
                description: "handoff evidence destination already exists: \(exportURL.lastPathComponent)"
            )
        }
        try press(
            identifier: "uiAcceptance.sales.exportHandoff",
            in: currentSheetRoots(),
            failure: "Research Handoff has no Export \(format) action"
        )
        try chooseEvidenceDirectoryInSavePanel(
            title: "Export Research Handoff",
            directory: arguments.evidenceDirectory,
            confirmTitle: "Export"
        )
        try waitUntil(timeout: 10, failure: "Export \(format) did not write the evidence file") {
            FileManager.default.fileExists(atPath: exportURL.path)
        }
        let data = try Data(contentsOf: exportURL)
        switch format {
        case "Markdown":
            guard let text = String(data: data, encoding: .utf8) else {
                throw AcceptanceFailure(description: "exported handoff Markdown is not UTF-8")
            }
            let summary = try HandoffEvidenceParser.parseMarkdown(text)
            guard summary == HandoffEvidenceSummary(
                rootTitle: "Acceptance Account",
                itemCount: 1,
                omittedCount: 0,
                recordTitles: ["Acceptance Editable Note"]
            ), text.contains("- Tags: acceptance, sales-ready") else {
                throw AcceptanceFailure(description: "exported handoff Markdown failed parsed content/count verification")
            }
        case "CSV":
            guard let text = String(data: data, encoding: .utf8) else {
                throw AcceptanceFailure(description: "exported handoff CSV is not UTF-8")
            }
            let records = try HandoffEvidenceParser.parseCSV(text)
            guard records.count == 1,
                  records[0]["schema_version"] == "1",
                  records[0]["title"] == "Acceptance Editable Note",
                  records[0]["folder_path"] == "Acceptance Account",
                  records[0]["tags"] == "acceptance|sales-ready"
            else {
                throw AcceptanceFailure(description: "exported handoff CSV failed parsed schema/content/count verification")
            }
        case "JSON":
            let summary = try HandoffEvidenceParser.parseJSON(data)
            guard summary == HandoffEvidenceSummary(
                rootTitle: "Acceptance Account",
                itemCount: 1,
                omittedCount: 0,
                recordTitles: ["Acceptance Editable Note"]
            ), let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let record = (object["records"] as? [[String: Any]])?.first,
               record["folderPath"] as? String == "Acceptance Account",
               record["tags"] as? [String] == ["acceptance", "sales-ready"]
            else {
                throw AcceptanceFailure(description: "exported handoff JSON failed parsed schema/content/count verification")
            }
        default:
            throw AcceptanceFailure(description: "unsupported acceptance handoff format \(format)")
        }
    }

    private func chooseEvidenceDirectoryInSavePanel(
        title: String,
        directory: URL,
        confirmTitle: String
    ) throws {
        try waitUntil(timeout: 8, failure: "\(title) save panel did not open") {
            AXTree.first(in: currentApplicationRoots(), title: title) != nil
        }
        try AXTree.pressGoToFolder()
        var pathField: AXUIElement?
        try waitUntil(timeout: 5, failure: "\(title) did not expose Go to Folder") {
            pathField = AXTree.first(in: currentApplicationRoots(), where: { node in
                node.role == kAXTextFieldRole as String
                    && (node.identifier == "PathTextField"
                        || node.title == "Go to the folder:"
                        || node.label == "Go to the folder:")
            })
            return pathField != nil
        }
        try AXTree.setValue(directory.path, on: pathField!)
        try AXTree.pressReturn()
        let confirm = try requiredElement(
            in: currentApplicationRoots(),
            title: confirmTitle,
            failure: "\(title) has no \(confirmTitle) action"
        )
        try AXTree.clickCenter(of: confirm)
        try waitUntil(timeout: 8, failure: "\(title) did not dismiss after export") {
            AXTree.first(in: currentApplicationRoots(), title: title) == nil
        }
    }

    private func verifyDebugBundleSaveAndProjectReview() throws {
        try selectHistoryFixture(query: "sarah@example.com", index: 1)
        try press(
            identifier: "uiAcceptance.library.more",
            in: currentLibraryRoots(),
            failure: "history fixture has no More menu for Debug Bundle"
        )
        try press(
            title: "Clip Tools",
            in: [AXUIElementCreateSystemWide()] + currentApplicationRoots(),
            failure: "history fixture More menu has no Clip Tools submenu"
        )
        try press(
            title: "Add to Debug Bundle",
            in: [AXUIElementCreateSystemWide()] + currentApplicationRoots(),
            failure: "Clip Tools has no Add to Debug Bundle action"
        )

        try selectHistoryFixture(query: "preview.clipboardrouter.test/loaded", index: 2)
        try press(
            identifier: "uiAcceptance.library.more",
            in: currentLibraryRoots(),
            failure: "second history fixture has no More menu for Debug Bundle"
        )
        try press(
            title: "Clip Tools",
            in: [AXUIElementCreateSystemWide()] + currentApplicationRoots(),
            failure: "second history fixture More menu has no Clip Tools submenu"
        )
        try press(
            title: "Add to Debug Bundle",
            in: [AXUIElementCreateSystemWide()] + currentApplicationRoots(),
            failure: "second fixture could not be added to Debug Bundle"
        )

        let actions = try requiredElement(
            in: currentLibraryRoots(),
            identifier: "uiAcceptance.library.actions",
            failure: "Library Actions destination is missing"
        )
        try AXTree.activateSelectableElement(actions)
        try press(
            title: "Clip Tools",
            in: currentLibraryRoots(),
            failure: "Actions workspace has no Clip Tools segment"
        )
        try waitUntil(timeout: 8, failure: "Debug Bundle workspace did not show the added fixture") {
            guard let workspace = AXTree.first(
                in: currentLibraryRoots(),
                identifier: "uiAcceptance.debugBundle.workspace"
            ) else { return false }
            return AXTree.string(kAXValueAttribute as String, workspace)
                == "Acceptance Project, 2 items"
        }
        let secondItemID = "uiAcceptance.debugBundle.item.00000000-0000-0000-0000-000000000002"
        try press(
            identifier: "uiAcceptance.debugBundle.moveEarlier.00000000-0000-0000-0000-000000000002",
            in: currentLibraryRoots(),
            failure: "second Debug Bundle item has no Move Earlier action"
        )
        try waitUntil(timeout: 5, failure: "Debug Bundle reorder did not move the second item first") {
            guard let item = AXTree.first(in: currentLibraryRoots(), identifier: secondItemID) else {
                return false
            }
            let text = [
                AXTree.string(kAXTitleAttribute as String, item),
                AXTree.string(kAXDescriptionAttribute as String, item),
                AXTree.string(kAXValueAttribute as String, item),
                AXTree.string(kAXHelpAttribute as String, item),
            ].compactMap { $0 }.joined(separator: " ")
            return text.contains("Debug Bundle item 1,")
        }
        try press(
            identifier: "uiAcceptance.debugBundle.review",
            in: currentLibraryRoots(),
            failure: "Debug Bundle workspace has no Review Bundle action"
        )
        try waitUntil(timeout: 8, failure: "Debug Bundle review sheet did not open") {
            AXTree.first(
                in: currentSheetRoots(),
                identifier: "uiAcceptance.debugBundle.reviewSheet"
            ) != nil
        }
        let destination = try requiredElement(
            in: currentSheetRoots(),
            identifier: "uiAcceptance.debugBundle.destination",
            failure: "Debug Bundle review has no destination project picker"
        )
        guard AXTree.string(kAXValueAttribute as String, destination) == "Acceptance Project" else {
            throw AcceptanceFailure(description: "Debug Bundle did not default to the active Acceptance Project")
        }
        try setText(
            identifier: "uiAcceptance.debugBundle.problem",
            value: "Acceptance packaged debug bundle review",
            in: currentSheetRoots,
            failure: "Debug Bundle problem statement field is missing"
        )
        try waitUntil(timeout: 5, failure: "Debug Bundle Markdown preview did not incorporate the review") {
            guard let preview = AXTree.first(
                in: currentSheetRoots(),
                identifier: "uiAcceptance.debugBundle.preview"
            ), let markdown = AXTree.string(kAXValueAttribute as String, preview)
            else { return false }
            return markdown.contains("Acceptance Project")
                && markdown.contains("Acceptance packaged debug bundle review")
        }
        let save = try waitForEnabledElement(
            identifier: "uiAcceptance.debugBundle.saveProject",
            in: currentSheetRoots,
            timeout: 5,
            failure: "Debug Bundle Save to Project did not enable"
        )
        try AXTree.perform(kAXPressAction as String, on: save)
        try waitUntil(timeout: 8, failure: "Debug Bundle did not confirm its local Project save") {
            guard let currentSave = AXTree.first(
                in: currentSheetRoots(),
                identifier: "uiAcceptance.debugBundle.saveProject"
            ) else { return false }
            return AXTree.string(kAXValueAttribute as String, currentSave) == "Saved"
        }
        try press(
            identifier: "uiAcceptance.debugBundle.close",
            in: currentSheetRoots(),
            failure: "Debug Bundle review has no Close action"
        )

        let projects = try requiredElement(
            in: currentLibraryRoots(),
            identifier: "uiAcceptance.library.projects",
            failure: "Projects destination disappeared after Debug Bundle save"
        )
        try AXTree.activateSelectableElement(projects)
        try press(
            title: "Debug Bundles",
            in: currentLibraryRoots(),
            failure: "Project workspace has no Debug Bundles tab"
        )
        try waitUntil(timeout: 8, failure: "Project did not render its saved Debug Bundle") {
            guard let count = AXTree.first(
                in: currentLibraryRoots(),
                identifier: "uiAcceptance.projects.debugBundles"
            ), AXTree.string(kAXValueAttribute as String, count) == "1 saved bundle"
            else { return false }
            return AXTree.first(in: currentLibraryRoots(), where: { node in
                node.identifier?.hasPrefix("uiAcceptance.projects.debugBundleRow.") == true
            }) != nil
        }
        try pass("debug-bundle-two-item-reorder-review-save-and-project-reopen")
    }

    private func prepareAcceptanceRepository() throws -> URL {
        let root = arguments.evidenceDirectory
            .appendingPathComponent("acceptance-repository", isDirectory: true)
        let git = root.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        try Data("ref: refs/heads/acceptance\n".utf8).write(
            to: git.appendingPathComponent("HEAD"),
            options: .atomic
        )
        return root
    }

    private func chooseRepositoryInOpenPanel(_ repositoryURL: URL) throws {
        try waitUntil(timeout: 8, failure: "repository chooser did not open") {
            AXTree.first(in: currentApplicationRoots(), title: "Choose Repository Folder") != nil
        }
        try AXTree.pressGoToFolder()
        var pathField: AXUIElement?
        try waitUntil(timeout: 5, failure: "repository chooser did not expose Go to Folder") {
            pathField = AXTree.first(in: currentApplicationRoots(), where: { node in
                node.role == kAXTextFieldRole as String
                    && (node.identifier == "PathTextField"
                        || node.title == "Go to the folder:"
                        || node.label == "Go to the folder:")
            })
            return pathField != nil
        }
        try AXTree.setValue(repositoryURL.path, on: pathField!)
        try AXTree.pressReturn()
        let chooseButton = try requiredElement(
            in: currentApplicationRoots(),
            title: "Choose Repository",
            failure: "repository chooser has no Choose Repository action"
        )
        // NSOpenPanel can transiently reject either path immediately after its Go to Folder
        // sheet closes. Try the fresh semantic action first, then one real click, and finally
        // one reacquired semantic retry; the panel dismissal remains authoritative.
        let chooseResult = AXTree.performResult(kAXPressAction as String, on: chooseButton)
        if chooseResult != .success {
            try AXTree.clickCenter(of: chooseButton)
        }
        do {
            try waitUntil(timeout: 3, failure: "repository chooser did not dismiss") {
                AXTree.first(in: currentApplicationRoots(), title: "Choose Repository Folder") == nil
            }
        } catch {
            guard let retryButton = AXTree.first(
                in: currentApplicationRoots(),
                title: "Choose Repository"
            ) else { throw error }
            let retryResult = AXTree.performResult(kAXPressAction as String, on: retryButton)
            if retryResult != .success {
                try AXTree.clickCenter(of: retryButton)
            }
            try waitUntil(timeout: 5, failure: "repository chooser did not dismiss") {
                AXTree.first(in: currentApplicationRoots(), title: "Choose Repository Folder") == nil
            }
        }
    }

    private func verifyPersistenceAcrossRelaunch(bundle: Bundle) throws {
        guard let activeProcess = process else {
            throw AcceptanceFailure(description: "no acceptance process exists for relaunch")
        }
        let relaunchBoundaryCount = evidence.boundaryCount
        // A Process closes its inherited pipe descriptors when it exits. Detach the
        // readability handler before creating the fresh pipe for the controlled relaunch;
        // reusing the first pipe causes Foundation to raise NSFileHandleOperationException.
        consoleCapture.stopMirroring()
        cachedLibraryWindow = nil
        activeProcess.terminate()
        activeProcess.waitUntilExit()
        let readyMarkerBaseline = consoleCapture.acceptanceReadyMarkerCount()
        let launchStartedAt = Date()
        let relaunched = try launch(bundle: bundle)
        let relaunchedRoot = AXUIElementCreateApplication(relaunched.processIdentifier)
        try waitForAcceptanceReadiness(
            afterMarkerCount: readyMarkerBaseline,
            startedAt: launchStartedAt,
            phase: "controlled-relaunch"
        )
        try waitUntil(timeout: 15, failure: "acceptance app did not relaunch with its existing run state") {
            AXTree.first(in: self.currentApplicationRoots(), where: {
                $0.role == kAXApplicationRole as String
            }) != nil
        }
        let statusItem = try waitForStatusItem(applicationRoot: relaunchedRoot, timeout: 15)
        try openMenu(statusItem: statusItem, appRoot: relaunchedRoot)
        try press(
            identifier: "uiAcceptance.menu.openLibrary",
            in: currentApplicationRoots(),
            failure: "relaunched app is missing Open Library"
        )
        try waitUntil(timeout: 10, failure: "Library did not reopen after controlled relaunch") {
            !currentLibraryRoots().isEmpty
        }
        let notes = try requiredElement(
            in: currentLibraryRoots(),
            identifier: "uiAcceptance.smartViews.row.Notes",
            failure: "relaunched Library has no Notes destination"
        )
        try AXTree.activateSelectableElement(notes)
        try waitUntil(timeout: 8, failure: "created note did not survive process relaunch") {
            let roots = currentLibraryRoots()
            return AXTree.firstClipTitle(
                in: roots,
                title: "Acceptance Created Note"
            ) != nil || AXTree.snapshot(roots: roots).contains("Acceptance Created Note,")
        }
        do {
            try waitUntil(timeout: 8, failure: "Custom Action follow-up note did not survive process relaunch") {
                let roots = currentLibraryRoots()
                return AXTree.firstClipTitle(
                    in: roots,
                    title: "Follow up: Acceptance Editable Note"
                ) != nil || AXTree.snapshot(roots: roots).contains("Follow up: Acceptance Editable Note,")
            }
        } catch let failure as AcceptanceFailure {
            try recordRelaunchBoundary(
                name: "custom-flow-follow-up-relaunch",
                failure: failure,
                prerequisite: "custom-flow-follow-up-note"
            )
        }
        guard AXTree.first(in: currentLibraryRoots(), where: { node in
            node.identifier?.hasPrefix("uiAcceptance.smartViews.row.") == true
                && node.value?.contains("name=Acceptance Saved Notes Updated") == true
                && node.value?.contains("pinned=true") == true
        }) != nil else {
            throw AcceptanceFailure(description: "edited pinned Smart View did not survive process relaunch")
        }
        let actions = try requiredElement(
            in: currentLibraryRoots(),
            identifier: "uiAcceptance.library.actions",
            failure: "relaunched Library has no Actions destination"
        )
        try AXTree.activateSelectableElement(actions)
        try press(
            title: "Custom Actions",
            in: currentLibraryRoots(),
            failure: "relaunched Actions workspace has no Custom Actions segment"
        )
        do {
            try waitUntil(timeout: 8, failure: "safe Custom Action definition did not survive process relaunch") {
                AXTree.first(in: currentLibraryRoots(), where: { node in
                    node.identifier?.hasPrefix("uiAcceptance.actions.flowRow.") == true
                        && node.value?.contains("Acceptance") == true
                        && node.value?.contains("Matches /") == true
                        && node.value?.contains("2 steps") == true
                }) != nil
            }
        } catch let failure as AcceptanceFailure {
            try recordRelaunchBoundary(
                name: "custom-flow-definition-relaunch",
                failure: failure,
                prerequisite: nil
            )
        }
        let auto = try requiredElement(
            in: currentLibraryRoots(),
            identifier: "uiAcceptance.library.autoOrganize",
            failure: "relaunched Library has no Auto Organize destination"
        )
        try AXTree.activateSelectableElement(auto)
        do {
            var persistedAutoRow: AXUIElement?
            try waitUntil(timeout: 8, failure: "edited Auto Organize rule did not survive process relaunch") {
                persistedAutoRow = AXTree.first(in: currentLibraryRoots(), where: { node in
                    node.identifier?.hasPrefix("uiAcceptance.autoOrganize.row.") == true
                        && node.value?.contains("name=Acceptance Auto Updated") == true
                        && node.value?.contains("enabled=false") == true
                        && node.value?.contains("behavior=suggest") == true
                        && node.value?.contains("suppressed=true") == true
                })
                return persistedAutoRow != nil
            }
            let persistedAutoID = try requiredIdentifier(
                persistedAutoRow!,
                failure: "persisted Auto Organize rule lost its stable UUID identifier"
            )
            let persistedAutoUUID = String(persistedAutoID.split(separator: ".").last ?? "")
            try press(
                identifier: "uiAcceptance.autoOrganize.edit.\(persistedAutoUUID)",
                in: currentLibraryRoots(),
                failure: "persisted Auto Organize rule has no Edit action"
            )
            try waitUntil(timeout: 5, failure: "persisted Auto Organize editor did not reopen") {
                guard let editor = AXTree.first(
                    in: currentSheetRoots(),
                    identifier: "uiAcceptance.autoOrganize.editor"
                ), let value = AXTree.string(kAXValueAttribute as String, editor),
                let matchValue = AXTree.first(
                    in: currentSheetRoots(),
                    identifier: "uiAcceptance.autoOrganize.matchValue"
                ) else { return false }
                return value.contains("match=Safe regex")
                    && AXTree.string(kAXValueAttribute as String, matchValue) == #"\bAcceptance\b"#
            }
            try press(
                identifier: "uiAcceptance.autoOrganize.cancel",
                in: currentSheetRoots(),
                failure: "persisted Auto Organize editor has no Cancel action"
            )
        } catch let failure as AcceptanceFailure {
            try recordRelaunchBoundary(
                name: "automatic-organization-relaunch",
                failure: failure,
                prerequisite: "automatic-organization"
            )
        }
        let projects = try requiredElement(
            in: currentLibraryRoots(),
            identifier: "uiAcceptance.library.projects",
            failure: "relaunched Library has no Projects destination"
        )
        try AXTree.activateSelectableElement(projects)
        try waitUntil(timeout: 8, failure: "created Project did not survive process relaunch") {
            AXTree.first(in: currentLibraryRoots(), title: "Acceptance Project") != nil
        }
        do {
            guard AXTree.first(
                in: currentLibraryRoots(),
                identifier: "uiAcceptance.folder.Acceptance Account"
            ) != nil else {
                throw AcceptanceFailure(description: "sales workspace did not survive process relaunch")
            }
        } catch let failure as AcceptanceFailure {
            try recordRelaunchBoundary(
                name: "sales-workspace-relaunch",
                failure: failure,
                prerequisite: "sales-workspace-and-handoff"
            )
        }
        do {
            try press(
                title: "Debug Bundles",
                in: currentLibraryRoots(),
                failure: "relaunched Project has no Debug Bundles tab"
            )
            try waitUntil(timeout: 8, failure: "saved Debug Bundle did not survive process relaunch") {
                guard let count = AXTree.first(
                    in: currentLibraryRoots(),
                    identifier: "uiAcceptance.projects.debugBundles"
                ), AXTree.string(kAXValueAttribute as String, count) == "1 saved bundle"
                else { return false }
                return AXTree.first(in: currentLibraryRoots(), where: { node in
                    node.identifier?.hasPrefix("uiAcceptance.projects.debugBundleRow.") == true
                }) != nil
            }
        } catch let failure as AcceptanceFailure {
            try recordRelaunchBoundary(
                name: "debug-bundle-relaunch",
                failure: failure,
                prerequisite: "debug-bundle-save-and-project-review"
            )
        }
        if evidence.boundaryCount == relaunchBoundaryCount {
            try pass("sqlite-note-project-and-ui-state-survive-controlled-relaunch")
        }
    }

    private func verifyLibraryWindowLifecycle(
        statusItem: AXUIElement,
        appRoot: AXUIElement
    ) throws {
        if settingsWindow() != nil {
            try closeSettings(appRoot: appRoot)
        }
        let library = try requiredLibraryWindow(
            failure: "Library window disappeared before lifecycle verification"
        )
        guard let minimizeButton = AXTree.first(in: [library], where: { node in
            node.subrole == "AXMinimizeButton"
        }) else {
            throw AcceptanceFailure(description: "Library window has no minimize button")
        }
        try AXTree.perform(kAXPressAction as String, on: minimizeButton)
        try waitUntil(timeout: 5, failure: "Library window did not minimize") {
            guard let current = currentLibraryRoots().first else { return false }
            return AXTree.boolean(kAXMinimizedAttribute as String, current) == true
        }
        try pressDockMinimizedLibraryItem()
        try waitUntil(timeout: 10, failure: "Dock activation did not restore the minimized Library") {
            guard let current = currentLibraryRoots().first else { return false }
            return AXTree.boolean(kAXMinimizedAttribute as String, current) != true
        }
        try pass("library-minimize-and-dock-activation-restore")

        try closeLibraryWindow()
        try activateFinderBeforeDockReopen()
        try pressDockApplicationItem()
        try waitUntil(timeout: 10, failure: "Dock activation did not recreate the closed Library") {
            !currentLibraryRoots().isEmpty
        }
        try pass("library-close-and-dock-reopen")

        try closeLibraryWindow()
        try openMenu(statusItem: statusItem, appRoot: appRoot)
        try press(
            identifier: "uiAcceptance.menu.openLibrary",
            in: currentApplicationRoots(),
            failure: "Open Library disappeared after closing its desktop window"
        )
        try waitUntil(timeout: 10, failure: "menu bar did not recreate the closed Library") {
            !currentLibraryRoots().isEmpty
        }
        try pass("library-close-and-menu-bar-reopen")
    }

    private func requiredLibraryWindow(failure: String) throws -> AXUIElement {
        guard let window = currentLibraryRoots().first else {
            throw AcceptanceFailure(description: failure)
        }
        return window
    }

    private func closeLibraryWindow() throws {
        let library = try requiredLibraryWindow(failure: "Library window is unavailable to close")
        guard let closeButton = AXTree.first(in: [library], where: { node in
            node.subrole == "AXCloseButton"
        }) else {
            throw AcceptanceFailure(description: "Library window has no close button")
        }
        try AXTree.perform(kAXPressAction as String, on: closeButton)
        cachedLibraryWindow = nil
        try waitUntil(timeout: 5, failure: "Library window did not close") {
            currentLibraryRoots().isEmpty
        }
    }

    private func pressDockApplicationItem() throws {
        var dockItem = currentDockApplicationItem()
        try waitUntil(timeout: 8, failure: "Clipboard Router did not appear in the Dock") {
            dockItem = currentDockApplicationItem()
            return dockItem != nil
        }
        let title = AXTree.string(kAXTitleAttribute as String, dockItem!) ?? "nil"
        let url = AXTree.url(dockItem!)?.path ?? "nil"
        let actions = AXTree.actionNames(dockItem!).joined(separator: ",")
        evidence.recordDiagnosticObservation(
            name: "dock-application-item-before-activation",
            value: "title=\(title) url=\(url) actions=\(actions) frontmost=\(frontmostApplicationDescription())"
        )
        // The user's Dock is configured to auto-hide. Hover the currently published tile long
        // enough to reveal the Dock, then reacquire its post-animation AX object and frame before
        // either semantic or physical activation.
        try AXTree.hoverCenter(of: dockItem!)
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        dockItem = currentDockApplicationItem()
        guard let revealedDockItem = dockItem else {
            throw AcceptanceFailure(description: "exact Clipboard Router Dock tile disappeared after reveal")
        }
        let pressResult = AXTree.performResult(kAXPressAction as String, on: revealedDockItem)
        evidence.recordDiagnosticObservation(
            name: "dock-application-item-axpress-result",
            value: String(pressResult.rawValue)
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        if process.map({ NSWorkspace.shared.frontmostApplication?.processIdentifier != $0.processIdentifier })
            ?? true
        {
            // Dock's AXPress can be acknowledged without activating an accessory-policy process
            // after its last ordinary window closes. Click the exact URL-matched application
            // tile once only when the fresh post-press state proves no activation occurred.
            try AXTree.hoverCenter(of: revealedDockItem)
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            guard let freshDockItem = currentDockApplicationItem() else {
                throw AcceptanceFailure(description: "exact Clipboard Router Dock tile disappeared before click")
            }
            try AXTree.clickCenter(of: freshDockItem)
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        evidence.recordDiagnosticObservation(
            name: "dock-application-item-after-click",
            value: "frontmost=\(frontmostApplicationDescription()) libraryVisible=\(!currentLibraryRoots().isEmpty)"
        )
        if let process,
           NSWorkspace.shared.frontmostApplication?.processIdentifier != process.processIdentifier
        {
            try waitUntil(timeout: 5, failure: "Dock press did not activate the exact Clipboard Router process") {
                NSWorkspace.shared.frontmostApplication?.processIdentifier
                    == process.processIdentifier
            }
        }
    }

    private func frontmostApplicationDescription() -> String {
        guard let application = NSWorkspace.shared.frontmostApplication else { return "nil" }
        return "\(application.bundleIdentifier ?? "nil")#\(application.processIdentifier)"
    }

    private func activateFinderBeforeDockReopen() throws {
        try activateFinder(reason: "Dock reopen")
    }

    private func activateFinderForStatusItem() throws {
        try activateFinder(reason: "status-item activation")
    }

    private func activateFinder(reason: String) throws {
        guard let finder = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.finder"
        ).first else {
            throw AcceptanceFailure(description: "Finder is unavailable before \(reason)")
        }
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier != "com.apple.finder" {
            _ = finder.activate(options: [.activateAllWindows])
        }
        // Best-effort precondition only: some macOS runner environments refuse or do not need
        // foreground activation for a background-launched agent (e.g. no user session focus,
        // Spaces/SIP restrictions). The subsequent status-item/Dock press is the real assertion;
        // failing to raise Finder first must not block it. Genuine hard failures (Accessibility
        // revoked, acceptance process exiting) still propagate.
        let deadline = Date().addingTimeInterval(5)
        var becameFrontmost = false
        repeat {
            guard AXIsProcessTrusted() else {
                throw AcceptanceFailure(
                    description: "Accessibility permission was revoked during the run",
                    isEnvironmental: true
                )
            }
            if process?.isRunning == false {
                throw AcceptanceFailure(
                    description: "acceptance application exited before Finder activation for \(reason)"
                )
            }
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" {
                becameFrontmost = true
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        evidence.recordDiagnosticObservation(
            name: "finder-activation-before-\(reason)",
            value: "becameFrontmost=\(becameFrontmost) frontmost=\(frontmostApplicationDescription())"
        )
    }

    private func pressDockMinimizedLibraryItem() throws {
        var dockItem: AXUIElement?
        try waitUntil(timeout: 8, failure: "minimized Library did not appear in the Dock") {
            dockItem = AXTree.first(in: dockRoots(), where: { node in
                DockMinimizedWindowItemCandidate(
                    subrole: node.subrole,
                    title: node.title,
                    actions: node.actions
                ).matchesLibrary
            })
            return dockItem != nil
        }
        try AXTree.perform(kAXPressAction as String, on: dockItem!)
    }

    private func currentDockApplicationItem() -> AXUIElement? {
        AXTree.first(in: dockRoots(), where: { node in
            DockApplicationItemCandidate(
                subrole: node.subrole,
                url: AXTree.url(node.element),
                actions: node.actions
            ).matches(applicationURL: arguments.applicationURL)
        })
    }

    private func settingsWindow() -> AXUIElement? {
        guard let applicationRoot = currentApplicationRoots().first else { return nil }
        return AXTree.first(in: AXTree.windowRoots(in: applicationRoot), where: { node in
            node.role == kAXWindowRole as String
                && (node.title == "Clipboard Router Settings"
                    || node.identifier == "com_apple_SwiftUI_Settings_window")
        })
    }

    private func selectLibraryFilter(title: String, failure: String) throws {
        var filter: AXUIElement?
        try waitUntil(timeout: 5, failure: failure) {
            filter = AXTree.first(in: currentLibraryRoots(), where: { node in
                LibraryFilterCandidate(
                    role: node.role,
                    title: node.title,
                    label: node.label,
                    value: node.value
                ).matches(title: title)
            })
            return filter != nil
        }
        try AXTree.perform(kAXPressAction as String, on: filter!)
    }

    private func currentApplicationRoots() -> [AXUIElement] {
        guard let process else { return [] }
        return [AXUIElementCreateApplication(process.processIdentifier)]
    }

    private func currentLibraryRoots() -> [AXUIElement] {
        if let cachedLibraryWindow {
            let role = AXTree.string(kAXRoleAttribute as String, cachedLibraryWindow)
            let identifier = AXTree.string(kAXIdentifierAttribute as String, cachedLibraryWindow)
            let title = AXTree.string(kAXTitleAttribute as String, cachedLibraryWindow)
            if role == kAXWindowRole as String,
               (identifier == "library" || title == "Clipboard Router"),
               AXTree.boolean(kAXMinimizedAttribute as String, cachedLibraryWindow) != true {
                return [cachedLibraryWindow]
            }
            self.cachedLibraryWindow = nil
        }
        guard let applicationRoot = currentApplicationRoots().first,
              let libraryWindow = AXTree.first(
                in: AXTree.windowRoots(in: applicationRoot),
                where: { node in
                    node.role == kAXWindowRole as String
                        && (node.identifier == "library" || node.title == "Clipboard Router")
                }
              )
        else { return [] }
        cachedLibraryWindow = libraryWindow
        return [libraryWindow]
    }

    /// Follow-up work can be hosted either by an ordinary Library sheet or by the
    /// dedicated menu-bar continuation window. Recreate the application element for
    /// every observation so a poll cannot retain a pre-presentation accessibility graph.
    private func currentSheetRoots() -> [AXUIElement] {
        guard let currentApplicationRoot = currentApplicationRoots().first else { return [] }
        var roots = AXTree.sheetRoots(in: currentApplicationRoot)
        if let continuationWindow = AXTree.first(
            in: AXTree.windowRoots(in: currentApplicationRoot),
            where: { node in
                node.role == kAXWindowRole as String
                    && node.identifier == "uiAcceptance.menuBarContinuation.window"
            }
        ) {
            roots.append(continuationWindow)
        }
        return roots
    }

    private func requiredElement(
        in roots: [AXUIElement],
        identifier: String,
        failure: String
    ) throws -> AXUIElement {
        guard let element = AXTree.first(in: roots, identifier: identifier) else {
            throw AcceptanceFailure(description: failure)
        }
        return element
    }

    private func requiredElement(
        in roots: [AXUIElement],
        title: String,
        failure: String
    ) throws -> AXUIElement {
        var element: AXUIElement?
        try waitUntil(timeout: 5, failure: failure) {
            element = AXTree.first(in: roots, title: title)
            return element != nil
        }
        return element!
    }

    /// Reacquires a dynamic SwiftUI control until its real AppKit accessibility element is
    /// enabled. Merely observing an AX value on an editor does not prove SwiftUI has propagated
    /// that value into the state which drives a button's disabled predicate.
    private func waitForEnabledElement(
        identifier: String,
        in currentRoots: () -> [AXUIElement],
        timeout: TimeInterval,
        failure: String
    ) throws -> AXUIElement {
        var enabledElement: AXUIElement?
        try waitUntil(timeout: timeout, failure: failure) {
            guard let candidate = AXTree.first(
                in: currentRoots(),
                identifier: identifier
            ), AXTree.boolean(kAXEnabledAttribute as String, candidate) == true,
            AXTree.actionNames(candidate).contains(kAXPressAction as String)
            else { return false }
            enabledElement = candidate
            return true
        }
        return enabledElement!
    }

    private func press(
        identifier: String,
        in roots: [AXUIElement],
        failure: String
    ) throws {
        if identifier == "uiAcceptance.autoOrganize.saveRule" {
            // The editor's Save button can return kAXErrorCannotComplete while
            // SwiftUI is replacing the sheet tree. Reacquire and retry the actual
            // AXPress until the sheet closes; the caller still verifies the saved
            // rule afterward, so this cannot turn a no-op into a pass.
            try waitUntil(timeout: 6, interval: 0.15, failure: failure) {
                if AXTree.first(
                    in: self.currentSheetRoots(),
                    identifier: "uiAcceptance.autoOrganize.editor"
                ) == nil {
                    return true
                }
                guard let candidate = AXTree.first(
                    in: self.currentSheetRoots(),
                    identifier: identifier
                ) else { return false }
                let error = AXTree.performResult(kAXPressAction as String, on: candidate)
                return error == .success
            }
            return
        }
        if identifier == "uiAcceptance.autoOrganize.alwaysApply"
            || identifier == "uiAcceptance.autoOrganize.neverSuggest" {
            // The suggestion card can be replaced in the same transaction that
            // handles either action. Retry the exact button until AXPress succeeds
            // or the card disappears; the following behavior/suppression assertion
            // remains authoritative.
            try waitUntil(timeout: 6, interval: 0.15, failure: failure) {
                guard let candidate = AXTree.first(
                    in: self.currentLibraryRoots(),
                    identifier: identifier
                ) else { return true }
                return AXTree.performResult(kAXPressAction as String, on: candidate) == .success
            }
            return
        }
        let element = try requiredElement(in: roots, identifier: identifier, failure: failure)
        try pressElement(element)
    }

    private func press(title: String, in roots: [AXUIElement], failure: String) throws {
        var element: AXUIElement?
        try waitUntil(timeout: 5, failure: failure) {
            element = AXTree.first(in: roots, where: { node in
                guard [
                    kAXMenuItemRole as String,
                    kAXButtonRole as String,
                    kAXMenuButtonRole as String,
                    kAXRadioButtonRole as String,
                    kAXCheckBoxRole as String,
                    kAXPopUpButtonRole as String,
                    kAXRowRole as String,
                ].contains(node.role ?? ""),
                node.actions.contains(kAXPressAction as String)
                else { return false }
                return node.title == title || node.label == title || node.value == title
            })
            return element != nil
        }
        do {
            try pressElement(element!)
        } catch let failure as AcceptanceFailure
            where failure.description == "AX row has no clickable frame"
                && title == "Acceptance Editable Note" {
            // SwiftUI's popup option can dispatch AXPress and close before it
            // publishes a frame. The matching suggestion assertion below is the
            // required proof that this specific selection took effect.
            return
        }
    }

    private func pressTitlePrefix(_ prefix: String, failure: String) throws {
        var element: AXUIElement?
        try waitUntil(timeout: 5, failure: failure) {
            let roots = [AXUIElementCreateSystemWide()] + currentApplicationRoots()
            element = AXTree.first(in: roots, where: { node in
                guard [
                    kAXMenuItemRole as String,
                    kAXButtonRole as String,
                    kAXMenuButtonRole as String,
                    kAXRowRole as String,
                ].contains(node.role ?? ""),
                node.actions.contains(kAXPressAction as String)
                else { return false }
                return node.title?.hasPrefix(prefix) == true
                    || node.label?.hasPrefix(prefix) == true
                    || node.value?.hasPrefix(prefix) == true
            })
            return element != nil
        }
        try pressElement(element!)
    }

    private func pressElement(_ element: AXUIElement) throws {
        // Capture the role before dispatching: popup menu items can disappear from
        // the AX tree as soon as AXPress succeeds, making a post-failure role query
        // return nil even though the item was the intended menu choice.
        let roleBeforePress = AXTree.string(kAXRoleAttribute as String, element)
        var error = AXTree.performResult(kAXPressAction as String, on: element)
        guard error != .success else { return }
        guard error.rawValue == -25200 else {
            throw AcceptanceFailure(
                description: "AX action \(kAXPressAction) failed with \(error.rawValue)",
                isEnvironmental: error == .apiDisabled
            )
        }
        if roleBeforePress == kAXButtonRole as String {
            // Buttons like Save Changes can be mid-relayout when the transient
            // -25200 fires (e.g. right after a text field commit). The button
            // itself is stable — unlike a popup row/menu item, it doesn't
            // disappear — so re-dispatching AXPress a few times gives the
            // SwiftUI transaction a chance to settle before falling back to a
            // synthetic click, which needs a published frame this element may
            // not have yet.
            for _ in 0..<3 {
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                error = AXTree.performResult(kAXPressAction as String, on: element)
                if error == .success { return }
                guard error.rawValue == -25200 else {
                    throw AcceptanceFailure(
                        description: "AX action \(kAXPressAction) failed with \(error.rawValue)",
                        isEnvironmental: error == .apiDisabled
                    )
                }
            }
        }
        // SwiftUI can publish a pressable element before its backing action has
        // completed the current transaction. A real click is the supported fallback
        // for this one transient AX error; all other AX failures remain fatal.
        do {
            try AXTree.clickCenter(of: element)
        } catch let clickFailure as AcceptanceFailure
            where clickFailure.description == "AX row has no clickable frame"
                && (roleBeforePress == kAXMenuItemRole as String
                    || roleBeforePress == kAXRowRole as String) {
            // Some SwiftUI popup menu items successfully dispatch AXPress but do not
            // publish a frame. A Picker(.menu) with enough options (e.g. Auto
            // Organize's preview-clip picker) is rendered by AppKit as a scrollable,
            // searchable list instead of a classic NSMenu, so its options surface as
            // AXRow rather than AXMenuItem. The next state assertion remains
            // authoritative.
            return
        }
    }

    private func setText(
        identifier: String,
        value: String,
        in currentRoots: () -> [AXUIElement] = { [] },
        failure: String
    ) throws {
        var field: AXUIElement?
        try waitUntil(timeout: 5, failure: failure) {
            let roots = currentRoots().isEmpty ? self.currentApplicationRoots() : currentRoots()
            field = AXTree.first(in: roots, identifier: identifier)
            return field != nil
        }
        guard let field else { throw AcceptanceFailure(description: failure) }
        try activateAcceptanceApplication()
        try AXTree.setFocused(true, on: field)
        try AXTree.setValue(value, on: field)
        try waitUntil(timeout: 4, failure: "\(failure): value did not commit") {
            let refreshedRoots = currentRoots().isEmpty ? self.currentApplicationRoots() : currentRoots()
            guard let current = AXTree.first(in: refreshedRoots, identifier: identifier) else { return false }
            return AXTree.string(kAXValueAttribute as String, current) == value
        }
    }

    private func pickerOptionIsSelected(
        identifier: String,
        title: String,
        in roots: [AXUIElement]
    ) -> Bool {
        guard let picker = AXTree.first(in: roots, identifier: identifier) else { return false }
        if AXTree.string(kAXValueAttribute as String, picker) == title { return true }
        return AXTree.first(in: [picker], where: { node in
            guard node.role == kAXRadioButtonRole as String,
                  node.title == title || node.label == title
            else { return false }
            return node.value == "Selected"
                || node.value == "1"
        }) != nil
    }

    private func selectSegmentOption(
        identifier: String,
        title: String,
        in currentRoots: () -> [AXUIElement],
        failure: String
    ) throws {
        var lastError: AXError = .failure
        for _ in 0..<6 {
            guard let picker = AXTree.first(in: currentRoots(), identifier: identifier),
                  let segment = AXTree.first(in: [picker], where: { node in
                      node.role == kAXRadioButtonRole as String
                          && (node.title == title || node.label == title || node.value == title)
                  }) else {
                RunLoop.current.run(until: Date().addingTimeInterval(0.25))
                continue
            }
            lastError = AXTree.performResult(kAXPressAction as String, on: segment)
            if lastError == .success {
                try waitUntil(timeout: 3, failure: failure) {
                    pickerOptionIsSelected(identifier: identifier, title: title, in: currentRoots())
                }
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        throw AcceptanceFailure(
            description: "(failure) (AX (lastError.rawValue))",
            isEnvironmental: lastError == .apiDisabled
        )
    }

    private func choosePickerOption(
        identifier: String,
        title: String,
        in currentRoots: () -> [AXUIElement],
        failure: String
    ) throws {
        let picker = try requiredElement(
            in: currentRoots(),
            identifier: identifier,
            failure: failure
        )
        // Picker(.segmented) does not publish a transient popup. Its options are real
        // AXRadioButton descendants, so pressing the segment is the only portable way to
        // change the bound value on macOS. Handle that native shape before trying menu-style
        // AXValue selection or a coordinate fallback.
        if let segment = AXTree.first(in: [picker], where: { node in
            guard node.role == kAXRadioButtonRole as String,
                  node.actions.contains(kAXPressAction as String)
            else { return false }
            return node.title == title || node.label == title || node.value == title
        }) {
            do {
                try pressElement(segment)
            } catch let clickFailure as AcceptanceFailure
                where clickFailure.description == "AX row has no clickable frame" {
                // A segmented SwiftUI picker can acknowledge AXPress while its backing
                // radio-button frame is being replaced. The state assertion below is the
                // authoritative result; do not turn that transient geometry gap into a
                // product failure.
            }
            try waitUntil(timeout: 3, failure: "\(failure): option (segment) did not apply") {
                let refreshed = AXTree.first(in: currentRoots(), identifier: identifier)
                guard let refreshed else { return false }
                if AXTree.string(kAXValueAttribute as String, refreshed) == title {
                    return true
                }
                return AXTree.first(in: [refreshed], where: { node in
                    node.role == kAXRadioButtonRole as String
                        && (node.title == title || node.label == title || node.value == title)
                        && (node.value == "Selected"
                            || node.value == "1")
                }) != nil
            }
            return
        }
        do {
            try pressElement(picker)
        } catch let clickFailure as AcceptanceFailure
            where clickFailure.description == "AX row has no clickable frame" {
            // SwiftUI's popup button can acknowledge AXPress while its menu anchor is
            // transiently frame-less. Continue with the live option/state checks below;
            // a missing option will still fail truthfully.
        }
        let optionRoots = [AXUIElementCreateSystemWide()] + currentApplicationRoots()
        var optionAppeared = false
        do {
            try waitUntil(timeout: 1, interval: 0.1, failure: "picker option pending") {
                AXTree.first(in: optionRoots, title: title) != nil
            }
            optionAppeared = true
        } catch {
            optionAppeared = false
        }
        if !optionAppeared {
            // Some macOS 26 Picker(.menu) instances acknowledge AXPress without
            // opening their popup while another window is settling. A fresh
            // coordinate click is a bounded fallback only when the requested
            // option is still absent; the following title press and state check
            // remain authoritative.
            let freshPicker = AXTree.first(
                in: currentRoots(),
                identifier: identifier
            ) ?? picker
            do {
                try AXTree.clickCenter(of: freshPicker)
            } catch let clickFailure as AcceptanceFailure
                where clickFailure.description == "AX row has no clickable frame" {
                // A menu-style Picker may expose a transient AXRow without a
                // frame. Fall through to the real popup/direct-value paths;
                // never turn this observation failure into a false pass.
            }
            if AXTree.first(in: optionRoots, title: title) == nil {
                // AXPopUpButton supports direct AXValue selection when its
                // transient menu is not exposed; this is still a real control
                // interaction and the caller verifies the resulting model state.
                try AXTree.setValue(title, on: freshPicker)
                try waitUntil(timeout: 3, failure: "\(failure): option (title) did not apply") {
                    AXTree.string(kAXValueAttribute as String, freshPicker) == title
                }
                return
            }
        }
        do {
            try press(
                title: title,
                in: optionRoots,
                failure: "\(failure): option \(title) did not appear"
            )
        } catch let clickFailure as AcceptanceFailure
            where clickFailure.description == "AX row has no clickable frame" {
            // The popup option may acknowledge AXPress while its transient row has no
            // geometry. Ask the owning picker to commit the same value and verify that
            // bound state, rather than failing on a frame that AppKit is replacing.
            let freshPicker = AXTree.first(in: currentRoots(), identifier: identifier) ?? picker
            try AXTree.setValue(title, on: freshPicker)
            try waitUntil(timeout: 3, failure: "\(failure): option (direct value) did not apply") {
                AXTree.string(kAXValueAttribute as String, freshPicker) == title
            }
        }
    }

    private func openContextMenu(identifier: String, failure: String) throws {
        let element = try requiredElement(
            in: currentLibraryRoots(),
            identifier: identifier,
            failure: failure
        )
        try activateAcceptanceApplication()
        try AXTree.showContextMenu(of: element)
    }

    private func requiredBundle() throws -> Bundle {
        guard let bundle = Bundle(url: arguments.applicationURL),
              let executableURL = bundle.executableURL,
              FileManager.default.isExecutableFile(atPath: executableURL.path)
        else { throw AcceptanceFailure(description: "packaged application is missing its executable") }
        return bundle
    }

    private func launch(bundle: Bundle) throws -> Process {
        guard let executableURL = bundle.executableURL else {
            throw AcceptanceFailure(description: "packaged application is missing its executable")
        }
        let task = Process()
        task.executableURL = executableURL
        task.arguments = [
            "--clipboard-router-ui-acceptance",
            "--ui-acceptance-run-id", arguments.runID,
        ]
        let pipe = consoleCapture.makePipe()
        task.standardOutput = pipe
        task.standardError = pipe
        try task.run()
        process = task
        return task
    }

    private func waitForStatusItem(
        applicationRoot _: AXUIElement,
        timeout: TimeInterval
    ) throws -> AXUIElement {
        var result: AXUIElement?
        var stableSignature: String?
        var stableObservations = 0
        try waitUntil(timeout: timeout, failure: "Clipboard Router status item was not discoverable through AX") {
            // Prefer the status extra exposed by the exact acceptance process. SystemUIServer
            // can retain another Clipboard Router status item from an installed/local build,
            // and pressing that lookalike would never open this process's acceptance surface.
            let roots = currentApplicationRoots() + systemUIServerRoots()
            result = AXTree.first(in: roots) { node in
                StatusItemCandidate(
                    role: node.role,
                    subrole: node.subrole,
                    title: node.title,
                    label: node.label,
                    value: node.value,
                    actions: node.actions
                ).isClipboardRouterStatusItem
            }
            guard let result else {
                stableSignature = nil
                stableObservations = 0
                return false
            }
            let signature = [
                AXTree.frameDescription(result),
                AXTree.actionNames(result).joined(separator: ","),
                AXTree.string(kAXTitleAttribute as String, result) ?? "",
                AXTree.string(kAXDescriptionAttribute as String, result) ?? "",
            ].joined(separator: "|")
            if signature == stableSignature {
                stableObservations += 1
            } else {
                stableSignature = signature
                stableObservations = 1
            }
            // AppModel readiness precedes SwiftUI MenuBarExtra readiness on a cold launch.
            // Requiring three seconds of an unchanged, actionable status item avoids pressing
            // the placeholder AX node before its transient window controller is operational.
            return stableObservations >= 30
        }
        return result!
    }

    private func currentStatusItem() -> AXUIElement? {
        AXTree.first(in: currentApplicationRoots() + systemUIServerRoots()) { node in
            StatusItemCandidate(
                role: node.role,
                subrole: node.subrole,
                title: node.title,
                label: node.label,
                value: node.value,
                actions: node.actions
            ).isClipboardRouterStatusItem
        }
    }

    private func matchingSystemStatusItem(for processItem: AXUIElement) -> AXUIElement? {
        guard let expectedFrame = AXTree.frame(of: processItem) else { return nil }
        return AXTree.first(in: systemUIServerRoots()) { node in
            StatusItemCandidate(
                role: node.role,
                subrole: node.subrole,
                title: node.title,
                label: node.label,
                value: node.value,
                actions: node.actions
            ).isClipboardRouterStatusItem
                && AXTree.frame(of: node.element) == expectedFrame
        }
    }

    private func evidenceRoots() -> [AXUIElement] {
        currentApplicationRoots() + [currentStatusItem()].compactMap { $0 }
    }

    private func systemUIServerRoots() -> [AXUIElement] {
        NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.systemuiserver"
        ).map { AXUIElementCreateApplication($0.processIdentifier) }
    }

    private func dockRoots() -> [AXUIElement] {
        NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.dock"
        ).map { AXUIElementCreateApplication($0.processIdentifier) }
    }

    private func waitUntil(
        timeout: TimeInterval,
        interval: TimeInterval = 0.1,
        failure: String,
        condition: () -> Bool
    ) throws {
        let initialSession = SessionAvailability.current()
        guard initialSession == .available else {
            throw AcceptanceFailure(
                description: "interactive session became unavailable before waiting for \(failure): \(initialSession.reason)",
                isEnvironmental: true
            )
        }
        var sessionBecameUnavailable = false
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            guard AXIsProcessTrusted() else {
                throw AcceptanceFailure(
                    description: "Accessibility permission was revoked during the run",
                    isEnvironmental: true
                )
            }
            if SessionAvailability.current() != .available {
                sessionBecameUnavailable = true
            }
            if process?.isRunning == false {
                throw AcceptanceFailure(description: "acceptance application exited before: \(failure)")
            }
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(interval))
        } while Date() < deadline
        // A cross-process AX query can itself consume the remaining budget while SwiftUI
        // publishes a replacement accessibility tree. Always perform one fresh observation
        // after the deadline before declaring failure; otherwise the evidence snapshot can
        // contain the requested control even though the last pre-deadline query saw the old tree.
        if condition() { return }
        throw failureRespectingSessionAvailability(
            failure,
            sessionBecameUnavailable: sessionBecameUnavailable
                || SessionAvailability.current() != .available
        )
    }

    /// Overload for conditions that must distinguish "not ready yet" (return `false`, keep
    /// polling) from a definitive schema failure (throw immediately). Used where the polled
    /// accessibility value can be missing entirely during a timing window but must not be
    /// silently treated as `false` if it is present and malformed.
    private func waitUntil(
        timeout: TimeInterval,
        interval: TimeInterval = 0.1,
        failure: String,
        condition: () throws -> Bool
    ) throws {
        let initialSession = SessionAvailability.current()
        guard initialSession == .available else {
            throw AcceptanceFailure(
                description: "interactive session became unavailable before waiting for \(failure): \(initialSession.reason)",
                isEnvironmental: true
            )
        }
        var sessionBecameUnavailable = false
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            guard AXIsProcessTrusted() else {
                throw AcceptanceFailure(
                    description: "Accessibility permission was revoked during the run",
                    isEnvironmental: true
                )
            }
            if SessionAvailability.current() != .available {
                sessionBecameUnavailable = true
            }
            if process?.isRunning == false {
                throw AcceptanceFailure(description: "acceptance application exited before: \(failure)")
            }
            if try condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(interval))
        } while Date() < deadline
        // A cross-process AX query can itself consume the remaining budget while SwiftUI
        // publishes a replacement accessibility tree. Always perform one fresh observation
        // after the deadline before declaring failure; otherwise the evidence snapshot can
        // contain the requested control even though the last pre-deadline query saw the old tree.
        if try condition() { return }
        throw failureRespectingSessionAvailability(
            failure,
            sessionBecameUnavailable: sessionBecameUnavailable
                || SessionAvailability.current() != .available
        )
    }

    /// Mid-run session-availability recheck (fixes the preflight-only check-then-use race): the
    /// console session is verified once before the run starts, but a run can take minutes, during
    /// which the screen can lock or the session can be switched away without that being caught
    /// anywhere else. This is called at the moment a `waitUntil` is about to report failure —
    /// exactly the "suspicious failure pattern" point where a lost console most plausibly explains
    /// an AX wait that never resolved.
    ///
    /// It must satisfy both directions of the race:
    ///  - a locked/unavailable console must not be misreported as a product failure, so when the
    ///    session is confirmed unavailable *right now* this is reported as an environmental
    ///    boundary (`isEnvironmental: true`, exit 77), matching the existing preflight convention;
    ///  - a real product failure must not be hidden behind a false "console was locked" claim, so
    ///    the original failure text is always preserved verbatim in the thrown description rather
    ///    than being replaced by the session-unavailable reason.
    private func failureRespectingSessionAvailability(
        _ failure: String,
        sessionBecameUnavailable: Bool
    ) -> AcceptanceFailure {
        let sessionAvailability = SessionAvailability.current()
        guard sessionBecameUnavailable,
              sessionAvailability != .available
        else {
            return AcceptanceFailure(description: failure)
        }
        return AcceptanceFailure(
            description: "\(failure) — NOT PROVEN: the console session became unavailable during the "
                + "wait (\(sessionAvailability.reason)); reported as an environmental boundary because "
                + "a lost console cannot be distinguished here from an unrelated product failure",
            isEnvironmental: true
        )
    }
}

private final class EvidenceRecorder {
    private let directory: URL
    private let runID: String
    private let applicationURL: URL
    private let startedAt = Date()
    private var passedCases: [String] = []
    private var caseTimingsMilliseconds: [String: Int] = [:]
    private var diagnosticCheckpoints: [[String: Any]] = []
    private var diagnosticObservations: [[String: String]] = []
    private var startupReadinessTimingsMilliseconds: [String: Int] = [:]
    private var boundaryCases: [[String: String]] = []

    var hasBoundaries: Bool { !boundaryCases.isEmpty }
    var boundaryCount: Int { boundaryCases.count }

    func hasBoundary(named name: String) -> Bool {
        boundaryCases.contains { $0["case"] == name }
    }

    var boundarySummary: String? {
        guard !boundaryCases.isEmpty else { return nil }
        return boundaryCases.map { entry in
            "\(entry["case"] ?? "unknown"): \(entry["error"] ?? "unknown")"
        }.joined(separator: " | ")
    }

    init(directory: URL, runID: String, applicationURL: URL) {
        self.directory = directory
        self.runID = runID
        self.applicationURL = applicationURL
    }

    func recordPass(_ name: String, durationMilliseconds: Int) {
        passedCases.append(name)
        caseTimingsMilliseconds[name] = durationMilliseconds
    }

    func recordDiagnosticCheckpoint(
        name: String,
        consoleByteCount: Int,
        forbiddenDiagnostic: String?
    ) {
        var checkpoint: [String: Any] = [
            "name": name,
            "elapsedMilliseconds": max(0, Int(Date().timeIntervalSince(startedAt) * 1_000)),
            "consoleByteCount": consoleByteCount,
            "forbiddenDiagnosticDetected": forbiddenDiagnostic != nil,
        ]
        if let forbiddenDiagnostic {
            checkpoint["forbiddenDiagnostic"] = forbiddenDiagnostic
        }
        diagnosticCheckpoints.append(checkpoint)
    }

    func recordDiagnosticObservation(name: String, value: String) {
        diagnosticObservations.append(["name": name, "value": value])
    }

    func recordStartupReadiness(phase: String, durationMilliseconds: Int) {
        startupReadinessTimingsMilliseconds[phase] = durationMilliseconds
    }

    func recordBoundary(name: String, error: String) throws {
        guard AcceptanceBoundaryPolicy.isDeclaredBoundary(name) else {
            throw AcceptanceFailure(
                description: "runner attempted to record undeclared acceptance boundary: \(name)"
            )
        }
        boundaryCases.append(["case": name, "error": error])
    }

    func finish(
        outcome: String,
        error: String?,
        roots: [AXUIElement],
        appConsole: Data
    ) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let treeURL = directory.appendingPathComponent("ax-tree.txt")
        let reportURL = directory.appendingPathComponent("report.json")
        let consoleURL = directory.appendingPathComponent("app-console.log")
        let artifactHashesURL = directory.appendingPathComponent("artifact-sha256.json")
        try Data(AXTree.snapshot(roots: roots).utf8).write(to: treeURL, options: .atomic)
        try appConsole.write(to: consoleURL, options: .atomic)
        let packageArtifacts = try packageArtifactRecords()
        try JSONSerialization.data(
            withJSONObject: packageArtifacts,
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: artifactHashesURL, options: .atomic)
        let consoleText = String(decoding: appConsole, as: UTF8.self)
        let forbiddenDiagnostics = AppConsolePolicy.forbiddenDiagnostics.filter {
            consoleText.localizedCaseInsensitiveContains($0)
        }
        if outcome != "failed", let diagnostic = forbiddenDiagnostics.first {
            throw AcceptanceFailure(
                description: "packaged app emitted forbidden AppKit diagnostic: \(diagnostic)"
            )
        }
        var report: [String: Any] = [
            "schemaVersion": 3,
            "runID": runID,
            "bundleIdentifier": "com.clipboardrouter.ClipboardRouter.uiacceptance",
            "outcome": outcome,
            "passedCases": passedCases,
            "caseTimingsMilliseconds": caseTimingsMilliseconds,
            "totalDurationMilliseconds": max(0, Int(Date().timeIntervalSince(startedAt) * 1_000)),
            "externalOnlyCases": ExternalAcceptanceBoundary.cases,
            "nonMutatingPackagedCases": NonMutatingPackagedBoundary.cases,
            "appConsole": consoleURL.lastPathComponent,
            "appConsoleByteCount": appConsole.count,
            "forbiddenConsoleDiagnosticsDetected": forbiddenDiagnostics,
            "diagnosticCheckpoints": diagnosticCheckpoints,
            "diagnosticObservations": diagnosticObservations,
            "startupReadinessTimingsMilliseconds": startupReadinessTimingsMilliseconds,
            "boundaryCases": boundaryCases,
            "packageArtifacts": packageArtifacts,
            "recordedAt": ISO8601DateFormatter().string(from: Date()),
            "screenshots": [],
            "screenshotPolicy": "omitted-to-avoid-capturing-unrelated-desktop-content",
        ]
        if let error { report["error"] = error }
        let reportData = try JSONSerialization.data(
            withJSONObject: report,
            options: [.prettyPrinted, .sortedKeys]
        )
        try reportData.write(to: reportURL, options: .atomic)

        let hashes = try [reportURL, treeURL, consoleURL, artifactHashesURL].map { url -> String in
            "\(try sha256Hex(of: url))  \(url.lastPathComponent)"
        }
        try Data((hashes.joined(separator: "\n") + "\n").utf8).write(
            to: directory.appendingPathComponent("sha256.txt"),
            options: .atomic
        )
        print("EVIDENCE \(directory.path)")
    }

    private func packageArtifactRecords() throws -> [[String: Any]] {
        guard let bundle = Bundle(url: applicationURL),
              let executableURL = bundle.executableURL
        else {
            throw AcceptanceFailure(description: "cannot bind evidence to the packaged application executable")
        }
        let artifacts: [(String, URL)] = [
            ("appExecutable", executableURL),
            ("infoPlist", applicationURL.appendingPathComponent("Contents/Info.plist")),
            ("bundledCLI", applicationURL.appendingPathComponent("Contents/Helpers/cr")),
            ("embeddedReleaseManifest", applicationURL.appendingPathComponent("Contents/Resources/ClipboardRouter.release.json")),
            ("adjacentReleaseManifest", URL(fileURLWithPath: applicationURL.path + ".release.json")),
        ]
        return try artifacts.map { name, url in
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else {
                throw AcceptanceFailure(
                    description: "packaged evidence artifact is missing: \(name) at \(url.path)"
                )
            }
            return [
                "name": name,
                "path": url.path,
                "sha256": try sha256Hex(of: url),
                "sizeBytes": values.fileSize ?? 0,
            ]
        }
    }

    private func sha256Hex(of url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url))
            .map { String(format: "%02x", $0) }
            .joined()
    }

}

private enum AXTree {
    struct Node {
        let element: AXUIElement
        let role: String?
        let subrole: String?
        let title: String?
        let label: String?
        let value: String?
        let identifier: String?
        let actions: [String]
    }

    static func first(
        in roots: [AXUIElement],
        identifier: String
    ) -> AXUIElement? {
        firstDepthFirst(
            in: roots,
            identity: { AXElementIdentity(element: $0) },
            matches: {
                string(kAXIdentifierAttribute as String, $0) == identifier
            },
            descendants: { element, depth in
                children(element, depth: depth)
            }
        )
    }

    /// Unlike `first(in:identifier:)`, collects every node carrying `identifier` instead of
    /// stopping at the first match. SwiftUI accessibility propagation can duplicate a node
    /// (for example under both the app-local and system-wide roots) so a truthful read of a
    /// live accessibility value must not silently trust whichever duplicate happens to sort
    /// first in a depth-first walk.
    static func all(
        in roots: [AXUIElement],
        identifier: String
    ) -> [AXUIElement] {
        var matches: [AXUIElement] = []
        var visited = Set<AXElementIdentity>()
        var stack = roots.reversed().map { ($0, 0) }
        var visitedCount = 0
        while let (element, depth) = stack.popLast(), visitedCount < 20_000 {
            let identity = AXElementIdentity(element: element)
            guard visited.insert(identity).inserted else { continue }
            visitedCount += 1
            if string(kAXIdentifierAttribute as String, element) == identifier {
                matches.append(element)
            }
            if depth < 14 {
                let nextChildren = children(element, depth: depth)
                stack.append(contentsOf: nextChildren.reversed().map { ($0, depth + 1) })
            }
        }
        return matches
    }

    /// Locate stable Library toolbar/sidebar controls without descending into the
    /// 1,001-row clip table. The table remains available to the normal traversal
    /// for row-specific assertions, but navigation controls must not pay that cost.
    static func firstLibraryControl(
        in roots: [AXUIElement],
        identifier: String
    ) -> AXUIElement? {
        let largeContentRoles: Set<String> = [
            kAXTableRole as String,
            kAXCellRole as String,
        ]
        return firstDepthFirst(
            in: roots,
            identity: { AXElementIdentity(element: $0) },
            matches: {
                string(kAXIdentifierAttribute as String, $0) == identifier
            },
            descendants: { element, depth in
                guard !largeContentRoles.contains(
                    string(kAXRoleAttribute as String, element) ?? ""
                ) else { return [] }
                return children(element, depth: depth)
            }
        )
    }

    static func sheetRoots(in applicationRoot: AXUIElement) -> [AXUIElement] {
        var candidates = elements("AXSheets", of: applicationRoot)
        let windows = windowRoots(in: applicationRoot)

        for window in windows {
            candidates.append(contentsOf: elements("AXSheets", of: window))
        }
        if candidates.isEmpty {
            for window in windows {
                candidates.append(contentsOf: descendantSheets(in: window))
            }
        }

        var seen = Set<AXElementIdentity>()
        return candidates.filter {
            seen.insert(AXElementIdentity(element: $0)).inserted
        }
    }

    static func windowRoots(in applicationRoot: AXUIElement) -> [AXUIElement] {
        let preferredWindows = [
            kAXFocusedWindowAttribute as String,
            kAXMainWindowAttribute as String,
        ].flatMap { elements($0, of: applicationRoot) }
        let candidates = preferredWindows
            + elements(kAXWindowsAttribute as String, of: applicationRoot)
            + elements(kAXChildrenAttribute as String, of: applicationRoot).filter {
                string(kAXRoleAttribute as String, $0) == kAXWindowRole as String
            }
        var seen = Set<AXElementIdentity>()
        return candidates.filter {
            seen.insert(AXElementIdentity(element: $0)).inserted
        }
    }

    /// SwiftUI sheets are not consistently published through an `AXSheets`
    /// attribute. On affected macOS builds they appear as ordinary descendants
    /// of the host window, so inspect that bounded, window-local hierarchy too.
    private static func descendantSheets(in window: AXUIElement) -> [AXUIElement] {
        var result: [AXUIElement] = []
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var visited = Set<AXElementIdentity>()
        var index = 0
        while index < queue.count, index < 2_000 {
            let (element, depth) = queue[index]
            index += 1
            guard visited.insert(AXElementIdentity(element: element)).inserted else { continue }
            let role = string(kAXRoleAttribute as String, element)
            if role == kAXSheetRole as String {
                result.append(element)
                continue
            }
            // A sheet is attached above the host window's table/outline content.
            // Entering those subtrees forces SwiftUI to materialize every Library
            // row and can query NSTableView again while it is still adding rows.
            // Keep the fallback search on the presentation hierarchy instead.
            if role == kAXTableRole as String
                || role == kAXOutlineRole as String
                || role == kAXScrollAreaRole as String
                || role == kAXRowRole as String
                || role == kAXCellRole as String
            {
                continue
            }
            if depth < 8 {
                let descendants = elements(kAXChildrenAttribute as String, of: element)
                    + elements(kAXContentsAttribute as String, of: element)
                    + elements("AXSheets", of: element)
                queue.append(contentsOf: descendants.map { ($0, depth + 1) })
            }
        }
        return result
    }

    static func first(in roots: [AXUIElement], title: String) -> AXUIElement? {
        firstDepthFirst(
            in: roots,
            identity: { AXElementIdentity(element: $0) },
            matches: { element in
                let candidates = [
                    string(kAXTitleAttribute as String, element),
                    string(kAXDescriptionAttribute as String, element),
                    string(kAXValueAttribute as String, element),
                ].compactMap { $0 }
                return candidates.contains { value in
                    value == title || value.hasPrefix(title + ",")
                }
            },
            descendants: { element, depth in
                children(element, depth: depth)
            }
        )
    }

    /// Search the Library content column for a clip title without descending through
    /// the application menu/sidebar hierarchy first. The relaunch proof only needs
    /// the persisted clip row; navigation controls have separate selectors.
    static func firstClipTitle(in roots: [AXUIElement], title: String) -> AXUIElement? {
        let excludedRoles: Set<String> = [
            kAXMenuBarRole as String,
            kAXMenuRole as String,
            kAXOutlineRole as String,
        ]
        return firstDepthFirst(
            in: roots,
            identity: { AXElementIdentity(element: $0) },
            matches: { element in
                let candidates = [
                    string(kAXTitleAttribute as String, element),
                    string(kAXDescriptionAttribute as String, element),
                    string(kAXValueAttribute as String, element),
                ].compactMap { $0 }
                return candidates.contains { value in
                    value == title || value.hasPrefix(title + ",")
                }
            },
            descendants: { element, depth in
                guard !excludedRoles.contains(
                    string(kAXRoleAttribute as String, element) ?? ""
                ) else { return [] }
                return children(element, depth: depth)
            }
        )
    }

    static func appearsBefore(
        identifier firstIdentifier: String,
        than secondIdentifier: String,
        in roots: [AXUIElement]
    ) -> Bool {
        var queue = roots.map { ($0, 0) }
        var visited = Set<AXElementIdentity>()
        var index = 0
        var firstIndex: Int?
        var secondIndex: Int?
        while index < queue.count, index < 20_000 {
            let (element, depth) = queue[index]
            index += 1
            guard visited.insert(AXElementIdentity(element: element)).inserted else { continue }
            let identifier = string(kAXIdentifierAttribute as String, element)
            if identifier == firstIdentifier { firstIndex = firstIndex ?? index }
            if identifier == secondIdentifier { secondIndex = secondIndex ?? index }
            if let firstIndex, let secondIndex { return firstIndex < secondIndex }
            if depth < 14 {
                queue.append(contentsOf: children(element, depth: depth).map { ($0, depth + 1) })
            }
        }
        return false
    }

    static func first(
        in roots: [AXUIElement],
        where predicate: (Node) -> Bool
    ) -> AXUIElement? {
        firstBreadthFirst(
            in: roots,
            identity: { AXElementIdentity(element: $0) },
            matches: { element in
                predicate(Node(
                    element: element,
                    role: string(kAXRoleAttribute, element),
                    subrole: string(kAXSubroleAttribute, element),
                    title: string(kAXTitleAttribute, element),
                    label: string(kAXDescriptionAttribute, element),
                    value: string(kAXValueAttribute, element),
                    identifier: string(kAXIdentifierAttribute, element),
                    actions: actionNames(element)
                ))
            },
            descendants: { element, depth in
                children(element, depth: depth)
            }
        )
    }

    private static func firstBreadthFirst<Element, Identity: Hashable>(
        in roots: [Element],
        maximumNodes: Int = 20_000,
        maximumDepth: Int = 14,
        identity: (Element) -> Identity,
        matches: (Element) -> Bool,
        descendants: (Element, Int) -> [Element]
    ) -> Element? {
        var queue = roots.map { ($0, 0) }
        var visited = Set<Identity>()
        var index = 0
        while index < queue.count, index < maximumNodes {
            let (element, depth) = queue[index]
            index += 1
            guard visited.insert(identity(element)).inserted else { continue }
            if matches(element) { return element }
            if depth < maximumDepth {
                queue.append(contentsOf: descendants(element, depth).map { ($0, depth + 1) })
            }
        }
        return nil
    }

    private static func firstDepthFirst<Element, Identity: Hashable>(
        in roots: [Element],
        maximumNodes: Int = 20_000,
        maximumDepth: Int = 14,
        identity: (Element) -> Identity,
        matches: (Element) -> Bool,
        descendants: (Element, Int) -> [Element]
    ) -> Element? {
        var stack = roots.reversed().map { ($0, 0) }
        var visited = Set<Identity>()
        var visitedCount = 0
        while let (element, depth) = stack.popLast(), visitedCount < maximumNodes {
            guard visited.insert(identity(element)).inserted else { continue }
            visitedCount += 1
            if matches(element) { return element }
            if depth < maximumDepth {
                let children = descendants(element, depth)
                stack.append(contentsOf: children.reversed().map { ($0, depth + 1) })
            }
        }
        return nil
    }

    static func runTraversalSelfTests() throws {
        struct FixtureNode: Hashable {
            let id: Int
        }
        let edges: [Int: [FixtureNode]] = [
            1: [FixtureNode(id: 2), FixtureNode(id: 3)],
            2: [FixtureNode(id: 4)],
            3: [FixtureNode(id: 5)],
        ]
        var probed: [Int] = []
        let match = firstBreadthFirst(
            in: [FixtureNode(id: 1)],
            identity: \.id,
            matches: { node in
                probed.append(node.id)
                return node.id == 4
            },
            descendants: { node, _ in edges[node.id] ?? [] }
        )
        guard match?.id == 4, probed == [1, 2, 3, 4] else {
            throw AcceptanceFailure(description: "AX traversal primitive is not deterministic breadth-first")
        }

        let siblingCells = (1 ... 1_001).map(FixtureNode.init(id:))
        let deepTarget = FixtureNode(id: 10_000)
        var wideEdges: [Int: [FixtureNode]] = [0: siblingCells]
        wideEdges[1] = [deepTarget]
        var depthFirstProbes: [Int] = []
        let depthFirstMatch = firstDepthFirst(
            in: [FixtureNode(id: 0)],
            identity: \.id,
            matches: { node in
                depthFirstProbes.append(node.id)
                return node == deepTarget
            },
            descendants: { node, _ in wideEdges[node.id] ?? [] }
        )
        guard depthFirstMatch == deepTarget,
              depthFirstProbes == [0, 1, deepTarget.id]
        else {
            throw AcceptanceFailure(
                description: "AX depth-first traversal did not enter the first sibling before scanning later siblings"
            )
        }

        struct CollidingIdentity: Hashable {
            let id: Int

            func hash(into hasher: inout Hasher) {
                hasher.combine(0)
            }
        }
        let collisionEdges: [Int: [FixtureNode]] = [
            20: [FixtureNode(id: 21), FixtureNode(id: 22)],
        ]
        var collisionProbes: [Int] = []
        let collisionMatch = firstDepthFirst(
            in: [FixtureNode(id: 20)],
            identity: { CollidingIdentity(id: $0.id) },
            matches: { node in
                collisionProbes.append(node.id)
                return node.id == 22
            },
            descendants: { node, _ in collisionEdges[node.id] ?? [] }
        )
        guard collisionMatch?.id == 22, collisionProbes == [20, 21, 22] else {
            throw AcceptanceFailure(
                description: "AX traversal discarded a distinct node whose identity hash collided"
            )
        }
    }

    static func perform(_ action: String, on element: AXUIElement) throws {
        let error = performResult(action, on: element)
        guard error == .success else {
            throw AcceptanceFailure(
                description: "AX action \(action) failed with \(error.rawValue)",
                isEnvironmental: error == .apiDisabled
            )
        }
    }

    static func performResult(_ action: String, on element: AXUIElement) -> AXError {
        AXUIElementPerformAction(element, action as CFString)
    }

    static func performIfAvailable(_ action: String, on element: AXUIElement) throws {
        guard actionNames(element).contains(action) else { return }
        try perform(action, on: element)
    }

    static func performAllowingObservedGenericFailure(
        _ action: String,
        on element: AXUIElement
    ) throws {
        let error = AXUIElementPerformAction(element, action as CFString)
        guard error == .success || error == .failure else {
            throw AcceptanceFailure(
                description: "AX action \(action) failed with \(error.rawValue)",
                isEnvironmental: error == .apiDisabled
            )
        }
    }

    static func setValue(_ value: Any, on element: AXUIElement) throws {
        let error = AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            value as CFTypeRef
        )
        guard error == .success else {
            throw AcceptanceFailure(
                description: "AX value update failed with \(error.rawValue)",
                isEnvironmental: error == .apiDisabled
            )
        }
    }

    static func activateSelectableElement(_ element: AXUIElement) throws {
        if let row = containingRow(of: element) {
            var isSettable = DarwinBoolean(false)
            let settableError = AXUIElementIsAttributeSettable(
                row,
                kAXSelectedAttribute as CFString,
                &isSettable
            )
            if settableError == .success, isSettable.boolValue {
                let selectionError = AXUIElementSetAttributeValue(
                    row,
                    kAXSelectedAttribute as CFString,
                    kCFBooleanTrue
                )
                if selectionError == .success { return }
                if selectionError == .apiDisabled {
                    throw AcceptanceFailure(
                        description: "native AX row selection failed because Accessibility is unavailable",
                        isEnvironmental: true
                    )
                }
            }
            if actionNames(row).contains(kAXPressAction as String) {
                try perform(kAXPressAction as String, on: row)
                return
            }
            try clickCenter(of: row)
            return
        }
        if actionNames(element).contains(kAXPressAction as String) {
            try perform(kAXPressAction as String, on: element)
            return
        }
        throw AcceptanceFailure(description: "identified element has no selectable AX row or action")
    }

    private static func containingRow(of element: AXUIElement) -> AXUIElement? {
        ancestor(of: element, role: kAXRowRole as String)
    }

    static func ancestor(
        of element: AXUIElement,
        role expectedRole: String,
        maximumDepth: Int = 20
    ) -> AXUIElement? {
        var current = element
        for _ in 0 ..< maximumDepth {
            if string(kAXRoleAttribute as String, current) == expectedRole {
                return current
            }
            guard let parent = attributeValue(kAXParentAttribute as String, current),
                  CFGetTypeID(parent) == AXUIElementGetTypeID()
            else { break }
            current = unsafeDowncast(parent, to: AXUIElement.self)
        }
        return nil
    }

    static func ancestor(
        of element: AXUIElement,
        identifierPrefix: String,
        maximumDepth: Int = 20
    ) -> AXUIElement? {
        var current = element
        for _ in 0 ..< maximumDepth {
            if let identifier = string(kAXIdentifierAttribute as String, current),
               identifier.hasPrefix(identifierPrefix) {
                return current
            }
            guard let parent = attributeValue(kAXParentAttribute as String, current),
                  CFGetTypeID(parent) == AXUIElementGetTypeID()
            else { break }
            current = unsafeDowncast(parent, to: AXUIElement.self)
        }
        return nil
    }

    static func clickSelectableElement(
        _ element: AXUIElement,
        modifiers: CGEventFlags = []
    ) throws {
        let row = containingRow(of: element) ?? element
        // A plain selection is deterministic through the native AXPress action and avoids
        // depending on WindowServer pointer delivery. Modifier-based multi-selection still
        // requires a real click so Command/Shift semantics are preserved.
        if modifiers.isEmpty, actionNames(row).contains(kAXPressAction as String),
           performResult(kAXPressAction as String, on: row) == .success {
            return
        }
        try clickCenter(of: row, modifiers: modifiers)
    }

    static func clickCenter(
        of element: AXUIElement,
        modifiers: CGEventFlags = []
    ) throws {
        guard let positionValue = attributeValue(kAXPositionAttribute as String, element),
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              let sizeValue = attributeValue(kAXSizeAttribute as String, element),
              CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else {
            throw AcceptanceFailure(description: "AX row has no clickable frame")
        }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
              size.width > 0,
              size.height > 0,
              let source = CGEventSource(stateID: .hidSystemState)
        else {
            throw AcceptanceFailure(description: "AX row frame could not be decoded")
        }
        let center = CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)
        CGWarpMouseCursorPosition(center)
        // Dock auto-hide and native hover affordances must see the pointer before the click.
        // Without this dwell, a synthetically positioned click can be consumed only to reveal
        // the Dock and never reach the exact application tile.
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        guard let mouseDown = CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseDown,
            mouseCursorPosition: center,
            mouseButton: .left
        ), let mouseUp = CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseUp,
            mouseCursorPosition: center,
            mouseButton: .left
        ) else {
            throw AcceptanceFailure(description: "could not create row click events")
        }
        mouseDown.flags = modifiers
        mouseUp.flags = modifiers
        mouseDown.post(tap: .cghidEventTap)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        mouseUp.post(tap: .cghidEventTap)
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        guard let positionValue = attributeValue(kAXPositionAttribute as String, element),
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              let sizeValue = attributeValue(kAXSizeAttribute as String, element),
              CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
              size.width > 0, size.height > 0
        else { return nil }
        return CGRect(origin: position, size: size)
    }

    static func frameDescription(_ element: AXUIElement) -> String {
        guard let frame = frame(of: element) else { return "frame=nil" }
        return "frame=\(Int(frame.origin.x)),\(Int(frame.origin.y)),\(Int(frame.width)),\(Int(frame.height))"
    }

    static func hoverCenter(of element: AXUIElement) throws {
        guard let positionValue = attributeValue(kAXPositionAttribute as String, element),
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              let sizeValue = attributeValue(kAXSizeAttribute as String, element),
              CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { throw AcceptanceFailure(description: "AX element has no hoverable frame") }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
              size.width > 0, size.height > 0
        else { throw AcceptanceFailure(description: "AX hover frame could not be decoded") }
        CGWarpMouseCursorPosition(CGPoint(
            x: position.x + size.width / 2,
            y: position.y + size.height / 2
        ))
    }

    /// A full-screen foreground app can hide the macOS menu bar while status-item AX frames
    /// remain published at their nominal y-coordinate. Moving directly to that center can hit
    /// the foreground app instead. Touch the display's top edge first, wait for AppKit's menu-bar
    /// reveal animation, then move into the freshly published status-item frame.
    static func revealMenuBar(near element: AXUIElement) throws {
        guard let frame = frame(of: element) else {
            throw AcceptanceFailure(description: "AX status item has no revealable frame")
        }
        CGWarpMouseCursorPosition(CGPoint(x: frame.midX, y: 0))
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        try hoverCenter(of: element)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }

    static func showContextMenu(of element: AXUIElement) throws {
        if actionNames(element).contains(kAXShowMenuAction as String) {
            let error = performResult(kAXShowMenuAction as String, on: element)
            if error == .success {
                return
            }
            // SwiftUI's AX row sometimes advertises AXShowMenu while returning the
            // generic interaction failure (-25204) during a state transition. Fall
            // through to the real row right-click; preserve permission/API failures.
            guard error.rawValue == -25204 else {
                throw AcceptanceFailure(
                    description: "AX action \(kAXShowMenuAction) failed with \(error.rawValue)",
                    isEnvironmental: error == .apiDisabled
                )
            }
        }
        let target = containingRow(of: element) ?? element
        guard let positionValue = attributeValue(kAXPositionAttribute as String, target),
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              let sizeValue = attributeValue(kAXSizeAttribute as String, target),
              CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { throw AcceptanceFailure(description: "AX element has no frame for its context menu") }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
              let source = CGEventSource(stateID: .hidSystemState)
        else { throw AcceptanceFailure(description: "AX context-menu frame could not be decoded") }
        let center = CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)
        guard let down = CGEvent(
            mouseEventSource: source,
            mouseType: .rightMouseDown,
            mouseCursorPosition: center,
            mouseButton: .right
        ), let up = CGEvent(
            mouseEventSource: source,
            mouseType: .rightMouseUp,
            mouseCursorPosition: center,
            mouseButton: .right
        ) else { throw AcceptanceFailure(description: "could not create context-menu events") }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// Scrolls without clicking the content beneath the pointer. macOS can hide a
    /// ScrollView's AXScrollBar until the first wheel event, so acceptance must not
    /// depend on the user's "Show scroll bars" preference.
    static func scroll(lines: Int32, on element: AXUIElement) throws {
        guard let positionValue = attributeValue(kAXPositionAttribute as String, element),
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              let sizeValue = attributeValue(kAXSizeAttribute as String, element),
              CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else {
            throw AcceptanceFailure(description: "AX scroll surface has no frame")
        }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
              size.width > 0,
              size.height > 0,
              let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(
                  scrollWheelEvent2Source: source,
                  units: .line,
                  wheelCount: 1,
                  wheel1: lines,
                  wheel2: 0,
                  wheel3: 0
              )
        else {
            throw AcceptanceFailure(description: "could not create menu scroll event")
        }
        let center = CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)
        CGWarpMouseCursorPosition(center)
        event.post(tap: .cghidEventTap)
    }

    static func setFocused(_ focused: Bool, on element: AXUIElement) throws {
        let error = AXUIElementSetAttributeValue(
            element,
            kAXFocusedAttribute as CFString,
            (focused ? kCFBooleanTrue : kCFBooleanFalse)
        )
        if error.rawValue == -25202 {
            // SwiftUI may reject a focus mutation while publishing a newly-rendered
            // field. A real click establishes the same user-visible focus boundary.
            try clickCenter(of: element)
            return
        }
        guard error == .success else {
            throw AcceptanceFailure(
                description: "AX focus update failed with \(error.rawValue)",
                isEnvironmental: error == .apiDisabled
            )
        }
    }

    static func pressReturn() throws {
        try pressKeyCode(36, description: "Return")
    }

    static func pressEscape() throws {
        try pressKeyCode(53, description: "Escape")
    }

    static func pressGoToFolder() throws {
        try pressKeyCode(
            5,
            flags: [.maskCommand, .maskShift],
            description: "Command-Shift-G"
        )
    }

    static func pressKeyCode(
        _ keyCode: CGKeyCode,
        flags: CGEventFlags = [],
        description: String
    ) throws {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: keyCode,
                keyDown: true
              ),
              let keyUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: keyCode,
                keyDown: false
              )
        else {
            throw AcceptanceFailure(description: "could not create \(description) key events")
        }
        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    static func snapshot(roots: [AXUIElement]) -> String {
        var lines: [String] = []
        var queue = roots.map { ($0, 0) }
        var visited = Set<AXElementIdentity>()
        var index = 0
        while index < queue.count, index < 20_000 {
            let (element, depth) = queue[index]
            index += 1
            guard visited.insert(AXElementIdentity(element: element)).inserted else { continue }
            let fields = [
                string(kAXRoleAttribute as String, element),
                string(kAXSubroleAttribute as String, element),
                string(kAXIdentifierAttribute as String, element),
                string(kAXTitleAttribute as String, element),
                string(kAXDescriptionAttribute as String, element),
                string(kAXValueAttribute as String, element),
            ].compactMap { $0?.replacingOccurrences(of: "\n", with: " ") }
            lines.append("\(String(repeating: "  ", count: min(depth, 20)))\(fields.joined(separator: " | "))")
            if depth < 14 {
                queue.append(contentsOf: children(element, depth: depth).map { ($0, depth + 1) })
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func children(_ element: AXUIElement, depth: Int) -> [AXUIElement] {
        var attributes = [
            kAXChildrenAttribute as String,
            kAXContentsAttribute as String,
        ]
        // Application-level convenience attributes are useful only at a root.
        // Avoid two cross-process AX calls for every descendant in large trees.
        if depth == 0 {
            attributes.append(kAXMenuBarAttribute as String)
            attributes.append(kAXWindowsAttribute as String)
        }
        return attributes.flatMap { attribute -> [AXUIElement] in
            elements(attribute, of: element)
        }
    }

    private static func elements(_ attribute: String, of element: AXUIElement) -> [AXUIElement] {
        guard let value = attributeValue(attribute, element) else { return [] }
        if let elements = value as? [AXUIElement] { return elements }
        if CFGetTypeID(value) == AXUIElementGetTypeID() {
            return [unsafeDowncast(value, to: AXUIElement.self)]
        }
        return []
    }

    static func string(_ attribute: String, _ element: AXUIElement) -> String? {
        guard let value = attributeValue(attribute, element) else { return nil }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    static func boolean(_ attribute: String, _ element: AXUIElement) -> Bool? {
        guard let value = attributeValue(attribute, element) else { return nil }
        if let boolean = value as? Bool { return boolean }
        if let number = value as? NSNumber { return number.boolValue }
        return nil
    }

    static func url(_ element: AXUIElement) -> URL? {
        guard let value = attributeValue(kAXURLAttribute as String, element) else { return nil }
        if let url = value as? URL { return url }
        if let string = value as? String { return URL(string: string) }
        return nil
    }

    private static func attributeValue(_ attribute: String, _ element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value
    }

    static func actionNames(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return names as? [String] ?? []
    }
}
