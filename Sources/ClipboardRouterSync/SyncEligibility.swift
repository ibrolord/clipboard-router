import ClipboardRouterCore
import Foundation

public enum SyncAnalysisState: String, Codable, Equatable, Sendable {
    case complete
    case pending
}

/// Metadata that is security-relevant to deciding whether a saved clip may leave this Mac.
public struct SavedClipSyncMetadata: Codable, Equatable, Sendable {
    public var analysisState: SyncAnalysisState
    public var coarseLocation: CoarseLocationContext?

    public init(
        analysisState: SyncAnalysisState = .complete,
        coarseLocation: CoarseLocationContext? = nil
    ) {
        self.analysisState = analysisState
        self.coarseLocation = coarseLocation
    }

    public static let ready = SavedClipSyncMetadata()
}

/// Origins without a saved-library case cannot accidentally be converted to a sync payload.
public enum SyncEligibilityCandidate: Equatable, Sendable {
    case savedClip(SavedClip, metadata: SavedClipSyncMetadata)
    case folder(ClipFolder)
    case history(id: UUID)
    case vault(id: UUID)
    case quarantine(id: UUID)
    case privateSession(id: UUID)
    case unsupported(id: UUID)

    public var id: UUID {
        switch self {
        case let .savedClip(clip, _): clip.id
        case let .folder(folder): folder.id
        case let .history(id), let .vault(id), let .quarantine(id),
             let .privateSession(id), let .unsupported(id): id
        }
    }
}

public enum SyncLocalOnlyReason: String, Codable, CaseIterable, Equatable, Sendable {
    case historyIsDeviceLocal
    case vaultIsDeviceLocal
    case quarantineIsMemoryOnly
    case privateSessionIsMemoryOnly
    case pendingSafetyAnalysis
    case sensitiveContentRequiresExplicitConsent
    case fileReferenceIsDeviceLocal
    case binaryAssetTransportUnavailable
    case locationSharingDisabled
    case unsupportedEntityType
}

public enum SyncEligibilityDecision: Equatable, Sendable {
    case eligible
    case localOnly(SyncLocalOnlyReason)
}

/// Fail-closed sync admission. Location is denied unless the caller supplies explicit opt-in.
public struct SyncEligibilityPolicy: Equatable, Sendable {
    public let allowsLocation: Bool

    public init(allowsLocation: Bool = false) {
        self.allowsLocation = allowsLocation
    }

    public func evaluate(_ candidate: SyncEligibilityCandidate) -> SyncEligibilityDecision {
        switch candidate {
        case .history:
            return .localOnly(.historyIsDeviceLocal)
        case .vault:
            return .localOnly(.vaultIsDeviceLocal)
        case .quarantine:
            return .localOnly(.quarantineIsMemoryOnly)
        case .privateSession:
            return .localOnly(.privateSessionIsMemoryOnly)
        case .unsupported:
            return .localOnly(.unsupportedEntityType)
        case .folder:
            return .eligible
        case let .savedClip(clip, metadata):
            if metadata.analysisState == .pending {
                return .localOnly(.pendingSafetyAnalysis)
            }
            if clip.sensitivity != nil {
                return .localOnly(.sensitiveContentRequiresExplicitConsent)
            }
            if clip.content.type == .fileURLs || !clip.content.representations.files.isEmpty {
                return .localOnly(.fileReferenceIsDeviceLocal)
            }
            let hasAssets = !clip.content.representations.referencedAssets.isEmpty
            if hasAssets {
                let kinds = Set(clip.content.representations.referencedAssets.map(\.kind))
                let isSupportedRich = clip.content.type == .richText
                    && kinds.isSubset(of: [.richText, .html])
                let isSupportedImage = clip.content.type == .image
                    && kinds.isSubset(of: [.image, .thumbnail])
                guard isSupportedRich || isSupportedImage else {
                    return .localOnly(.binaryAssetTransportUnavailable)
                }
                if metadata.coarseLocation != nil
                    || clip.captureContext?.coarseLocation != nil
                {
                    return .localOnly(.locationSharingDisabled)
                }
            }
            if metadata.coarseLocation != nil || clip.captureContext?.coarseLocation != nil,
               !allowsLocation
            {
                return .localOnly(.locationSharingDisabled)
            }
            return .eligible
        }
    }
}
