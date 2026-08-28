import XCTest
@testable import ClipboardRouterApp

@MainActor
final class ClipActionCatalogTests: XCTestCase {
    func testActionInventoryParityAcrossSupportedClipStates() {
        for capabilities in capabilityMatrix {
            let rawMenu = ids(for: capabilities, surface: .menuBar)
            let rawContext = ids(for: capabilities, surface: .libraryContext)
            let rawInspector = ids(for: capabilities, surface: .libraryInspector)
            let observedDifferences = rawMenu.symmetricDifference(rawContext)
                .union(rawContext.symmetricDifference(rawInspector))
            XCTAssertTrue(
                observedDifferences.isSubset(of: ClipActionCatalog.deliberateSurfaceDifferences),
                "Undeclared surface difference: \(observedDifferences)"
            )

            let menu = rawMenu
                .subtracting([.showInLibrary])
            let context = rawContext
            let inspector = rawInspector
                .subtracting([.rename, .editTags])

            XCTAssertEqual(menu, context, "Menu/row action drift for \(capabilities)")
            XCTAssertEqual(context, inspector, "Row/inspector action drift for \(capabilities)")
        }
    }

    func testEveryInventoryHasUniqueStableIDsAndCanonicalOrdering() {
        for capabilities in capabilityMatrix {
            for surface in ClipActionSurface.allCases {
                let inventory = ClipActionCatalog.inventory(for: capabilities, surface: surface)
                XCTAssertEqual(Set(inventory.descriptors.map(\.id)).count, inventory.descriptors.count)

                let positions = inventory.descriptors.map { ($0.group.rawValue, $0.order, $0.id.rawValue) }
                XCTAssertEqual(
                    positions.map { "\($0.0):\($0.1):\($0.2)" },
                    positions.sorted {
                        if $0.0 != $1.0 { return $0.0 < $1.0 }
                        if $0.1 != $1.1 { return $0.1 < $1.1 }
                        return $0.2 < $1.2
                    }.map { "\($0.0):\($0.1):\($0.2)" }
                )
            }
        }
    }

    func testPrivateAndSensitiveStatesDoNotExposeOutboundActions() {
        let privateInventory = ClipActionCatalog.inventory(
            for: privateClip,
            surface: .menuBar
        )
        XCTAssertTrue(privateInventory.descriptors.isEmpty)

        let sensitiveInventory = ClipActionCatalog.inventory(
            for: sensitiveHistory,
            surface: .libraryContext
        )
        XCTAssertFalse(sensitiveInventory.contains(.share))
        XCTAssertFalse(sensitiveInventory.contains(.copyAndOpen))
        XCTAssertFalse(sensitiveInventory.contains(.useAI))
        XCTAssertFalse(sensitiveInventory.contains(.clipTools))
        XCTAssertEqual(sensitiveInventory[.pin]?.isEnabled, false)
        XCTAssertNotNil(sensitiveInventory[.pin]?.disabledReason)
    }

    func testSharedViewerMutationsAreVisibleButTruthfullyDisabled() {
        let inventory = ClipActionCatalog.inventory(for: sharedViewer, surface: .libraryInspector)
        for id: ClipActionID in [.moveToFolder, .pin, .rename, .editTags, .delete] {
            XCTAssertEqual(inventory[id]?.isEnabled, false, "Expected \(id) disabled")
            XCTAssertFalse(inventory[id]?.disabledReason?.isEmpty ?? true)
        }
        XCTAssertFalse(inventory.contains(.editClip))
        XCTAssertFalse(inventory.contains(.editNote))
    }

    func testAIAndCRMRemainIndependentCapabilities() {
        var capabilities = normalHistory
        capabilities.canUseAssistant = false
        capabilities.canRouteToAI = true
        capabilities.canSendToCRM = true
        let inventory = ClipActionCatalog.inventory(for: capabilities, surface: .menuBar)

        XCTAssertFalse(inventory.contains(.useAI))
        XCTAssertTrue(inventory.contains(.copyAndOpen))
        XCTAssertTrue(inventory.contains(.sendToCRM))
    }

    private func ids(
        for capabilities: ClipActionCapabilities,
        surface: ClipActionSurface
    ) -> Set<ClipActionID> {
        Set(ClipActionCatalog.inventory(for: capabilities, surface: surface).descriptors.map(\.id))
    }

    private var capabilityMatrix: [ClipActionCapabilities] {
        [
            normalHistory,
            savedClipEditor,
            savedNoteEditor,
            sensitiveHistory,
            privateClip,
            sharedViewer,
            sharedEditorMedia,
        ]
    }

    private var normalHistory: ClipActionCapabilities {
        makeCapabilities(organization: .saveToFolder, isHistory: true)
    }

    private var savedClipEditor: ClipActionCapabilities {
        makeCapabilities(
            organization: .moveToFolder,
            isHistory: false,
            isSaved: true,
            canMutateSaved: true,
            canSetShortcut: true
        )
    }

    private var savedNoteEditor: ClipActionCapabilities {
        var capabilities = savedClipEditor
        capabilities.isNote = true
        capabilities.canEditNote = true
        capabilities.canEditClip = false
        capabilities.canMakeNote = false
        return capabilities
    }

    private var sensitiveHistory: ClipActionCapabilities {
        var capabilities = normalHistory
        capabilities.isSensitive = true
        capabilities.canEditClip = false
        capabilities.canMakeNote = false
        capabilities.canShare = false
        capabilities.canRouteToAI = false
        capabilities.canUseAssistant = false
        capabilities.canSendToCRM = false
        capabilities.canUseWorkflows = false
        capabilities.hasQuickActions = false
        capabilities.hasActionFlows = false
        return capabilities
    }

    private var privateClip: ClipActionCapabilities {
        makeCapabilities(
            organization: .none,
            isHistory: false,
            isPrivate: true,
            canEditClip: false,
            canMakeNote: false,
            canMoveToVault: false,
            canShare: false,
            canExport: false,
            hasQuickActions: false,
            hasActionFlows: false,
            canRouteToAI: false,
            canUseAssistant: false,
            canSendToCRM: false,
            canUseWorkflows: false,
            showsDelete: false,
            canDelete: false
        )
    }

    private var sharedViewer: ClipActionCapabilities {
        makeCapabilities(
            organization: .moveToFolder,
            isHistory: false,
            isSaved: true,
            canMutateSaved: false,
            canEditNote: false,
            canEditClip: false,
            canMakeNote: false,
            canSetShortcut: false,
            canMoveToVault: false,
            canDelete: false
        )
    }

    private var sharedEditorMedia: ClipActionCapabilities {
        makeCapabilities(
            organization: .moveToFolder,
            isHistory: false,
            isSaved: true,
            canMutateSaved: true,
            canEditClip: false,
            canMakeNote: false,
            canSetShortcut: true,
            canSendToCRM: false
        )
    }

    private func makeCapabilities(
        organization: ClipContextMenuPolicy.Organization,
        isHistory: Bool,
        isSaved: Bool = false,
        isPrivate: Bool = false,
        isNote: Bool = false,
        isPinned: Bool = false,
        isSensitive: Bool = false,
        canMutateSaved: Bool = false,
        canEditNote: Bool = false,
        canEditClip: Bool = true,
        canMakeNote: Bool = true,
        canSetShortcut: Bool = false,
        canMoveToVault: Bool = true,
        canShare: Bool = true,
        canExport: Bool = true,
        hasQuickActions: Bool = true,
        hasActionFlows: Bool = true,
        canRouteToAI: Bool = true,
        canUseAssistant: Bool = true,
        canSendToCRM: Bool = true,
        canUseWorkflows: Bool = true,
        showsDelete: Bool = true,
        canDelete: Bool = true
    ) -> ClipActionCapabilities {
        ClipActionCapabilities(
            organization: organization,
            isHistory: isHistory,
            isSaved: isSaved,
            isPrivate: isPrivate,
            isNote: isNote,
            isPinned: isPinned,
            isSensitive: isSensitive,
            canMutateSaved: canMutateSaved,
            canEditNote: canEditNote,
            canEditClip: canEditClip,
            canMakeNote: canMakeNote,
            canSetShortcut: canSetShortcut,
            canMoveToVault: canMoveToVault,
            vaultUnavailableReason: canMoveToVault ? nil : "Vault unavailable",
            canShare: canShare,
            canExport: canExport,
            exportUnavailableReason: nil,
            hasQuickActions: hasQuickActions,
            hasActionFlows: hasActionFlows,
            canRouteToAI: canRouteToAI,
            canUseAssistant: canUseAssistant,
            canSendToCRM: canSendToCRM,
            canUseWorkflows: canUseWorkflows,
            showsDelete: showsDelete,
            canDelete: canDelete
        )
    }
}
