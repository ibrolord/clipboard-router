import Foundation

public actor VaultSession: VaultSessionKeyAccess {
    public static let defaultTimeout: TimeInterval = 5 * 60

    private let authenticator: any VaultAuthenticating
    private let keyProvider: any VaultKeyProviding
    private let timeout: TimeInterval
    private let now: @Sendable () -> Date
    private var keyData: Data?
    private var expiresAt: Date?
    /// Incremented by every unlock attempt and every lock. A suspended unlock may publish
    /// key material only while its captured generation is still current.
    private var unlockGeneration: UInt64 = 0
    private var keyCreationAllowed = false
    private var storeStatePrepared = false

    public init(
        authenticator: any VaultAuthenticating,
        keyProvider: any VaultKeyProviding,
        timeout: TimeInterval = VaultSession.defaultTimeout,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        precondition(timeout > 0)
        self.authenticator = authenticator
        self.keyProvider = keyProvider
        self.timeout = timeout
        self.now = now
    }

    public var isUnlocked: Bool {
        _ = lockIfExpired()
        return keyData != nil
    }

    public func prepareForStore(hasEncryptedItems: Bool) async {
        // Re-preparing against a different store invalidates any current session.
        lock()
        storeStatePrepared = true
        keyCreationAllowed = !hasEncryptedItems
    }

    public func unlock(reason: String = "Unlock your Clipboard Router vault") async throws {
        unlockGeneration &+= 1
        let generation = unlockGeneration
        do {
            guard storeStatePrepared else { throw VaultError.keyStateUnprepared }
            try await authenticator.authenticate(reason: reason)
            guard generation == unlockGeneration else { throw VaultError.locked }
            var loaded: Data
            if let existing = try await keyProvider.loadKey(authenticationReason: reason) {
                loaded = existing
            } else {
                guard keyCreationAllowed else { throw VaultError.missingKeyForExistingVault }
                loaded = try await keyProvider.createKey(authenticationReason: reason)
            }
            guard generation == unlockGeneration else {
                loaded.resetBytes(in: loaded.startIndex..<loaded.endIndex)
                throw VaultError.locked
            }
            guard loaded.count == VaultCrypto.keyByteCount else {
                throw VaultError.invalidKeyLength
            }
            // Once any key has been accepted, this session must never regenerate it. If the
            // Keychain item disappears later, the only safe outcome is explicit recovery/reset.
            keyCreationAllowed = false
            keyData = loaded
            expiresAt = now().addingTimeInterval(timeout)
        } catch let error as VaultError {
            if generation == unlockGeneration { lock() }
            throw error
        } catch {
            if generation == unlockGeneration { lock() }
            throw VaultError.authenticationFailed
        }
    }

    public func lock() {
        unlockGeneration &+= 1
        // Data is copy-on-write, so reliable process-memory zeroization cannot be promised.
        // Drop the session's reference; Crypto operations are synchronous and never retain it
        // across a caller-controlled suspension point.
        keyData = nil
        expiresAt = nil
    }

    /// Atomically verifies that the session has not reached its deadline and extends it.
    /// Call this immediately before an action that uses plaintext already held by the UI.
    public func authorizeActivity(at date: Date? = nil) throws {
        let currentDate = date ?? now()
        _ = lockIfExpired(at: currentDate)
        guard keyData != nil else { throw VaultError.locked }
        expiresAt = currentDate.addingTimeInterval(timeout)
    }

    public func noteActivity(at date: Date? = nil) throws {
        try authorizeActivity(at: date)
    }

    @discardableResult
    public func lockIfExpired(at date: Date? = nil) -> Bool {
        guard let expiresAt, (date ?? now()) >= expiresAt else { return false }
        lock()
        return true
    }

    public func handleLifecycleEvent(_ event: VaultLifecycleEvent) {
        switch event {
        case .appDidEnterBackground, .screenDidLock, .systemWillSleep, .appWillTerminate:
            lock()
        }
    }

    public func withUnlockedKey<T: Sendable>(
        _ operation: @Sendable (Data) throws -> T
    ) async throws -> T {
        _ = lockIfExpired()
        guard let keyData else { throw VaultError.locked }
        let generation = unlockGeneration
        // The operation is synchronous while this actor is isolated. Key bytes are never
        // handed across a caller-controlled suspension point.
        let result = try operation(keyData)
        guard generation == unlockGeneration, self.keyData != nil else {
            throw VaultError.locked
        }
        try noteActivity()
        return result
    }
}

/// Starts no hidden global work. The app owns its lifecycle and explicitly starts/stops polling.
public actor VaultAutoLockCoordinator {
    private let session: VaultSession
    private let pollingNanoseconds: UInt64
    private var task: Task<Void, Never>?

    public init(session: VaultSession, pollingInterval: TimeInterval = 1) {
        precondition(pollingInterval > 0)
        self.session = session
        self.pollingNanoseconds = UInt64(pollingInterval * 1_000_000_000)
    }

    public func start() {
        guard task == nil else { return }
        let session = session
        let interval = pollingNanoseconds
        task = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                _ = await session.lockIfExpired()
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    public func handleLifecycleEvent(_ event: VaultLifecycleEvent) async {
        await session.handleLifecycleEvent(event)
    }
}
