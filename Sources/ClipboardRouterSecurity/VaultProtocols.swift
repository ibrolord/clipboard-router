import Foundation

public protocol VaultAuthenticating: Sendable {
    func authenticate(reason: String) async throws
}

public protocol VaultKeyProviding: Sendable {
    /// Returns the raw 256-bit key after provider-level access control, or nil if absent.
    func loadKey(authenticationReason: String) async throws -> Data?
    /// Creates a key. Callers must first prove that the encrypted store is empty.
    func createKey(authenticationReason: String) async throws -> Data
    func deleteKey() async throws
}

public protocol VaultStore: Sendable {
    func load() async throws -> VaultStoreSnapshot
    func save(_ snapshot: VaultStoreSnapshot) async throws
}

public protocol VaultSessionKeyAccess: Sendable {
    /// Production sessions use this to forbid silent key regeneration for a nonempty store.
    func prepareForStore(hasEncryptedItems: Bool) async
    func withUnlockedKey<T: Sendable>(
        _ operation: @Sendable (Data) throws -> T
    ) async throws -> T
}
