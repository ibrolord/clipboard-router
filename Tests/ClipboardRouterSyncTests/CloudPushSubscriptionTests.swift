import ClipboardRouterSync
import Foundation
import XCTest

final class CloudPushSubscriptionTests: XCTestCase {
    func testInstallCreatesSilentPrivateAndSharedSubscriptions() async throws {
        let client = FakeCloudPushSubscriptionClient(accountFingerprint: "account-a")
        let store = InMemoryCloudPushInstallationStateStore()
        let coordinator = makeCoordinator(client: client, store: store)

        let report = await coordinator.install()

        let snapshot = await client.snapshot()
        XCTAssertEqual(
            InstallationResult(report: report, client: snapshot),
            InstallationResult(
                report: CloudPushInstallationReport(
                    status: .ready(
                        lastVerifiedAt: referenceDate,
                        repairedScopes: []
                    )
                ),
                client: FakeClientSnapshot(
                    subscriptions: [
                        "account-a|private": .database(contentAvailable: true),
                        "account-a|shared": .database(contentAvailable: true),
                    ],
                    saves: ["account-a|private", "account-a|shared"],
                    deletes: []
                )
            )
        )
    }

    func testSecondInstallVerifiesServerWithoutSavingDuplicates() async throws {
        let client = FakeCloudPushSubscriptionClient(accountFingerprint: "account-a")
        let coordinator = makeCoordinator(
            client: client,
            store: InMemoryCloudPushInstallationStateStore()
        )

        _ = await coordinator.install()
        _ = await coordinator.install()

        let saveCount = await client.snapshot().saves.count
        XCTAssertEqual(saveCount, 2)
    }

    func testMissingServerSubscriptionRepairsPersistedInstallation() async throws {
        let context = try CloudPushInstallationContext(
            containerIdentifier: containerIdentifier,
            environment: .development,
            accountFingerprint: "account-a"
        )
        let persisted = CloudPushInstallation(
            context: context,
            installedScopes: Set(CloudPushDatabaseScope.allCases),
            lastVerifiedAt: referenceDate.addingTimeInterval(-60)
        )
        let store = InMemoryCloudPushInstallationStateStore(
            registry: CloudPushInstallationRegistry(
                installations: [context.registryKey: persisted]
            )
        )
        let client = FakeCloudPushSubscriptionClient(accountFingerprint: "account-a")
        let coordinator = makeCoordinator(client: client, store: store)

        let report = await coordinator.install()

        XCTAssertEqual(
            report.status,
            .ready(
                lastVerifiedAt: referenceDate,
                repairedScopes: Set(CloudPushDatabaseScope.allCases)
            )
        )
    }

    func testIncompatibleServerSubscriptionsAreDeletedBeforeReplacement() async throws {
        let client = FakeCloudPushSubscriptionClient(
            accountFingerprint: "account-a",
            subscriptions: [
                "account-a|private": .incompatible,
                "account-a|shared": .database(contentAvailable: false),
            ]
        )
        let coordinator = makeCoordinator(
            client: client,
            store: InMemoryCloudPushInstallationStateStore()
        )

        let report = await coordinator.install()
        let clientSnapshot = await client.snapshot()

        XCTAssertEqual(
            RepairResult(report: report, client: clientSnapshot),
            RepairResult(
                report: CloudPushInstallationReport(
                    status: .ready(
                        lastVerifiedAt: referenceDate,
                        repairedScopes: Set(CloudPushDatabaseScope.allCases)
                    )
                ),
                client: FakeClientSnapshot(
                    subscriptions: [
                        "account-a|private": .database(contentAvailable: true),
                        "account-a|shared": .database(contentAvailable: true),
                    ],
                    saves: ["account-a|private", "account-a|shared"],
                    deletes: ["account-a|private", "account-a|shared"]
                )
            )
        )
    }

    func testAccountChangeKeepsSeparatePersistedInstallations() async throws {
        let client = FakeCloudPushSubscriptionClient(accountFingerprint: "account-a")
        let store = InMemoryCloudPushInstallationStateStore()
        let coordinator = makeCoordinator(client: client, store: store)

        _ = await coordinator.install()
        await client.setAccountFingerprint("account-b")
        _ = await coordinator.install()

        let installationCount = await store.snapshot().installations.count
        XCTAssertEqual(installationCount, 2)
    }

    func testInstallationStateIsSeparatedByContainerEnvironmentAndAccount() async throws {
        let store = InMemoryCloudPushInstallationStateStore()
        let development = CloudPushSubscriptionCoordinator(
            containerIdentifier: containerIdentifier,
            environment: .development,
            client: FakeCloudPushSubscriptionClient(accountFingerprint: "account-a"),
            store: store,
            now: { referenceDate }
        )
        let production = CloudPushSubscriptionCoordinator(
            containerIdentifier: containerIdentifier,
            environment: .production,
            client: FakeCloudPushSubscriptionClient(accountFingerprint: "account-a"),
            store: store,
            now: { referenceDate }
        )
        let otherContainer = CloudPushSubscriptionCoordinator(
            containerIdentifier: "iCloud.com.example.OtherClipboardRouter",
            environment: .development,
            client: FakeCloudPushSubscriptionClient(accountFingerprint: "account-b"),
            store: store,
            now: { referenceDate }
        )

        _ = await development.install()
        _ = await production.install()
        _ = await otherContainer.install()
        let keys = Set(await store.snapshot().installations.keys)

        XCTAssertEqual(
            keys,
            [
                "\(containerIdentifier)|development|account-a",
                "\(containerIdentifier)|production|account-a",
                "iCloud.com.example.OtherClipboardRouter|development|account-b",
            ]
        )
    }

    func testCorruptLocalRegistryIsRebuiltFromServerState() async throws {
        let client = FakeCloudPushSubscriptionClient(
            accountFingerprint: "account-a",
            subscriptions: [
                "account-a|private": .database(contentAvailable: true),
                "account-a|shared": .database(contentAvailable: true),
            ]
        )
        let store = InMemoryCloudPushInstallationStateStore(
            loadError: .invalidPersistedState
        )
        let coordinator = makeCoordinator(client: client, store: store)

        let report = await coordinator.install()

        XCTAssertEqual(
            report.status,
            .ready(
                lastVerifiedAt: referenceDate,
                repairedScopes: Set(CloudPushDatabaseScope.allCases)
            )
        )
    }

    func testOfflineInstallReportsPollingRecoveryState() async throws {
        let client = FakeCloudPushSubscriptionClient(
            accountFingerprint: "account-a",
            error: .offline
        )
        let coordinator = makeCoordinator(
            client: client,
            store: InMemoryCloudPushInstallationStateStore()
        )

        let report = await coordinator.install()

        XCTAssertEqual(report.status, .unavailable(.offline))
    }

    func testNotificationRouterAcceptsOnlyMatchingContainerScopeAndIdentifier() {
        let valid = CloudPushNotification(
            containerIdentifier: containerIdentifier,
            subscriptionID: CloudPushSubscriptionIdentifiers.identifier(for: .private),
            databaseScope: .private
        )
        let wrongContainer = CloudPushNotification(
            containerIdentifier: "iCloud.example.Other",
            subscriptionID: CloudPushSubscriptionIdentifiers.identifier(for: .private),
            databaseScope: .private
        )
        let wrongIdentifier = CloudPushNotification(
            containerIdentifier: containerIdentifier,
            subscriptionID: "untrusted",
            databaseScope: .private
        )

        let result = [valid, wrongContainer, wrongIdentifier].map {
            CloudPushNotificationRouter.refreshScopes(
                for: $0,
                expectedContainerIdentifier: containerIdentifier
            )
        }

        XCTAssertEqual(result, [[.private], [], []])
    }

    func testRefreshCoalescerMergesNotificationsArrivingDuringFetch() async {
        let recorder = BlockingRefreshRecorder()
        let coalescer = CloudPushRefreshCoalescer { scopes in
            await recorder.refresh(scopes)
        }

        let first = Task { await coalescer.requestRefresh(for: [.private]) }
        await recorder.waitForFirstRefresh()
        let second = Task { await coalescer.requestRefresh(for: [.shared]) }
        await second.value
        await recorder.releaseFirstRefresh()
        await first.value

        let batches = await recorder.snapshot()
        XCTAssertEqual(batches, [[.private], [.shared]])
    }

    func testJSONStoreRoundTripsPerEnvironmentRegistry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = try CloudPushInstallationContext(
            containerIdentifier: containerIdentifier,
            environment: .production,
            accountFingerprint: "account-a"
        )
        let registry = CloudPushInstallationRegistry(
            installations: [
                context.registryKey: CloudPushInstallation(
                    context: context,
                    installedScopes: [.private, .shared],
                    lastVerifiedAt: referenceDate
                )
            ]
        )
        let store = JSONFileCloudPushInstallationStateStore(
            fileURL: directory.appendingPathComponent("subscriptions.json")
        )

        try await store.save(registry)
        let reloaded = try await store.load()

        XCTAssertEqual(reloaded, registry)
    }

    private func makeCoordinator(
        client: FakeCloudPushSubscriptionClient,
        store: any CloudPushInstallationStateStore
    ) -> CloudPushSubscriptionCoordinator {
        CloudPushSubscriptionCoordinator(
            containerIdentifier: containerIdentifier,
            environment: .development,
            client: client,
            store: store,
            now: { referenceDate }
        )
    }
}

private let containerIdentifier = "iCloud.com.example.ClipboardRouter"
private let referenceDate = Date(timeIntervalSince1970: 1_786_000_000)

private struct InstallationResult: Equatable {
    let report: CloudPushInstallationReport
    let client: FakeClientSnapshot
}

private typealias RepairResult = InstallationResult

private struct FakeClientSnapshot: Equatable {
    let subscriptions: [String: CloudPushRemoteSubscription]
    let saves: [String]
    let deletes: [String]
}

private actor FakeCloudPushSubscriptionClient: CloudPushSubscriptionClient {
    private var accountFingerprint: String
    private var subscriptions: [String: CloudPushRemoteSubscription]
    private var saves: [String] = []
    private var deletes: [String] = []
    private let error: CloudPushSubscriptionError?

    init(
        accountFingerprint: String,
        subscriptions: [String: CloudPushRemoteSubscription] = [:],
        error: CloudPushSubscriptionError? = nil
    ) {
        self.accountFingerprint = accountFingerprint
        self.subscriptions = subscriptions
        self.error = error
    }

    func accountIdentity() async throws -> SyncAccountIdentity {
        if let error { throw error }
        return SyncAccountIdentity(state: .available, fingerprint: accountFingerprint)
    }

    func subscription(
        id: String,
        in scope: CloudPushDatabaseScope
    ) async throws -> CloudPushRemoteSubscription? {
        if let error { throw error }
        return subscriptions[key(scope)]
    }

    func saveSilentDatabaseSubscription(
        id: String,
        in scope: CloudPushDatabaseScope
    ) async throws {
        if let error { throw error }
        let key = key(scope)
        saves.append(key)
        subscriptions[key] = .database(contentAvailable: true)
    }

    func deleteSubscription(id: String, in scope: CloudPushDatabaseScope) async throws {
        if let error { throw error }
        let key = key(scope)
        deletes.append(key)
        subscriptions.removeValue(forKey: key)
    }

    func setAccountFingerprint(_ value: String) {
        accountFingerprint = value
    }

    func snapshot() -> FakeClientSnapshot {
        FakeClientSnapshot(
            subscriptions: subscriptions,
            saves: saves,
            deletes: deletes
        )
    }

    private func key(_ scope: CloudPushDatabaseScope) -> String {
        "\(accountFingerprint)|\(scope.rawValue)"
    }
}

private actor BlockingRefreshRecorder {
    private var batches: [Set<CloudPushDatabaseScope>] = []
    private var firstStartedWaiter: CheckedContinuation<Void, Never>?
    private var firstRelease: CheckedContinuation<Void, Never>?

    func refresh(_ scopes: Set<CloudPushDatabaseScope>) async {
        batches.append(scopes)
        if batches.count == 1 {
            firstStartedWaiter?.resume()
            firstStartedWaiter = nil
            await withCheckedContinuation { continuation in
                firstRelease = continuation
            }
        }
    }

    func waitForFirstRefresh() async {
        if !batches.isEmpty { return }
        await withCheckedContinuation { continuation in
            firstStartedWaiter = continuation
        }
    }

    func releaseFirstRefresh() {
        firstRelease?.resume()
        firstRelease = nil
    }

    func snapshot() -> [Set<CloudPushDatabaseScope>] { batches }
}
