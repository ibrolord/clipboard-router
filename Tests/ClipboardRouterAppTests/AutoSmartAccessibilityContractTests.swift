import ClipboardRouterCore
import XCTest
@testable import ClipboardRouterApp

final class AutoSmartAccessibilityContractTests: XCTestCase {
    private let fixedID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

    func testSmartViewContractUsesStableUUIDKeyedControlsAndParseableState() throws {
        let view = try UserSmartView(
            id: fixedID,
            name: "Qualified | Leads",
            query: "tag:qualified",
            isPinned: true,
            sortOrder: 9,
            createdAt: Date(timeIntervalSince1970: 10)
        )

        XCTAssertEqual(
            SmartViewBulkAccessibility.smartViewRow(fixedID),
            "uiAcceptance.smartViews.row.aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        )
        for control in ["edit", "pin", "moveUp", "moveDown", "delete"] {
            XCTAssertEqual(
                SmartViewBulkAccessibility.smartViewControl(control, id: fixedID),
                "uiAcceptance.smartViews.\(control).aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
            )
        }
        XCTAssertEqual(
            SmartViewBulkAccessibility.smartViewValue(view, order: 2),
            #"name=Qualified \| Leads|query=tag:qualified|pinned=true|order=2"#
        )
    }

    func testSmartViewEditorAndBulkResultValuesExposeValidationAndCounts() {
        XCTAssertEqual(
            SmartViewBulkAccessibility.editorValue(
                editingID: fixedID,
                isPinned: false,
                isSaving: true,
                validationError: "Query | invalid",
                saveError: nil
            ),
            #"mode=edit|view=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee|pinned=false|saving=true|valid=false|error=Query \| invalid"#
        )

        let result = BulkLibraryActionResult(
            action: "Add | Tags",
            successCount: 2,
            failures: [
                .init(id: fixedID, title: "History", reason: "Read-only")
            ]
        )
        XCTAssertEqual(
            SmartViewBulkAccessibility.bulkResultValue(result),
            #"action=Add \| Tags|success=2|failure=1"#
        )
    }

    func testAutomaticOrganizationContractUsesStableUUIDKeyedControlsAndState() throws {
        let rule = try AutomaticOrganizationRule(
            id: fixedID,
            name: "Route | Leads",
            isEnabled: true,
            priority: 7,
            behavior: .alwaysApply,
            matcher: .contentType(.plainText),
            action: AutomaticOrganizationAction(addedTags: ["qualified"])
        )

        XCTAssertEqual(
            AutomaticOrganizationAccessibility.ruleRow(fixedID),
            "uiAcceptance.autoOrganize.row.aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        )
        for control in ["edit", "enable", "behavior", "moveUp", "moveDown", "delete"] {
            XCTAssertEqual(
                AutomaticOrganizationAccessibility.ruleControl(control, ruleID: fixedID),
                "uiAcceptance.autoOrganize.\(control).aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
            )
        }
        XCTAssertEqual(
            AutomaticOrganizationAccessibility.ruleValue(
                rule,
                order: 1,
                isSuppressed: false
            ),
            #"name=Route \| Leads|enabled=true|behavior=alwaysApply|order=1|suppressed=false"#
        )
        XCTAssertEqual(
            AutomaticOrganizationAccessibility.ruleValue(
                rule,
                order: 1,
                isSuppressed: true
            ),
            #"name=Route \| Leads|enabled=false|behavior=alwaysApply|order=1|suppressed=true"#
        )
    }

    func testAutomaticOrganizationDashboardEditorAndSuggestionValuesExposeOutcomes() throws {
        XCTAssertEqual(
            AutomaticOrganizationAccessibility.dashboardValue(
                previewClipID: fixedID,
                ruleCount: 2,
                receiptCount: 1,
                status: "Organization applied.",
                error: nil
            ),
            "previewClip=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee|rules=2|receipts=1|status=Organization applied.|error=none"
        )
        XCTAssertEqual(
            AutomaticOrganizationAccessibility.editorValue(
                editingRuleID: fixedID,
                matchKind: .safeRegex,
                isDestinationEligible: false,
                error: "Folder | unavailable"
            ),
            #"mode=edit|rule=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee|match=Safe regex|destinationValid=false|error=Folder \| unavailable"#
        )

        let rule = try AutomaticOrganizationRule(
            id: fixedID,
            name: "Qualify",
            priority: 0,
            matcher: .contentType(.plainText),
            action: AutomaticOrganizationAction(addedTags: ["qualified"])
        )
        let clipID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let clip = PresentedClip(
            id: clipID,
            title: "Lead",
            content: try ClipContent.detect(text: "Lead"),
            date: Date(timeIntervalSince1970: 20),
            sourceBundleIdentifier: nil,
            origin: .saved(folderID: nil)
        )
        let suggestion = AutomaticOrganizationSuggestion(
            rule: rule,
            reason: "Content type is plainText",
            confidence: 100
        )

        XCTAssertEqual(
            AutomaticOrganizationAccessibility.suggestionValue(
                suggestion,
                clip: clip,
                hasUndoReceipt: true,
                status: "Organization applied.",
                error: nil
            ),
            "rule=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee|clip=11111111-2222-3333-4444-555555555555|confidence=100|undo=true|tags=|status=Organization applied.|error=none"
        )

        var taggedClip = clip
        taggedClip.tags = ["qualified", "auto-ready"]
        XCTAssertEqual(
            AutomaticOrganizationAccessibility.suggestionValue(
                suggestion,
                clip: taggedClip,
                hasUndoReceipt: false,
                status: nil,
                error: nil
            ),
            "rule=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee|clip=11111111-2222-3333-4444-555555555555|confidence=100|undo=false|tags=auto-ready,qualified|status=none|error=none"
        )
    }

    func testAutomaticOrganizationSuggestionValueEscapesSpecialCharactersInTags() throws {
        let rule = try AutomaticOrganizationRule(
            id: fixedID,
            name: "Qualify",
            priority: 0,
            matcher: .contentType(.plainText),
            action: AutomaticOrganizationAction(addedTags: ["qualified"])
        )
        let clipID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        var clip = PresentedClip(
            id: clipID,
            title: "Lead",
            content: try ClipContent.detect(text: "Lead"),
            date: Date(timeIntervalSince1970: 20),
            sourceBundleIdentifier: nil,
            origin: .saved(folderID: nil)
        )
        let suggestion = AutomaticOrganizationSuggestion(
            rule: rule,
            reason: "Content type is plainText",
            confidence: 100
        )

        // Comma: the inner separator between tags must itself be escaped so a
        // comma inside a tag cannot be misread as a boundary between two tags.
        clip.tags = ["a,b"]
        XCTAssertEqual(
            AutomaticOrganizationAccessibility.suggestionValue(
                suggestion, clip: clip, hasUndoReceipt: false, status: nil, error: nil
            ),
            "rule=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee|clip=11111111-2222-3333-4444-555555555555|confidence=100|undo=false|tags=a\\,b|status=none|error=none"
        )

        // Pipe: must not be readable as the boundary that ends the tags= field early.
        clip.tags = ["a|b"]
        XCTAssertEqual(
            AutomaticOrganizationAccessibility.suggestionValue(
                suggestion, clip: clip, hasUndoReceipt: false, status: nil, error: nil
            ),
            "rule=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee|clip=11111111-2222-3333-4444-555555555555|confidence=100|undo=false|tags=a\\|b|status=none|error=none"
        )

        // Backslash: must be doubled so a literal backslash is not misread as an escape lead-in.
        clip.tags = [#"a\b"#]
        XCTAssertEqual(
            AutomaticOrganizationAccessibility.suggestionValue(
                suggestion, clip: clip, hasUndoReceipt: false, status: nil, error: nil
            ),
            #"rule=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee|clip=11111111-2222-3333-4444-555555555555|confidence=100|undo=false|tags=a\\b|status=none|error=none"#
        )

        // Newline: must not fracture the single-line AX value across multiple lines.
        clip.tags = ["a\nb"]
        XCTAssertEqual(
            AutomaticOrganizationAccessibility.suggestionValue(
                suggestion, clip: clip, hasUndoReceipt: false, status: nil, error: nil
            ),
            #"rule=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee|clip=11111111-2222-3333-4444-555555555555|confidence=100|undo=false|tags=a\nb|status=none|error=none"#
        )

        // All four together, plus a second ordinary tag, exercise escaping and the
        // comma separator side by side without cross-contamination.
        clip.tags = ["a,b|c\\d\ne", "plain"]
        XCTAssertEqual(
            AutomaticOrganizationAccessibility.suggestionValue(
                suggestion, clip: clip, hasUndoReceipt: false, status: nil, error: nil
            ),
            #"rule=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee|clip=11111111-2222-3333-4444-555555555555|confidence=100|undo=false|tags=a\,b\|c\\d\ne,plain|status=none|error=none"#
        )
    }
}
