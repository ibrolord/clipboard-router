import ClipboardRouterCore
import Foundation
import SwiftUI

enum ClipAgeFormatter {
    static func string(
        since date: Date,
        relativeTo now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let elapsedSeconds = max(0, Int(now.timeIntervalSince(date)))
        guard elapsedSeconds >= 60 else { return "Just now" }

        let elapsedMinutes = elapsedSeconds / 60
        guard elapsedMinutes >= 60 else { return "\(elapsedMinutes) min" }

        let elapsedHours = elapsedMinutes / 60
        if elapsedHours < 24 {
            let remainingMinutes = elapsedMinutes % 60
            return remainingMinutes == 0
                ? "\(elapsedHours) hr"
                : "\(elapsedHours) hr, \(remainingMinutes) min"
        }

        let start = calendar.startOfDay(for: date)
        let end = calendar.startOfDay(for: now)
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: end),
           start == yesterday
        {
            return "Yesterday"
        }
        let elapsedDays = max(1, calendar.dateComponents([.day], from: start, to: end).day ?? 1)
        guard elapsedDays >= 7 else { return "\(elapsedDays) d" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

struct MinuteRelativeTimestamp: View {
    let date: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Text(ClipAgeFormatter.string(since: date, relativeTo: context.date))
        }
    }
}

struct StoredLinkPreviewDescriptor: Equatable {
    let url: URL
    let title: String
    let host: String
    let displayURL: String

    init?(content: ClipContent) {
        let metadata = content.representations.url
        let candidate = metadata?.originalURL ?? (content.type == .url ? content.text : nil)
        guard let candidate else { return nil }

        let rawURL = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: rawURL),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let parsedHost = url.host(percentEncoded: false),
              !parsedHost.isEmpty
        else { return nil }

        let storedTitle = metadata?.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.url = url
        self.title = storedTitle.flatMap { $0.isEmpty ? nil : $0 } ?? parsedHost
        self.host = parsedHost
        self.displayURL = url.absoluteString
    }
}
