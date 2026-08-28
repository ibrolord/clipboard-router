import Foundation
@testable import ClipboardRouterCore
@testable import ClipboardRouterApp
import XCTest

final class RemainingAcceptanceContractsTests: XCTestCase {
    private let fixedID = UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!

    func testBulkActionsAndDestinationsExposeStableIdentifiers() {
        XCTAssertEqual(SmartViewBulkAccessibility.bulkSave, "uiAcceptance.bulk.save")
        XCTAssertEqual(SmartViewBulkAccessibility.bulkMove, "uiAcceptance.bulk.move")
        XCTAssertEqual(SmartViewBulkAccessibility.bulkPin, "uiAcceptance.bulk.pin")
        XCTAssertEqual(SmartViewBulkAccessibility.bulkUnpin, "uiAcceptance.bulk.unpin")
        XCTAssertEqual(SmartViewBulkAccessibility.bulkExport, "uiAcceptance.bulk.export")
        XCTAssertEqual(SmartViewBulkAccessibility.bulkClear, "uiAcceptance.bulk.clear")
        XCTAssertEqual(
            SmartViewBulkAccessibility.bulkDestination(nil),
            "uiAcceptance.bulk.destination.saved"
        )
        XCTAssertEqual(
            SmartViewBulkAccessibility.bulkDestination(fixedID),
            "uiAcceptance.bulk.destination.01234567-89ab-cdef-0123-456789abcdef"
        )
    }

    func testClipActionDescriptorsExposeSurfaceOrderAndDisabledReason() {
        let enabled = ClipActionDescriptor(
            id: .pin,
            group: .organization,
            order: 110,
            title: "Pin",
            symbolName: "pin",
            isEnabled: true,
            disabledReason: nil,
            presentation: .immediate
        )
        let disabled = ClipActionDescriptor(
            id: .moveToVault,
            group: .organization,
            order: 120,
            title: "Move to Vault…",
            symbolName: "lock",
            isEnabled: false,
            disabledReason: "Vault | locked",
            presentation: .persistentContinuation
        )
        let inventory = ClipActionInventory(
            surface: .libraryContext,
            descriptors: [enabled, disabled]
        )

        XCTAssertEqual(
            ClipActionAcceptanceAccessibility.action(
                disabled,
                clipID: fixedID,
                surface: .libraryContext
            ),
            "uiAcceptance.clipAction.libraryContext.01234567-89ab-cdef-0123-456789abcdef.moveToVault"
        )
        XCTAssertEqual(
            ClipActionAcceptanceAccessibility.descriptorValue(disabled, index: 1),
            #"index=1|id=moveToVault|group=1|order=120|enabled=false|reason=Vault \| locked|presentation=persistentContinuation"#
        )
        XCTAssertEqual(
            ClipActionAcceptanceAccessibility.inventoryValue(inventory),
            #"index=0|id=pin|group=1|order=110|enabled=true|reason=none|presentation=immediate;index=1|id=moveToVault|group=1|order=120|enabled=false|reason=Vault \| locked|presentation=persistentContinuation"#
        )
    }

    func testFlowEditorAndLedgerContractsAreUUIDKeyedAndParseable() {
        XCTAssertEqual(ActionFlowAccessibility.flowTrigger, "uiAcceptance.flow.trigger")
        XCTAssertEqual(ActionFlowAccessibility.flowTriggerFolder, "uiAcceptance.flow.triggerFolder")
        XCTAssertEqual(ActionFlowAccessibility.flowIncludeDescendants, "uiAcceptance.flow.includeDescendants")
        XCTAssertEqual(ActionFlowAccessibility.flowMove, "uiAcceptance.flow.move")
        XCTAssertEqual(ActionFlowAccessibility.flowOpen, "uiAcceptance.flow.open")
        XCTAssertEqual(
            ActionFlowAccessibility.openApplicationScope(fixedID),
            "uiAcceptance.flow.openApplication.01234567-89ab-cdef-0123-456789abcdef"
        )
        XCTAssertEqual(
            ActionFlowAccessibility.structuredEditorState(
                triggerFolderID: fixedID,
                includesDescendants: true,
                moveFolderID: nil,
                openKind: "website | CRM",
                stepCount: 3,
                canCommit: false
            ),
            #"triggerFolder=01234567-89ab-cdef-0123-456789abcdef|descendants=true|moveFolder=none|open=website \| CRM|steps=3|canCommit=false"#
        )

        let step = AutomationRunStepReceipt(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            sourceStepIDs: [fixedID],
            position: 0,
            kind: .organizeLibrary,
            retrySafety: .retrySafe
        )
        let run = AutomationRunRecord(
            id: fixedID,
            flowID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            flowVersionFingerprint: "flow",
            clipID: UUID(uuidString: "99999999-8888-7777-6666-555555555555")!,
            clipFingerprint: "clip",
            idempotencyKeyHash: "key",
            triggerKind: .manual,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2),
            status: .needsReview,
            steps: [step],
            lease: nil,
            failureCode: nil
        )
        XCTAssertEqual(
            AutomationRunAccessibility.row(fixedID),
            "uiAcceptance.flow.ledger.row.01234567-89ab-cdef-0123-456789abcdef"
        )
        XCTAssertEqual(
            AutomationRunAccessibility.rowValue(run, flowName: "Sales | Review"),
            #"flow=Sales \| Review|status=needsReview|completed=0|total=1|retry=false|failure=none"#
        )
    }

    func testAssistantCoversAllSixPresetsAndResultStates() {
        XCTAssertEqual(AssistantPurpose.allCases.count, 6)
        XCTAssertEqual(
            AssistantPurpose.allCases.map(AssistantAcceptanceAccessibility.preset),
            [
                "uiAcceptance.assistant.preset.quickAnswer",
                "uiAcceptance.assistant.preset.enrich",
                "uiAcceptance.assistant.preset.rewrite",
                "uiAcceptance.assistant.preset.format",
                "uiAcceptance.assistant.preset.followUp",
                "uiAcceptance.assistant.preset.research",
            ]
        )
        XCTAssertEqual(
            AssistantAcceptanceAccessibility.sheet(fixedID),
            "uiAcceptance.assistant.sheet.01234567-89ab-cdef-0123-456789abcdef"
        )
        XCTAssertEqual(
            AssistantAcceptanceAccessibility.stateValue(
                purpose: .research,
                engine: .onDevice,
                isWorking: false,
                isSaving: true,
                responseCount: 1,
                hasError: false
            ),
            "purpose=research|engine=onDevice|working=false|saving=true|responses=1|error=false"
        )
        let response = HostedAssistantResponse(
            requestID: "req|1",
            model: "local|model",
            text: "Answer",
            citations: []
        )
        XCTAssertEqual(
            AssistantAcceptanceAccessibility.responseValue(response),
            #"model=local\|model|request=req\|1|citations=0|characters=6"#
        )
    }

    func testApplicationBrowserAndProjectPickersUseRequestAndProjectUUIDs() {
        let application = ApplicationExclusionOption(
            bundleIdentifier: "com.example.Editor",
            displayName: "Editor",
            applicationURL: URL(fileURLWithPath: "/Applications/Editor.app"),
            teamIdentifier: "TEAM",
            isRunning: true
        )
        XCTAssertEqual(
            ApplicationBrowserAccessibility.root(fixedID),
            "uiAcceptance.appBrowser.root.01234567-89ab-cdef-0123-456789abcdef"
        )
        XCTAssertEqual(
            ApplicationBrowserAccessibility.row(requestID: fixedID, application: application),
            "uiAcceptance.appBrowser.row.01234567-89ab-cdef-0123-456789abcdef.com.example.Editor"
        )
        XCTAssertEqual(
            ApplicationBrowserAccessibility.stateValue(
                resultCount: 3,
                selectedApplicationID: "/Applications/Editor.app",
                isDiscovering: false
            ),
            "results=3|selected=/Applications/Editor.app|discovering=false"
        )
        XCTAssertEqual(
            DeveloperProjectPickerAccessibility.ideSearch(fixedID),
            "uiAcceptance.projects.ide.search.01234567-89ab-cdef-0123-456789abcdef"
        )
        XCTAssertEqual(
            DeveloperProjectPickerAccessibility.captureRow(
                projectID: fixedID,
                bundleIdentifier: "com.example.Editor"
            ),
            "uiAcceptance.projects.captureApps.row.01234567-89ab-cdef-0123-456789abcdef.com.example.Editor"
        )
    }

    func testCRMSetupReviewReceiptAndReconciliationContracts() {
        XCTAssertEqual(
            CRMAcceptanceAccessibility.connection(fixedID),
            "uiAcceptance.crm.connection.01234567-89ab-cdef-0123-456789abcdef"
        )
        XCTAssertEqual(
            CRMAcceptanceAccessibility.connectionValue(.setupRequired("Broker | missing")),
            #"state=setupRequired|account=none|scopes=0|reason=Broker \| missing"#
        )
        XCTAssertEqual(
            CRMAcceptanceAccessibility.receiptValue(.reconciliationRequired(idempotencyKey: "key|1")),
            #"status=reconciliationRequired|key=key\|1"#
        )
        XCTAssertEqual(
            CRMAcceptanceAccessibility.reconcile(fixedID),
            "uiAcceptance.crm.reconcile.01234567-89ab-cdef-0123-456789abcdef"
        )
    }
}
