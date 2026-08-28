import AppKit
import ClipboardRouterCore
import Foundation

public enum ClipboardRouterPasteboardType {
    public static let appOrigin = "com.clipboardrouter.clip-origin"
    public static let jpeg = "public.jpeg"
    public static let heic = "public.heic"
}

public struct PasteboardSnapshot: Equatable, Sendable {
    public let changeCount: Int
    public let text: String?
    public let typeIdentifiers: Set<String>

    public init(changeCount: Int, text: String?, typeIdentifiers: Set<String>) {
        self.changeCount = changeCount
        self.text = text
        self.typeIdentifiers = typeIdentifiers
    }
}

@MainActor
public protocol PasteboardSnapshotReading: AnyObject {
    /// Reads only generation and declared types. It must not request clipboard payload data.
    func metadataSnapshot() -> PasteboardSnapshot
    /// Reads the current string only after policy and type checks accept the change.
    func stringValue(ifChangeCountIs expectedChangeCount: Int) -> String?
}

@MainActor
public protocol PasteboardDraftReading: PasteboardSnapshotReading {
    /// Reads all supported representations from one generation. The implementation must check the
    /// generation before and after every payload access and return no partial draft after a change.
    func captureDraft(
        ifChangeCountIs expectedChangeCount: Int,
        declaredTypeIdentifiers: Set<String>,
        limits: PasteboardCaptureLimits
    ) -> PasteboardDraftReadOutcome
}

@MainActor
public final class SystemPasteboardReader: PasteboardDraftReading {
    private let pasteboard: NSPasteboard

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    public func metadataSnapshot() -> PasteboardSnapshot {
        PasteboardSnapshot(
            changeCount: pasteboard.changeCount,
            text: nil,
            typeIdentifiers: Set(pasteboard.types?.map(\.rawValue) ?? [])
        )
    }

    public func stringValue(ifChangeCountIs expectedChangeCount: Int) -> String? {
        guard pasteboard.changeCount == expectedChangeCount else { return nil }
        let value = pasteboard.string(forType: .string)
        guard pasteboard.changeCount == expectedChangeCount else { return nil }
        return value
    }

    public func captureDraft(
        ifChangeCountIs expectedChangeCount: Int,
        declaredTypeIdentifiers: Set<String>,
        limits: PasteboardCaptureLimits
    ) -> PasteboardDraftReadOutcome {
        guard pasteboard.changeCount == expectedChangeCount else { return .generationChanged }

        var totalBytes = 0
        func checkedSize(
            _ byteCount: Int,
            maximum: Int,
            kind: PasteboardCaptureLimitKind
        ) -> PasteboardCaptureLimitKind? {
            guard byteCount <= maximum else { return kind }
            guard totalBytes <= limits.maximumTotalBytes - byteCount else { return .total }
            totalBytes += byteCount
            return nil
        }
        func readString(_ type: NSPasteboard.PasteboardType) -> (String?, Bool) {
            guard pasteboard.changeCount == expectedChangeCount else { return (nil, false) }
            let value = pasteboard.string(forType: type)
            return (value, pasteboard.changeCount == expectedChangeCount)
        }
        func readData(_ type: NSPasteboard.PasteboardType) -> (Data?, Bool) {
            guard pasteboard.changeCount == expectedChangeCount else { return (nil, false) }
            let value = pasteboard.data(forType: type)
            return (value, pasteboard.changeCount == expectedChangeCount)
        }

        var plainText: String?
        if declaredTypeIdentifiers.contains(NSPasteboard.PasteboardType.string.rawValue) {
            let read = readString(.string)
            guard read.1 else { return .generationChanged }
            if let value = read.0, !value.isEmpty {
                if let exceeded = checkedSize(
                    value.utf8.count,
                    maximum: limits.maximumPlainTextBytes,
                    kind: .plainText
                ) {
                    return .limitExceeded(exceeded)
                }
                plainText = value
            }
        }

        var explicitURL: URL?
        var fileURLFromURLRepresentation: URL?
        if declaredTypeIdentifiers.contains(NSPasteboard.PasteboardType.URL.rawValue) {
            let read = readString(.URL)
            guard read.1 else { return .generationChanged }
            if let value = read.0, !value.isEmpty {
                if let exceeded = checkedSize(
                    value.utf8.count,
                    maximum: limits.maximumURLBytes,
                    kind: .url
                ) {
                    return .limitExceeded(exceeded)
                }
                guard let parsed = URL(string: value) else { return .invalidPayload }
                if parsed.isFileURL {
                    fileURLFromURLRepresentation = parsed.standardizedFileURL
                } else {
                    explicitURL = parsed
                }
            }
        }

        var richTextData: Data?
        if declaredTypeIdentifiers.contains(NSPasteboard.PasteboardType.rtf.rawValue) {
            let read = readData(.rtf)
            guard read.1 else { return .generationChanged }
            if let value = read.0, !value.isEmpty {
                if let exceeded = checkedSize(
                    value.count,
                    maximum: limits.maximumRichTextBytes,
                    kind: .richText
                ) {
                    return .limitExceeded(exceeded)
                }
                richTextData = value
            }
        }

        var htmlData: Data?
        if declaredTypeIdentifiers.contains(NSPasteboard.PasteboardType.html.rawValue) {
            let read = readData(.html)
            guard read.1 else { return .generationChanged }
            if let value = read.0, !value.isEmpty {
                if let exceeded = checkedSize(
                    value.count,
                    maximum: limits.maximumHTMLBytes,
                    kind: .html
                ) {
                    return .limitExceeded(exceeded)
                }
                htmlData = value
            }
        }

        let imageTypes: [NSPasteboard.PasteboardType] = [
            .png,
            NSPasteboard.PasteboardType(ClipboardRouterPasteboardType.jpeg),
            NSPasteboard.PasteboardType(ClipboardRouterPasteboardType.heic),
            .tiff,
        ]
        var image: PasteboardImageDraft?
        if let imageType = imageTypes.first(where: {
            declaredTypeIdentifiers.contains($0.rawValue)
        }) {
            let read = readData(imageType)
            guard read.1 else { return .generationChanged }
            if let value = read.0, !value.isEmpty {
                if let exceeded = checkedSize(
                    value.count,
                    maximum: limits.maximumImageBytes,
                    kind: .image
                ) {
                    return .limitExceeded(exceeded)
                }
                image = PasteboardImageDraft(
                    data: value,
                    uniformTypeIdentifier: imageType.rawValue
                )
            }
        }

        var fileURLs: [URL] = []
        if declaredTypeIdentifiers.contains(NSPasteboard.PasteboardType.fileURL.rawValue) {
            guard pasteboard.changeCount == expectedChangeCount else { return .generationChanged }
            let items = pasteboard.pasteboardItems ?? []
            guard pasteboard.changeCount == expectedChangeCount else { return .generationChanged }
            let fileItems = items.filter { $0.types.contains(.fileURL) }
            guard fileItems.count <= limits.maximumFileURLCount else {
                return .limitExceeded(.fileURLCount)
            }
            for item in fileItems {
                guard pasteboard.changeCount == expectedChangeCount else {
                    return .generationChanged
                }
                guard let value = item.string(forType: .fileURL),
                      pasteboard.changeCount == expectedChangeCount
                else { continue }
                if let exceeded = checkedSize(
                    value.utf8.count,
                    maximum: limits.maximumFileURLBytes,
                    kind: .fileURL
                ) {
                    return .limitExceeded(exceeded)
                }
                guard let url = URL(string: value), url.isFileURL else {
                    return .invalidPayload
                }
                fileURLs.append(url.standardizedFileURL)
            }
        }

        if let fileURLFromURLRepresentation,
           !fileURLs.contains(fileURLFromURLRepresentation)
        {
            guard fileURLs.count < limits.maximumFileURLCount else {
                return .limitExceeded(.fileURLCount)
            }
            fileURLs.append(fileURLFromURLRepresentation)
        }

        if explicitURL == nil,
           let plainText,
           let candidate = URL(string: plainText.trimmingCharacters(in: .whitespacesAndNewlines)),
           let scheme = candidate.scheme?.lowercased(),
           ["http", "https"].contains(scheme),
           candidate.host?.isEmpty == false
        {
            explicitURL = candidate
        }

        guard pasteboard.changeCount == expectedChangeCount else { return .generationChanged }
        let draft = PasteboardCaptureDraft(
            changeCount: expectedChangeCount,
            typeIdentifiers: declaredTypeIdentifiers,
            plainText: plainText,
            url: explicitURL,
            richTextData: richTextData,
            htmlData: htmlData,
            image: image,
            fileURLs: fileURLs
        )
        return draft.isEmpty ? .noSupportedContent : .captured(draft)
    }
}

@MainActor
public protocol FrontmostApplicationProviding: AnyObject {
    var frontmostBundleIdentifier: String? { get }
    var frontmostApplicationName: String? { get }
}

public extension FrontmostApplicationProviding {
    var frontmostApplicationName: String? { nil }
}

@MainActor
public final class WorkspaceFrontmostApplicationProvider: FrontmostApplicationProviding {
    private let workspace: NSWorkspace

    public init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
    }

    public var frontmostBundleIdentifier: String? {
        workspace.frontmostApplication?.bundleIdentifier
    }

    public var frontmostApplicationName: String? {
        workspace.frontmostApplication?.localizedName
    }
}

public struct ClipboardMonitorConfiguration: Equatable, Sendable {
    public var isCaptureEnabled: Bool
    public var excludedApplicationBundleIdentifiers: Set<String>

    public init(
        isCaptureEnabled: Bool = true,
        excludedApplicationBundleIdentifiers: Set<String> = []
    ) {
        self.isCaptureEnabled = isCaptureEnabled
        self.excludedApplicationBundleIdentifiers = Set(
            excludedApplicationBundleIdentifiers.map(Self.normalizeBundleIdentifier)
        )
    }

    public func excludes(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        let candidate = Self.normalizeBundleIdentifier(bundleIdentifier)
        return excludedApplicationBundleIdentifiers.contains { excluded in
            Self.normalizeBundleIdentifier(excluded) == candidate
        }
    }

    private static func normalizeBundleIdentifier(_ identifier: String) -> String {
        identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

@MainActor
public protocol RepeatingScheduling: AnyObject {
    func schedule(every interval: TimeInterval, _ action: @escaping @MainActor () -> Void)
    func cancel()
}

@MainActor
public final class RunLoopRepeatingScheduler: RepeatingScheduling {
    private var timer: Timer?

    public init() {}

    public func schedule(
        every interval: TimeInterval,
        _ action: @escaping @MainActor () -> Void
    ) {
        cancel()
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated {
                action()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func cancel() {
        timer?.invalidate()
        timer = nil
    }
}

/// Polls the macOS pasteboard without treating content that predates launch as a new capture.
///
/// The monitor performs privacy rejection before reading content into the library. Core applies
/// the same policy again at persistence time, so a configuration race cannot leak an excluded clip.
@MainActor
public final class ClipboardMonitor {
    public static let defaultPollInterval: TimeInterval = 0.35

    private let pasteboard: any PasteboardSnapshotReading
    private let applications: any FrontmostApplicationProviding
    private let scheduler: any RepeatingScheduling
    private let configuration: @MainActor () -> ClipboardMonitorConfiguration
    private let sourceContextProvider: any PasteboardSourceContextProviding
    private let captureLimits: PasteboardCaptureLimits
    private let onCapture: (@MainActor (CaptureCandidate) -> Void)?
    private let onDraft: (@MainActor (PasteboardCaptureDraft) -> Void)?
    private var lastObservedChangeCount: Int?
    private var activeExcludedApplication: ExcludedApplicationInterval?

    private struct ExcludedApplicationInterval {
        let normalizedBundleIdentifier: String
        let activationChangeCount: Int
    }

    public private(set) var isRunning = false

    public init(
        pasteboard: any PasteboardSnapshotReading,
        applications: any FrontmostApplicationProviding,
        scheduler: any RepeatingScheduling = RunLoopRepeatingScheduler(),
        configuration: @escaping @MainActor () -> ClipboardMonitorConfiguration,
        onCapture: @escaping @MainActor (CaptureCandidate) -> Void
    ) {
        self.pasteboard = pasteboard
        self.applications = applications
        self.scheduler = scheduler
        self.configuration = configuration
        self.sourceContextProvider = DefaultPasteboardSourceContextProvider()
        self.captureLimits = .default
        self.onCapture = onCapture
        self.onDraft = nil
    }

    /// Typed capture entry point. Draft payload bytes remain in memory; this initializer never
    /// writes to `ClipAssetStoring` or any other persistence layer.
    public init(
        pasteboard: any PasteboardDraftReading,
        applications: any FrontmostApplicationProviding,
        scheduler: any RepeatingScheduling = RunLoopRepeatingScheduler(),
        configuration: @escaping @MainActor () -> ClipboardMonitorConfiguration,
        sourceContextProvider: any PasteboardSourceContextProviding =
            DefaultPasteboardSourceContextProvider(),
        captureLimits: PasteboardCaptureLimits = .default,
        onDraft: @escaping @MainActor (PasteboardCaptureDraft) -> Void
    ) {
        self.pasteboard = pasteboard
        self.applications = applications
        self.scheduler = scheduler
        self.configuration = configuration
        self.sourceContextProvider = sourceContextProvider
        self.captureLimits = captureLimits
        self.onCapture = nil
        self.onDraft = onDraft
    }

    public func start(pollInterval: TimeInterval = defaultPollInterval) {
        guard !isRunning else { return }
        precondition(pollInterval > 0, "The clipboard polling interval must be positive.")

        // Establishing the baseline is deliberate: the clipboard value present before launch is
        // not captured just because Clipboard Router started.
        let baseline = pasteboard.metadataSnapshot().changeCount
        lastObservedChangeCount = baseline
        if let bundleIdentifier = applications.frontmostBundleIdentifier,
           configuration().excludes(bundleIdentifier: bundleIdentifier)
        {
            activeExcludedApplication = ExcludedApplicationInterval(
                normalizedBundleIdentifier: Self.normalize(bundleIdentifier),
                activationChangeCount: baseline
            )
        }
        isRunning = true
        scheduler.schedule(every: pollInterval) { [weak self] in
            self?.pollNow()
        }
    }

    public func stop() {
        guard isRunning else { return }
        scheduler.cancel()
        isRunning = false
        lastObservedChangeCount = nil
        activeExcludedApplication = nil
    }

    /// Records the generation at the beginning of an excluded application's active interval.
    /// A pre-existing, unseen generation may belong to the application that just lost focus, so it
    /// must not be consumed merely because an excluded application became frontmost.
    public func applicationDidActivate(bundleIdentifier: String?) {
        guard isRunning else { return }
        guard let bundleIdentifier,
              configuration().excludes(bundleIdentifier: bundleIdentifier)
        else {
            activeExcludedApplication = nil
            return
        }
        activeExcludedApplication = ExcludedApplicationInterval(
            normalizedBundleIdentifier: Self.normalize(bundleIdentifier),
            activationChangeCount: pasteboard.metadataSnapshot().changeCount
        )
    }

    /// Application attribution is sampled, not supplied by NSPasteboard. Consume the current
    /// generation only if it advanced while this excluded application was active. This prevents
    /// both privacy leakage after a fast switch and loss of an allowed copy made just beforehand.
    public func applicationDidDeactivate(bundleIdentifier: String?) {
        guard isRunning,
              let bundleIdentifier,
              configuration().excludes(bundleIdentifier: bundleIdentifier),
              let interval = activeExcludedApplication,
              interval.normalizedBundleIdentifier == Self.normalize(bundleIdentifier)
        else { return }
        activeExcludedApplication = nil
        let currentChangeCount = pasteboard.metadataSnapshot().changeCount
        if currentChangeCount != interval.activationChangeCount {
            lastObservedChangeCount = currentChangeCount
        }
    }

    /// Exposed to make every state transition deterministic in tests.
    public func pollNow() {
        guard isRunning else { return }
        let sample = pasteboard.metadataSnapshot()

        guard sample.changeCount != lastObservedChangeCount else { return }

        let currentConfiguration = configuration()
        guard currentConfiguration.isCaptureEnabled else {
            lastObservedChangeCount = sample.changeCount
            return
        }

        let sourceBundleIdentifier = applications.frontmostBundleIdentifier
        guard !currentConfiguration.excludes(bundleIdentifier: sourceBundleIdentifier) else {
            if let sourceBundleIdentifier,
               let interval = activeExcludedApplication,
               interval.normalizedBundleIdentifier == Self.normalize(sourceBundleIdentifier),
               sample.changeCount == interval.activationChangeCount
            {
                // This generation predates the excluded interval and may be an allowed copy.
                return
            }
            lastObservedChangeCount = sample.changeCount
            return
        }
        let sourceApplicationName = applications.frontmostApplicationName

        // Advance before type or payload rejection so rejected content is never captured later
        // when settings or declared types change without a corresponding pasteboard change.
        lastObservedChangeCount = sample.changeCount

        let ignoredTypes = PasteboardSemanticType.privacySensitiveTypes
            .union([ClipboardRouterPasteboardType.appOrigin])
        guard sample.typeIdentifiers.isDisjoint(with: ignoredTypes) else { return }

        if let draftReader = pasteboard as? any PasteboardDraftReading {
            guard case let .captured(rawDraft) = draftReader.captureDraft(
                ifChangeCountIs: sample.changeCount,
                declaredTypeIdentifiers: sample.typeIdentifiers,
                limits: captureLimits
            ) else { return }
            let source = sourceContextProvider.sourceContext(
                applicationBundleIdentifier: sourceBundleIdentifier,
                applicationName: sourceApplicationName,
                explicitPayloadURL: rawDraft.url
            )
            let draft = rawDraft.replacingSource(source)
            onDraft?(draft)
            if let candidate = draft.legacyCaptureCandidate() {
                onCapture?(candidate)
            }
            return
        }

        guard let text = pasteboard.stringValue(ifChangeCountIs: sample.changeCount),
              !text.isEmpty,
              let content = try? ClipContent.detect(text: text)
        else { return }

        onCapture?(
            CaptureCandidate(
                content: content,
                sourceApplicationBundleIdentifier: sourceBundleIdentifier,
                pasteboardTypeIdentifiers: sample.typeIdentifiers
            )
        )
    }

    private static func normalize(_ bundleIdentifier: String) -> String {
        bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
