import AppKit
import ClipboardRouterCore
import Foundation

public struct SecurePasteReceipt: Equatable, Sendable {
    public let generation: Int
    public let marker: String

    public init(generation: Int, marker: String) {
        self.generation = generation
        self.marker = marker
    }
}

public enum SecurePastePolicy {
    public static func shouldClear(
        receipt: SecurePasteReceipt,
        currentGeneration: Int,
        currentMarker: String?
    ) -> Bool {
        receipt.generation == currentGeneration && receipt.marker == currentMarker
    }
}

public protocol SecurePasteboard: Sendable {
    /// Replaces the pasteboard with the text and an application-private marker.
    /// Returns the generation after the write completes.
    func writeSecureString(_ value: String, marker: String) async throws -> Int
    /// Writes an explicitly decrypted, representation-preserving Vault payload host-locally.
    func writeSecurePayload(_ payload: VaultRestoredPayload, marker: String) async throws -> Int
    /// Checks generation and marker and clears without an actor hop between those operations.
    func clearIfOwned(_ receipt: SecurePasteReceipt) async -> Bool
}

@MainActor
public final class SystemSecurePasteboard: SecurePasteboard {
    public static let markerType = NSPasteboard.PasteboardType(
        "com.clipboardrouter.secure-paste-receipt"
    )
    /// Must remain byte-for-byte identical to ClipboardRouterPlatform's app-origin type.
    /// The platform monitor rejects this type before decrypted Vault text reaches history.
    public static let appOriginType = NSPasteboard.PasteboardType(
        "com.clipboardrouter.clip-origin"
    )
    public static let writingOptions: NSPasteboard.ContentsOptions = [.currentHostOnly]

    private let pasteboard: NSPasteboard

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    public func writeSecureString(_ value: String, marker: String) async throws -> Int {
        // Prevent decrypted Vault content from entering Universal Clipboard. This call also
        // replaces the current contents; using clearContents() would lose the host-only option.
        pasteboard.prepareForNewContents(with: Self.writingOptions)
        let item = NSPasteboardItem()
        item.setString(value, forType: .string)
        item.setString(marker, forType: Self.markerType)
        item.setString("1", forType: Self.appOriginType)
        guard pasteboard.writeObjects([item]) else {
            throw SecurePasteError.writeFailed
        }
        return pasteboard.changeCount
    }

    public func writeSecurePayload(
        _ payload: VaultRestoredPayload,
        marker: String
    ) async throws -> Int {
        let items = try makeItems(payload: payload, marker: marker)
        guard !items.isEmpty else { throw SecurePasteError.writeFailed }
        pasteboard.prepareForNewContents(with: Self.writingOptions)
        guard pasteboard.writeObjects(items) else { throw SecurePasteError.writeFailed }
        return pasteboard.changeCount
    }

    public func clearIfOwned(_ receipt: SecurePasteReceipt) async -> Bool {
        guard SecurePastePolicy.shouldClear(
            receipt: receipt,
            currentGeneration: pasteboard.changeCount,
            currentMarker: pasteboard.string(forType: Self.markerType)
        ) else { return false }
        pasteboard.clearContents()
        return true
    }

    private func makeItems(
        payload: VaultRestoredPayload,
        marker: String
    ) throws -> [NSPasteboardItem] {
        let content = payload.content
        let sourceTypes = Set(payload.sourceTypeIdentifiers)
        let primary = NSPasteboardItem()
        var hasPrimary = false

        if shouldWritePlainText(content: content, sourceTypes: sourceTypes) {
            guard primary.setString(content.text, forType: .string) else {
                throw SecurePasteError.writeFailed
            }
            hasPrimary = true
        }
        if let url = content.representations.url?.originalURL {
            guard primary.setString(url, forType: .URL) else { throw SecurePasteError.writeFailed }
            hasPrimary = true
        }
        for asset in payload.assets {
            let type: NSPasteboard.PasteboardType
            switch asset.descriptor.kind {
            case .richText: type = .rtf
            case .html: type = .html
            case .image:
                let identifier = asset.descriptor.uniformTypeIdentifier
                guard !identifier.isEmpty, identifier.utf8.count <= 255 else {
                    throw SecurePasteError.writeFailed
                }
                type = NSPasteboard.PasteboardType(identifier)
            case .thumbnail, .pdf:
                // Thumbnails are local derived UI data and PDFs are not a captured primary
                // representation in the current payload model. Neither may leak onto pasteboard.
                continue
            }
            guard primary.setData(asset.data, forType: type) else {
                throw SecurePasteError.writeFailed
            }
            hasPrimary = true
        }

        var items: [NSPasteboardItem] = []
        if hasPrimary {
            try addOwnershipMarkers(to: primary, marker: marker)
            items.append(primary)
        }
        for file in content.representations.files {
            let item = NSPasteboardItem()
            guard item.setString(file.url.absoluteString, forType: .fileURL) else {
                throw SecurePasteError.writeFailed
            }
            try addOwnershipMarkers(to: item, marker: marker)
            items.append(item)
        }
        return items
    }

    private func addOwnershipMarkers(to item: NSPasteboardItem, marker: String) throws {
        guard item.setString(marker, forType: Self.markerType),
              item.setString("1", forType: Self.appOriginType)
        else { throw SecurePasteError.writeFailed }
    }

    private func shouldWritePlainText(
        content: ClipContent,
        sourceTypes: Set<String>
    ) -> Bool {
        if !sourceTypes.isEmpty {
            return sourceTypes.contains(NSPasteboard.PasteboardType.string.rawValue)
        }
        return switch content.type {
        case .plainText, .url, .richText: true
        case .image, .fileURLs: false
        }
    }
}

public enum SecurePasteError: Error, Equatable, Sendable {
    case writeFailed
}

public actor SecurePasteController {
    private let pasteboard: any SecurePasteboard
    private let clearDelayNanoseconds: UInt64
    private var clearTasks: [String: Task<Void, Never>] = [:]

    public init(pasteboard: any SecurePasteboard, clearDelay: TimeInterval = 45) {
        precondition(clearDelay > 0)
        self.pasteboard = pasteboard
        self.clearDelayNanoseconds = UInt64(clearDelay * 1_000_000_000)
    }

    @discardableResult
    public func copy(
        _ value: String,
        clearDelay: TimeInterval? = nil
    ) async throws -> SecurePasteReceipt {
        let marker = UUID().uuidString.lowercased()
        let generation = try await pasteboard.writeSecureString(value, marker: marker)
        let receipt = SecurePasteReceipt(generation: generation, marker: marker)
        let delayNanoseconds: UInt64
        if let clearDelay {
            precondition(clearDelay > 0)
            delayNanoseconds = UInt64(clearDelay * 1_000_000_000)
        } else {
            delayNanoseconds = clearDelayNanoseconds
        }
        scheduleClear(for: receipt, delayNanoseconds: delayNanoseconds)
        return receipt
    }

    @discardableResult
    public func copy(
        _ payload: VaultRestoredPayload,
        clearDelay: TimeInterval? = nil
    ) async throws -> SecurePasteReceipt {
        let marker = UUID().uuidString.lowercased()
        let generation = try await pasteboard.writeSecurePayload(payload, marker: marker)
        let receipt = SecurePasteReceipt(generation: generation, marker: marker)
        let delayNanoseconds = effectiveDelayNanoseconds(clearDelay)
        scheduleClear(for: receipt, delayNanoseconds: delayNanoseconds)
        return receipt
    }

    @discardableResult
    public func clearIfStillOwned(_ receipt: SecurePasteReceipt) async -> Bool {
        let didClear = await pasteboard.clearIfOwned(receipt)
        clearTasks.removeValue(forKey: receipt.marker)?.cancel()
        return didClear
    }

    public func pendingClearCount() -> Int { clearTasks.count }

    public func cancelPendingClears() {
        for task in clearTasks.values { task.cancel() }
        clearTasks.removeAll()
    }

    private func scheduleClear(
        for receipt: SecurePasteReceipt,
        delayNanoseconds: UInt64
    ) {
        let delay = delayNanoseconds
        clearTasks[receipt.marker] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            _ = await self?.clearIfStillOwned(receipt)
        }
    }

    private func effectiveDelayNanoseconds(_ clearDelay: TimeInterval?) -> UInt64 {
        if let clearDelay {
            precondition(clearDelay > 0)
            return UInt64(clearDelay * 1_000_000_000)
        }
        return clearDelayNanoseconds
    }
}

public actor InMemorySecurePasteboard: SecurePasteboard {
    public private(set) var generation: Int
    public private(set) var text: String?
    public private(set) var marker: String?
    public private(set) var payload: VaultRestoredPayload?

    public init(generation: Int = 0) { self.generation = generation }

    public func writeSecureString(_ value: String, marker: String) async throws -> Int {
        generation += 1
        text = value
        payload = nil
        self.marker = marker
        return generation
    }

    public func writeSecurePayload(
        _ payload: VaultRestoredPayload,
        marker: String
    ) async throws -> Int {
        generation += 1
        text = payload.content.text
        self.payload = payload
        self.marker = marker
        return generation
    }

    public func clearIfOwned(_ receipt: SecurePasteReceipt) async -> Bool {
        guard SecurePastePolicy.shouldClear(
            receipt: receipt,
            currentGeneration: generation,
            currentMarker: marker
        ) else { return false }
        generation += 1
        text = nil
        payload = nil
        marker = nil
        return true
    }

    /// Simulates another application or the user replacing the pasteboard.
    public func simulateExternalCopy(_ value: String, preservingMarker: Bool = false) {
        generation += 1
        text = value
        payload = nil
        if !preservingMarker { marker = nil }
    }

    /// Simulates marker tampering without changing the generation (for policy testing).
    public func setMarkerForTesting(_ value: String?) { marker = value }
}
