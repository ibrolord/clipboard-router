import ClipboardRouterCore
import Foundation

/// Syncs only explicitly saved clips and folders. It has no pasteboard, history, or vault dependency.
public actor SavedLibrarySyncCoordinator {
    private let deviceID: String
    private let transport: any SavedLibrarySyncTransport
    private let store: any SavedLibrarySyncStateStore
    private let assetStore: (any ClipAssetStoring)?
    private let assetStager: (any SavedLibrarySyncAssetStaging)?
    private let now: @Sendable () -> Date
    private let eligibilityPolicy: SyncEligibilityPolicy
    private var state: SavedLibrarySyncSnapshot
    private var operationGeneration: UInt64 = 0
    private var isMutationInProgress = false
    private var mutationWaiters: [CheckedContinuation<Void, Never>] = []

    public static func open(
        deviceID: String,
        transport: any SavedLibrarySyncTransport,
        store: any SavedLibrarySyncStateStore,
        assetStore: (any ClipAssetStoring)? = nil,
        assetStager: (any SavedLibrarySyncAssetStaging)? = nil,
        eligibilityPolicy: SyncEligibilityPolicy = SyncEligibilityPolicy(),
        now: @escaping @Sendable () -> Date = Date.init
    ) async throws -> SavedLibrarySyncCoordinator {
        let loaded = try await store.load()
        return SavedLibrarySyncCoordinator(
            deviceID: deviceID,
            transport: transport,
            store: store,
            snapshot: loaded,
            assetStore: assetStore,
            assetStager: assetStager,
            eligibilityPolicy: eligibilityPolicy,
            now: now
        )
    }

    public init(
        deviceID: String,
        transport: any SavedLibrarySyncTransport,
        store: any SavedLibrarySyncStateStore,
        snapshot: SavedLibrarySyncSnapshot = .disabled,
        assetStore: (any ClipAssetStoring)? = nil,
        assetStager: (any SavedLibrarySyncAssetStaging)? = nil,
        eligibilityPolicy: SyncEligibilityPolicy = SyncEligibilityPolicy(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.deviceID = deviceID
        self.transport = transport
        self.store = store
        self.assetStore = assetStore
        self.assetStager = assetStager
        self.state = snapshot
        self.eligibilityPolicy = eligibilityPolicy
        self.now = now
    }

    public func snapshot() -> SavedLibrarySyncSnapshot { state }

    public func setEnabled(_ enabled: Bool) async throws {
        if !enabled {
            // Invalidate a transport operation immediately, even while it is suspended.
            operationGeneration &+= 1
            var next = state
            next.isEnabled = false
            next.status = .disabled
            next.pendingAccountFingerprint = nil
            state = next // fail closed in memory before persistence suspends
            try await store.save(next)
            return
        }

        await acquireMutationPermit()
        defer { releaseMutationPermit() }
        let generation = operationGeneration
        var next = state
        next.isEnabled = true
        next.status = .idle(lastSuccessfulSync: nil)
        try await commit(next, expectedGeneration: generation)
    }

    /// Required before any queued clips are uploaded after macOS switches iCloud accounts.
    public func confirmPendingAccountChange() async throws {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }
        let generation = operationGeneration
        guard state.isEnabled, let pending = state.pendingAccountFingerprint else {
            throw SavedLibrarySyncError.accountConfirmationNotPending
        }
        var next = state
        next.confirmedAccountFingerprint = pending
        next.pendingAccountFingerprint = nil
        next.changeToken = nil // CK server tokens are scoped to the former account.
        try enforceLocalOnlyExclusions(in: &next)
        // Explicit confirmation means migrate the complete saved library into the new private
        // database. Re-stamp and enqueue live values and tombstones; an empty old outbox must
        // not make the new account appear successfully synced while receiving nothing.
        for existing in Array(next.records.values) {
            let stamp = try nextStamp(for: existing.id, in: &next)
            let migrated: SavedLibrarySyncRecord
            if existing.isTombstone {
                migrated = try .tombstone(id: existing.id, kind: existing.kind, stamp: stamp)
            } else if let payload = existing.payload {
                migrated = try .live(
                    payload,
                    stamp: stamp,
                    savedClipMetadata: existing.savedClipMetadata,
                    assetManifest: existing.assetManifest
                )
            } else {
                throw SavedLibrarySyncError.invalidRecord(existing.id)
            }
            next.records[existing.id] = migrated
            next.outbox[existing.id] = migrated
            if !Self.isLocalOnly(existing.id, in: next) {
                next.entityStates[existing.id] = .queued
            }
        }
        next.status = .idle(lastSuccessfulSync: nil)
        try await commit(next, expectedGeneration: generation)
    }

    @discardableResult
    public func recordSavedClip(_ clip: SavedClip) async throws -> SavedLibrarySyncRecord {
        try await recordSavedClip(clip, metadata: .ready)
    }

    @discardableResult
    public func recordSavedClip(
        _ clip: SavedClip,
        metadata: SavedClipSyncMetadata
    ) async throws -> SavedLibrarySyncRecord {
        let candidate = SyncEligibilityCandidate.savedClip(clip, metadata: metadata)
        switch eligibilityPolicy.evaluate(candidate) {
        case .eligible:
            let sourceManifest = try SavedLibrarySyncAssetDescriptor.manifest(for: clip)
            let canonicalReferences = Set(try sourceManifest.map { try $0.localReference() })
            guard canonicalReferences == clip.content.representations.referencedAssets else {
                throw SavedLibrarySyncError.invalidAssetManifest
            }
            let canonicalClip = try SavedLibrarySyncAssetDescriptor.canonicalizedClip(clip)
            let manifest = try SavedLibrarySyncAssetDescriptor.manifest(for: canonicalClip)
            if !manifest.isEmpty, assetStore == nil || assetStager == nil {
                let reason = SyncLocalOnlyReason.binaryAssetTransportUnavailable
                try await recordLocalOnly(id: clip.id, reason: reason)
                throw SavedLibrarySyncError.ineligible(clip.id, reason)
            }
            let storedMetadata = metadata == .ready ? nil : metadata
            return try await record(
                .savedClip(canonicalClip),
                savedClipMetadata: storedMetadata,
                assetManifest: manifest
            )
        case let .localOnly(reason):
            try await recordLocalOnly(id: clip.id, reason: reason)
            throw SavedLibrarySyncError.ineligible(clip.id, reason)
        }
    }

    @discardableResult
    public func recordFolder(_ folder: ClipFolder) async throws -> SavedLibrarySyncRecord {
        try await record(.folder(folder))
    }

    public func eligibility(for candidate: SyncEligibilityCandidate) -> SyncEligibilityDecision {
        eligibilityPolicy.evaluate(candidate)
    }

    /// Records only privacy-safe metadata for non-syncable entities so the UI can explain why.
    @discardableResult
    public func markLocalOnly(
        _ candidate: SyncEligibilityCandidate
    ) async throws -> SyncEligibilityDecision {
        let decision = eligibilityPolicy.evaluate(candidate)
        if case let .localOnly(reason) = decision {
            try await recordLocalOnly(id: candidate.id, reason: reason)
        }
        return decision
    }

    public func entityState(for id: UUID) -> SyncEntityState? {
        state.entityStates[id]
    }

    @discardableResult
    public func recordDeletion(id: UUID, kind: SyncEntityKind) async throws -> SavedLibrarySyncRecord {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }
        let generation = operationGeneration
        var next = state
        let retiredAssets = next.records[id]?.assetManifest ?? []
        let stamp = try nextStamp(for: id, in: &next)
        let tombstone = try SavedLibrarySyncRecord.tombstone(id: id, kind: kind, stamp: stamp)
        next.records[id] = tombstone
        next.outbox[id] = tombstone
        next.entityStates[id] = .queued
        if kind == .folder { try normalizeOrphanedFolderReferences(in: &next) }
        updateAssetGarbage(in: &next, retiring: retiredAssets)
        try await commit(next, expectedGeneration: generation)
        return tombstone
    }

    /// Returns a stable projection. Folder corrections are generated once during merge/deletion,
    /// preserving the clip's modifiedAt rather than re-editing it on every projection.
    public func materializedLibrary() -> (savedClips: [SavedClip], folders: [ClipFolder]) {
        let liveFolderIDs = Set(state.records.values.compactMap { record -> UUID? in
            guard !record.isTombstone, case let .folder(folder) = record.payload else { return nil }
            return folder.id
        })
        var clips: [SavedClip] = []
        var folders: [ClipFolder] = []
        for record in state.records.values where !record.isTombstone {
            guard !Self.isLocalOnly(record.id, in: state) else { continue }
            switch record.payload {
            case let .savedClip(clip):
                if let folderID = clip.folderID, !liveFolderIDs.contains(folderID),
                   let unfiled = try? SavedClip(
                       id: clip.id,
                       kind: clip.kind,
                       name: clip.name,
                       content: clip.content,
                       folderID: nil,
                       sourceHistoryItemID: clip.sourceHistoryItemID,
                       derivedFromHistoryItemID: clip.derivedFromHistoryItemID,
                       createdAt: clip.createdAt,
                       modifiedAt: clip.modifiedAt,
                       pinnedAt: clip.pinnedAt,
                       tags: clip.tags ?? [],
                       sourceApplicationBundleIdentifier: clip.sourceApplicationBundleIdentifier,
                       originatingDeviceIdentifier: clip.originatingDeviceIdentifier,
                       captureContext: clip.captureContext,
                       originallyCapturedAt: clip.originallyCapturedAt,
                       sensitivity: clip.sensitivity,
                       pasteboardTypeIdentifiers: clip.pasteboardTypeIdentifiers ?? []
                   ) {
                    clips.append(unfiled)
                } else {
                    clips.append(clip)
                }
            case let .folder(folder): folders.append(folder)
            case nil: break
            }
        }
        clips.sort { $0.id.uuidString < $1.id.uuidString }
        folders.sort { lhs, rhs in
            lhs.sortOrder == rhs.sortOrder
                ? lhs.id.uuidString < rhs.id.uuidString
                : lhs.sortOrder < rhs.sortOrder
        }
        return (clips, folders)
    }

    public func synchronize() async {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }
        let generation = operationGeneration
        guard isRunCurrent(generation) else { return }

        do {
            try await updateStatus(.syncing, generation: generation)
            let identity = try await transport.accountIdentity()
            guard isRunCurrent(generation) else { return }
            guard identity.state == .available else {
                try await updateStatus(.accountUnavailable(identity.state), generation: generation)
                return
            }
            guard let fingerprint = identity.fingerprint, !fingerprint.isEmpty else {
                throw SavedLibrarySyncError.accountIdentityUnavailable
            }

            if let confirmed = state.confirmedAccountFingerprint, confirmed != fingerprint {
                var next = state
                next.pendingAccountFingerprint = fingerprint
                next.status = .failed("iCloud account changed. Confirm before syncing saved clips.")
                try await commit(next, expectedGeneration: generation)
                return // Never upload old outbox before explicit confirmation.
            } else if state.confirmedAccountFingerprint == nil {
                var next = state
                next.confirmedAccountFingerprint = fingerprint
                next.pendingAccountFingerprint = nil
                try await commit(next, expectedGeneration: generation)
            }

            try await enforceLocalOnlyExclusions(generation: generation)
            try await materializeIncomingAssets(
                for: state.records.values.filter { state.outbox[$0.id] == nil },
                generation: generation
            )
            try await flushOutbox(generation: generation)
            guard isRunCurrent(generation) else { return }
            let batch = try await transport.fetchChanges(after: state.changeToken)
            guard isRunCurrent(generation) else { return }
            try await materializeIncomingAssets(
                for: batch.records,
                generation: generation
            )
            try await merge(
                batch.records,
                changeToken: batch.changeToken,
                generation: generation
            )
            try await flushOutbox(generation: generation)
            guard isRunCurrent(generation) else { return }
            try await collectRemoteAssetGarbage(generation: generation)
            try await updateStatus(.idle(lastSuccessfulSync: now()), generation: generation)
        } catch SavedLibrarySyncError.disabled {
            return
        } catch SavedLibrarySyncError.offline {
            try? await updateStatusIfCurrent(.offline, generation: generation)
        } catch let error as SavedLibrarySyncError {
            try? await updateStatusIfCurrent(.failed(error.localizedDescription), generation: generation)
        } catch {
            try? await updateStatusIfCurrent(.failed(String(describing: error)), generation: generation)
        }
    }

    private func record(
        _ payload: SavedLibraryPayload,
        savedClipMetadata: SavedClipSyncMetadata? = nil,
        assetManifest: [SavedLibrarySyncAssetDescriptor] = []
    ) async throws -> SavedLibrarySyncRecord {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }
        let generation = operationGeneration
        var next = state
        let retiredAssets = next.records[payload.id]?.assetManifest ?? []
        let stamp = try nextStamp(for: payload.id, in: &next)
        let record = try SavedLibrarySyncRecord.live(
            payload,
            stamp: stamp,
            savedClipMetadata: savedClipMetadata,
            assetManifest: assetManifest
        )
        next.records[payload.id] = record
        next.outbox[payload.id] = record
        next.entityStates[payload.id] = .queued
        updateAssetGarbage(in: &next, retiring: retiredAssets)
        if case .folder = payload { try normalizeOrphanedFolderReferences(in: &next) }
        try await commit(next, expectedGeneration: generation)
        return record
    }

    private func recordLocalOnly(id: UUID, reason: SyncLocalOnlyReason) async throws {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }
        let generation = operationGeneration
        var next = state
        next.entityStates[id] = .localOnly(reason: reason)
        try enforceLocalOnlyExclusion(for: id, in: &next)
        try await commit(next, expectedGeneration: generation)
    }

    private func nextStamp(
        for id: UUID,
        in snapshot: inout SavedLibrarySyncSnapshot
    ) throws -> LamportStamp {
        let entityCounter = snapshot.records[id]?.stamp.counter ?? 0
        let current = max(snapshot.localLamportCounter, entityCounter)
        guard current < Int64.max - 1 else { throw SavedLibrarySyncError.lamportOverflow }
        snapshot.localLamportCounter = current + 1
        return try LamportStamp(counter: snapshot.localLamportCounter, deviceID: deviceID)
    }

    private func merge(
        _ incoming: [SavedLibrarySyncRecord],
        changeToken: Data?,
        generation: UInt64
    ) async throws {
        try requireCurrentRun(generation)
        var next = state
        var retiredAssets: [SavedLibrarySyncAssetDescriptor] = []
        for remote in incoming {
            try SavedLibrarySyncRecord.validate(remote)
            if Self.isLocalOnly(remote.id, in: next) {
                try mergeRemoteRecordIntoLocalOnlyExclusion(remote, in: &next)
                continue
            }
            if case let .savedClip(clip) = remote.payload {
                let metadata = remote.savedClipMetadata ?? .ready
                if case let .localOnly(reason) = eligibilityPolicy.evaluate(
                    .savedClip(clip, metadata: metadata)
                ) {
                    throw SavedLibrarySyncError.ineligible(clip.id, reason)
                }
            }
            next.localLamportCounter = max(next.localLamportCounter, remote.stamp.counter)
            if let local = next.records[remote.id] {
                try SavedLibrarySyncRecord.rejectStampCollision(between: local, and: remote)
                if remote.stamp > local.stamp {
                    retiredAssets.append(contentsOf: local.assetManifest)
                    let hadPendingLocalChange = next.outbox[remote.id] != nil
                    let replacedLocalDeviceVersion = local.stamp.deviceID == deviceID
                        && remote.stamp.deviceID != deviceID
                    next.records[remote.id] = remote
                    if let pending = next.outbox[remote.id], pending.stamp <= remote.stamp {
                        next.outbox.removeValue(forKey: remote.id)
                    }
                    next.entityStates[remote.id] = (hadPendingLocalChange || replacedLocalDeviceVersion)
                        ? .conflict(local: local.stamp, remote: remote.stamp)
                        : .synced(at: now(), deviceID: remote.stamp.deviceID)
                } else if local.stamp > remote.stamp {
                    next.outbox[local.id] = local
                    next.entityStates[local.id] = .queued
                }
            } else {
                next.records[remote.id] = remote
                next.entityStates[remote.id] = .synced(
                    at: now(),
                    deviceID: remote.stamp.deviceID
                )
            }
        }
        updateAssetGarbage(in: &next, retiring: retiredAssets)
        try normalizeOrphanedFolderReferences(in: &next)
        next.changeToken = changeToken
        try await commit(next, expectedGeneration: generation)
    }

    private func normalizeOrphanedFolderReferences(
        in snapshot: inout SavedLibrarySyncSnapshot
    ) throws {
        let explicitlyDeletedFolderIDs = Set(snapshot.records.values.compactMap { record -> UUID? in
            guard record.isTombstone, record.kind == .folder else { return nil }
            return record.id
        })
        var liveFolders = Dictionary(uniqueKeysWithValues: snapshot.records.values.compactMap {
            record -> (UUID, ClipFolder)? in
            guard !record.isTombstone, case let .folder(folder) = record.payload else { return nil }
            return (folder.id, folder)
        })

        // Promote descendants of explicitly deleted parents. A merely absent parent may still be
        // arriving in the same CloudKit change stream, so it is not corrected prematurely.
        for folder in liveFolders.values.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            guard let parentID = folder.parentFolderID,
                  explicitlyDeletedFolderIDs.contains(parentID)
            else { continue }
            try writeFolderCorrection(folder, parentFolderID: nil, in: &snapshot)
            liveFolders[folder.id]?.parentFolderID = nil
        }

        // Break each cycle at the lexicographically smallest member. Every replica makes the same
        // choice independent of record arrival order.
        var visited: Set<UUID> = []
        for start in liveFolders.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard !visited.contains(start) else { continue }
            var path: [UUID] = []
            var positions: [UUID: Int] = [:]
            var cursor: UUID? = start
            while let id = cursor, let folder = liveFolders[id], !visited.contains(id) {
                if let cycleStart = positions[id] {
                    let cycle = Array(path[cycleStart...])
                    if let breakID = cycle.min(by: { $0.uuidString < $1.uuidString }),
                       let value = liveFolders[breakID]
                    {
                        try writeFolderCorrection(value, parentFolderID: nil, in: &snapshot)
                        liveFolders[breakID]?.parentFolderID = nil
                    }
                    break
                }
                positions[id] = path.count
                path.append(id)
                cursor = folder.parentFolderID
            }
            visited.formUnion(path)
        }

        let records = Array(snapshot.records.values)
        for record in records {
            guard !record.isTombstone,
                  case let .savedClip(clip) = record.payload,
                  let folderID = clip.folderID,
                  explicitlyDeletedFolderIDs.contains(folderID)
            else { continue }
            let corrected = try SavedClip(
                id: clip.id,
                kind: clip.kind,
                name: clip.name,
                content: clip.content,
                folderID: nil,
                sourceHistoryItemID: clip.sourceHistoryItemID,
                derivedFromHistoryItemID: clip.derivedFromHistoryItemID,
                createdAt: clip.createdAt,
                modifiedAt: clip.modifiedAt,
                pinnedAt: clip.pinnedAt,
                tags: clip.tags ?? [],
                sourceApplicationBundleIdentifier: clip.sourceApplicationBundleIdentifier,
                originatingDeviceIdentifier: clip.originatingDeviceIdentifier,
                captureContext: clip.captureContext,
                originallyCapturedAt: clip.originallyCapturedAt,
                sensitivity: clip.sensitivity,
                pasteboardTypeIdentifiers: clip.pasteboardTypeIdentifiers ?? []
            )
            let stamp = try nextStamp(for: clip.id, in: &snapshot)
            let correction = try SavedLibrarySyncRecord.live(
                .savedClip(corrected),
                stamp: stamp,
                savedClipMetadata: record.savedClipMetadata,
                assetManifest: record.assetManifest
            )
            snapshot.records[clip.id] = correction
            snapshot.outbox[clip.id] = correction
            snapshot.entityStates[clip.id] = .queued
        }
    }

    private func writeFolderCorrection(
        _ folder: ClipFolder,
        parentFolderID: UUID?,
        in snapshot: inout SavedLibrarySyncSnapshot
    ) throws {
        let corrected = try ClipFolder(
            id: folder.id,
            name: folder.name,
            parentFolderID: parentFolderID,
            sortOrder: folder.sortOrder,
            createdAt: folder.createdAt,
            modifiedAt: folder.modifiedAt
        )
        let stamp = try nextStamp(for: folder.id, in: &snapshot)
        let record = try SavedLibrarySyncRecord.live(.folder(corrected), stamp: stamp)
        snapshot.records[folder.id] = record
        snapshot.outbox[folder.id] = record
        snapshot.entityStates[folder.id] = .queued
    }

    private func flushOutbox(generation: UInt64) async throws {
        try requireCurrentRun(generation)
        let pending = SavedLibrarySyncRecord.dependencyOrdered(state.outbox.values)
        guard !pending.isEmpty else { return }
        let manifests = pending.flatMap(\.assetManifest)
        do {
          if !manifests.isEmpty {
            guard let assetStore, let assetStager else {
                throw SavedLibrarySyncError.assetTransportUnavailable
            }
            var preparing = state
            for record in pending where !record.assetManifest.isEmpty {
                preparing.entityStates[record.id] = .preparingAssets
            }
            try await commit(preparing, expectedGeneration: generation)
            let unique = Dictionary(grouping: manifests, by: \.digest).values.compactMap(\.first)
                .sorted(by: SavedLibrarySyncAssetDescriptor.deterministicOrder)
            var assetUploading = state
            for record in pending where !record.assetManifest.isEmpty {
                assetUploading.entityStates[record.id] = .uploadingAssets
            }
            try await commit(assetUploading, expectedGeneration: generation)
            for batch in SavedLibrarySyncAssetDescriptor.boundedBatches(unique) {
                var uploads: [SavedLibrarySyncAssetUpload] = []
                for descriptor in batch {
                    uploads.append(try await assetStager.stage(descriptor, from: assetStore))
                }
                let accepted = try await transport.pushAssets(uploads)
                let expected = Set(batch.map(\.digest))
                guard accepted.isSuperset(of: expected) else {
                    throw SavedLibrarySyncError.transportFailure(
                        "Asset transport did not confirm every staged digest"
                    )
                }
                for digest in expected {
                    try await assetStager.removeStagedAsset(digest: digest)
                }
            }
          }
        } catch {
            await markFailed(pending, error: error, generation: generation)
            throw error
        }
        var uploading = state
        for record in pending {
            if !Self.isLocalOnly(record.id, in: uploading) {
                uploading.entityStates[record.id] = .uploading
            }
        }
        try await commit(uploading, expectedGeneration: generation)
        do {
            try await transport.push(pending)
        } catch {
            await markFailed(pending, error: error, generation: generation)
            throw error
        }
        try requireCurrentRun(generation)
        var next = state
        for sent in pending where next.outbox[sent.id] == sent {
            next.outbox.removeValue(forKey: sent.id)
            if !Self.isLocalOnly(sent.id, in: next) {
                next.entityStates[sent.id] = .synced(at: now(), deviceID: deviceID)
            }
        }
        try await commit(next, expectedGeneration: generation)
    }

    private func materializeIncomingAssets(
        for records: [SavedLibrarySyncRecord],
        generation: UInt64
    ) async throws {
        try requireCurrentRun(generation)
        for record in records where !record.assetManifest.isEmpty {
            try SavedLibrarySyncRecord.validate(record)
            if let local = state.records[record.id], local.stamp == record.stamp {
                try SavedLibrarySyncRecord.rejectStampCollision(between: local, and: record)
            }
            guard case let .savedClip(clip) = record.payload else {
                throw SavedLibrarySyncError.invalidAssetManifest
            }
            let metadata = record.savedClipMetadata ?? .ready
            if case let .localOnly(reason) = eligibilityPolicy.evaluate(
                .savedClip(clip, metadata: metadata)
            ) {
                throw SavedLibrarySyncError.ineligible(clip.id, reason)
            }
        }
        let candidates = records.filter { record in
            guard !record.isTombstone, !record.assetManifest.isEmpty else { return false }
            guard let local = state.records[record.id] else { return true }
            return record.stamp >= local.stamp
        }
        let descriptors = candidates.flatMap(\.assetManifest)
        guard !descriptors.isEmpty else { return }
        guard let assetStore, let assetStager else {
            throw SavedLibrarySyncError.assetTransportUnavailable
        }
        var missing: [SavedLibrarySyncAssetDescriptor] = []
        for descriptor in descriptors {
            do { _ = try await assetStore.read(descriptor.localReference()) }
            catch { missing.append(descriptor) }
        }
        let uniqueMissing = Dictionary(grouping: missing, by: { descriptor in
            "\(descriptor.digest):\(descriptor.kind.rawValue):\(descriptor.uniformTypeIdentifier)"
        }).values.compactMap(\.first)
            .sorted(by: SavedLibrarySyncAssetDescriptor.deterministicOrder)
        guard !uniqueMissing.isEmpty else { return }

        let affectedIDs = Set(candidates.filter { record in
            !Set(record.assetManifest).isDisjoint(with: Set(uniqueMissing))
        }.map(\.id))
        let priorStates = Dictionary(uniqueKeysWithValues: affectedIDs.compactMap { id in
            state.entityStates[id].map { (id, $0) }
        })
        var downloading = state
        for id in affectedIDs { downloading.entityStates[id] = .downloadingAssets }
        try await commit(downloading, expectedGeneration: generation)

        do {
            for batch in SavedLibrarySyncAssetDescriptor.boundedBatches(uniqueMissing) {
                let downloads = try await transport.fetchAssets(batch)
                guard downloads.count == batch.count,
                      Set(downloads.map(\.descriptor)) == Set(batch)
                else {
                    throw SavedLibrarySyncError.transportFailure(
                        "Asset transport returned an incomplete or mismatched download set"
                    )
                }
                for download in downloads {
                    _ = try await assetStager.materialize(download, into: assetStore)
                }
            }
        } catch {
            var failed = state
            for id in affectedIDs { failed.entityStates[id] = .failed(String(describing: error)) }
            try? await commit(failed, expectedGeneration: generation)
            throw error
        }
        try requireCurrentRun(generation)
        var restored = state
        for id in affectedIDs {
            restored.entityStates[id] = priorStates[id] ?? .queued
        }
        try await commit(restored, expectedGeneration: generation)
    }

    private func markFailed(
        _ records: [SavedLibrarySyncRecord],
        error: any Error,
        generation: UInt64
    ) async {
        guard isRunCurrent(generation) else { return }
        var failed = state
        for record in records where failed.outbox[record.id] == record {
            if !Self.isLocalOnly(record.id, in: failed) {
                failed.entityStates[record.id] = .failed(String(describing: error))
            }
        }
        try? await commit(failed, expectedGeneration: generation)
    }

    private func collectRemoteAssetGarbage(generation: UInt64) async throws {
        try requireCurrentRun(generation)
        let cutoff = now().addingTimeInterval(-SavedLibrarySyncAssetPolicy.garbageCollectionGrace)
        let due = Set(state.assetGarbage.compactMap { digest, retiredAt in
            retiredAt <= cutoff ? digest : nil
        })
        guard !due.isEmpty else { return }
        // Content-addressed assets can be re-referenced concurrently by another Mac. CloudKit
        // cannot atomically prove that no live record references an independent asset record, so
        // client-side remote deletion is deliberately disabled. Prefer bounded server-managed GC
        // when that capability exists; until then, leak encrypted/sandboxed remote bytes rather
        // than delete another device's live attachment.
        try requireCurrentRun(generation)
        var next = state
        for digest in due { next.assetGarbage.removeValue(forKey: digest) }
        try await commit(next, expectedGeneration: generation)
    }

    private func enforceLocalOnlyExclusions(generation: UInt64) async throws {
        try requireCurrentRun(generation)
        var next = state
        try enforceLocalOnlyExclusions(in: &next)
        guard next != state else { return }
        try await commit(next, expectedGeneration: generation)
    }

    private func enforceLocalOnlyExclusions(
        in snapshot: inout SavedLibrarySyncSnapshot
    ) throws {
        let excludedIDs = snapshot.entityStates.compactMap { id, entityState -> UUID? in
            guard case .localOnly = entityState else { return nil }
            return id
        }
        for id in excludedIDs {
            try enforceLocalOnlyExclusion(for: id, in: &snapshot)
        }
        updateAssetGarbage(in: &snapshot)
    }

    /// Replaces any formerly synced live value with a higher-stamped tombstone. If no record has
    /// ever existed for this ID, the local-only state alone is sufficient and no kind is guessed.
    private func enforceLocalOnlyExclusion(
        for id: UUID,
        in snapshot: inout SavedLibrarySyncSnapshot
    ) throws {
        guard let existing = snapshot.records[id] else {
            snapshot.outbox.removeValue(forKey: id)
            return
        }
        if existing.isTombstone {
            if snapshot.outbox[id]?.isTombstone == false {
                snapshot.outbox[id] = existing
            }
            return
        }
        let retiredAssets = existing.assetManifest
        let stamp = try nextStamp(for: id, in: &snapshot)
        let tombstone = try SavedLibrarySyncRecord.tombstone(
            id: id,
            kind: existing.kind,
            stamp: stamp
        )
        snapshot.records[id] = tombstone
        snapshot.outbox[id] = tombstone
        updateAssetGarbage(in: &snapshot, retiring: retiredAssets)
    }

    /// A local exclusion always outranks a remote live record, regardless of its Lamport value.
    /// Remote tombstones may be accepted because they enforce the same absence.
    private func mergeRemoteRecordIntoLocalOnlyExclusion(
        _ remote: SavedLibrarySyncRecord,
        in snapshot: inout SavedLibrarySyncSnapshot
    ) throws {
        snapshot.localLamportCounter = max(snapshot.localLamportCounter, remote.stamp.counter)
        let local = snapshot.records[remote.id]

        if let local {
            try SavedLibrarySyncRecord.rejectStampCollision(between: local, and: remote)
        }

        if remote.isTombstone {
            if local == nil || remote.stamp > local!.stamp {
                snapshot.records[remote.id] = remote
                if let pending = snapshot.outbox[remote.id], pending.stamp <= remote.stamp {
                    snapshot.outbox.removeValue(forKey: remote.id)
                }
            } else if let local, local.stamp > remote.stamp {
                snapshot.outbox[remote.id] = local
            }
            return
        }

        if let local, local.isTombstone, local.stamp > remote.stamp {
            snapshot.outbox[remote.id] = local
            return
        }
        let retiredAssets = local?.assetManifest ?? []
        let stamp = try nextStamp(for: remote.id, in: &snapshot)
        let tombstone = try SavedLibrarySyncRecord.tombstone(
            id: remote.id,
            kind: remote.kind,
            stamp: stamp
        )
        snapshot.records[remote.id] = tombstone
        snapshot.outbox[remote.id] = tombstone
        updateAssetGarbage(in: &snapshot, retiring: retiredAssets)
    }

    private static func isLocalOnly(
        _ id: UUID,
        in snapshot: SavedLibrarySyncSnapshot
    ) -> Bool {
        guard case .localOnly = snapshot.entityStates[id] else { return false }
        return true
    }

    private func updateAssetGarbage(
        in snapshot: inout SavedLibrarySyncSnapshot,
        retiring descriptors: [SavedLibrarySyncAssetDescriptor] = []
    ) {
        let liveDigests = Set(snapshot.records.values.flatMap { record -> [String] in
            guard !record.isTombstone else { return [] }
            return record.assetManifest.map(\.digest)
        })
        for descriptor in descriptors where !liveDigests.contains(descriptor.digest) {
            snapshot.assetGarbage[descriptor.digest] = snapshot.assetGarbage[descriptor.digest]
                ?? now()
        }
        for digest in liveDigests { snapshot.assetGarbage.removeValue(forKey: digest) }
    }

    private func updateStatus(
        _ status: SavedLibrarySyncStatus,
        generation: UInt64
    ) async throws {
        try requireCurrentRun(generation)
        var next = state
        next.status = status
        try await commit(next, expectedGeneration: generation)
    }

    private func updateStatusIfCurrent(
        _ status: SavedLibrarySyncStatus,
        generation: UInt64
    ) async throws {
        guard isRunCurrent(generation) else { return }
        try await updateStatus(status, generation: generation)
    }

    private func isRunCurrent(_ generation: UInt64) -> Bool {
        generation == operationGeneration && state.isEnabled
    }

    private func requireCurrentRun(_ generation: UInt64) throws {
        guard isRunCurrent(generation) else { throw SavedLibrarySyncError.disabled }
    }

    private func commit(
        _ next: SavedLibrarySyncSnapshot,
        expectedGeneration: UInt64
    ) async throws {
        guard expectedGeneration == operationGeneration else {
            throw SavedLibrarySyncError.disabled
        }
        try await store.save(next)
        guard expectedGeneration == operationGeneration else {
            // A concurrent opt-out won while persistence was suspended. Restore its state to
            // disk so an older enabled snapshot can never become the durable winner.
            try await store.save(state)
            throw SavedLibrarySyncError.disabled
        }
        state = next
    }

    private func acquireMutationPermit() async {
        if !isMutationInProgress {
            isMutationInProgress = true
            return
        }
        await withCheckedContinuation { mutationWaiters.append($0) }
    }

    private func releaseMutationPermit() {
        guard !mutationWaiters.isEmpty else {
            isMutationInProgress = false
            return
        }
        mutationWaiters.removeFirst().resume()
    }
}
