import ClipboardRouterCore
import ClipboardRouterPlatform
import Foundation
import XCTest
@testable import ClipboardRouterApp

@MainActor
final class DirectLicenseAppTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testEngineeringBuildIsExplicitAndLeavesEvaluationFeaturesUnlocked() async {
        let model = makeModel(
            verifier: StubLicenseVerifier(isConfigured: false, claimsByToken: [:]),
            store: StubLicenseCredentialStore(),
            repository: StubLicenseRepository(isConfigured: false),
            clock: FixedLicenseClock(now: now)
        )
        await model.start()

        XCTAssertTrue(model.isDirectLicenseEngineeringBuild)
        XCTAssertEqual(model.directLicenseStatus, .unavailable(.engineeringBuild))
        XCTAssertTrue(model.directLicenseAccessPolicy.allows(.premiumCreation))
        XCTAssertTrue(model.directLicenseAccessPolicy.allows(.automation))
        XCTAssertTrue(model.directLicenseAccessPolicy.allows(.cloud))
        XCTAssertTrue(model.directLicenseAccessPolicy.allows(.ai))
    }

    func testMacAppStoreBuildHidesEngineeringLabelButKeepsPremiumUnlocked() async {
        let directModel = makeModel(
            verifier: StubLicenseVerifier(isConfigured: false, claimsByToken: [:]),
            store: StubLicenseCredentialStore(),
            repository: StubLicenseRepository(isConfigured: false),
            clock: FixedLicenseClock(now: now),
            distributionChannel: .direct
        )
        await directModel.start()
        XCTAssertFalse(directModel.isMacAppStoreDistribution)
        XCTAssertTrue(directModel.canExportBundledCommandLineTool)
        XCTAssertTrue(directModel.isDirectLicenseEngineeringBuild)

        let masModel = makeModel(
            verifier: StubLicenseVerifier(isConfigured: false, claimsByToken: [:]),
            store: StubLicenseCredentialStore(),
            repository: StubLicenseRepository(isConfigured: false),
            clock: FixedLicenseClock(now: now),
            distributionChannel: .macAppStore
        )
        await masModel.start()

        // The distribution channel never changes commerce configuration or entitlement
        // evaluation; it only changes what the UI is allowed to say about it.
        XCTAssertTrue(masModel.isMacAppStoreDistribution)
        XCTAssertFalse(masModel.canExportBundledCommandLineTool)
        XCTAssertTrue(masModel.isDirectLicenseEngineeringBuild)
        XCTAssertEqual(masModel.directLicenseStatus, .unavailable(.engineeringBuild))
        XCTAssertTrue(masModel.directLicenseAccessPolicy.allows(.premiumCreation))
        XCTAssertTrue(masModel.directLicenseAccessPolicy.allows(.automation))
        XCTAssertTrue(masModel.directLicenseAccessPolicy.allows(.cloud))
        XCTAssertTrue(masModel.directLicenseAccessPolicy.allows(.ai))
    }

    func testConfiguredBuildWithoutLicenseGatesNewPremiumCreationOnly() async {
        let model = makeModel(
            verifier: StubLicenseVerifier(isConfigured: true, claimsByToken: [:]),
            store: StubLicenseCredentialStore(),
            repository: StubLicenseRepository(isConfigured: true),
            clock: FixedLicenseClock(now: now)
        )
        await model.start()

        XCTAssertEqual(model.directLicenseStatus, .unavailable(.noLicense))
        XCTAssertFalse(model.createNote(title: "New", body: "Premium creation"))
        XCTAssertEqual(model.errorMessage, DirectLicenseError.premiumLicenseRequired.localizedDescription)
        XCTAssertTrue(model.directLicenseAccessPolicy.allows(.search))
        XCTAssertTrue(model.directLicenseAccessPolicy.allows(.copy))
        XCTAssertTrue(model.directLicenseAccessPolicy.allows(.export))
        XCTAssertTrue(model.directLicenseAccessPolicy.allows(.delete))
    }

    func testPartialProductionConfigurationFailsClosedInsteadOfUnlockingEngineeringMode() async {
        let verifierOnly = makeModel(
            verifier: StubLicenseVerifier(isConfigured: true, claimsByToken: [:]),
            store: StubLicenseCredentialStore(),
            repository: StubLicenseRepository(isConfigured: false),
            clock: FixedLicenseClock(now: now)
        )
        await verifierOnly.start()

        XCTAssertFalse(verifierOnly.isDirectLicenseEngineeringBuild)
        XCTAssertEqual(verifierOnly.directLicenseStatus, .unavailable(.verifierUnavailable))
        XCTAssertFalse(verifierOnly.directLicenseAccessPolicy.allows(.automation))

        let repositoryOnly = makeModel(
            verifier: StubLicenseVerifier(isConfigured: false, claimsByToken: [:]),
            store: StubLicenseCredentialStore(),
            repository: StubLicenseRepository(isConfigured: true),
            clock: FixedLicenseClock(now: now)
        )
        await repositoryOnly.start()

        XCTAssertFalse(repositoryOnly.isDirectLicenseEngineeringBuild)
        XCTAssertEqual(repositoryOnly.directLicenseStatus, .unavailable(.verifierUnavailable))
        XCTAssertFalse(repositoryOnly.directLicenseAccessPolicy.allows(.automation))
    }

    func testRepeatedActivationIsIdempotentAndStoresOnlyVerifiedScopedToken() async throws {
        let claims = try activeClaims()
        let store = StubLicenseCredentialStore()
        let repository = StubLicenseRepository(
            isConfigured: true,
            activationToken: "signed-token"
        )
        let model = makeModel(
            verifier: StubLicenseVerifier(
                isConfigured: true,
                claimsByToken: ["signed-token": claims]
            ),
            store: store,
            repository: repository,
            clock: FixedLicenseClock(now: now)
        )
        await model.start()

        model.activateDirectLicense(key: "LICENSE-KEY")
        let firstActivationCompleted = await waitUntil { !model.isDirectLicenseOperationInProgress }
        XCTAssertTrue(firstActivationCompleted)
        XCTAssertEqual(model.directLicenseStatus,
                       .active(plan: .subscription, expiresAt: claims.expiresAt))

        model.activateDirectLicense(key: "LICENSE-KEY")
        let secondActivationCompleted = await waitUntil { !model.isDirectLicenseOperationInProgress }
        let activationCount = await repository.activationCount()
        let storedToken = await store.currentToken()
        let tokenSaveCount = await store.tokenSaveCount()
        XCTAssertTrue(secondActivationCompleted)
        XCTAssertEqual(activationCount, 2)
        XCTAssertEqual(storedToken, "signed-token")
        XCTAssertEqual(tokenSaveCount, 2)
        XCTAssertEqual(model.directLicenseID, claims.licenseID)
        XCTAssertEqual(model.directLicenseAccountID, claims.accountID)
    }

    func testServiceOutagePreservesVerifiedLocalLicenseAndCredential() async throws {
        let claims = try activeClaims()
        let store = StubLicenseCredentialStore(token: "signed-token")
        let repository = StubLicenseRepository(
            isConfigured: true,
            refreshError: .repositoryUnavailable
        )
        let model = makeModel(
            verifier: StubLicenseVerifier(
                isConfigured: true,
                claimsByToken: ["signed-token": claims]
            ),
            store: store,
            repository: repository,
            clock: FixedLicenseClock(now: now)
        )
        await model.start()
        XCTAssertEqual(model.directLicenseStatus,
                       .active(plan: .subscription, expiresAt: claims.expiresAt))

        model.refreshDirectLicense()
        let refreshCompleted = await waitUntil { !model.isDirectLicenseOperationInProgress }
        let storedToken = await store.currentToken()
        XCTAssertTrue(refreshCompleted)
        XCTAssertEqual(model.directLicenseStatus,
                       .active(plan: .subscription, expiresAt: claims.expiresAt))
        XCTAssertEqual(storedToken, "signed-token")
        XCTAssertTrue(model.statusMessage?.contains("unavailable") == true)
    }

    func testDeactivateFailurePreservesTokenButDisconnectExplicitlyDeletesLocalState() async throws {
        let claims = try activeClaims()
        let store = StubLicenseCredentialStore(token: "signed-token")
        let repository = StubLicenseRepository(
            isConfigured: true,
            deactivateError: .deactivationRejected
        )
        let model = makeModel(
            verifier: StubLicenseVerifier(
                isConfigured: true,
                claimsByToken: ["signed-token": claims]
            ),
            store: store,
            repository: repository,
            clock: FixedLicenseClock(now: now)
        )
        await model.start()

        model.deactivateDirectLicenseDevice()
        let deactivateCompleted = await waitUntil { !model.isDirectLicenseOperationInProgress }
        let tokenAfterFailedDeactivation = await store.currentToken()
        XCTAssertTrue(deactivateCompleted)
        XCTAssertEqual(tokenAfterFailedDeactivation, "signed-token")
        XCTAssertEqual(model.directLicenseStatus,
                       .active(plan: .subscription, expiresAt: claims.expiresAt))

        model.disconnectDirectLicense()
        let disconnectCompleted = await waitUntil { !model.isDirectLicenseOperationInProgress }
        let tokenAfterDisconnect = await store.currentToken()
        let checkpointAfterDisconnect = await store.currentCheckpoint()
        XCTAssertTrue(disconnectCompleted)
        XCTAssertNil(tokenAfterDisconnect)
        XCTAssertNotNil(checkpointAfterDisconnect)
        XCTAssertEqual(model.directLicenseStatus, .unavailable(.noLicense))
    }

    func testWrongDeviceActivationCannotReplaceExistingCredential() async throws {
        let existingClaims = try activeClaims()
        let wrongDeviceClaims = try DirectLicenseTokenClaims(
            licenseID: "license-other",
            accountID: "account-other",
            deviceID: "device-other",
            plan: .lifetime,
            issuedAt: now
        )
        let store = StubLicenseCredentialStore(token: "existing-token")
        let repository = StubLicenseRepository(
            isConfigured: true,
            activationToken: "wrong-device-token"
        )
        let model = makeModel(
            verifier: StubLicenseVerifier(
                isConfigured: true,
                claimsByToken: [
                    "existing-token": existingClaims,
                    "wrong-device-token": wrongDeviceClaims,
                ]
            ),
            store: store,
            repository: repository,
            clock: FixedLicenseClock(now: now)
        )
        await model.start()

        model.activateDirectLicense(key: "LICENSE-KEY")
        let activationCompleted = await waitUntil { !model.isDirectLicenseOperationInProgress }
        let storedToken = await store.currentToken()
        XCTAssertTrue(activationCompleted)
        XCTAssertEqual(storedToken, "existing-token")
        XCTAssertEqual(model.directLicenseStatus,
                       .active(plan: .subscription, expiresAt: existingClaims.expiresAt))
    }

    func testExecutionPolicyExpiresAtExactLocalBoundaryWithoutWaitingForRefreshLoop() async throws {
        let clock = MutableLicenseClock(now: now)
        let claims = try DirectLicenseTokenClaims(
            licenseID: "license-boundary",
            accountID: "account-a",
            deviceID: "device-a",
            plan: .subscription,
            issuedAt: now.addingTimeInterval(-60),
            expiresAt: now.addingTimeInterval(5),
            offlineGraceDuration: 0
        )
        let model = makeModel(
            verifier: StubLicenseVerifier(isConfigured: true, claimsByToken: ["token": claims]),
            store: StubLicenseCredentialStore(token: "token"),
            repository: StubLicenseRepository(isConfigured: true),
            clock: clock
        )
        await model.start()
        XCTAssertTrue(model.directLicenseAccessPolicy.allows(.automation))

        clock.advance(by: 6)

        XCTAssertFalse(model.directLicenseAccessPolicy.allows(.automation))
        XCTAssertTrue(model.directLicenseAccessPolicy.allows(.copy))
    }

    private func activeClaims() throws -> DirectLicenseTokenClaims {
        try DirectLicenseTokenClaims(
            licenseID: "license-a",
            accountID: "account-a",
            deviceID: "device-a",
            plan: .subscription,
            issuedAt: now.addingTimeInterval(-60),
            expiresAt: now.addingTimeInterval(3_600),
            offlineGraceDuration: 600
        )
    }

    private func makeModel(
        verifier: StubLicenseVerifier,
        store: StubLicenseCredentialStore,
        repository: StubLicenseRepository,
        clock: any DirectLicenseClockProviding,
        distributionChannel: DistributionChannel = .direct
    ) -> AppModel {
        let suite = "DirectLicenseAppTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set("device-a", forKey: "directLicenseDeviceID.v1")
        return AppModel(
            defaults: defaults,
            hotKey: DirectLicenseHotKeyRegistrar(),
            directLicenseVerifier: verifier,
            directLicenseCredentialStore: store,
            directLicenseRepository: repository,
            directLicenseClock: clock,
            distributionChannelProvider: StubDistributionChannelProvider(channel: distributionChannel),
            supportDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("DirectLicenseAppTests-\(UUID().uuidString)"),
            libraryPersistence: InMemoryClipboardLibraryStore()
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

private struct StubDistributionChannelProvider: DistributionChannelProviding {
    let channel: DistributionChannel
}

private struct StubLicenseVerifier: DirectLicenseTokenVerifying {
    let isConfigured: Bool
    let claimsByToken: [String: DirectLicenseTokenClaims]

    func verify(_ token: String) throws -> DirectLicenseTokenClaims {
        guard let claims = claimsByToken[token] else { throw DirectLicenseError.invalidSignature }
        return claims
    }
}

private actor StubLicenseCredentialStore: DirectLicenseCredentialStoring {
    private var token: String?
    private var checkpoint: DirectLicenseClockCheckpoint?
    private var saves = 0

    init(token: String? = nil, checkpoint: DirectLicenseClockCheckpoint? = nil) {
        self.token = token
        self.checkpoint = checkpoint
    }

    func loadToken() -> String? { token }
    func saveToken(_ token: String) { self.token = token; saves += 1 }
    func deleteToken() { token = nil }
    func loadClockCheckpoint() -> DirectLicenseClockCheckpoint? { checkpoint }
    func saveClockCheckpoint(_ checkpoint: DirectLicenseClockCheckpoint) {
        self.checkpoint = checkpoint
    }
    func deleteClockCheckpoint() { checkpoint = nil }

    func currentToken() -> String? { token }
    func currentCheckpoint() -> DirectLicenseClockCheckpoint? { checkpoint }
    func tokenSaveCount() -> Int { saves }
}

private actor StubLicenseRepository: DirectLicenseRepositoryClient {
    nonisolated let isConfigured: Bool
    private let activationToken: String?
    private let refreshError: DirectLicenseError?
    private let deactivateError: DirectLicenseError?
    private var activations = 0

    init(
        isConfigured: Bool,
        activationToken: String? = nil,
        refreshError: DirectLicenseError? = nil,
        deactivateError: DirectLicenseError? = nil
    ) {
        self.isConfigured = isConfigured
        self.activationToken = activationToken
        self.refreshError = refreshError
        self.deactivateError = deactivateError
    }

    func startTrial(deviceID: String) throws -> String {
        guard let activationToken else { throw DirectLicenseError.activationRejected }
        return activationToken
    }

    func activate(licenseKey: String, deviceID: String) throws -> String {
        activations += 1
        guard let activationToken else { throw DirectLicenseError.activationRejected }
        return activationToken
    }

    func restore(accountID: String, deviceID: String) throws -> String {
        guard let activationToken else { throw DirectLicenseError.restoreRejected }
        return activationToken
    }

    func refresh(token: String, deviceID: String) throws -> String {
        if let refreshError { throw refreshError }
        return token
    }

    func deactivate(token: String, deviceID: String) throws {
        if let deactivateError { throw deactivateError }
    }

    func activationCount() -> Int { activations }
}

private struct FixedLicenseClock: DirectLicenseClockProviding {
    let now: Date
    func observation() -> DirectLicenseClockObservation {
        DirectLicenseClockObservation(wallClock: now, monotonicUptime: 10_000)
    }
}

private final class MutableLicenseClock: DirectLicenseClockProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var now: Date

    init(now: Date) { self.now = now }

    func advance(by interval: TimeInterval) {
        lock.lock()
        now = now.addingTimeInterval(interval)
        lock.unlock()
    }

    func observation() -> DirectLicenseClockObservation {
        lock.lock()
        defer { lock.unlock() }
        return DirectLicenseClockObservation(wallClock: now, monotonicUptime: 10_000)
    }
}

@MainActor
private final class DirectLicenseHotKeyRegistrar: GlobalHotKeyRegistering {
    func register(
        _ descriptor: GlobalHotKeyDescriptor,
        handler: @escaping @MainActor () -> Void
    ) throws {}
    func unregister() {}
}
