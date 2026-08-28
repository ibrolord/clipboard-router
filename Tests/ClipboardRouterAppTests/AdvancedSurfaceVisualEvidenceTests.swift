import AppKit
import ClipboardRouterCore
import ClipboardRouterPlatform
import CryptoKit
import SwiftUI
import XCTest
@testable import ClipboardRouterApp

/// App-only visual evidence for advanced production workflows that are not covered by the
/// menu/Library continuation matrix. Every image is rendered from the real SwiftUI view into an
/// `NSHostingView`; no desktop or unrelated window pixels can enter the evidence.
///
/// Set `CLIPBOARD_ROUTER_ADVANCED_SURFACE_EVIDENCE_DIR` to retain the PNGs, manifest, and SHA-256
/// checksum file. Without it, the same assertions run in an isolated temporary directory.
@MainActor
final class AdvancedSurfaceVisualEvidenceTests: XCTestCase {
    private struct Viewport: Codable, Equatable {
        let width: Int
        let height: Int

        var size: CGSize { CGSize(width: width, height: height) }
        var slug: String { "\(width)x\(height)" }
    }

    private struct Scenario {
        let name: String
        let category: String
        let sizeClass: String
        let viewport: Viewport
        let requiredAccessibilityAnchors: [String]
        let requiredOCRAnchors: [String]
        let minimumNativeControls: Int
        let minimumScrollViews: Int
        let build: @MainActor () -> AnyView
    }

    private struct Evidence: Codable {
        let surface: String
        let category: String
        let sizeClass: String
        let file: String
        let logicalWidth: Int
        let logicalHeight: Int
        let pixelWidth: Int
        let pixelHeight: Int
        let sampledColorCount: Int
        let nontransparentPixelRatio: Double
        let nativeControlCount: Int
        let scrollViewCount: Int
        let visibleNativeViewCount: Int
        let accessibilityAnchorCount: Int
        let ocrAnchorCount: Int
        let geometry: [String: Double]
        let recognizedText: [String]
        let sha256: String
    }

    private struct Manifest: Codable {
        let schemaVersion: Int
        let renderedAt: String
        let renderer: String
        let appearance: String
        let scenarioCount: Int
        let categories: [String]
        let scenarios: [Evidence]
    }

    private struct Fixture {
        let model: AppModel
        let codeClip: PresentedClip
        let savedClipIDs: Set<UUID>
        let flow: ClipFlow
        let debugBundleRequest: DeveloperDebugBundleReviewRequest
        let smartView: UserSmartView
        let handoff: HandoffReviewRequest
    }

    func testRenderAdvancedProductionSurfaceEvidence() async throws {
        let outputDirectory = try evidenceDirectory()
        let fixture = try await makeFixture()
        fixture.model.actionsWorkspaceMode = .automations
        fixture.model.selectLibrarySection(.allSaved)
        fixture.model.setSelectedClipIDs(fixture.savedClipIDs)

        let idle = try await makeLivePreviewFixture(
            path: "idle",
            result: .success(LiveLinkPreviewMetadata(
                sourceURL: try XCTUnwrap(URL(string: "https://example.com/product")),
                title: "Clipboard workflows for teams",
                siteName: "Example Product",
                summary: "A concise guide to reviewed clipboard workflows and safe team handoffs.",
                fetchedAt: Date(timeIntervalSince1970: 2_000_000_000)
            )),
            load: false
        )
        let loaded = try await makeLivePreviewFixture(
            path: "loaded",
            result: .success(LiveLinkPreviewMetadata(
                sourceURL: try XCTUnwrap(URL(string: "https://example.com/product")),
                title: "Clipboard workflows for teams",
                siteName: "Example Product",
                summary: "A concise guide to reviewed clipboard workflows and safe team handoffs.",
                fetchedAt: Date(timeIntervalSince1970: 2_000_000_000)
            )),
            load: true
        )
        let offline = try await makeLivePreviewFixture(
            path: "offline",
            result: .failure(.offline),
            load: true
        )
        let blocked = try await makeLivePreviewFixture(
            path: "blocked",
            url: "http://example.com/private",
            result: .success(LiveLinkPreviewMetadata(
                sourceURL: try XCTUnwrap(URL(string: "https://example.com/product")),
                title: "Must not load"
            )),
            load: true
        )

        let scenarios = makeScenarios(
            fixture: fixture,
            idle: idle,
            loaded: loaded,
            offline: offline,
            blocked: blocked
        )
        XCTAssertEqual(scenarios.count, 24)

        let evidence = try scenarios.map { try render($0, into: outputDirectory) }

        XCTAssertEqual(evidence.count, 24)
        XCTAssertEqual(Set(evidence.map(\.file)).count, evidence.count)
        XCTAssertEqual(Set(evidence.map(\.sha256)).count, evidence.count)

        let requiredCategories: Set<String> = [
            "projects", "debug-bundle", "auto-organize", "smart-views-bulk",
            "actions", "sales", "live-link-preview",
        ]
        XCTAssertEqual(Set(evidence.map(\.category)), requiredCategories)
        for category in ["projects", "auto-organize", "smart-views-bulk", "actions", "live-link-preview"] {
            let sizeClasses = Set(evidence.filter { $0.category == category }.map(\.sizeClass))
            XCTAssertTrue(
                sizeClasses.contains("minimum") || sizeClasses.contains("production-sheet"),
                "\(category) lacks minimum-size evidence"
            )
            XCTAssertTrue(
                sizeClasses.contains("normal") || sizeClasses.contains("production-sheet"),
                "\(category) lacks normal-size evidence"
            )
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let manifest = Manifest(
            schemaVersion: 1,
            renderedAt: formatter.string(from: Date()),
            renderer: "NSHostingView.cacheDisplay (app-only; no desktop capture)",
            appearance: "NSAppearance.Name.darkAqua",
            scenarioCount: evidence.count,
            categories: requiredCategories.sorted(),
            scenarios: evidence
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let manifestData = try encoder.encode(manifest)
        let manifestURL = outputDirectory.appendingPathComponent("manifest.json")
        try manifestData.write(to: manifestURL, options: .atomic)

        let checksumEntries = evidence.map { "\($0.sha256)  \($0.file)" } + [
            "\(sha256(manifestData))  manifest.json",
        ]
        try (checksumEntries.joined(separator: "\n") + "\n").write(
            to: outputDirectory.appendingPathComponent("sha256.txt"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func makeScenarios(
        fixture: Fixture,
        idle: (AppModel, PresentedClip, StoredLinkPreviewDescriptor),
        loaded: (AppModel, PresentedClip, StoredLinkPreviewDescriptor),
        offline: (AppModel, PresentedClip, StoredLinkPreviewDescriptor),
        blocked: (AppModel, PresentedClip, StoredLinkPreviewDescriptor)
    ) -> [Scenario] {
        let projectSizes = [
            ("minimum", Viewport(width: 780, height: 600)),
            ("normal", Viewport(width: 1_080, height: 720)),
        ]
        let autoOrganizeSizes = [
            ("minimum", Viewport(width: 680, height: 600)),
            ("normal", Viewport(width: 900, height: 700)),
        ]
        let bulkSizes = [
            ("minimum", Viewport(width: 900, height: 590)),
            ("normal", Viewport(width: 1_080, height: 700)),
        ]
        let actionsSizes = [
            ("minimum", Viewport(width: 680, height: 600)),
            ("normal", Viewport(width: 900, height: 720)),
        ]
        let liveSizes = [
            ("minimum", Viewport(width: 480, height: 330)),
            ("normal", Viewport(width: 700, height: 390)),
        ]

        var scenarios: [Scenario] = []
        scenarios += projectSizes.map { sizeClass, viewport in
            Scenario(
                name: "projects-detail-\(sizeClass)",
                category: "projects",
                sizeClass: sizeClass,
                viewport: viewport,
                requiredAccessibilityAnchors: ["Timeline", "Debug Bundles"],
                requiredOCRAnchors: ["Security Toolkit", "Debug Bundles"],
                minimumNativeControls: 5,
                minimumScrollViews: 2,
                build: { AnyView(DeveloperProjectsView(model: fixture.model)) }
            )
        }
        scenarios.append(Scenario(
            name: "new-project",
            category: "projects",
            sizeClass: "production-sheet",
            viewport: Viewport(width: 520, height: 390),
            // SwiftUI's in-process NSHostingView tree does not expose test identifiers for this
            // sheet. Packaged AX coverage verifies those IDs; this visual gate uses OCR and native
            // control geometry instead of recording a false identifier claim.
            requiredAccessibilityAnchors: [],
            requiredOCRAnchors: ["New Project", "Choose"],
            minimumNativeControls: 2,
            minimumScrollViews: 0,
            build: { AnyView(DeveloperProjectEditorView(model: fixture.model, dismiss: {})) }
        ))
        scenarios += [
            ("minimum", Viewport(width: 700, height: 560)),
            ("normal", Viewport(width: 900, height: 680)),
        ].map { sizeClass, viewport in
            Scenario(
                name: "debug-bundle-review-\(sizeClass)",
                category: "debug-bundle",
                sizeClass: sizeClass,
                viewport: viewport,
                requiredAccessibilityAnchors: ["Project display name", "Problem statement"],
                requiredOCRAnchors: ["Debug Bundle", "Save to Project"],
                minimumNativeControls: 6,
                minimumScrollViews: 2,
                build: {
                    AnyView(DebugBundleReviewSheet(
                        model: fixture.model,
                        request: fixture.debugBundleRequest
                    ))
                }
            )
        }
        scenarios += autoOrganizeSizes.map { sizeClass, viewport in
            Scenario(
                name: "auto-organize-rules-\(sizeClass)",
                category: "auto-organize",
                sizeClass: sizeClass,
                viewport: viewport,
                requiredAccessibilityAnchors: ["Product workflow guide", "Suggest"],
                requiredOCRAnchors: ["Auto Organize", "Ordered rules"],
                minimumNativeControls: 7,
                minimumScrollViews: 1,
                build: { AnyView(AutomaticOrganizationDashboardView(model: fixture.model)) }
            )
        }
        scenarios.append(Scenario(
            name: "auto-organize-rule-editor",
            category: "auto-organize",
            sizeClass: "production-sheet",
            viewport: Viewport(width: 520, height: 560),
            requiredAccessibilityAnchors: ["Route product links", "Link domain"],
            requiredOCRAnchors: ["Edit Organization Rule", "Route product links"],
            minimumNativeControls: 6,
            minimumScrollViews: 0,
            build: {
                AnyView(AutomaticOrganizationRuleEditorSheet(
                    model: fixture.model,
                    editingRule: fixture.model.automaticOrganizationSnapshot.rules.first,
                    dismiss: {}
                ))
            }
        ))
        scenarios.append(Scenario(
            name: "smart-view-editor",
            category: "smart-views-bulk",
            sizeClass: "production-sheet",
            viewport: Viewport(width: 500, height: 390),
            requiredAccessibilityAnchors: ["Product links", "type:url domain:example.com tag:research"],
            requiredOCRAnchors: ["Edit Smart View", "Domain: example.com"],
            minimumNativeControls: 3,
            minimumScrollViews: 0,
            build: { AnyView(SaveSmartViewSheet(model: fixture.model, editing: fixture.smartView)) }
        ))
        scenarios += bulkSizes.map { sizeClass, viewport in
            Scenario(
                name: "bulk-toolbar-\(sizeClass)",
                category: "smart-views-bulk",
                sizeClass: sizeClass,
                viewport: viewport,
                requiredAccessibilityAnchors: ["Selected Items", "All", "Notes", "Pinned"],
                requiredOCRAnchors: ["2 selected", "Saved"],
                minimumNativeControls: 7,
                minimumScrollViews: 3,
                build: { AnyView(MainWindowView(model: fixture.model)) }
            )
        }
        scenarios.append(Scenario(
            name: "bulk-result",
            category: "smart-views-bulk",
            sizeClass: "production-sheet",
            viewport: Viewport(width: 520, height: 360),
            requiredAccessibilityAnchors: [],
            requiredOCRAnchors: ["Added Tags", "Not changed"],
            minimumNativeControls: 1,
            minimumScrollViews: 1,
            build: {
                AnyView(BulkLibraryResultSheet(
                    result: BulkLibraryActionResult(
                        action: "Added Tags",
                        successCount: 2,
                        failures: [BulkLibraryActionResult.Failure(
                            id: UUID(),
                            title: "History item remains unchanged",
                            reason: "Save this History item before adding tags."
                        )]
                    ),
                    dismiss: {}
                ))
            }
        ))
        scenarios += actionsSizes.map { sizeClass, viewport in
            Scenario(
                name: "actions-workspace-\(sizeClass)",
                category: "actions",
                sizeClass: sizeClass,
                viewport: viewport,
                requiredAccessibilityAnchors: ["Custom Actions", "Clip Tools"],
                requiredOCRAnchors: ["Actions", "Custom actions"],
                minimumNativeControls: 4,
                minimumScrollViews: 1,
                build: { AnyView(WorkflowDashboardView(model: fixture.model)) }
            )
        }
        scenarios.append(Scenario(
            name: "custom-flow-editor",
            category: "actions",
            sizeClass: "production-sheet",
            viewport: Viewport(width: 640, height: 720),
            requiredAccessibilityAnchors: ["Sales research handoff", "Any clip", "Website or CRM"],
            requiredOCRAnchors: ["Edit Custom Action", "Steps"],
            minimumNativeControls: 10,
            minimumScrollViews: 1,
            build: {
                AnyView(FlowEditorSheet(
                    existingFlow: fixture.flow,
                    folders: fixture.model.folderDestinations,
                    aiAvailability: .appleIntelligenceUnavailable,
                    applications: [],
                    isDiscoveringApplications: false,
                    refreshApplications: {},
                    makeApplicationStep: { _, _ in nil },
                    save: { _, _, _, _, _ in false },
                    cancel: {}
                ))
            }
        ))
        scenarios.append(Scenario(
            name: "custom-flow-review",
            category: "actions",
            sizeClass: "production-sheet",
            viewport: Viewport(width: 560, height: 430),
            requiredAccessibilityAnchors: [],
            requiredOCRAnchors: ["Run custom action", "Sales research handoff"],
            minimumNativeControls: 1,
            minimumScrollViews: 1,
            build: {
                AnyView(ClipFlowReviewSheet(
                    request: try! ClipFlowRunReviewRequest(
                        sourceClip: fixture.codeClip,
                        flow: fixture.flow,
                        triggeredAutomatically: false
                    ),
                    folderName: { _ in "Accounts / Acme" },
                    run: { true },
                    cancel: {}
                ))
            }
        ))
        scenarios.append(Scenario(
            name: "new-sales-workspace",
            category: "sales",
            sizeClass: "production-sheet",
            viewport: Viewport(width: 520, height: 390),
            requiredAccessibilityAnchors: ["Workspace name"],
            requiredOCRAnchors: ["New Sales Workspace", "Accounts"],
            minimumNativeControls: 1,
            minimumScrollViews: 0,
            build: { AnyView(NewSalesWorkspaceSheet(create: { _ in })) }
        ))
        scenarios.append(Scenario(
            name: "research-handoff-review",
            category: "sales",
            sizeClass: "production-sheet",
            viewport: Viewport(width: 650, height: 500),
            requiredAccessibilityAnchors: ["Markdown", "CSV", "JSON"],
            requiredOCRAnchors: ["Review Research Handoff", "Omitted"],
            minimumNativeControls: 1,
            minimumScrollViews: 1,
            build: {
                AnyView(HandoffReviewSheet(
                    request: fixture.handoff,
                    copyMarkdown: { _ in },
                    export: { _, _ in },
                    cancel: {}
                ))
            }
        ))

        for (stateName, stateFixture, stateOCR) in [
            ("idle", idle, "No network request"),
            ("loaded", loaded, "clipboard workflows"),
        ] {
            scenarios += liveSizes.map { sizeClass, viewport in
                liveScenario(
                    name: "live-preview-\(stateName)-\(sizeClass)",
                    sizeClass: sizeClass,
                    viewport: viewport,
                    fixture: stateFixture,
                    stateOCR: stateOCR
                )
            }
        }
        scenarios.append(liveScenario(
            name: "live-preview-offline-normal",
            sizeClass: "normal",
            viewport: Viewport(width: 700, height: 390),
            fixture: offline,
            stateOCR: "offline"
        ))
        scenarios.append(liveScenario(
            name: "live-preview-blocked-minimum",
            sizeClass: "minimum",
            viewport: Viewport(width: 480, height: 330),
            fixture: blocked,
            stateOCR: "HTTPS link"
        ))
        return scenarios
    }

    private func liveScenario(
        name: String,
        sizeClass: String,
        viewport: Viewport,
        fixture: (AppModel, PresentedClip, StoredLinkPreviewDescriptor),
        stateOCR: String
    ) -> Scenario {
        Scenario(
            name: name,
            category: "live-link-preview",
            sizeClass: sizeClass,
            viewport: viewport,
            requiredAccessibilityAnchors: [fixture.2.url.absoluteString],
            requiredOCRAnchors: [stateOCR],
            minimumNativeControls: 1,
            minimumScrollViews: 0,
            build: {
                AnyView(
                    LiveLinkPreviewCard(
                        descriptor: fixture.2,
                        clip: fixture.1,
                        model: fixture.0
                    )
                    .padding(18)
                )
            }
        )
    }

    private func makeFixture() async throws -> Fixture {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardRouterAdvancedVisual-\(UUID().uuidString)", isDirectory: true)
        let configuration = UIAcceptanceRuntime.Configuration(
            runID: "advanced-visual-\(UUID().uuidString.lowercased())",
            defaultsSuiteName: "com.clipboardrouter.advanced-visual.\(UUID().uuidString)",
            supportDirectory: support
        )
        guard let model = UIAcceptanceRuntime.makeModel(configuration: configuration) else {
            throw CocoaError(.coderInvalidValue)
        }

        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let rootFolderID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
        let accountsFolderID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        let messagingFolderID = UUID(uuidString: "20000000-0000-0000-0000-000000000003")!
        let folders = [
            try ClipFolder(id: rootFolderID, name: "Acme Campaign", sortOrder: 0, createdAt: now),
            try ClipFolder(
                id: accountsFolderID,
                name: "Accounts",
                parentFolderID: rootFolderID,
                sortOrder: 0,
                createdAt: now
            ),
            try ClipFolder(
                id: messagingFolderID,
                name: "Messaging",
                parentFolderID: rootFolderID,
                sortOrder: 1,
                createdAt: now
            ),
        ]
        let codeID = UUID(uuidString: "21000000-0000-0000-0000-000000000001")!
        let errorID = UUID(uuidString: "21000000-0000-0000-0000-000000000002")!
        let linkID = UUID(uuidString: "22000000-0000-0000-0000-000000000001")!
        let noteID = UUID(uuidString: "22000000-0000-0000-0000-000000000002")!
        let researchID = UUID(uuidString: "22000000-0000-0000-0000-000000000003")!
        let history = [
            HistoryItem(
                id: codeID,
                content: try ClipContent.detect(text: "func route(_ clip: Clip) { organizer.preview(clip) }"),
                createdAt: now,
                sourceApplicationBundleIdentifier: "com.apple.dt.Xcode"
            ),
            HistoryItem(
                id: errorID,
                content: try ClipContent.detect(text: "Fatal error: project handoff could not be rendered"),
                createdAt: now.addingTimeInterval(-10),
                sourceApplicationBundleIdentifier: "com.apple.Terminal"
            ),
        ]
        let saved = [
            try SavedClip(
                id: linkID,
                name: "Product workflow guide",
                content: ClipContent.detect(text: "https://example.com/product"),
                folderID: messagingFolderID,
                createdAt: now.addingTimeInterval(30),
                pinnedAt: now.addingTimeInterval(30),
                tags: ["research", "product"]
            ),
            try SavedClip(
                id: noteID,
                kind: .note,
                name: "Acme discovery notes",
                content: ClipContent.detect(text: "Sarah owns security operations. Review the workflow on Thursday."),
                folderID: accountsFolderID,
                createdAt: now.addingTimeInterval(20),
                tags: ["account", "discovery"]
            ),
            try SavedClip(
                id: researchID,
                name: "Competitive positioning",
                content: ClipContent.detect(text: "Reviewed differentiation: local rules, explicit handoffs, no automatic sends."),
                folderID: rootFolderID,
                createdAt: now.addingTimeInterval(10),
                tags: ["competitive"]
            ),
        ]
        let snapshot = ClipboardLibrarySnapshot(
            history: history,
            savedClips: saved,
            folders: folders,
            settings: ClipboardLibrarySettings(
                capturePolicy: CapturePolicy(isCaptureEnabled: false),
                retentionPolicy: .unlimited,
                maximumHistoryItemCount: 10_000,
                isSecretDetectionEnabled: false
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(snapshot).write(
            to: support.appendingPathComponent("library.json"),
            options: .atomic
        )

        let repository = try DeveloperRepositoryReference(
            displayName: "clipboard-router",
            securityScopedBookmark: Data([0x01, 0x02, 0x03]),
            canonicalPathFingerprint: String(repeating: "a", count: 64),
            branch: "feature/advanced-evidence",
            inspectedAt: now
        )
        let projectID = UUID(uuidString: "23000000-0000-0000-0000-000000000001")!
        let project = try DeveloperProject(
            id: projectID,
            name: "Security Toolkit",
            createdAt: now.addingTimeInterval(-3_600),
            modifiedAt: now,
            repository: repository,
            autoAddDeveloperClips: true,
            allowedSourceBundleIdentifiers: ["com.apple.Terminal", "com.apple.dt.Xcode"],
            preferredIDEBundleIdentifier: "com.apple.dt.Xcode"
        )
        let workspace = try DeveloperWorkspaceSnapshot(
            projects: [project],
            activeProjectID: project.id,
            memberships: [
                DeveloperClipMembership(
                    id: UUID(uuidString: "23000000-0000-0000-0000-000000000002")!,
                    projectID: project.id,
                    clip: .history(codeID),
                    addedAt: now
                ),
            ]
        )
        try await JSONFileDeveloperWorkspaceStore(
            fileURL: support.appendingPathComponent("developer-workspace.json")
        ).save(workspace)

        let rule = try AutomaticOrganizationRule(
            id: UUID(uuidString: "24000000-0000-0000-0000-000000000001")!,
            name: "Route product links",
            priority: 0,
            behavior: .suggest,
            matcher: .domain("example.com"),
            action: AutomaticOrganizationAction(
                movesToFolder: true,
                destinationFolderID: messagingFolderID,
                addedTags: ["product-research"]
            )
        )
        try await JSONFileAutomaticOrganizationStore(
            fileURL: support.appendingPathComponent("automatic-organization.json")
        ).save(try AutomaticOrganizationSnapshot(
            rules: [rule],
            locallyCreatedSavedItemIDs: Set(saved.map(\.id))
        ))

        await model.start()
        XCTAssertTrue(model.isReady)
        XCTAssertEqual(model.developerProjects.map(\.name), ["Security Toolkit"])
        XCTAssertEqual(model.automaticOrganizationSnapshot.rules.map(\.name), ["Route product links"])

        let codeClip = try XCTUnwrap(model.clipsForSelectedSection.first(where: { $0.id == codeID }))
        var pack = try ContextPack(
            id: UUID(uuidString: "25000000-0000-0000-0000-000000000001")!,
            name: "Security Toolkit"
        )
        try pack.append(ContextPackItem(
            id: codeClip.id,
            title: codeClip.title,
            textRepresentation: codeClip.content.text,
            capturedAt: codeClip.date,
            sourceApplication: "Xcode"
        ))
        try pack.append(ContextPackItem(
            id: errorID,
            title: "Fatal project handoff error",
            textRepresentation: history[1].content.text,
            capturedAt: history[1].createdAt,
            sourceApplication: "Terminal"
        ))

        let flow = try ClipFlow(
            id: UUID(uuidString: "26000000-0000-0000-0000-000000000001")!,
            name: "Sales research handoff",
            steps: [
                .addTags(
                    id: UUID(uuidString: "26000000-0000-0000-0000-000000000002")!,
                    tags: ["reviewed", "sales"]
                ),
                .openWeb(
                    id: UUID(uuidString: "26000000-0000-0000-0000-000000000003")!,
                    template: "https://app.hubspot.com/search?q={email}",
                    label: "HubSpot"
                ),
                .createTaskDraft(
                    id: UUID(uuidString: "26000000-0000-0000-0000-000000000004")!,
                    titleTemplate: "Follow up: {title}",
                    dueInDays: 2
                ),
            ]
        )
        let smartView = try UserSmartView(
            name: "Product links",
            query: "type:url domain:example.com tag:research",
            isPinned: true
        )
        let handoff = HandoffReviewRequest(projection: HandoffProjection(
            exportedAt: now,
            rootFolderPath: "Acme Campaign",
            records: [
                HandoffRecord(
                    itemID: noteID,
                    kind: .note,
                    title: "Acme discovery notes",
                    body: saved[1].content.text,
                    contentType: .plainText,
                    url: nil,
                    domain: nil,
                    sourceApplicationBundleIdentifier: nil,
                    originallyCapturedAt: nil,
                    createdAt: saved[1].createdAt,
                    modifiedAt: saved[1].modifiedAt,
                    folderPath: "Acme Campaign / Accounts",
                    tags: saved[1].tags ?? []
                ),
                HandoffRecord(
                    itemID: linkID,
                    kind: .clip,
                    title: "Product workflow guide",
                    body: saved[0].content.text,
                    contentType: .url,
                    url: saved[0].content.text,
                    domain: "example.com",
                    sourceApplicationBundleIdentifier: nil,
                    originallyCapturedAt: nil,
                    createdAt: saved[0].createdAt,
                    modifiedAt: saved[0].modifiedAt,
                    folderPath: "Acme Campaign / Messaging",
                    tags: saved[0].tags ?? []
                ),
            ],
            omissions: [
                HandoffOmission(itemID: UUID(), title: "Local screenshot", reasonCode: .unsupportedBinaryAsset),
                HandoffOmission(itemID: UUID(), title: "Flagged account key", reasonCode: .sensitive),
            ]
        ))
        return Fixture(
            model: model,
            codeClip: codeClip,
            savedClipIDs: [linkID, noteID],
            flow: flow,
            debugBundleRequest: DeveloperDebugBundleReviewRequest(pack: pack, generatedAt: now),
            smartView: smartView,
            handoff: handoff
        )
    }

    private func makeLivePreviewFixture(
        path: String,
        url: String = "https://example.com/product",
        result: Result<LiveLinkPreviewMetadata, LiveLinkPreviewError>,
        load: Bool
    ) async throws -> (AppModel, PresentedClip, StoredLinkPreviewDescriptor) {
        let content = try ClipContent.detect(text: url)
        let item = HistoryItem(
            content: content,
            createdAt: Date(timeIntervalSince1970: 2_000_000_000)
        )
        let suite = "com.clipboardrouter.advanced-visual.live.\(path).\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defaults.set(true, forKey: "hasCompletedOnboarding.v1")
        let model = AppModel(
            defaults: defaults,
            liveLinkPreviewClient: AdvancedVisualPreviewClient(result: result),
            pasteboardReader: SystemPasteboardReader(
                pasteboard: NSPasteboard(name: NSPasteboard.Name(
                    "com.clipboardrouter.advanced-visual.live.\(path).\(UUID().uuidString)"
                ))
            ),
            hotKey: AdvancedVisualHotKeyRegistrar(),
            supportDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("ClipboardRouterAdvancedLive-\(UUID().uuidString)", isDirectory: true),
            libraryPersistence: InMemoryClipboardLibraryStore(
                snapshot: ClipboardLibrarySnapshot(
                    history: [item],
                    settings: ClipboardLibrarySettings(
                        capturePolicy: CapturePolicy(isCaptureEnabled: false)
                    )
                )
            )
        )
        await model.start()
        let clip = try XCTUnwrap(model.clipsForSelectedSection.first)
        if load { await model.loadLiveLinkPreview(for: clip) }
        let descriptor = try XCTUnwrap(StoredLinkPreviewDescriptor(content: content))
        return (model, clip, descriptor)
    }

    private func render(_ scenario: Scenario, into outputDirectory: URL) throws -> Evidence {
        let root = scenario.build()
            .frame(width: scenario.viewport.size.width, height: scenario.viewport.size.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .dark)
            .tint(.blue)
        let hostingView = NSHostingView(rootView: AnyView(root))
        hostingView.appearance = NSAppearance(named: .darkAqua)
        hostingView.frame = NSRect(origin: .zero, size: scenario.viewport.size)
        let window = makeWindow(hostingView: hostingView, size: scenario.viewport.size)
        settle(window: window, view: hostingView)

        let evidence = try capture(
            name: scenario.name,
            category: scenario.category,
            sizeClass: scenario.sizeClass,
            viewport: scenario.viewport,
            view: hostingView,
            requiredAccessibilityAnchors: scenario.requiredAccessibilityAnchors,
            requiredOCRAnchors: scenario.requiredOCRAnchors,
            minimumNativeControls: scenario.minimumNativeControls,
            minimumScrollViews: scenario.minimumScrollViews,
            into: outputDirectory
        )
        window.contentView = nil
        window.close()
        return evidence
    }

    private func capture(
        name: String,
        category: String,
        sizeClass: String,
        viewport: Viewport,
        view: NSView,
        requiredAccessibilityAnchors: [String],
        requiredOCRAnchors: [String],
        minimumNativeControls: Int,
        minimumScrollViews: Int,
        into outputDirectory: URL
    ) throws -> Evidence {
        XCTAssertEqual(view.bounds.width, viewport.size.width, accuracy: 1.1)
        XCTAssertEqual(view.bounds.height, viewport.size.height, accuracy: 1.1)

        let allViews = descendants(of: view)
        let visibleViews = allViews.filter { candidate in
            guard !candidate.isHidden, candidate.alphaValue > 0.01,
                  candidate.bounds.width > 1, candidate.bounds.height > 1
            else { return false }
            return candidate.convert(candidate.bounds, to: view).intersects(view.bounds)
        }
        XCTAssertGreaterThanOrEqual(visibleViews.count, 8, "\(name) did not lay out production views")

        let controls = visibleViews.compactMap { $0 as? NSControl }
        let scrollViews = visibleViews.compactMap { $0 as? NSScrollView }
        XCTAssertGreaterThanOrEqual(
            controls.count,
            minimumNativeControls,
            "\(name) is missing native controls"
        )
        XCTAssertGreaterThanOrEqual(
            scrollViews.count,
            minimumScrollViews,
            "\(name) is missing its expected scroll container"
        )

        let accessibilityText = accessibilitySnapshot(from: view)
            + " | " + nativeControlSnapshot(from: view)
        let matchedAccessibilityAnchors = requiredAccessibilityAnchors.filter {
            accessibilityText.localizedCaseInsensitiveContains($0)
        }
        for anchor in requiredAccessibilityAnchors {
            XCTAssertTrue(
                accessibilityText.localizedCaseInsensitiveContains(anchor),
                "Missing accessibility anchor ‘\(anchor)’ in \(name). Snapshot: \(accessibilityText)"
            )
        }

        let bitmap = try bitmapImage(of: view, size: viewport.size)
        let sampledColorCount = sampledColors(in: bitmap)
        let nontransparentPixelRatio = nontransparentRatio(in: bitmap)
        XCTAssertGreaterThan(sampledColorCount, 25, "\(name) rendered blank or visually incomplete")
        XCTAssertGreaterThan(nontransparentPixelRatio, 0.92, "\(name) left most pixels blank")
        XCTAssertLessThan(nearWhiteRatio(in: bitmap), 0.25, "\(name) lost its dark production background")

        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let fileName = "\(name)-\(viewport.slug).png"
        let imageURL = outputDirectory.appendingPathComponent(fileName)
        try png.write(to: imageURL, options: .atomic)

        let recognized = try recognizeText(in: imageURL)
        let normalizedOCR = normalizedText(recognized.joined(separator: " "))
        for anchor in requiredOCRAnchors {
            XCTAssertTrue(
                normalizedOCR.contains(normalizedText(anchor)),
                "Missing visibly rendered OCR anchor ‘\(anchor)’ in \(name). OCR: \(recognized)"
            )
        }

        let controlFrames = controls.map { $0.convert($0.bounds, to: view) }
        let visibleControlFrames = controlFrames.filter { $0.intersects(view.bounds) }
        let widestControl = visibleControlFrames.map(\.width).max() ?? 0
        let tallestScrollView = scrollViews.map { $0.convert($0.bounds, to: view).height }.max() ?? 0
        let minimumVisibleControlRatio = visibleControlFrames.map { frame -> Double in
            let area = max(frame.width * frame.height, 1)
            let visibleArea = frame.intersection(view.bounds).width * frame.intersection(view.bounds).height
            return visibleArea / area
        }.min() ?? 1
        XCTAssertGreaterThan(
            minimumVisibleControlRatio,
            0.15,
            "\(name) contains a severely clipped visible native control"
        )

        return Evidence(
            surface: name,
            category: category,
            sizeClass: sizeClass,
            file: fileName,
            logicalWidth: viewport.width,
            logicalHeight: viewport.height,
            pixelWidth: bitmap.pixelsWide,
            pixelHeight: bitmap.pixelsHigh,
            sampledColorCount: sampledColorCount,
            nontransparentPixelRatio: nontransparentPixelRatio,
            nativeControlCount: controls.count,
            scrollViewCount: scrollViews.count,
            visibleNativeViewCount: visibleViews.count,
            accessibilityAnchorCount: matchedAccessibilityAnchors.count,
            ocrAnchorCount: requiredOCRAnchors.count,
            geometry: [
                "widestNativeControl": widestControl,
                "tallestScrollView": tallestScrollView,
                "minimumVisibleControlRatio": minimumVisibleControlRatio,
            ],
            recognizedText: recognized,
            sha256: sha256(png)
        )
    }

    private func makeWindow(hostingView: NSView, size: CGSize) -> NSWindow {
        let window = AdvancedVisualWindow(
            contentRect: NSRect(origin: NSPoint(x: 180, y: 180), size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        return window
    }

    private func settle(window: NSWindow, view: NSView) {
        for _ in 0..<4 {
            window.layoutIfNeeded()
            view.layoutSubtreeIfNeeded()
            drainMainRunLoop(for: 0.08)
        }
        window.layoutIfNeeded()
        view.layoutSubtreeIfNeeded()
    }

    private func bitmapImage(of view: NSView, size: CGSize) throws -> NSBitmapImageRep {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width.rounded()),
            pixelsHigh: Int(size.height.rounded()),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [],
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { throw CocoaError(.coderInvalidValue) }
        bitmap.size = size
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    private func recognizeText(in imageURL: URL) throws -> [String] {
        let candidates = [
            "/opt/homebrew/bin/tesseract",
            "/usr/local/bin/tesseract",
        ]
        guard let executable = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else {
            throw XCTSkip("Tesseract is required for advanced visual OCR assertions")
        }
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        let physicalPath: String
        if imageURL.path.hasPrefix("/tmp/") {
            physicalPath = "/private" + imageURL.path
        } else if imageURL.path.hasPrefix("/var/") {
            physicalPath = "/private" + imageURL.path
        } else {
            physicalPath = imageURL.path
        }
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = [
            physicalPath,
            "stdout",
            "--psm",
            "11",
        ]
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let detail = String(
                data: errors.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            let message = "Tesseract OCR failed with status \(process.terminationStatus) for \(physicalPath). \(detail)"
            throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: message])
        }
        let recognized = String(data: data, encoding: .utf8) ?? ""
        return recognized.split(separator: "\n").map(String.init)
    }

    private func normalizedText(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: "…", with: "")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
            .joined(separator: " ")
    }

    private func sampledColors(in bitmap: NSBitmapImageRep) -> Int {
        var colors = Set<UInt32>()
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 8) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 8) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                let red = UInt32((color.redComponent * 255).rounded())
                let green = UInt32((color.greenComponent * 255).rounded())
                let blue = UInt32((color.blueComponent * 255).rounded())
                colors.insert((red << 16) | (green << 8) | blue)
            }
        }
        return colors.count
    }

    private func nontransparentRatio(in bitmap: NSBitmapImageRep) -> Double {
        var opaque = 0
        var samples = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 8) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 8) {
                samples += 1
                if (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 { opaque += 1 }
            }
        }
        return samples == 0 ? 0 : Double(opaque) / Double(samples)
    }

    private func nearWhiteRatio(in bitmap: NSBitmapImageRep) -> Double {
        var nearWhite = 0
        var samples = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 8) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 8) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                samples += 1
                if color.redComponent > 0.92,
                   color.greenComponent > 0.92,
                   color.blueComponent > 0.92
                { nearWhite += 1 }
            }
        }
        return samples == 0 ? 0 : Double(nearWhite) / Double(samples)
    }

    private func accessibilitySnapshot(from view: NSView) -> String {
        var components: [String] = []
        var visited = Set<ObjectIdentifier>()

        func visit(_ value: Any, depth: Int) {
            guard depth < 40, let object = value as? NSObject else { return }
            let identifier = ObjectIdentifier(object)
            guard visited.insert(identifier).inserted else { return }
            for selectorName in [
                "accessibilityIdentifier", "accessibilityLabel", "accessibilityTitle",
                "accessibilityValue", "accessibilityHelp", "accessibilityRoleDescription",
            ] {
                let selector = NSSelectorFromString(selectorName)
                guard object.responds(to: selector),
                      let value = object.perform(selector)?.takeUnretainedValue()
                else { continue }
                if let string = value as? String { components.append(string) }
                else if let number = value as? NSNumber { components.append(number.stringValue) }
            }
            let childrenSelector = NSSelectorFromString("accessibilityChildren")
            if object.responds(to: childrenSelector),
               let children = object.perform(childrenSelector)?.takeUnretainedValue() as? [Any]
            {
                children.forEach { visit($0, depth: depth + 1) }
            }
            if let childView = object as? NSView {
                childView.subviews.forEach { visit($0, depth: depth + 1) }
            }
        }

        visit(view, depth: 0)
        return components.joined(separator: " | ")
    }

    private func nativeControlSnapshot(from view: NSView) -> String {
        descendants(of: view).flatMap { candidate -> [String] in
            var values: [String] = []
            if let control = candidate as? NSControl {
                if !control.stringValue.isEmpty { values.append(control.stringValue) }
                if let identifier = control.identifier?.rawValue { values.append(identifier) }
                if let label = control.accessibilityLabel(), !label.isEmpty { values.append(label) }
            }
            if let field = candidate as? NSTextField, let placeholder = field.placeholderString {
                values.append(placeholder)
            }
            if let button = candidate as? NSButton, !button.title.isEmpty {
                values.append(button.title)
            }
            if let segmented = candidate as? NSSegmentedControl {
                for index in 0..<segmented.segmentCount {
                    if let label = segmented.label(forSegment: index), !label.isEmpty {
                        values.append(label)
                    }
                }
            }
            return values
        }.joined(separator: " | ")
    }

    private func descendants(of root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap(descendants(of:))
    }

    private func drainMainRunLoop(for duration: TimeInterval) {
        let deadline = Date().addingTimeInterval(duration)
        while RunLoop.main.run(mode: .default, before: deadline), Date() < deadline {}
    }

    private func evidenceDirectory() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        let url: URL
        if let requested = environment["CLIPBOARD_ROUTER_ADVANCED_SURFACE_EVIDENCE_DIR"],
           !requested.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            url = URL(fileURLWithPath: requested, isDirectory: true)
        } else {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("ClipboardRouterAdvancedSurfaceVisualEvidence", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private final class AdvancedVisualWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
private final class AdvancedVisualHotKeyRegistrar: GlobalHotKeyRegistering {
    func register(
        _ descriptor: GlobalHotKeyDescriptor,
        handler: @escaping @MainActor () -> Void
    ) throws {}

    func unregister() {}
}

private actor AdvancedVisualPreviewClient: LiveLinkPreviewFetching {
    let result: Result<LiveLinkPreviewMetadata, LiveLinkPreviewError>

    init(result: Result<LiveLinkPreviewMetadata, LiveLinkPreviewError>) {
        self.result = result
    }

    func preview(for url: URL, refresh: Bool) async throws -> LiveLinkPreviewMetadata {
        try result.get()
    }

    func removeCachedPreview(for url: URL) async {}
    func clearCache() async {}
}
