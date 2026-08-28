import ClipboardRouterCore
import Foundation

/// Metadata returned after a clip is quarantined. It deliberately omits the clip content.
public struct QuarantineReceipt: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let detectedAt: Date
    public let expiresAt: Date
    public let detections: [SecretDetection]

    public init(
        id: UUID,
        detectedAt: Date,
        expiresAt: Date,
        detections: [SecretDetection]
    ) {
        self.id = id
        self.detectedAt = detectedAt
        self.expiresAt = expiresAt
        self.detections = detections
    }
}

/// Content is exposed only through an explicit review operation.
public struct QuarantineReview: Equatable, Identifiable, Sendable {
    public let receipt: QuarantineReceipt
    public let content: ClipContent

    public var id: UUID { receipt.id }

    public init(receipt: QuarantineReceipt, content: ClipContent) {
        self.receipt = receipt
        self.content = content
    }
}

public enum QuarantineDecision: Equatable, Sendable {
    case allowed
    case quarantined(QuarantineReceipt)
}

/// One actor-consistent maintenance result for timer-driven UI integration.
public struct QuarantineExpirationSnapshot: Equatable, Sendable {
    public let purgedCount: Int
    public let pending: [QuarantineReceipt]
    public let health: ClipboardHealthSummary
    public let nextExpirationDate: Date?

    public init(
        purgedCount: Int,
        pending: [QuarantineReceipt],
        health: ClipboardHealthSummary,
        nextExpirationDate: Date?
    ) {
        self.purgedCount = purgedCount
        self.pending = pending
        self.health = health
        self.nextExpirationDate = nextExpirationDate
    }
}

/// Actor-isolated, process-memory-only quarantine. No store, logger, or transport is accepted.
public actor QuarantineStore {
    public static let timeToLive: TimeInterval = 24 * 60 * 60

    private struct Entry: Sendable {
        let receipt: QuarantineReceipt
        let content: ClipContent
    }

    private let detector: SecretDetector
    private let timeToLive: TimeInterval
    private var entries: [UUID: Entry] = [:]

    public init(
        detector: SecretDetector = SecretDetector(),
        timeToLive: TimeInterval = QuarantineStore.timeToLive
    ) {
        precondition(timeToLive > 0, "Quarantine time to live must be positive.")
        self.detector = detector
        self.timeToLive = timeToLive
    }

    /// The intended capture-path gate: clear content is allowed; sensitive content is retained
    /// only in process memory until the user explicitly keeps, deletes, or lets it expire.
    @discardableResult
    public func submit(_ content: ClipContent, at now: Date = Date()) -> QuarantineDecision {
        _ = purgeExpiredEntries(at: now)
        let scan = detector.scan(content)
        guard scan.containsSecret else { return .allowed }

        let receipt = QuarantineReceipt(
            id: UUID(),
            detectedAt: now,
            expiresAt: now.addingTimeInterval(timeToLive),
            detections: scan.detections
        )
        entries[receipt.id] = Entry(receipt: receipt, content: content)
        return .quarantined(receipt)
    }

    /// Reviewing does not extend the TTL or move the content into ordinary storage.
    public func review(id: UUID, at now: Date = Date()) -> QuarantineReview? {
        _ = purgeExpiredEntries(at: now)
        guard let entry = entries[id] else { return nil }
        return QuarantineReview(receipt: entry.receipt, content: entry.content)
    }

    /// Removes and returns the clip so the caller can deliberately persist it as ordinary data.
    public func keep(id: UUID, at now: Date = Date()) -> ClipContent? {
        _ = purgeExpiredEntries(at: now)
        return entries.removeValue(forKey: id)?.content
    }

    /// Removes content from process memory. No tombstone retaining the value is created.
    @discardableResult
    public func delete(id: UUID, at now: Date = Date()) -> Bool {
        _ = purgeExpiredEntries(at: now)
        return entries.removeValue(forKey: id) != nil
    }

    /// Returns metadata only, sorted for stable UI rendering and deterministic tests.
    public func pending(at now: Date = Date()) -> [QuarantineReceipt] {
        _ = purgeExpiredEntries(at: now)
        return entries.values.map(\.receipt).sorted { lhs, rhs in
            if lhs.detectedAt != rhs.detectedAt { return lhs.detectedAt < rhs.detectedAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    @discardableResult
    public func purgeExpired(at now: Date = Date()) -> Int {
        purgeExpiredEntries(at: now)
    }

    public func health(at now: Date = Date()) -> ClipboardHealthSummary {
        _ = purgeExpiredEntries(at: now)
        return ClipboardHealth.summarize(entries.values.map(\.receipt))
    }

    /// Purges and returns all metadata required to schedule the next expiry without retaining
    /// content or racing separate `pending` and `health` actor calls.
    public func expirationSnapshot(at now: Date = Date()) -> QuarantineExpirationSnapshot {
        let purgedCount = purgeExpiredEntries(at: now)
        let receipts = entries.values.map(\.receipt).sorted { lhs, rhs in
            if lhs.detectedAt != rhs.detectedAt { return lhs.detectedAt < rhs.detectedAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return QuarantineExpirationSnapshot(
            purgedCount: purgedCount,
            pending: receipts,
            health: ClipboardHealth.summarize(receipts),
            nextExpirationDate: receipts.map(\.expiresAt).min()
        )
    }

    private func purgeExpiredEntries(at now: Date) -> Int {
        let expiredIDs = entries.compactMap { id, entry in
            entry.receipt.expiresAt <= now ? id : nil
        }
        for id in expiredIDs {
            entries.removeValue(forKey: id)
        }
        return expiredIDs.count
    }
}
