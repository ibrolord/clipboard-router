import XCTest
@testable import ClipboardRouterApp

final class SettingsViewSupportTests: XCTestCase {
    func testClipLimitAdjustableAccessibilityAnnouncesRangeAndResult() {
        XCTAssertEqual(MenuBarClipLimitAccessibility.label, "Adjust clips shown")
        XCTAssertTrue(MenuBarClipLimitAccessibility.hint.contains("1 to 1,000"))
        XCTAssertEqual(MenuBarClipLimitAccessibility.value(1), "1 clip")
        XCTAssertEqual(MenuBarClipLimitAccessibility.value(100), "100 clips")
        XCTAssertEqual(MenuBarClipLimitAccessibility.value(1_000), "1000 clips")
    }

    func testSettingsDetailReadingMeasureIsBounded() {
        XCTAssertEqual(SettingsLayout.maximumDetailContentWidth, 760)
        XCTAssertTrue((760...840).contains(SettingsLayout.maximumDetailContentWidth))
    }

    func testVisibleTabsExcludeLegacyAutomationsDestination() {
        XCTAssertEqual(
            SettingsTab.visibleCases,
            [.general, .destinations, .assistant, .crm, .sync, .license, .privacy]
        )
    }

    func testStoredSelectionMigratesLegacyAliases() {
        XCTAssertEqual(SettingsTab.resolved(storedValue: "Apps"), .destinations)
        XCTAssertEqual(SettingsTab.resolved(storedValue: "Open With"), .destinations)
        XCTAssertEqual(SettingsTab.resolved(storedValue: "Open in Apps"), .destinations)
        XCTAssertEqual(SettingsTab.resolved(storedValue: "AI Handoffs"), .destinations)
        XCTAssertEqual(SettingsTab.resolved(storedValue: "Assistant"), .assistant)
        XCTAssertEqual(SettingsTab.resolved(storedValue: "Automations"), .general)
    }

    func testStoredSelectionPreservesCurrentDeepLinkValues() {
        for tab in SettingsTab.visibleCases {
            XCTAssertEqual(SettingsTab.resolved(storedValue: tab.rawValue), tab)
        }
    }

    func testStoredSelectionDefaultsUnknownAndEmptyValuesToGeneral() {
        XCTAssertEqual(SettingsTab.resolved(storedValue: ""), .general)
        XCTAssertEqual(SettingsTab.resolved(storedValue: "Unexpected"), .general)
    }

    func testMacAppStoreDistributionHidesTheLicenseTab() {
        XCTAssertEqual(
            SettingsTab.visibleCases(isMacAppStoreDistribution: false),
            SettingsTab.visibleCases
        )
        XCTAssertEqual(
            SettingsTab.visibleCases(isMacAppStoreDistribution: true),
            [.general, .destinations, .assistant, .crm, .sync, .privacy]
        )
        XCTAssertFalse(
            SettingsTab.visibleCases(isMacAppStoreDistribution: true).contains(.license)
        )
    }

    func testMacAppStoreDistributionClampsAStoredLicenseSelectionToGeneral() {
        XCTAssertEqual(
            SettingsTab.resolved(storedValue: "License", isMacAppStoreDistribution: false),
            .license
        )
        XCTAssertEqual(
            SettingsTab.resolved(storedValue: "License", isMacAppStoreDistribution: true),
            .general
        )
        // Non-license selections are unaffected by the distribution channel.
        XCTAssertEqual(
            SettingsTab.resolved(storedValue: "CRM", isMacAppStoreDistribution: true),
            .crm
        )
    }

    func testClipLimitParserAcceptsOnlyCompleteInRangeIntegers() {
        XCTAssertEqual(MenuBarClipLimitDraft.validValue(in: "1", range: 1...1_000), 1)
        XCTAssertEqual(MenuBarClipLimitDraft.validValue(in: " 742 ", range: 1...1_000), 742)
        XCTAssertEqual(MenuBarClipLimitDraft.validValue(in: "1000", range: 1...1_000), 1_000)

        XCTAssertNil(MenuBarClipLimitDraft.validValue(in: "", range: 1...1_000))
        XCTAssertNil(MenuBarClipLimitDraft.validValue(in: "0", range: 1...1_000))
        XCTAssertNil(MenuBarClipLimitDraft.validValue(in: "1001", range: 1...1_000))
        XCTAssertNil(MenuBarClipLimitDraft.validValue(in: "12 clips", range: 1...1_000))
    }

    func testClipLimitCommitPreservesLastValidValueForInvalidDrafts() {
        XCTAssertEqual(
            MenuBarClipLimitDraft.committedValue(in: "", currentValue: 742, range: 1...1_000),
            742
        )
        XCTAssertEqual(
            MenuBarClipLimitDraft.committedValue(in: "not a number", currentValue: 742, range: 1...1_000),
            742
        )
    }

    func testClipLimitCommitClampsCompleteNumericDrafts() {
        XCTAssertEqual(
            MenuBarClipLimitDraft.committedValue(in: "0", currentValue: 742, range: 1...1_000),
            1
        )
        XCTAssertEqual(
            MenuBarClipLimitDraft.committedValue(in: "1001", currentValue: 742, range: 1...1_000),
            1_000
        )
    }
}
