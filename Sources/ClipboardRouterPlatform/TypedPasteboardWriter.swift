import AppKit
import ClipboardRouterCore
import Foundation

public enum ClipPasteboardWriteMode: Equatable, Sendable {
    case original
    case plainText
}

public enum TypedPasteboardWriteError: Error, Equatable, LocalizedError, Sendable {
    case invalidAssetTypeIdentifier
    case pasteboardWriteFailed

    public var errorDescription: String? {
        switch self {
        case .invalidAssetTypeIdentifier:
            "A clip asset has an invalid type identifier."
        case .pasteboardWriteFailed:
            "Clipboard Router could not write the typed clip to the pasteboard."
        }
    }
}

@MainActor
public protocol TypedPasteboardWriting: AnyObject {
    func write(_ content: ClipContent, mode: ClipPasteboardWriteMode) async throws
    func write(
        _ content: ClipContent,
        mode: ClipPasteboardWriteMode,
        sourceTypeIdentifiers: [String]
    ) async throws
}

public extension TypedPasteboardWriting {
    /// Compatibility dispatch for test doubles and other writers that only support the original
    /// two-argument contract. Representation-aware writers override this requirement so callers
    /// can distinguish original plain text from derived OCR/search fallback text.
    func write(
        _ content: ClipContent,
        mode: ClipPasteboardWriteMode,
        sourceTypeIdentifiers: [String]
    ) async throws {
        try await write(content, mode: mode)
    }
}

/// Reads all referenced assets before clearing the pasteboard, preventing a missing asset from
/// replacing the user's current clipboard with a partial value.
@MainActor
public final class TypedSystemPasteboardWriter: TypedPasteboardWriting {
    private struct LoadedRepresentations {
        let richText: Data?
        let html: Data?
        let image: (data: Data, type: NSPasteboard.PasteboardType)?
    }

    private let pasteboard: NSPasteboard
    private let assetStore: any ClipAssetStoring

    public init(
        pasteboard: NSPasteboard = .general,
        assetStore: any ClipAssetStoring
    ) {
        self.pasteboard = pasteboard
        self.assetStore = assetStore
    }

    public func write(_ content: ClipContent, mode: ClipPasteboardWriteMode) async throws {
        try await write(
            content,
            mode: mode,
            sourceTypeIdentifiers: nil
        )
    }

    public func write(
        _ content: ClipContent,
        mode: ClipPasteboardWriteMode,
        sourceTypeIdentifiers: [String]
    ) async throws {
        try await write(
            content,
            mode: mode,
            sourceTypeIdentifiers: Set(sourceTypeIdentifiers)
        )
    }

    private func write(
        _ content: ClipContent,
        mode: ClipPasteboardWriteMode,
        sourceTypeIdentifiers: Set<String>?
    ) async throws {
        let loaded = try await loadRepresentations(for: content, mode: mode)
        let items = try makeItems(
            content: content,
            mode: mode,
            sourceTypeIdentifiers: sourceTypeIdentifiers,
            loaded: loaded
        )
        guard !items.isEmpty else {
            throw TypedPasteboardWriteError.pasteboardWriteFailed
        }
        pasteboard.clearContents()
        guard pasteboard.writeObjects(items) else {
            throw TypedPasteboardWriteError.pasteboardWriteFailed
        }
    }

    private func loadRepresentations(
        for content: ClipContent,
        mode: ClipPasteboardWriteMode
    ) async throws -> LoadedRepresentations {
        guard mode == .original else {
            return LoadedRepresentations(richText: nil, html: nil, image: nil)
        }
        let richText: Data?
        if let reference = content.representations.richText {
            richText = try await assetStore.read(reference)
        } else {
            richText = nil
        }
        let html: Data?
        if let reference = content.representations.html {
            html = try await assetStore.read(reference)
        } else {
            html = nil
        }
        let image: (data: Data, type: NSPasteboard.PasteboardType)?
        if let reference = content.representations.image {
            let typeIdentifier = reference.uniformTypeIdentifier
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !typeIdentifier.isEmpty, typeIdentifier.utf8.count <= 255 else {
                throw TypedPasteboardWriteError.invalidAssetTypeIdentifier
            }
            image = (
                try await assetStore.read(reference),
                NSPasteboard.PasteboardType(typeIdentifier)
            )
        } else {
            image = nil
        }
        return LoadedRepresentations(richText: richText, html: html, image: image)
    }

    private func makeItems(
        content: ClipContent,
        mode: ClipPasteboardWriteMode,
        sourceTypeIdentifiers: Set<String>?,
        loaded: LoadedRepresentations
    ) throws -> [NSPasteboardItem] {
        let markerType = NSPasteboard.PasteboardType(ClipboardRouterPasteboardType.appOrigin)
        let primary = NSPasteboardItem()
        var hasPrimaryRepresentation = false

        if shouldWritePlainText(
            for: content,
            mode: mode,
            sourceTypeIdentifiers: sourceTypeIdentifiers
        ) {
            guard primary.setString(content.text, forType: .string) else {
                throw TypedPasteboardWriteError.pasteboardWriteFailed
            }
            hasPrimaryRepresentation = true
        }

        if mode == .original {
            if let url = content.representations.url?.originalURL {
                guard primary.setString(url, forType: .URL) else {
                    throw TypedPasteboardWriteError.pasteboardWriteFailed
                }
                hasPrimaryRepresentation = true
            }
            if let richText = loaded.richText,
               !primary.setData(richText, forType: .rtf)
            {
                throw TypedPasteboardWriteError.pasteboardWriteFailed
            }
            if loaded.richText != nil { hasPrimaryRepresentation = true }
            if let html = loaded.html,
               !primary.setData(html, forType: .html)
            {
                throw TypedPasteboardWriteError.pasteboardWriteFailed
            }
            if loaded.html != nil { hasPrimaryRepresentation = true }
            if let image = loaded.image,
               !primary.setData(image.data, forType: image.type)
            {
                throw TypedPasteboardWriteError.pasteboardWriteFailed
            }
            if loaded.image != nil { hasPrimaryRepresentation = true }
        }

        var primaryItems: [NSPasteboardItem] = []
        if hasPrimaryRepresentation {
            guard primary.setString("1", forType: markerType) else {
                throw TypedPasteboardWriteError.pasteboardWriteFailed
            }
            primaryItems = [primary]
        }

        guard mode == .original, !content.representations.files.isEmpty else {
            return primaryItems
        }
        let fileItems = try content.representations.files.map { file -> NSPasteboardItem in
            let item = NSPasteboardItem()
            guard item.setString(file.url.absoluteString, forType: .fileURL),
                  item.setString("1", forType: markerType)
            else { throw TypedPasteboardWriteError.pasteboardWriteFailed }
            return item
        }
        return primaryItems + fileItems
    }

    private func shouldWritePlainText(
        for content: ClipContent,
        mode: ClipPasteboardWriteMode,
        sourceTypeIdentifiers: Set<String>?
    ) -> Bool {
        guard mode == .original else { return true }
        if let sourceTypeIdentifiers, !sourceTypeIdentifiers.isEmpty {
            return sourceTypeIdentifiers.contains(NSPasteboard.PasteboardType.string.rawValue)
        }

        // Older persisted clips have no source-type metadata. Their semantic type is the safest
        // compatibility signal: image OCR and generated file-name previews are derived metadata,
        // while text, URL, and rich-text clips historically exposed a useful text fallback.
        switch content.type {
        case .plainText, .url, .richText:
            return true
        case .image, .fileURLs:
            return false
        }
    }
}
