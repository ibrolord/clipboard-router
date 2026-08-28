import Foundation
import XCTest
@testable import ClipboardRouterCore

final class ProductMetricsTests: XCTestCase {
    func testLedgerHasClosedContentBlindSchemaAndNeverSerializesCanary() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProductMetrics-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = LocalProductMetricsLedger(fileURL: directory.appendingPathComponent("events.json"))
        let canary = "PROSPECT_SECRET_CANARY_DO_NOT_RECORD"
        let event = ProductMetricEvent(
            anonymousInstallationID: UUID(),
            occurredAt: Date(timeIntervalSince1970: 100),
            name: .recoveredAndReused,
            surface: .library,
            action: .copy,
            ageBucket: .older,
            resultCountBucket: .sixToTwenty,
            itemKind: .clip,
            contentType: .url
        )
        try await ledger.record(event)

        let data = try await ledger.exportData()
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains(canary))
        XCTAssertFalse(text.contains("query"))
        XCTAssertFalse(text.contains("folder"))
        XCTAssertFalse(text.contains("tag"))
        let loaded = try await ledger.load()
        XCTAssertEqual(loaded, [event])
    }

    func testMetricBucketsAreCoarseAndCountsAreCapped() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(ProductMetricAgeBucket.classify(now, relativeTo: now), .sameDay)
        XCTAssertEqual(
            ProductMetricAgeBucket.classify(now.addingTimeInterval(-3 * 86_400), relativeTo: now),
            .oneToSevenDays
        )
        XCTAssertEqual(
            ProductMetricAgeBucket.classify(now.addingTimeInterval(-9 * 86_400), relativeTo: now),
            .older
        )
        XCTAssertEqual(ProductMetricCountBucket.classify(21), .moreThanTwenty)
        let event = ProductMetricEvent(
            anonymousInstallationID: UUID(),
            name: .researchHandoffExported,
            eligibleItemCount: 1_000_000,
            omittedItemCount: -1
        )
        XCTAssertEqual(event.eligibleItemCount, 100_000)
        XCTAssertEqual(event.omittedItemCount, 0)
    }
}
