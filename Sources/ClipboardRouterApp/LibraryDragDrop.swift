import CoreTransferable
import Foundation
import UniformTypeIdentifiers

extension UTType {
    static let clipboardRouterLibraryItem = UTType(exportedAs: "com.clipboardrouter.library-item")
    static let clipboardRouterFolder = UTType(exportedAs: "com.clipboardrouter.folder")
}

/// Drag payloads intentionally contain identity and origin only. Clip/note text, file paths,
/// metadata, and thumbnails never leave the in-process library through drag-and-drop.
struct LibraryItemTransfer: Codable, Hashable, Transferable {
    enum Origin: String, Codable {
        case history
        case saved
    }

    let id: UUID
    let origin: Origin

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .clipboardRouterLibraryItem)
    }
}

struct FolderTransfer: Codable, Hashable, Transferable {
    let id: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .clipboardRouterFolder)
    }
}
