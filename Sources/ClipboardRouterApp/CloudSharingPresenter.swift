import AppKit
import ClipboardRouterSync
import Foundation

enum CloudSharingPresentationError: Error, LocalizedError {
    case serviceUnavailable
    case cannotPresentShare

    var errorDescription: String? {
        switch self {
        case .serviceUnavailable:
            "macOS Cloud Sharing is unavailable on this Mac. The folder share still exists; try Manage Sharing again after signing in to iCloud."
        case .cannotPresentShare:
            "macOS cannot present this CloudKit share. Check iCloud account restrictions and try again."
        }
    }
}

@MainActor
protocol CloudSharingPresenting: AnyObject {
    func present(_ presentation: CloudKitSharePresentation) throws
}

@MainActor
final class SystemCloudSharingPresenter: CloudSharingPresenting {
    func present(_ presentation: CloudKitSharePresentation) throws {
        let itemProvider = NSItemProvider()
        itemProvider.registerCloudKitShare(
            presentation.share,
            container: presentation.container
        )
        guard let service = NSSharingService(named: .cloudSharing) else {
            throw CloudSharingPresentationError.serviceUnavailable
        }
        guard service.canPerform(withItems: [itemProvider]) else {
            throw CloudSharingPresentationError.cannotPresentShare
        }
        service.perform(withItems: [itemProvider])
    }
}
