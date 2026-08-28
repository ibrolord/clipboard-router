import Foundation
import XCTest
@testable import ClipboardRouterCore

final class AutomationRunLedgerTests: XCTestCase {
    func testTwoWorkersCannotClaimSameStep() async throws {
        let ledger = AutomationRunLedger(persistence: InMemoryAutomationRunLedgerStore())
        let plan = try makePlan(steps: [.addTags(id: UUID(), tags: ["qualified"])])
        _ = try await ledger.createRun(
            plan: plan,
            triggerKind: .manual,
            idempotencyKey: "manual-1",
            requiresReview: false
        )

        async let first: Result<AutomationRunClaim, any Error> = captureResult {
            try await ledger.claimNextStep(runID: plan.id, workerID: UUID())
        }
        async let second: Result<AutomationRunClaim, any Error> = captureResult {
            try await ledger.claimNextStep(runID: plan.id, workerID: UUID())
        }
        let results = await [first, second]

        XCTAssertEqual(results.filter { if case .success = $0 { true } else { false } }.count, 1)
        XCTAssertEqual(results.filter { result in
            guard case let .failure(error) = result else { return false }
            return error as? AutomationRunLedgerError == .activeLease
        }.count, 1)
    }

    func testCrashRecoveryPreservesCompletedStepAndMakesUnknownExternalOutcomeUncertain() async throws {
        let store = InMemoryAutomationRunLedgerStore()
        let worker = UUID()
        let organizationID = UUID()
        let externalID = UUID()
        let plan = try makePlan(steps: [
            .addTags(id: organizationID, tags: ["qualified"]),
            .openWeb(id: externalID, template: "https://example.com?q={clip}", label: "CRM"),
        ])
        let firstLedger = AutomationRunLedger(persistence: store)
        _ = try await firstLedger.createRun(
            plan: plan,
            triggerKind: .manual,
            idempotencyKey: "crash-run",
            requiresReview: false
        )
        let organization = try await firstLedger.claimNextStep(runID: plan.id, workerID: worker)
        try await firstLedger.markStepSucceeded(organization)
        _ = try await firstLedger.claimNextStep(runID: plan.id, workerID: worker)

        let relaunched = AutomationRunLedger(persistence: store)
        let recovered = try await relaunched.restoreForRelaunch(currentWorkerID: UUID())
        let run = try XCTUnwrap(recovered.runs.first)

        XCTAssertEqual(run.status, .uncertain)
        XCTAssertEqual(run.steps.map(\.status), [.succeeded, .uncertain])
        await XCTAssertThrowsErrorAsync {
            _ = try await relaunched.claimNextStep(runID: plan.id, workerID: UUID())
        } verify: { error in
            XCTAssertEqual(error as? AutomationRunLedgerError, .reconciliationRequired)
        }
    }

    func testDuplicateTriggerReturnsExistingRun() async throws {
        let ledger = AutomationRunLedger(persistence: InMemoryAutomationRunLedgerStore())
        let firstPlan = try makePlan(steps: [.addTags(id: UUID(), tags: ["one"])])
        let secondPlan = try makePlan(steps: [.addTags(id: UUID(), tags: ["two"])])
        let first = try await ledger.createRun(
            plan: firstPlan,
            triggerKind: .localFolderEntry,
            idempotencyKey: "stable-trigger-event",
            requiresReview: false
        )
        let duplicate = try await ledger.createRun(
            plan: secondPlan,
            triggerKind: .localFolderEntry,
            idempotencyKey: "stable-trigger-event",
            requiresReview: false
        )

        XCTAssertTrue(first.wasCreated)
        XCTAssertFalse(duplicate.wasCreated)
        XCTAssertEqual(duplicate.record.id, first.record.id)
        let snapshot = await ledger.snapshot()
        XCTAssertEqual(snapshot.runs.count, 1)
    }

    func testOnlyRetrySafeFailedStepCanBeClaimedAgain() async throws {
        let safeLedger = AutomationRunLedger(persistence: InMemoryAutomationRunLedgerStore())
        let safePlan = try makePlan(steps: [.moveToFolder(id: UUID(), folderID: nil)])
        _ = try await safeLedger.createRun(
            plan: safePlan,
            triggerKind: .manual,
            idempotencyKey: "safe",
            requiresReview: false
        )
        let firstClaim = try await safeLedger.claimNextStep(runID: safePlan.id, workerID: UUID())
        try await safeLedger.markStepFailed(firstClaim, code: .executionFailed, outcomeIsKnown: true)
        let retry = try await safeLedger.claimNextStep(runID: safePlan.id, workerID: UUID())
        XCTAssertEqual(retry.receipt.id, firstClaim.receipt.id)
        XCTAssertEqual(retry.receipt.attemptCount, 2)

        let unsafeLedger = AutomationRunLedger(persistence: InMemoryAutomationRunLedgerStore())
        let unsafePlan = try makePlan(steps: [
            .openWeb(id: UUID(), template: "https://example.com?q={clip}", label: "CRM"),
        ])
        _ = try await unsafeLedger.createRun(
            plan: unsafePlan,
            triggerKind: .manual,
            idempotencyKey: "unsafe",
            requiresReview: false
        )
        let unsafeClaim = try await unsafeLedger.claimNextStep(runID: unsafePlan.id, workerID: UUID())
        try await unsafeLedger.markStepFailed(unsafeClaim, code: .executionFailed, outcomeIsKnown: true)
        await XCTAssertThrowsErrorAsync {
            _ = try await unsafeLedger.claimNextStep(runID: unsafePlan.id, workerID: UUID())
        } verify: { error in
            XCTAssertEqual(error as? AutomationRunLedgerError, .noRunnableStep)
        }
    }

    func testPersistenceIsChecksummedPrivateAndContainsNoBodiesCredentialsOrBookmarks() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutomationLedger-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("runs.json")
        let store = JSONFileAutomationRunLedgerStore(fileURL: fileURL)
        let ledger = AutomationRunLedger(persistence: store)
        let secret = "sk-proj-abcdefghijklmnopqrstuvwxyz123456"
        let plan = try makePlan(steps: [
            .openApplication(
                id: UUID(),
                bookmarkData: Data("bookmark-\(secret)".utf8),
                displayName: "Private CRM"
            ),
        ])
        _ = try await ledger.createRun(
            plan: plan,
            triggerKind: .manual,
            idempotencyKey: "event-\(secret)",
            requiresReview: true
        )

        let raw = try Data(contentsOf: fileURL)
        let text = String(decoding: raw, as: UTF8.self)
        XCTAssertFalse(text.contains(secret))
        XCTAssertFalse(text.contains("bookmark-"))
        XCTAssertFalse(text.contains("Private CRM"))
        let directoryMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        )
        let fileMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(directoryMode.intValue & 0o777, 0o700)
        XCTAssertEqual(fileMode.intValue & 0o777, 0o600)
        let loaded = try await store.load()
        let snapshot = await ledger.snapshot()
        XCTAssertEqual(loaded, snapshot)

        var damaged = raw
        damaged[damaged.index(before: damaged.endIndex)] ^= 1
        try damaged.write(to: fileURL, options: .atomic)
        await XCTAssertThrowsErrorAsync { _ = try await store.load() }
    }

    func testPauseHooksPreventNewClaimsWithoutChangingReceipts() async throws {
        let ledger = AutomationRunLedger(persistence: InMemoryAutomationRunLedgerStore())
        let plan = try makePlan(steps: [.addTags(id: UUID(), tags: ["paused"])])
        _ = try await ledger.createRun(
            plan: plan,
            triggerKind: .manual,
            idempotencyKey: "paused",
            requiresReview: false
        )
        try await ledger.setPaused(true)
        await XCTAssertThrowsErrorAsync {
            _ = try await ledger.claimNextStep(runID: plan.id, workerID: UUID())
        } verify: { XCTAssertEqual($0 as? AutomationRunLedgerError, .paused) }
        let snapshot = await ledger.snapshot()
        XCTAssertEqual(snapshot.runs[0].steps[0].status, .pending)
    }

    func testExpiredLeaseRecoversSafeStepButBlocksUnknownExternalReplay() async throws {
        let clock = RunLedgerTestClock(Date(timeIntervalSince1970: 10))
        let safe = AutomationRunLedger(
            persistence: InMemoryAutomationRunLedgerStore(),
            leaseDuration: 1,
            now: clock.now
        )
        let safePlan = try makePlan(steps: [.addTags(id: UUID(), tags: ["safe"])])
        _ = try await safe.createRun(
            plan: safePlan,
            triggerKind: .manual,
            idempotencyKey: "expire-safe",
            requiresReview: false
        )
        _ = try await safe.claimNextStep(runID: safePlan.id, workerID: UUID())
        clock.advance(by: 2)
        let recovered = try await safe.claimNextStep(runID: safePlan.id, workerID: UUID())
        XCTAssertEqual(recovered.receipt.attemptCount, 2)

        let unsafe = AutomationRunLedger(
            persistence: InMemoryAutomationRunLedgerStore(),
            leaseDuration: 1,
            now: clock.now
        )
        let unsafePlan = try makePlan(steps: [
            .openWeb(id: UUID(), template: "https://example.com?q={clip}", label: "CRM"),
        ])
        _ = try await unsafe.createRun(
            plan: unsafePlan,
            triggerKind: .manual,
            idempotencyKey: "expire-unsafe",
            requiresReview: false
        )
        _ = try await unsafe.claimNextStep(runID: unsafePlan.id, workerID: UUID())
        clock.advance(by: 2)
        await XCTAssertThrowsErrorAsync {
            _ = try await unsafe.claimNextStep(runID: unsafePlan.id, workerID: UUID())
        } verify: { error in
            XCTAssertEqual(error as? AutomationRunLedgerError, .reconciliationRequired)
        }
        let unsafeSnapshot = await unsafe.snapshot()
        XCTAssertEqual(unsafeSnapshot.runs.first?.status, .uncertain)
    }

    private func makePlan(steps: [ClipFlowStep]) throws -> ClipFlowRunPlan {
        let flow = try ClipFlow(name: "Test flow", steps: steps)
        return try ClipFlowRunPlan(
            flow: flow,
            clipID: UUID(),
            clipFingerprint: String(repeating: "a", count: 64),
            createdAt: Date(timeIntervalSince1970: 100)
        )
    }
}

private final class RunLedgerTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) { self.value = value }
    func now() -> Date { lock.withLock { value } }
    func advance(by interval: TimeInterval) {
        lock.withLock { value = value.addingTimeInterval(interval) }
    }
}

private func captureResult<T>(
    _ operation: () async throws -> T
) async -> Result<T, any Error> {
    do { return .success(try await operation()) }
    catch { return .failure(error) }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line,
    verify: (any Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {
        verify(error)
    }
}
