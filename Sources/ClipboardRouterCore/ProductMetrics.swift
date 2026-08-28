import Foundation

public enum ProductMetricName: String, Codable, Sendable {
    case recoveredAndReused
    case salesWorkspaceCreated
    case researchHandoffExported
}

public enum ProductMetricSurface: String, Codable, Sendable {
    case menuBar
    case library
}

public enum ProductMetricAction: String, Codable, Sendable {
    case copy
    case save
    case move
    case export
}

public enum ProductMetricAgeBucket: String, Codable, Sendable {
    case sameDay
    case oneToSevenDays
    case older

    public static func classify(_ date: Date, relativeTo now: Date = Date()) -> Self {
        let days = max(0, Calendar(identifier: .gregorian).dateComponents(
            [.day], from: date, to: now
        ).day ?? 0)
        if days == 0 { return .sameDay }
        if days <= 7 { return .oneToSevenDays }
        return .older
    }
}

public enum ProductMetricCountBucket: String, Codable, Sendable {
    case zero
    case oneToFive
    case sixToTwenty
    case moreThanTwenty

    public static func classify(_ count: Int) -> Self {
        switch max(0, count) {
        case 0: .zero
        case 1 ... 5: .oneToFive
        case 6 ... 20: .sixToTwenty
        default: .moreThanTwenty
        }
    }
}

/// A deliberately closed event schema. It has no arbitrary string property bag, which prevents
/// callers from recording clipboard bodies, search queries, URLs, folder names, or tags.
public struct ProductMetricEvent: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let anonymousInstallationID: UUID
    public let occurredAt: Date
    public let name: ProductMetricName
    public let surface: ProductMetricSurface?
    public let action: ProductMetricAction?
    public let ageBucket: ProductMetricAgeBucket?
    public let resultCountBucket: ProductMetricCountBucket?
    public let itemKind: SavedItemKind?
    public let contentType: SupportedContentType?
    public let eligibleItemCount: Int?
    public let omittedItemCount: Int?

    public init(
        version: Int = Self.currentVersion,
        anonymousInstallationID: UUID,
        occurredAt: Date = Date(),
        name: ProductMetricName,
        surface: ProductMetricSurface? = nil,
        action: ProductMetricAction? = nil,
        ageBucket: ProductMetricAgeBucket? = nil,
        resultCountBucket: ProductMetricCountBucket? = nil,
        itemKind: SavedItemKind? = nil,
        contentType: SupportedContentType? = nil,
        eligibleItemCount: Int? = nil,
        omittedItemCount: Int? = nil
    ) {
        self.version = version
        self.anonymousInstallationID = anonymousInstallationID
        self.occurredAt = occurredAt
        self.name = name
        self.surface = surface
        self.action = action
        self.ageBucket = ageBucket
        self.resultCountBucket = resultCountBucket
        self.itemKind = itemKind
        self.contentType = contentType
        self.eligibleItemCount = eligibleItemCount.map { min(max(0, $0), 100_000) }
        self.omittedItemCount = omittedItemCount.map { min(max(0, $0), 100_000) }
    }
}

public actor LocalProductMetricsLedger {
    public let fileURL: URL
    private let maximumEventCount: Int
    private var cachedEvents: [ProductMetricEvent]?

    public init(fileURL: URL, maximumEventCount: Int = 10_000) {
        self.fileURL = fileURL
        self.maximumEventCount = max(1, maximumEventCount)
    }

    public func record(_ event: ProductMetricEvent) throws {
        var events = try load()
        events.append(event)
        if events.count > maximumEventCount {
            events.removeFirst(events.count - maximumEventCount)
        }
        try persist(events)
        cachedEvents = events
    }

    public func load() throws -> [ProductMetricEvent] {
        if let cachedEvents { return cachedEvents }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            cachedEvents = []
            return []
        }
        let events = try JSONDecoder().decode(
            [ProductMetricEvent].self,
            from: Data(contentsOf: fileURL)
        )
        cachedEvents = events
        return events
    }

    public func exportData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(load())
    }

    private func persist(_ events: [ProductMetricEvent]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(events)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }
}
