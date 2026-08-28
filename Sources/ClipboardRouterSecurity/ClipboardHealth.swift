import Foundation

/// Aggregate-only clipboard safety information. It never contains clip text or matched values.
public struct ClipboardHealthSummary: Codable, Equatable, Sendable {
    public let quarantinedClipCount: Int
    public let categoryCounts: [SecretCategory: Int]

    public init(quarantinedClipCount: Int, categoryCounts: [SecretCategory: Int]) {
        self.quarantinedClipCount = quarantinedClipCount
        self.categoryCounts = categoryCounts
    }

    public func count(for category: SecretCategory) -> Int {
        categoryCounts[category, default: 0]
    }

    public static let empty = ClipboardHealthSummary(
        quarantinedClipCount: 0,
        categoryCounts: [:]
    )
}

public enum ClipboardHealth {
    /// Each category is counted at most once per quarantined clip.
    public static func summarize(_ receipts: [QuarantineReceipt]) -> ClipboardHealthSummary {
        var counts: [SecretCategory: Int] = [:]
        for receipt in receipts {
            for category in Set(receipt.detections.map(\.category)) {
                counts[category, default: 0] += 1
            }
        }
        return ClipboardHealthSummary(
            quarantinedClipCount: receipts.count,
            categoryCounts: counts
        )
    }
}
