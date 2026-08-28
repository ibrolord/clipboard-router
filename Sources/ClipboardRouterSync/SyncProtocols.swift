import Foundation

public protocol SavedLibrarySyncTransport: Sendable {
    func accountIdentity() async throws -> SyncAccountIdentity
    func fetchChanges(after token: Data?) async throws -> SyncFetchBatch
    func push(_ records: [SavedLibrarySyncRecord]) async throws
    func pushAssets(_ assets: [SavedLibrarySyncAssetUpload]) async throws -> Set<String>
    func fetchAssets(
        _ descriptors: [SavedLibrarySyncAssetDescriptor]
    ) async throws -> [SavedLibrarySyncAssetDownload]
    func garbageCollectAssets(digests: Set<String>) async throws
}

public extension SavedLibrarySyncTransport {
    func pushAssets(_ assets: [SavedLibrarySyncAssetUpload]) async throws -> Set<String> {
        guard assets.isEmpty else { throw SavedLibrarySyncError.assetTransportUnavailable }
        return []
    }

    func fetchAssets(
        _ descriptors: [SavedLibrarySyncAssetDescriptor]
    ) async throws -> [SavedLibrarySyncAssetDownload] {
        guard descriptors.isEmpty else { throw SavedLibrarySyncError.assetTransportUnavailable }
        return []
    }

    func garbageCollectAssets(digests: Set<String>) async throws {
        guard digests.isEmpty else { throw SavedLibrarySyncError.assetTransportUnavailable }
    }
}

public protocol SavedLibrarySyncStateStore: Sendable {
    func load() async throws -> SavedLibrarySyncSnapshot
    func save(_ snapshot: SavedLibrarySyncSnapshot) async throws
}
