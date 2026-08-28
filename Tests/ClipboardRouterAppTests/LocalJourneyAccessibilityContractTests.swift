import Foundation
import XCTest
@testable import ClipboardRouterApp

final class LocalJourneyAccessibilityContractTests: XCTestCase {
    func testSalesJourneyIdentifiersAreStableAndUnique() {
        let identifiers = [
            SalesResearchAccessibility.workspaceSheet,
            SalesResearchAccessibility.workspaceName,
            SalesResearchAccessibility.createWorkspace,
            SalesResearchAccessibility.cancelWorkspace,
            SalesResearchAccessibility.handoffReview,
            SalesResearchAccessibility.handoffSummary,
            SalesResearchAccessibility.handoffFormat,
            SalesResearchAccessibility.cancelHandoff,
            SalesResearchAccessibility.copyHandoff,
            SalesResearchAccessibility.exportHandoff,
        ]

        XCTAssertEqual(Set(identifiers).count, identifiers.count)
        XCTAssertEqual(
            SalesResearchAccessibility.handoffSummaryValue(ready: 3, omitted: 1),
            "3 ready, 1 omitted"
        )
    }

    func testDebugBundleJourneyIdentifiersAreStableAndUnique() {
        let identifiers = [
            DebugBundleAccessibility.workspace,
            DebugBundleAccessibility.review,
            DebugBundleAccessibility.reviewSheet,
            DebugBundleAccessibility.close,
            DebugBundleAccessibility.projectName,
            DebugBundleAccessibility.destination,
            DebugBundleAccessibility.problem,
            DebugBundleAccessibility.validation,
            DebugBundleAccessibility.preview,
            DebugBundleAccessibility.saveProject,
            DebugBundleAccessibility.copy,
            DebugBundleAccessibility.clear,
        ]

        XCTAssertEqual(Set(identifiers).count, identifiers.count)
    }

    func testDeveloperProjectJourneyIdentifiersAreStableAndDeterministic() {
        let id = UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!

        XCTAssertEqual(
            DeveloperProjectsAccessibility.projectRow(id),
            "uiAcceptance.projects.row.01234567-89ab-cdef-0123-456789abcdef"
        )
        XCTAssertEqual(
            DeveloperProjectsAccessibility.debugBundleRow(id),
            "uiAcceptance.projects.debugBundleRow.01234567-89ab-cdef-0123-456789abcdef"
        )
        XCTAssertNotEqual(
            DeveloperProjectsAccessibility.projectRow(id),
            DeveloperProjectsAccessibility.debugBundleRow(id)
        )
    }
}
