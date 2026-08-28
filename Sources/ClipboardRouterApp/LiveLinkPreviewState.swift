import ClipboardRouterPlatform
import Foundation

enum LiveLinkPreviewState: Equatable {
    case idle
    case loading
    case loaded(LiveLinkPreviewMetadata)
    case blocked(String)
    case offline(String)
    case failed(String)

    var metadata: LiveLinkPreviewMetadata? {
        if case let .loaded(metadata) = self { return metadata }
        return nil
    }
}

enum LiveLinkPreviewEligibility: Equatable {
    case eligible(URL)
    case blocked(String)
}
