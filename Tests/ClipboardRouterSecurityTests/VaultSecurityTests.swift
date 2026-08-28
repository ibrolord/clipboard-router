import ClipboardRouterCore
import Foundation
import AppKit
import XCTest
@testable import ClipboardRouterSecurity

final class VaultSecurityTests: XCTestCase {
    @MainActor
    func testSystemSecurePasteIsHostOnlyAndCarriesMonitorExclusionMarker() async throws {
        // The production writer runs inside an NSApplication. `withUniqueName()` also creates
        // and registers the isolated pasteboard; `NSPasteboard(name:)` only looks up an arbitrary
        // name and does not guarantee a writable pasteboard-server instance.
        _ = NSApplication.shared
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let writer = SystemSecurePasteboard(pasteboard: pasteboard)
        let marker = UUID().uuidString.lowercased()

        _ = try await writer.writeSecureString("decrypted vault text", marker: marker)

        XCTAssertEqual(pasteboard.string(forType: .string), "decrypted vault text")
        XCTAssertEqual(
            pasteboard.string(forType: SystemSecurePasteboard.markerType),
            marker
        )
        XCTAssertEqual(
            pasteboard.string(forType: SystemSecurePasteboard.appOriginType),
            "1"
        )
        XCTAssertEqual(
            SystemSecurePasteboard.appOriginType.rawValue,
            "com.clipboardrouter.clip-origin"
        )
        XCTAssertTrue(
            SystemSecurePasteboard.writingOptions.contains(.currentHostOnly),
            "Vault writes must never enter Universal Clipboard"
        )
    }

    func testAESGCMRoundTripAuthenticatesEnvelopeIdentityAndVersion() throws {
        let key = VaultCrypto.generateKeyData()
        let item = try makeItem(text: "confidential customer research")
        let envelope = try VaultCrypto.seal(item, using: key)

        XCTAssertEqual(try VaultCrypto.open(envelope, using: key), item)

        let changedID = VaultCiphertextEnvelope(
            id: UUID(),
            version: envelope.version,
            nonce: envelope.nonce,
            ciphertext: envelope.ciphertext,
            tag: envelope.tag
        )
        XCTAssertThrowsError(try VaultCrypto.open(changedID, using: key)) { error in
            XCTAssertEqual(error as? VaultError, .invalidEnvelope)
        }

        let changedVersion = VaultCiphertextEnvelope(
            id: envelope.id,
            version: envelope.version + 1,
            nonce: envelope.nonce,
            ciphertext: envelope.ciphertext,
            tag: envelope.tag
        )
        XCTAssertThrowsError(try VaultCrypto.open(changedVersion, using: key)) { error in
            XCTAssertEqual(
                error as? VaultError,
                .unsupportedEnvelopeVersion(VaultCiphertextEnvelope.currentVersion + 1)
            )
        }
    }

    func testVaultItemRejectsNonTextTypesAndEveryExternalRepresentation() throws {
        let digest = String(repeating: "a", count: 64)
        let asset = try ClipAssetReference(
            digest: digest,
            kind: .richText,
            uniformTypeIdentifier: "public.rtf",
            byteCount: 10,
            relativePath: "\(digest).rtf"
        )
        let file = try ClipFileReference(url: URL(fileURLWithPath: "/tmp/private.txt"))
        let rejected = [
            try ClipContent(type: .image, text: "Image placeholder"),
            try ClipContent(
                type: .plainText,
                text: "Fallback",
                representations: ClipRepresentations(richText: asset)
            ),
            try ClipContent(
                type: .plainText,
                text: "Fallback",
                representations: ClipRepresentations(files: [file])
            ),
            try ClipContent(
                type: .url,
                text: "Local file URL",
                representations: ClipRepresentations(
                    url: URLClipMetadata(originalURL: "file:///tmp/private.txt")
                )
            ),
            try ClipContent(type: .url, text: "file:///tmp/private.txt"),
        ]

        for content in rejected {
            XCTAssertThrowsError(try VaultItem(name: "Rejected", content: content)) { error in
                XCTAssertEqual(error as? VaultError, .unsupportedExternalRepresentations)
            }
        }

        let validURL = try ClipContent.detect(text: "https://example.com/research")
        XCTAssertNoThrow(try VaultItem(name: "URL", content: validURL))
    }

    func testVaultItemDecodeCannotBypassContentValidation() throws {
        let invalidContent = try ClipContent(type: .image, text: "Image placeholder")
        let wire = UnsafeVaultItemWire(
            id: UUID(),
            name: "Invalid legacy item",
            content: invalidContent,
            createdAt: Date(timeIntervalSince1970: 1),
            modifiedAt: Date(timeIntervalSince1970: 2)
        )

        XCTAssertThrowsError(try JSONDecoder().decode(VaultItem.self, from: JSONEncoder().encode(wire))) {
            error in
            XCTAssertEqual(error as? VaultError, .unsupportedExternalRepresentations)
        }
    }

    func testVaultItemProvenanceRoundTripsAndLegacyPayloadDecodesWithoutIt() throws {
        let date = Date(timeIntervalSince1970: 12_345)
        let historyID = UUID()
        let savedID = UUID()
        let content = try ClipContent.detect(text: "encrypted provenance")
        let provenance = VaultItemProvenance(
            ordinaryOrigin: .saved,
            sourceHistoryItemID: historyID,
            sourceSavedClipID: savedID,
            linkedSavedClipIDs: [savedID],
            sourceApplicationBundleIdentifier: "com.example.source",
            originatingDeviceIdentifier: "device-a",
            originallyCapturedAt: date,
            pasteboardTypeIdentifiers: ["public.utf8-plain-text"]
        )
        let item = try VaultItem(
            id: savedID,
            name: "Protected",
            content: content,
            createdAt: date,
            modifiedAt: date,
            provenance: provenance
        )
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let decoded = try decoder.decode(VaultItem.self, from: encoder.encode(item))

        XCTAssertEqual(decoded, item)
        XCTAssertEqual(decoded.provenance, provenance)

        let legacyWire = UnsafeVaultItemWire(
            id: savedID,
            name: "Legacy",
            content: content,
            createdAt: date,
            modifiedAt: date
        )
        let legacy = try decoder.decode(VaultItem.self, from: encoder.encode(legacyWire))
        XCTAssertNil(legacy.provenance)
        XCTAssertEqual(legacy.kind, .clip)
    }

    func testPlainTextAndURLNotesRoundTripInsideAuthenticatedCiphertext() throws {
        let key = VaultCrypto.generateKeyData()
        for content in [
            try ClipContent(type: .plainText, text: "editable note"),
            try ClipContent.detect(text: "https://example.com/note"),
        ] {
            let date = Date(timeIntervalSince1970: 12_345)
            let note = try VaultItem(
                kind: .note,
                name: "Note",
                content: content,
                createdAt: date,
                modifiedAt: date
            )
            let envelope = try VaultCrypto.seal(note, using: key)
            XCTAssertEqual(try VaultCrypto.open(envelope, using: key), note)
            XCTAssertEqual(try VaultCrypto.open(envelope, using: key).kind, .note)
            let envelopeJSON = String(decoding: try JSONEncoder().encode(envelope), as: UTF8.self)
            XCTAssertFalse(envelopeJSON.contains("note"))
            XCTAssertFalse(envelopeJSON.contains("editable note"))
        }
    }

    func testNotesUseSameFailClosedContentEligibilityAsClips() throws {
        let external = try ClipFileReference(url: URL(fileURLWithPath: "/tmp/secret.txt"))
        let content = try ClipContent(
            type: .plainText,
            text: "fallback",
            representations: ClipRepresentations(files: [external])
        )
        XCTAssertThrowsError(try VaultItem(kind: .note, name: "Unsafe", content: content)) {
            XCTAssertEqual($0 as? VaultError, .unsupportedExternalRepresentations)
        }
    }

    func testCiphertextAndTagTamperingAreRejected() throws {
        let key = VaultCrypto.generateKeyData()
        let envelope = try VaultCrypto.seal(makeItem(text: "secret"), using: key)
        var changedCiphertext = envelope.ciphertext
        changedCiphertext[changedCiphertext.startIndex] ^= 0x01
        let cipherTampered = VaultCiphertextEnvelope(
            id: envelope.id,
            version: envelope.version,
            nonce: envelope.nonce,
            ciphertext: changedCiphertext,
            tag: envelope.tag
        )
        XCTAssertThrowsError(try VaultCrypto.open(cipherTampered, using: key))

        var changedTag = envelope.tag
        changedTag[changedTag.startIndex] ^= 0x01
        let tagTampered = VaultCiphertextEnvelope(
            id: envelope.id,
            version: envelope.version,
            nonce: envelope.nonce,
            ciphertext: envelope.ciphertext,
            tag: changedTag
        )
        XCTAssertThrowsError(try VaultCrypto.open(tagTampered, using: key))
    }

    func testAuthenticationFailureNeverLoadsKeyAndSessionExpires() async throws {
        let authenticator = StubVaultAuthenticator(shouldSucceed: false)
        let keyProvider = InMemoryVaultKeyProvider()
        let start = Date(timeIntervalSince1970: 10_000)
        let session = VaultSession(
            authenticator: authenticator,
            keyProvider: keyProvider,
            timeout: 300,
            now: { start }
        )
        await session.prepareForStore(hasEncryptedItems: false)

        await XCTAssertThrowsErrorAsync(try await session.unlock()) { error in
            XCTAssertEqual(error as? VaultError, .authenticationFailed)
        }
        let lockedAfterFailure = await session.isUnlocked
        let loadCountAfterFailure = await keyProvider.loadCount
        XCTAssertFalse(lockedAfterFailure)
        XCTAssertEqual(loadCountAfterFailure, 0)

        await authenticator.setShouldSucceed(true)
        try await session.unlock()
        let unlocked = await session.isUnlocked
        let beforeDeadline = await session.lockIfExpired(at: start.addingTimeInterval(299.9))
        let atDeadline = await session.lockIfExpired(at: start.addingTimeInterval(300))
        let lockedAfterDeadline = await session.isUnlocked
        XCTAssertTrue(unlocked)
        XCTAssertFalse(beforeDeadline)
        XCTAssertTrue(atDeadline)
        XCTAssertFalse(lockedAfterDeadline)
    }

    func testActivityAuthorizationFailsClosedAtDeadlineWithoutPolling() async throws {
        let start = Date(timeIntervalSince1970: 20_000)
        let session = VaultSession(
            authenticator: StubVaultAuthenticator(),
            keyProvider: InMemoryVaultKeyProvider(),
            timeout: 300,
            now: { start }
        )
        await session.prepareForStore(hasEncryptedItems: false)
        try await session.unlock()

        await XCTAssertThrowsErrorAsync(
            try await session.authorizeActivity(at: start.addingTimeInterval(300))
        ) { error in
            XCTAssertEqual(error as? VaultError, .locked)
        }
        let remainsUnlocked = await session.isUnlocked
        XCTAssertFalse(remainsUnlocked)
    }

    func testEverySensitiveLifecycleEventLocksImmediately() async throws {
        for event in [
            VaultLifecycleEvent.appDidEnterBackground,
            .screenDidLock,
            .systemWillSleep,
            .appWillTerminate,
        ] {
            let session = VaultSession(
                authenticator: StubVaultAuthenticator(),
                keyProvider: InMemoryVaultKeyProvider()
            )
            await session.prepareForStore(hasEncryptedItems: false)
            try await session.unlock()
            await session.handleLifecycleEvent(event)
            let remainsUnlocked = await session.isUnlocked
            XCTAssertFalse(remainsUnlocked)
        }
    }

    func testVaultStoreContainsNoPlaintextAndCannotReadWhileLocked() async throws {
        let store = InMemoryVaultStore()
        let session = VaultSession(
            authenticator: StubVaultAuthenticator(),
            keyProvider: InMemoryVaultKeyProvider()
        )
        let library = try await VaultLibrary.open(store: store, session: session)
        let secret = "acquisition target: Northwind"
        let item = try makeItem(text: secret)

        await XCTAssertThrowsErrorAsync(try await library.add(item)) { error in
            XCTAssertEqual(error as? VaultError, .locked)
        }
        try await session.unlock()
        try await library.add(item)
        let encodedStore = try JSONEncoder().encode(await library.encryptedSnapshot())
        let decryptedItems = try await library.items()
        XCTAssertNil(String(data: encodedStore, encoding: .utf8)?.range(of: secret))
        XCTAssertEqual(decryptedItems, [item])

        await session.lock()
        await XCTAssertThrowsErrorAsync(try await library.items()) { error in
            XCTAssertEqual(error as? VaultError, .locked)
        }
    }

    func testSecurePasteClearsOnlyOwnedGenerationAndMarker() async throws {
        let pasteboard = InMemorySecurePasteboard(generation: 40)
        let controller = SecurePasteController(pasteboard: pasteboard, clearDelay: 10_000)
        let receipt = try await controller.copy("vault value")
        XCTAssertEqual(receipt.generation, 41)
        let didClearOwned = await controller.clearIfStillOwned(receipt)
        let textAfterOwnedClear = await pasteboard.text
        XCTAssertTrue(didClearOwned)
        XCTAssertNil(textAfterOwnedClear)

        let stale = try await controller.copy("new vault value")
        await pasteboard.simulateExternalCopy("user copied this")
        let didClearExternal = await controller.clearIfStillOwned(stale)
        let externalText = await pasteboard.text
        XCTAssertFalse(didClearExternal)
        XCTAssertEqual(externalText, "user copied this")

        let wrongMarker = try await controller.copy("third value")
        await pasteboard.setMarkerForTesting("not-the-receipt")
        let didClearWrongMarker = await controller.clearIfStillOwned(wrongMarker)
        let wrongMarkerText = await pasteboard.text
        let pendingCount = await controller.pendingClearCount()
        XCTAssertFalse(didClearWrongMarker)
        XCTAssertEqual(wrongMarkerText, "third value")
        XCTAssertEqual(pendingCount, 0, "Completed stale timers must not leak task entries")
        await controller.cancelPendingClears()
    }

    func testLockDuringAuthenticationInvalidatesSuspendedUnlock() async throws {
        let entered = AsyncTestGate()
        let release = AsyncTestGate()
        let session = VaultSession(
            authenticator: GatedAuthenticator(entered: entered, release: release),
            keyProvider: InMemoryVaultKeyProvider(key: VaultCrypto.generateKeyData())
        )
        await session.prepareForStore(hasEncryptedItems: true)

        let unlock = Task { try await session.unlock() }
        let authenticationStarted = await waitForGate(entered)
        XCTAssertTrue(authenticationStarted, "Authenticator did not suspend in time")
        await session.handleLifecycleEvent(.screenDidLock)
        await release.open()
        await XCTAssertThrowsErrorAsync(try await unlock.value) { error in
            XCTAssertEqual(error as? VaultError, .locked)
        }
        let isUnlocked = await session.isUnlockedValue()
        XCTAssertFalse(isUnlocked)
    }

    func testLockDuringKeyLoadInvalidatesSuspendedUnlock() async throws {
        let entered = AsyncTestGate()
        let release = AsyncTestGate()
        let provider = GatedKeyProvider(
            key: VaultCrypto.generateKeyData(),
            entered: entered,
            release: release
        )
        let session = VaultSession(
            authenticator: StubVaultAuthenticator(),
            keyProvider: provider
        )
        await session.prepareForStore(hasEncryptedItems: true)

        let unlock = Task { try await session.unlock() }
        let keyLoadStarted = await waitForGate(entered)
        XCTAssertTrue(keyLoadStarted, "Key provider did not suspend in time")
        await session.handleLifecycleEvent(.systemWillSleep)
        await release.open()
        await XCTAssertThrowsErrorAsync(try await unlock.value) { error in
            XCTAssertEqual(error as? VaultError, .locked)
        }
        let isUnlocked = await session.isUnlockedValue()
        XCTAssertFalse(isUnlocked)
    }

    func testConcurrentVaultMutationsDoNotLoseUnrelatedChanges() async throws {
        let session = VaultSession(
            authenticator: StubVaultAuthenticator(),
            keyProvider: InMemoryVaultKeyProvider()
        )
        let library = try await VaultLibrary.open(store: InMemoryVaultStore(), session: session)
        try await session.unlock()

        let items = try (0..<30).map { try makeItem(text: "parallel-\($0)") }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for item in items {
                group.addTask { _ = try await library.add(item) }
            }
            try await group.waitForAll()
        }
        let parallelItemIDs = Set(try await library.items().map(\.id))
        XCTAssertEqual(parallelItemIDs, Set(items.map(\.id)))

        let first = items[0]
        let second = items[1]
        let replacement = try VaultItem(
            id: first.id,
            name: "Replaced",
            content: ClipContent(type: .plainText, text: "replacement"),
            createdAt: first.createdAt,
            modifiedAt: first.modifiedAt.addingTimeInterval(1)
        )
        let added = try makeItem(text: "concurrent-add")
        async let replace: Void = library.replace(replacement)
        async let delete: Void = library.delete(id: second.id)
        async let add: VaultItem = library.add(added)
        _ = try await (replace, delete, add)

        let final = try await library.items()
        XCTAssertEqual(final.first(where: { $0.id == first.id }), replacement)
        XCTAssertFalse(final.contains(where: { $0.id == second.id }))
        XCTAssertTrue(final.contains(where: { $0.id == added.id }))
    }

    func testVaultDeleteRequiresUnlockedSession() async throws {
        let session = VaultSession(
            authenticator: StubVaultAuthenticator(),
            keyProvider: InMemoryVaultKeyProvider()
        )
        let library = try await VaultLibrary.open(store: InMemoryVaultStore(), session: session)
        try await session.unlock()
        let item = try makeItem(text: "must authenticate to delete")
        _ = try await library.add(item)
        await session.lock()

        await XCTAssertThrowsErrorAsync(try await library.delete(id: item.id)) { error in
            XCTAssertEqual(error as? VaultError, .locked)
        }
        let remainingIDs = await library.encryptedSnapshot().envelopes.map(\.id)
        XCTAssertEqual(remainingIDs, [item.id])
    }

    func testMissingOrMismatchedKeyForExistingCiphertextFailsClosed() async throws {
        let correctKey = VaultCrypto.generateKeyData()
        let existing = try makeItem(text: "irreplaceable")
        let encrypted = try VaultCrypto.seal(existing, using: correctKey)
        let original = VaultStoreSnapshot(envelopes: [encrypted])

        let missingSession = VaultSession(
            authenticator: StubVaultAuthenticator(),
            keyProvider: InMemoryVaultKeyProvider(key: nil)
        )
        let missingStore = InMemoryVaultStore(snapshot: original)
        _ = try await VaultLibrary.open(store: missingStore, session: missingSession)
        await XCTAssertThrowsErrorAsync(try await missingSession.unlock()) { error in
            XCTAssertEqual(error as? VaultError, .missingKeyForExistingVault)
        }
        let missingSnapshot = try await missingStore.load()
        XCTAssertEqual(missingSnapshot, original)

        let wrongSession = VaultSession(
            authenticator: StubVaultAuthenticator(),
            keyProvider: InMemoryVaultKeyProvider(key: VaultCrypto.generateKeyData())
        )
        let wrongStore = InMemoryVaultStore(snapshot: original)
        let wrongLibrary = try await VaultLibrary.open(store: wrongStore, session: wrongSession)
        try await wrongSession.unlock()
        await XCTAssertThrowsErrorAsync(try await wrongLibrary.add(makeItem(text: "must not mix keys"))) { error in
            XCTAssertEqual(error as? VaultError, .invalidEnvelope)
        }
        let wrongSnapshot = try await wrongStore.load()
        XCTAssertEqual(wrongSnapshot, original)

        let initiallyEmptyProvider = InMemoryVaultKeyProvider()
        let initiallyEmptySession = VaultSession(
            authenticator: StubVaultAuthenticator(),
            keyProvider: initiallyEmptyProvider
        )
        let initiallyEmptyLibrary = try await VaultLibrary.open(
            store: InMemoryVaultStore(),
            session: initiallyEmptySession
        )
        try await initiallyEmptySession.unlock()
        _ = try await initiallyEmptyLibrary.add(makeItem(text: "key now protects ciphertext"))
        await initiallyEmptySession.lock()
        try await initiallyEmptyProvider.deleteKey()
        await XCTAssertThrowsErrorAsync(try await initiallyEmptySession.unlock()) { error in
            XCTAssertEqual(error as? VaultError, .missingKeyForExistingVault)
        }
    }

    func testMigrationJournalResumesWithoutDuplicatingEncryptedItem() async throws {
        let item = try makeItem(text: "migrate exactly once")
        let source = TestMigrationSource(items: [item])
        let destination = TestMigrationDestination()
        let journalStore = InMemoryVaultMigrationJournalStore()
        let coordinator = VaultMigrationCoordinator(
            journalStore: journalStore,
            source: source,
            destination: destination,
            now: { Date(timeIntervalSince1970: 99) }
        )

        let first = try await coordinator.run(migrationID: "plain-to-vault-v1", fromVersion: 0, toVersion: 1)
        let second = try await coordinator.run(migrationID: "plain-to-vault-v1", fromVersion: 0, toVersion: 1)

        XCTAssertEqual(first.entries.map(\.stage), [.sourceRemoved])
        XCTAssertEqual(second.entries.map(\.stage), [.sourceRemoved])
        let insertCount = await destination.insertCount
        let removeCount = await source.removeCount
        let itemIDs = await destination.itemIDs
        XCTAssertEqual(insertCount, 1)
        XCTAssertEqual(removeCount, 1)
        XCTAssertEqual(itemIDs, [item.id])
    }

    func testMigrationEncryptedStageRevalidatesDestinationBeforeRemovingSource() async throws {
        let item = try makeItem(text: "plaintext remains until verified")
        let encryptedJournal = VaultMigrationJournal(
            migrationID: "resume",
            fromVersion: 0,
            toVersion: 1,
            entries: [VaultMigrationEntry(id: item.id, stage: .encrypted)]
        )

        let matchingSource = TestMigrationSource(items: [item])
        let matchingDestination = TestMigrationDestination(items: [item])
        let matching = VaultMigrationCoordinator(
            journalStore: InMemoryVaultMigrationJournalStore(journal: encryptedJournal),
            source: matchingSource,
            destination: matchingDestination
        )
        _ = try await matching.run(migrationID: "resume", fromVersion: 0, toVersion: 1)
        let matchingRemoveCount = await matchingSource.removeCountValue()
        XCTAssertEqual(matchingRemoveCount, 1)

        let mismatched = try VaultItem(
            id: item.id,
            name: item.name,
            content: ClipContent(type: .plainText, text: "different ciphertext payload"),
            createdAt: item.createdAt
        )
        let badSource = TestMigrationSource(items: [item])
        let bad = VaultMigrationCoordinator(
            journalStore: InMemoryVaultMigrationJournalStore(journal: encryptedJournal),
            source: badSource,
            destination: TestMigrationDestination(items: [mismatched])
        )
        await XCTAssertThrowsErrorAsync(
            try await bad.run(migrationID: "resume", fromVersion: 0, toVersion: 1)
        ) { error in
            XCTAssertEqual(error as? VaultError, .migrationConflict)
        }
        let badRemoveCount = await badSource.removeCountValue()
        XCTAssertEqual(badRemoveCount, 0)
    }

    func testMigrationRejectsDuplicateSourceIDsWithoutTrap() async throws {
        let item = try makeItem(text: "duplicate")
        let coordinator = VaultMigrationCoordinator(
            journalStore: InMemoryVaultMigrationJournalStore(),
            source: TestMigrationSource(items: [item, item]),
            destination: TestMigrationDestination()
        )
        await XCTAssertThrowsErrorAsync(
            try await coordinator.run(migrationID: "duplicates", fromVersion: 0, toVersion: 1)
        ) { error in
            XCTAssertEqual(error as? VaultError, .duplicateItem(item.id))
        }
    }

    private func makeItem(text: String) throws -> VaultItem {
        try VaultItem(
            name: "Protected",
            content: ClipContent(type: .plainText, text: text),
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
    }
}

private struct UnsafeVaultItemWire: Encodable {
    let id: UUID
    let name: String
    let content: ClipContent
    let createdAt: Date
    let modifiedAt: Date
}

private actor TestMigrationSource: VaultMigrationSource {
    private var items: [VaultItem]
    private(set) var removeCount = 0

    init(items: [VaultItem]) {
        self.items = items
    }

    func candidates() async throws -> [VaultItem] {
        items.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    func removeCandidate(id: UUID) async throws {
        if let index = items.firstIndex(where: { $0.id == id }) {
            items.remove(at: index)
            removeCount += 1
        }
    }

    func removeCountValue() -> Int { removeCount }
}

private actor TestMigrationDestination: VaultMigrationDestination {
    private var items: [UUID: VaultItem] = [:]
    private(set) var insertCount = 0

    init(items: [VaultItem] = []) {
        self.items = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
    }

    var itemIDs: [UUID] { items.keys.sorted { $0.uuidString < $1.uuidString } }
    func existingItem(id: UUID) async throws -> VaultItem? { items[id] }
    func insertIfAbsent(_ item: VaultItem) async throws {
        guard items[item.id] == nil else { return }
        items[item.id] = item
        insertCount += 1
    }
}

private actor AsyncTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let continuations = waiters
        waiters.removeAll()
        continuations.forEach { $0.resume() }
    }

    func isOpenValue() -> Bool { isOpen }
}

private actor GatedAuthenticator: VaultAuthenticating {
    let entered: AsyncTestGate
    let release: AsyncTestGate
    init(entered: AsyncTestGate, release: AsyncTestGate) {
        self.entered = entered
        self.release = release
    }
    func authenticate(reason: String) async throws {
        await entered.open()
        await release.wait()
    }
}

private actor GatedKeyProvider: VaultKeyProviding {
    let key: Data
    let entered: AsyncTestGate
    let release: AsyncTestGate
    init(key: Data, entered: AsyncTestGate, release: AsyncTestGate) {
        self.key = key
        self.entered = entered
        self.release = release
    }
    func loadKey(authenticationReason: String) async throws -> Data? {
        await entered.open()
        await release.wait()
        return key
    }
    func createKey(authenticationReason: String) async throws -> Data { key }
    func deleteKey() async throws {}
}

private extension VaultSession {
    func isUnlockedValue() -> Bool { isUnlocked }
}

private func waitForGate(_ gate: AsyncTestGate) async -> Bool {
    for _ in 0..<200 {
        if await gate.isOpenValue() { return true }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(2))
    }
    return await gate.isOpenValue()
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (any Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw")
    } catch {
        errorHandler(error)
    }
}
