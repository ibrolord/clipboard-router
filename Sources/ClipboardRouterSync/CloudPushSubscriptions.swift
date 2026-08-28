import CloudKit
import CryptoKit
import Foundation

public enum CloudPushDatabaseScope: String, Codable, CaseIterable, Hashable, Sendable {
    case `private`
    case shared
}

public enum CloudPushEnvironment: String, Codable, Hashable, Sendable {
    case development
    case production
}

public enum CloudPushSubscriptionIdentifiers {
    public static func identifier(for scope: CloudPushDatabaseScope) -> String {
        switch scope {
        case .private: "com.clipboardrouter.cloudkit.database.private.v1"
        case .shared: "com.clipboardrouter.cloudkit.database.shared.v1"
        }
    }
}

public struct CloudPushInstallationContext: Codable, Equatable, Hashable, Sendable {
    public let containerIdentifier: String
    public let environment: CloudPushEnvironment
    public let accountFingerprint: String

    public init(
        containerIdentifier: String,
        environment: CloudPushEnvironment,
        accountFingerprint: String
    ) throws {
        let container = containerIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let account = accountFingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard container.hasPrefix("iCloud."), !account.isEmpty else {
            throw CloudPushSubscriptionError.configurationMissing
        }
        self.containerIdentifier = container
        self.environment = environment
        self.accountFingerprint = account
    }

    public var registryKey: String {
        "\(containerIdentifier)|\(environment.rawValue)|\(accountFingerprint)"
    }
}

public struct CloudPushInstallation: Codable, Equatable, Sendable {
    public let context: CloudPushInstallationContext
    public var installedScopes: Set<CloudPushDatabaseScope>
    public var lastVerifiedAt: Date?

    public init(
        context: CloudPushInstallationContext,
        installedScopes: Set<CloudPushDatabaseScope> = [],
        lastVerifiedAt: Date? = nil
    ) {
        self.context = context
        self.installedScopes = installedScopes
        self.lastVerifiedAt = lastVerifiedAt
    }
}

public struct CloudPushInstallationRegistry: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public var installations: [String: CloudPushInstallation]

    public init(installations: [String: CloudPushInstallation] = [:]) {
        schemaVersion = Self.currentSchemaVersion
        self.installations = installations
    }

    public func validated() throws -> CloudPushInstallationRegistry {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw CloudPushSubscriptionError.invalidPersistedState
        }
        for (key, installation) in installations {
            guard key == installation.context.registryKey,
                  installation.installedScopes.isSubset(of: Set(CloudPushDatabaseScope.allCases))
            else { throw CloudPushSubscriptionError.invalidPersistedState }
        }
        return self
    }
}

public enum CloudPushRemoteSubscription: Equatable, Sendable {
    case database(contentAvailable: Bool)
    case incompatible

    public var isValidSilentDatabaseSubscription: Bool {
        self == .database(contentAvailable: true)
    }
}

public protocol CloudPushSubscriptionClient: Sendable {
    func accountIdentity() async throws -> SyncAccountIdentity
    func subscription(
        id: String,
        in scope: CloudPushDatabaseScope
    ) async throws -> CloudPushRemoteSubscription?
    func saveSilentDatabaseSubscription(
        id: String,
        in scope: CloudPushDatabaseScope
    ) async throws
    func deleteSubscription(id: String, in scope: CloudPushDatabaseScope) async throws
}

public protocol CloudPushInstallationStateStore: Sendable {
    func load() async throws -> CloudPushInstallationRegistry
    func save(_ registry: CloudPushInstallationRegistry) async throws
}

public actor JSONFileCloudPushInstallationStateStore: CloudPushInstallationStateStore {
    public let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL) {
        self.fileURL = fileURL.standardizedFileURL
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        self.decoder = decoder
    }

    public func load() async throws -> CloudPushInstallationRegistry {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return CloudPushInstallationRegistry()
        }
        do {
            let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
            return try decoder.decode(CloudPushInstallationRegistry.self, from: data).validated()
        } catch let error as CloudPushSubscriptionError {
            throw error
        } catch {
            throw CloudPushSubscriptionError.invalidPersistedState
        }
    }

    public func save(_ registry: CloudPushInstallationRegistry) async throws {
        do {
            let checked = try registry.validated()
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try encoder.encode(checked).write(to: fileURL, options: .atomic)
        } catch let error as CloudPushSubscriptionError {
            throw error
        } catch {
            throw CloudPushSubscriptionError.persistenceFailure
        }
    }
}

public actor InMemoryCloudPushInstallationStateStore: CloudPushInstallationStateStore {
    private var registry: CloudPushInstallationRegistry
    private let loadError: CloudPushSubscriptionError?

    public init(
        registry: CloudPushInstallationRegistry = CloudPushInstallationRegistry(),
        loadError: CloudPushSubscriptionError? = nil
    ) {
        self.registry = registry
        self.loadError = loadError
    }

    public func load() async throws -> CloudPushInstallationRegistry {
        if let loadError { throw loadError }
        return registry
    }

    public func save(_ registry: CloudPushInstallationRegistry) async throws {
        self.registry = try registry.validated()
    }

    public func snapshot() -> CloudPushInstallationRegistry { registry }
}

public enum CloudPushInstallationIssue: Equatable, Sendable {
    case configurationMissing
    case noAccount
    case restrictedAccount
    case temporarilyUnavailable
    case couldNotDetermineAccount
    case offline
    case permissionDenied
    case quotaExceeded
    case persistenceFailure
    case cloudFailure(String)

    public var message: String {
        switch self {
        case .configurationMissing:
            "Cloud push refresh is unavailable because the signed CloudKit configuration is incomplete. Recovery polling remains active."
        case .noAccount:
            "Cloud push refresh is waiting for an iCloud account. Recovery polling remains active."
        case .restrictedAccount:
            "Cloud push refresh is unavailable for this restricted iCloud account. Recovery polling remains active."
        case .temporarilyUnavailable:
            "Cloud push refresh is temporarily unavailable. Recovery polling remains active."
        case .couldNotDetermineAccount:
            "Cloud push refresh could not verify the iCloud account. Recovery polling remains active."
        case .offline:
            "Cloud push refresh could not be verified while offline. Recovery polling remains active."
        case .permissionDenied:
            "Cloud push subscriptions were denied by CloudKit. Recovery polling remains active."
        case .quotaExceeded:
            "CloudKit rejected push subscriptions because an account limit was reached. Recovery polling remains active."
        case .persistenceFailure:
            "Cloud push installation state could not be saved. Recovery polling remains active."
        case let .cloudFailure(message):
            "Cloud push refresh is unavailable: \(message). Recovery polling remains active."
        }
    }
}

public enum CloudPushInstallationStatus: Equatable, Sendable {
    case notConfigured
    case installing
    case ready(lastVerifiedAt: Date, repairedScopes: Set<CloudPushDatabaseScope>)
    case unavailable(CloudPushInstallationIssue)
}

public struct CloudPushInstallationReport: Equatable, Sendable {
    public let status: CloudPushInstallationStatus

    public init(status: CloudPushInstallationStatus) {
        self.status = status
    }
}

public enum CloudPushSubscriptionError: Error, Equatable, Sendable {
    case configurationMissing
    case invalidPersistedState
    case persistenceFailure
    case accountUnavailable(SyncAccountState)
    case offline
    case permissionDenied
    case quotaExceeded
    case cloudFailure(String)
}

public actor CloudPushSubscriptionCoordinator {
    public nonisolated let containerIdentifier: String
    public nonisolated let environment: CloudPushEnvironment

    private let client: any CloudPushSubscriptionClient
    private let store: any CloudPushInstallationStateStore
    private let now: @Sendable () -> Date
    private var currentStatus: CloudPushInstallationStatus = .notConfigured

    public init(
        containerIdentifier: String,
        environment: CloudPushEnvironment,
        client: any CloudPushSubscriptionClient,
        store: any CloudPushInstallationStateStore,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.containerIdentifier = containerIdentifier
        self.environment = environment
        self.client = client
        self.store = store
        self.now = now
    }

    public func status() -> CloudPushInstallationStatus { currentStatus }

    @discardableResult
    public func install() async -> CloudPushInstallationReport {
        currentStatus = .installing
        do {
            let identity = try await client.accountIdentity()
            guard identity.state == .available, let fingerprint = identity.fingerprint else {
                throw CloudPushSubscriptionError.accountUnavailable(identity.state)
            }
            let context = try CloudPushInstallationContext(
                containerIdentifier: containerIdentifier,
                environment: environment,
                accountFingerprint: fingerprint
            )
            var repairedScopes: Set<CloudPushDatabaseScope> = []
            var registry: CloudPushInstallationRegistry
            do {
                registry = try await store.load().validated()
            } catch {
                // Subscription state contains no user content. Rebuild it from authoritative
                // server subscription state instead of disabling otherwise healthy sync.
                registry = CloudPushInstallationRegistry()
                repairedScopes.formUnion(CloudPushDatabaseScope.allCases)
            }
            var installation = registry.installations[context.registryKey]
                ?? CloudPushInstallation(context: context)

            for scope in CloudPushDatabaseScope.allCases {
                let id = CloudPushSubscriptionIdentifiers.identifier(for: scope)
                let remote = try await client.subscription(id: id, in: scope)
                if remote?.isValidSilentDatabaseSubscription != true {
                    if remote != nil {
                        try await client.deleteSubscription(id: id, in: scope)
                    }
                    if installation.installedScopes.contains(scope) || remote != nil {
                        repairedScopes.insert(scope)
                    }
                    try await client.saveSilentDatabaseSubscription(id: id, in: scope)
                }
                installation.installedScopes.insert(scope)
                installation.lastVerifiedAt = now()
                registry.installations[context.registryKey] = installation
                try await store.save(registry)
            }

            let verifiedAt = installation.lastVerifiedAt ?? now()
            currentStatus = .ready(
                lastVerifiedAt: verifiedAt,
                repairedScopes: repairedScopes
            )
        } catch {
            currentStatus = .unavailable(Self.issue(for: error))
        }
        return CloudPushInstallationReport(status: currentStatus)
    }

    private static func issue(for error: any Error) -> CloudPushInstallationIssue {
        guard let error = error as? CloudPushSubscriptionError else {
            return .cloudFailure(String(describing: error))
        }
        switch error {
        case .configurationMissing: return .configurationMissing
        case .invalidPersistedState, .persistenceFailure: return .persistenceFailure
        case let .accountUnavailable(state):
            switch state {
            case .noAccount: return .noAccount
            case .restricted: return .restrictedAccount
            case .temporarilyUnavailable: return .temporarilyUnavailable
            case .couldNotDetermine: return .couldNotDetermineAccount
            case .available: return .couldNotDetermineAccount
            }
        case .offline: return .offline
        case .permissionDenied: return .permissionDenied
        case .quotaExceeded: return .quotaExceeded
        case let .cloudFailure(message): return .cloudFailure(message)
        }
    }
}

public actor CloudKitPushSubscriptionClient: CloudPushSubscriptionClient {
    public let containerIdentifier: String
    private let container: CKContainer
    private let privateDatabase: CKDatabase
    private let sharedDatabase: CKDatabase

    public init(containerIdentifier: String) {
        self.containerIdentifier = containerIdentifier
        let container = CKContainer(identifier: containerIdentifier)
        self.container = container
        privateDatabase = container.privateCloudDatabase
        sharedDatabase = container.sharedCloudDatabase
    }

    public func accountIdentity() async throws -> SyncAccountIdentity {
        do {
            let status = try await container.accountStatus()
            switch status {
            case .available:
                let recordID = try await container.userRecordID()
                let fingerprint = SHA256.hash(data: Data(recordID.recordName.utf8))
                    .map { String(format: "%02x", $0) }
                    .joined()
                return SyncAccountIdentity(state: .available, fingerprint: fingerprint)
            case .noAccount: return SyncAccountIdentity(state: .noAccount, fingerprint: nil)
            case .restricted: return SyncAccountIdentity(state: .restricted, fingerprint: nil)
            case .couldNotDetermine:
                return SyncAccountIdentity(state: .couldNotDetermine, fingerprint: nil)
            case .temporarilyUnavailable:
                return SyncAccountIdentity(state: .temporarilyUnavailable, fingerprint: nil)
            @unknown default:
                return SyncAccountIdentity(state: .couldNotDetermine, fingerprint: nil)
            }
        } catch {
            throw Self.map(error)
        }
    }

    public func subscription(
        id: String,
        in scope: CloudPushDatabaseScope
    ) async throws -> CloudPushRemoteSubscription? {
        do {
            let subscription = try await database(for: scope).subscription(for: id)
            guard subscription is CKDatabaseSubscription else { return .incompatible }
            return .database(
                contentAvailable: subscription.notificationInfo?.shouldSendContentAvailable == true
            )
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        } catch {
            throw Self.map(error)
        }
    }

    public func saveSilentDatabaseSubscription(
        id: String,
        in scope: CloudPushDatabaseScope
    ) async throws {
        let subscription = CKDatabaseSubscription(subscriptionID: id)
        let notification = CKSubscription.NotificationInfo()
        notification.shouldSendContentAvailable = true
        subscription.notificationInfo = notification
        do {
            let saved = try await database(for: scope).save(subscription)
            guard saved is CKDatabaseSubscription,
                  saved.notificationInfo?.shouldSendContentAvailable == true
            else { throw CloudPushSubscriptionError.cloudFailure("CloudKit returned an incompatible subscription") }
        } catch {
            throw Self.map(error)
        }
    }

    public func deleteSubscription(id: String, in scope: CloudPushDatabaseScope) async throws {
        do {
            _ = try await database(for: scope).deleteSubscription(withID: id)
        } catch let error as CKError where error.code == .unknownItem {
            return
        } catch {
            throw Self.map(error)
        }
    }

    private func database(for scope: CloudPushDatabaseScope) -> CKDatabase {
        switch scope {
        case .private: privateDatabase
        case .shared: sharedDatabase
        }
    }

    private static func map(_ error: any Error) -> CloudPushSubscriptionError {
        if let error = error as? CloudPushSubscriptionError { return error }
        guard let error = error as? CKError else {
            return .cloudFailure(String(describing: error))
        }
        switch error.code {
        case .networkFailure, .networkUnavailable, .serviceUnavailable, .requestRateLimited:
            return .offline
        case .notAuthenticated:
            return .accountUnavailable(.noAccount)
        case .permissionFailure, .badContainer, .missingEntitlement:
            return .permissionDenied
        case .quotaExceeded, .limitExceeded:
            return .quotaExceeded
        default:
            return .cloudFailure(error.localizedDescription)
        }
    }
}

public struct CloudPushNotification: Equatable, Sendable {
    public let containerIdentifier: String?
    public let subscriptionID: String
    public let databaseScope: CloudPushDatabaseScope

    public init(
        containerIdentifier: String?,
        subscriptionID: String,
        databaseScope: CloudPushDatabaseScope
    ) {
        self.containerIdentifier = containerIdentifier
        self.subscriptionID = subscriptionID
        self.databaseScope = databaseScope
    }
}

public protocol CloudPushNotificationDecoding {
    func decode(_ userInfo: [AnyHashable: Any]) -> CloudPushNotification?
}

public struct CloudKitPushNotificationDecoder: CloudPushNotificationDecoding {
    public init() {}

    public func decode(_ userInfo: [AnyHashable: Any]) -> CloudPushNotification? {
        guard let notification = CKNotification(
            fromRemoteNotificationDictionary: userInfo
        ) as? CKDatabaseNotification,
              let subscriptionID = notification.subscriptionID
        else { return nil }
        let scope: CloudPushDatabaseScope
        switch notification.databaseScope {
        case .private: scope = .private
        case .shared: scope = .shared
        case .public: return nil
        @unknown default: return nil
        }
        return CloudPushNotification(
            containerIdentifier: notification.containerIdentifier,
            subscriptionID: subscriptionID,
            databaseScope: scope
        )
    }
}

public enum CloudPushNotificationRouter {
    public static func refreshScopes(
        for notification: CloudPushNotification,
        expectedContainerIdentifier: String
    ) -> Set<CloudPushDatabaseScope> {
        guard notification.containerIdentifier == expectedContainerIdentifier,
              notification.subscriptionID == CloudPushSubscriptionIdentifiers.identifier(
                for: notification.databaseScope
              )
        else { return [] }
        return [notification.databaseScope]
    }
}

public actor CloudPushRefreshCoalescer {
    public typealias Refresh = @Sendable (Set<CloudPushDatabaseScope>) async -> Void

    private let refresh: Refresh
    private var pendingScopes: Set<CloudPushDatabaseScope> = []
    private var isRefreshing = false

    public init(refresh: @escaping Refresh) {
        self.refresh = refresh
    }

    /// Concurrent notifications are hints, not change payloads. While a fetch is running, merge
    /// every newly delivered scope into one subsequent token-based refresh pass.
    public func requestRefresh(for scopes: Set<CloudPushDatabaseScope>) async {
        pendingScopes.formUnion(scopes)
        guard !pendingScopes.isEmpty, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        while !pendingScopes.isEmpty {
            let batch = pendingScopes
            pendingScopes.removeAll()
            await refresh(batch)
        }
    }
}
