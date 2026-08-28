import ClipboardRouterCore
import Foundation

public actor VaultLibrary {
    private let store: any VaultStore
    private let assetStore: any VaultEncryptedAssetStoring
    private let session: any VaultSessionKeyAccess
    private var snapshot: VaultStoreSnapshot
    private var isMutationInProgress = false
    private var mutationWaiters: [CheckedContinuation<Void, Never>] = []

    public static func open(
        store: any VaultStore,
        session: any VaultSessionKeyAccess,
        assetStore: any VaultEncryptedAssetStoring = InMemoryVaultEncryptedAssetStore()
    ) async throws -> VaultLibrary {
        let loaded = try await store.load()
        await session.prepareForStore(hasEncryptedItems: !loaded.envelopes.isEmpty)
        return VaultLibrary(
            store: store,
            session: session,
            assetStore: assetStore,
            snapshot: loaded
        )
    }

    public init(
        store: any VaultStore,
        session: any VaultSessionKeyAccess,
        assetStore: any VaultEncryptedAssetStoring = InMemoryVaultEncryptedAssetStore(),
        snapshot: VaultStoreSnapshot = .empty
    ) {
        self.store = store
        self.session = session
        self.assetStore = assetStore
        self.snapshot = snapshot
    }

    public func encryptedSnapshot() -> VaultStoreSnapshot { snapshot }

    public func items() async throws -> [VaultItem] {
        let envelopes = snapshot.envelopes
        return try await session.withUnlockedKey { key in
            try envelopes.map { try VaultCrypto.open($0, using: key) }
                .sorted { $0.modifiedAt > $1.modifiedAt }
        }
    }

    @discardableResult
    public func add(
        _ item: VaultItem,
        sourceAssets: (any ClipAssetStoring)? = nil
    ) async throws -> VaultItem {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }
        try await verifyKeyMatchesExistingCiphertext()
        guard !snapshot.envelopes.contains(where: { $0.id == item.id }) else {
            throw VaultError.duplicateItem(item.id)
        }
        let referencesByDescriptor = try Self.referencesByDescriptor(for: item)
        if !item.assets.isEmpty, sourceAssets == nil {
            throw VaultError.missingAsset(item.assets[0].storageIdentifier)
        }
        var written: [VaultAssetDescriptor] = []
        var persistedEnvelope = false
        do {
            if let sourceAssets {
                for descriptor in item.assets {
                    guard let reference = referencesByDescriptor[descriptor] else {
                        throw VaultError.invalidAssetManifest
                    }
                    let plaintext = try await sourceAssets.read(reference)
                    let encrypted = try await session.withUnlockedKey { key in
                        try VaultAssetCrypto.seal(
                            plaintext,
                            descriptor: descriptor,
                            itemID: item.id,
                            using: key
                        )
                    }
                    try await assetStore.write(encrypted, descriptor: descriptor)
                    written.append(descriptor)
                }
            }
            let envelope = try await session.withUnlockedKey { key in
                try VaultCrypto.seal(item, using: key)
            }
            var next = snapshot
            next.envelopes.append(envelope)
            try await store.save(next)
            persistedEnvelope = true
            // This is the deletion gate used by AppModel. It authenticates the new item envelope
            // and every original binary representation before the ordinary transaction can run.
            let opened = try await session.withUnlockedKey { key in
                try VaultCrypto.open(envelope, using: key)
            }
            guard opened.exactlyMatchesMoveManifest(item) else {
                throw VaultError.migrationConflict
            }
            _ = try await restoredPayload(for: opened)
            snapshot = next
            return item
        } catch {
            var mayRemoveAssets = !persistedEnvelope
            if persistedEnvelope {
                // Roll the item index back before removing its assets. If rollback itself fails,
                // retain every ciphertext file so a future relaunch can still authenticate the
                // persisted envelope; the ordinary source remains untouched either way.
                do {
                    try await store.save(snapshot)
                    mayRemoveAssets = true
                } catch {
                    mayRemoveAssets = false
                }
            }
            if mayRemoveAssets {
                for descriptor in written { try? await assetStore.remove(descriptor: descriptor) }
            }
            throw error
        }
    }

    public func replace(_ item: VaultItem) async throws {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }
        try await verifyKeyMatchesExistingCiphertext()
        guard let index = snapshot.envelopes.firstIndex(where: { $0.id == item.id }) else {
            throw VaultError.itemNotFound(item.id)
        }
        let currentEnvelope = snapshot.envelopes[index]
        let current = try await session.withUnlockedKey { key in
            try VaultCrypto.open(currentEnvelope, using: key)
        }
        guard current.assets == item.assets else { throw VaultError.invalidAssetManifest }
        try await verifyAssets(for: item)
        let envelope = try await session.withUnlockedKey { key in
            try VaultCrypto.seal(item, using: key)
        }
        var next = snapshot
        next.envelopes[index] = envelope
        try await store.save(next)
        snapshot = next
    }

    public func delete(id: UUID) async throws {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }
        try await verifyKeyMatchesExistingCiphertext()
        guard let index = snapshot.envelopes.firstIndex(where: { $0.id == id }) else {
            throw VaultError.itemNotFound(id)
        }
        // Deletion is a sensitive Vault mutation and requires a currently unlocked session. Open
        // the item first so its authenticated manifest, rather than clear envelope metadata,
        // determines which opaque ciphertext assets may be removed.
        let currentEnvelope = snapshot.envelopes[index]
        let item = try await session.withUnlockedKey { key in
            try VaultCrypto.open(currentEnvelope, using: key)
        }
        var next = snapshot
        next.envelopes.remove(at: index)
        try await store.save(next)
        snapshot = next
        for descriptor in item.assets { try? await assetStore.remove(descriptor: descriptor) }
    }

    public func restoredPayload(id: UUID) async throws -> VaultRestoredPayload {
        guard let envelope = snapshot.envelopes.first(where: { $0.id == id }) else {
            throw VaultError.itemNotFound(id)
        }
        let item = try await session.withUnlockedKey { key in
            try VaultCrypto.open(envelope, using: key)
        }
        return try await restoredPayload(for: item)
    }

    public func verifyAssets(for item: VaultItem) async throws {
        _ = try await restoredPayload(for: item)
    }

    private func restoredPayload(for item: VaultItem) async throws -> VaultRestoredPayload {
        _ = try Self.referencesByDescriptor(for: item)
        var restored: [VaultRestoredAsset] = []
        restored.reserveCapacity(item.assets.count)
        for descriptor in item.assets {
            let encrypted = try await assetStore.read(descriptor: descriptor)
            let plaintext = try await session.withUnlockedKey { key in
                try VaultAssetCrypto.open(
                    encrypted,
                    descriptor: descriptor,
                    itemID: item.id,
                    using: key
                )
            }
            restored.append(VaultRestoredAsset(descriptor: descriptor, data: plaintext))
        }
        return VaultRestoredPayload(
            content: item.content,
            sourceTypeIdentifiers: item.provenance?.pasteboardTypeIdentifiers ?? [],
            assets: restored
        )
    }

    private static func referencesByDescriptor(
        for item: VaultItem
    ) throws -> [VaultAssetDescriptor: ClipAssetReference] {
        let references = item.content.representations.referencedAssets.sorted {
            if $0.kind.rawValue != $1.kind.rawValue {
                return $0.kind.rawValue < $1.kind.rawValue
            }
            return $0.digest < $1.digest
        }
        let expected = try references.map {
            try VaultAssetDescriptor(itemID: item.id, reference: $0)
        }
        guard expected == item.assets else { throw VaultError.invalidAssetManifest }
        return Dictionary(uniqueKeysWithValues: zip(expected, references))
    }

    private func acquireMutationPermit() async {
        if !isMutationInProgress {
            isMutationInProgress = true
            return
        }
        await withCheckedContinuation { continuation in
            mutationWaiters.append(continuation)
        }
    }

    private func verifyKeyMatchesExistingCiphertext() async throws {
        guard let envelope = snapshot.envelopes.first else {
            // Even the first insertion requires an authenticated, prepared session.
            try await session.withUnlockedKey { _ in () }
            return
        }
        try await session.withUnlockedKey { key in
            _ = try VaultCrypto.open(envelope, using: key)
        }
    }

    private func releaseMutationPermit() {
        guard !mutationWaiters.isEmpty else {
            isMutationInProgress = false
            return
        }
        mutationWaiters.removeFirst().resume()
    }
}

extension VaultLibrary: VaultMigrationDestination {
    public func existingItem(id: UUID) async throws -> VaultItem? {
        guard let envelope = snapshot.envelopes.first(where: { $0.id == id }) else { return nil }
        return try await session.withUnlockedKey { key in
            try VaultCrypto.open(envelope, using: key)
        }
    }

    public func insertIfAbsent(_ item: VaultItem) async throws {
        guard !snapshot.envelopes.contains(where: { $0.id == item.id }) else { return }
        _ = try await add(item)
    }
}
