import CryptoKit
import Foundation

public enum AutomationRunStatus: String, Codable, CaseIterable, Sendable {
    case planned
    case running
    case needsReview
    case succeeded
    case failed
    case uncertain
    case cancelled
}

public enum AutomationRunTriggerKind: String, Codable, Sendable {
    case manual
    case localFolderEntry
}

public enum AutomationRunStepKind: String, Codable, Sendable {
    case organizeLibrary
    case openWeb
    case openApplication
    case createTaskDraft
    case enrichWithOnDeviceAI
}

public enum AutomationRunStepStatus: String, Codable, Sendable {
    case pending
    case running
    case succeeded
    case failed
    case uncertain
    case cancelled
}

public enum AutomationRunRetrySafety: String, Codable, Sendable {
    case retrySafe
    case requiresReconciliation
}

public enum AutomationRunFailureCode: String, Codable, Sendable {
    case executionFailed
    case leaseExpired
    case staleFlow
    case staleClip
    case ineligible
    case permissionDenied
    case persistenceFailed
    case cancelled
}

public struct AutomationRunStepReceipt: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let sourceStepIDs: [UUID]
    public let position: Int
    public let kind: AutomationRunStepKind
    public let retrySafety: AutomationRunRetrySafety
    public internal(set) var status: AutomationRunStepStatus
    public internal(set) var attemptCount: Int
    public internal(set) var startedAt: Date?
    public internal(set) var finishedAt: Date?
    public internal(set) var failureCode: AutomationRunFailureCode?

    init(
        id: UUID,
        sourceStepIDs: [UUID],
        position: Int,
        kind: AutomationRunStepKind,
        retrySafety: AutomationRunRetrySafety
    ) {
        self.id = id
        self.sourceStepIDs = sourceStepIDs
        self.position = position
        self.kind = kind
        self.retrySafety = retrySafety
        status = .pending
        attemptCount = 0
    }
}

public struct AutomationRunLease: Codable, Equatable, Sendable {
    public let token: UUID
    public let workerID: UUID
    public let stepReceiptID: UUID
    public let expiresAt: Date
}

public struct AutomationRunRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let flowID: UUID
    public let flowVersionFingerprint: String
    public let clipID: UUID
    public let clipFingerprint: String
    public let idempotencyKeyHash: String
    public let triggerKind: AutomationRunTriggerKind
    public let createdAt: Date
    public internal(set) var updatedAt: Date
    public internal(set) var status: AutomationRunStatus
    public internal(set) var steps: [AutomationRunStepReceipt]
    public internal(set) var lease: AutomationRunLease?
    public internal(set) var failureCode: AutomationRunFailureCode?

    public var completedStepCount: Int {
        steps.lazy.filter { $0.status == .succeeded }.count
    }

    public var canRetry: Bool {
        status == .failed && steps.contains {
            $0.status == .failed && $0.retrySafety == .retrySafe
        }
    }
}

public struct AutomationRunLedgerControls: Codable, Equatable, Sendable {
    public var isPaused: Bool
    public var pausedFlowIDs: Set<UUID>

    public init(isPaused: Bool = false, pausedFlowIDs: Set<UUID> = []) {
        self.isPaused = isPaused
        self.pausedFlowIDs = pausedFlowIDs
    }
}

public struct AutomationRunLedgerSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let empty = AutomationRunLedgerSnapshot()

    public let schemaVersion: Int
    public var runs: [AutomationRunRecord]
    public var controls: AutomationRunLedgerControls

    public init(
        runs: [AutomationRunRecord] = [],
        controls: AutomationRunLedgerControls = AutomationRunLedgerControls()
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.runs = runs
        self.controls = controls
    }
}

public struct AutomationRunClaim: Equatable, Sendable {
    public let runID: UUID
    public let receipt: AutomationRunStepReceipt
    public let lease: AutomationRunLease
}

public struct AutomationRunCreationResult: Equatable, Sendable {
    public let record: AutomationRunRecord
    public let wasCreated: Bool
}

public enum AutomationRunReconciliationDecision: Sendable {
    case markSucceeded
    case cancelRemaining
}

public enum AutomationRunLedgerError: Error, Equatable, LocalizedError, Sendable {
    case runNotFound(UUID)
    case invalidRecord
    case duplicateStep
    case reviewRequired
    case paused
    case activeLease
    case noRunnableStep
    case invalidLease
    case invalidTransition
    case reconciliationRequired
    case capacityReached
    case fileTooLarge(URL, maximum: Int)
    case unreadableFile(URL)
    case undecodableFile(URL)
    case checksumMismatch(URL)
    case unwritableFile(URL)

    public var errorDescription: String? {
        switch self {
        case .runNotFound: "The automation run no longer exists."
        case .invalidRecord: "The automation run ledger contains an invalid record."
        case .duplicateStep: "The automation contains duplicate step identifiers."
        case .reviewRequired: "Review this automation before continuing."
        case .paused: "Automation execution is paused."
        case .activeLease: "Another automation worker is already executing this run."
        case .noRunnableStep: "This automation has no step that can be run safely."
        case .invalidLease: "The automation execution lease is no longer valid."
        case .invalidTransition: "The automation run cannot make that state transition."
        case .reconciliationRequired: "The previous outcome is unknown and requires a manual decision."
        case .capacityReached: "Resolve or cancel an existing automation run before starting another."
        case let .fileTooLarge(url, maximum):
            "The automation ledger at \(url.path) exceeds \(maximum) bytes."
        case let .unreadableFile(url): "The automation ledger cannot be read at \(url.path)."
        case let .undecodableFile(url): "The automation ledger cannot be decoded at \(url.path)."
        case let .checksumMismatch(url): "The automation ledger checksum does not match at \(url.path)."
        case let .unwritableFile(url): "The automation ledger cannot be written at \(url.path)."
        }
    }
}

public protocol AutomationRunLedgerPersisting: Sendable {
    func load() async throws -> AutomationRunLedgerSnapshot
    func save(_ snapshot: AutomationRunLedgerSnapshot) async throws
}

public actor AutomationRunLedger {
    public static let defaultLeaseDuration: TimeInterval = 30
    public static let maximumRetainedRuns = 1_000

    private let persistence: any AutomationRunLedgerPersisting
    private let now: @Sendable () -> Date
    private let leaseDuration: TimeInterval
    private var state: AutomationRunLedgerSnapshot = .empty

    public init(
        persistence: any AutomationRunLedgerPersisting,
        leaseDuration: TimeInterval = defaultLeaseDuration,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.persistence = persistence
        self.leaseDuration = max(1, leaseDuration)
        self.now = now
    }

    public func restoreForRelaunch(currentWorkerID: UUID) async throws
        -> AutomationRunLedgerSnapshot
    {
        state = try await persistence.load()
        try Self.validate(state)
        var changed = false
        let timestamp = now()
        for runIndex in state.runs.indices {
            let lease = state.runs[runIndex].lease
            let abandoned = lease.map {
                $0.workerID != currentWorkerID || $0.expiresAt <= timestamp
            } ?? false
            if abandoned, let receiptID = lease?.stepReceiptID,
               let stepIndex = state.runs[runIndex].steps.firstIndex(where: { $0.id == receiptID })
            {
                if state.runs[runIndex].steps[stepIndex].retrySafety == .retrySafe {
                    state.runs[runIndex].steps[stepIndex].status = .failed
                    state.runs[runIndex].steps[stepIndex].failureCode = .leaseExpired
                    state.runs[runIndex].status = .needsReview
                    state.runs[runIndex].failureCode = .leaseExpired
                } else {
                    state.runs[runIndex].steps[stepIndex].status = .uncertain
                    state.runs[runIndex].steps[stepIndex].failureCode = .leaseExpired
                    state.runs[runIndex].status = .uncertain
                    state.runs[runIndex].failureCode = .leaseExpired
                }
                state.runs[runIndex].steps[stepIndex].finishedAt = timestamp
                state.runs[runIndex].lease = nil
                state.runs[runIndex].updatedAt = timestamp
                changed = true
            } else if [.planned, .running].contains(state.runs[runIndex].status) {
                state.runs[runIndex].status = .needsReview
                state.runs[runIndex].lease = nil
                state.runs[runIndex].updatedAt = timestamp
                changed = true
            }
        }
        if changed { try await persistence.save(state) }
        return state
    }

    public func snapshot() -> AutomationRunLedgerSnapshot { state }

    public func createRun(
        plan: ClipFlowRunPlan,
        triggerKind: AutomationRunTriggerKind,
        idempotencyKey: String,
        requiresReview: Bool
    ) async throws -> AutomationRunCreationResult {
        let keyHash = Self.hash(Data(idempotencyKey.utf8))
        if let existing = state.runs.first(where: { $0.idempotencyKeyHash == keyHash }) {
            return AutomationRunCreationResult(record: existing, wasCreated: false)
        }
        let receipts = try Self.receipts(for: plan.steps)
        let timestamp = now()
        let record = AutomationRunRecord(
            id: plan.id,
            flowID: plan.flowID,
            flowVersionFingerprint: plan.flowVersionFingerprint,
            clipID: plan.clipID,
            clipFingerprint: plan.clipFingerprint,
            idempotencyKeyHash: keyHash,
            triggerKind: triggerKind,
            createdAt: plan.createdAt,
            updatedAt: timestamp,
            status: requiresReview ? .needsReview : .planned,
            steps: receipts,
            lease: nil,
            failureCode: nil
        )
        try await committing {
            while $0.runs.count >= Self.maximumRetainedRuns,
                  let oldestTerminal = $0.runs.lastIndex(where: {
                      [.succeeded, .failed, .cancelled].contains($0.status)
                  })
            {
                $0.runs.remove(at: oldestTerminal)
            }
            guard $0.runs.count < Self.maximumRetainedRuns else {
                throw AutomationRunLedgerError.capacityReached
            }
            $0.runs.append(record)
            $0.runs.sort { $0.createdAt > $1.createdAt }
        }
        return AutomationRunCreationResult(record: record, wasCreated: true)
    }

    public func approve(_ runID: UUID) async throws {
        try await committing { snapshot in
            guard let index = snapshot.runs.firstIndex(where: { $0.id == runID }) else {
                throw AutomationRunLedgerError.runNotFound(runID)
            }
            guard snapshot.runs[index].status == .needsReview else {
                throw AutomationRunLedgerError.invalidTransition
            }
            snapshot.runs[index].status = snapshot.runs[index].steps.contains {
                $0.status == .failed
            } ? .failed : .planned
            snapshot.runs[index].updatedAt = now()
        }
    }

    public func claimNextStep(runID: UUID, workerID: UUID) async throws -> AutomationRunClaim {
        if state.controls.isPaused { throw AutomationRunLedgerError.paused }
        guard let initialIndex = state.runs.firstIndex(where: { $0.id == runID }) else {
            throw AutomationRunLedgerError.runNotFound(runID)
        }
        if state.controls.pausedFlowIDs.contains(state.runs[initialIndex].flowID) {
            throw AutomationRunLedgerError.paused
        }
        if state.runs[initialIndex].status == .needsReview {
            throw AutomationRunLedgerError.reviewRequired
        }
        if state.runs[initialIndex].status == .uncertain {
            throw AutomationRunLedgerError.reconciliationRequired
        }
        if let lease = state.runs[initialIndex].lease {
            if lease.expiresAt > now() {
                throw AutomationRunLedgerError.activeLease
            }
            try await recoverExpiredLease(runID: runID)
            guard let recovered = state.runs.first(where: { $0.id == runID }) else {
                throw AutomationRunLedgerError.runNotFound(runID)
            }
            if recovered.status == .uncertain {
                throw AutomationRunLedgerError.reconciliationRequired
            }
        }

        var claim: AutomationRunClaim?
        try await committing { snapshot in
            guard let runIndex = snapshot.runs.firstIndex(where: { $0.id == runID }) else {
                throw AutomationRunLedgerError.runNotFound(runID)
            }
            let candidate = snapshot.runs[runIndex].steps.firstIndex {
                $0.status == .failed && $0.retrySafety == .retrySafe
            } ?? snapshot.runs[runIndex].steps.firstIndex { $0.status == .pending }
            guard let stepIndex = candidate else { throw AutomationRunLedgerError.noRunnableStep }
            let timestamp = now()
            let lease = AutomationRunLease(
                token: UUID(),
                workerID: workerID,
                stepReceiptID: snapshot.runs[runIndex].steps[stepIndex].id,
                expiresAt: timestamp.addingTimeInterval(leaseDuration)
            )
            snapshot.runs[runIndex].steps[stepIndex].status = .running
            snapshot.runs[runIndex].steps[stepIndex].attemptCount += 1
            snapshot.runs[runIndex].steps[stepIndex].startedAt = timestamp
            snapshot.runs[runIndex].steps[stepIndex].finishedAt = nil
            snapshot.runs[runIndex].steps[stepIndex].failureCode = nil
            snapshot.runs[runIndex].status = .running
            snapshot.runs[runIndex].lease = lease
            snapshot.runs[runIndex].failureCode = nil
            snapshot.runs[runIndex].updatedAt = timestamp
            claim = AutomationRunClaim(
                runID: runID,
                receipt: snapshot.runs[runIndex].steps[stepIndex],
                lease: lease
            )
        }
        return claim!
    }

    public func markStepSucceeded(_ claim: AutomationRunClaim) async throws {
        try await committing { snapshot in
            let indexes = try Self.indexes(for: claim, in: snapshot)
            let timestamp = now()
            snapshot.runs[indexes.run].steps[indexes.step].status = .succeeded
            snapshot.runs[indexes.run].steps[indexes.step].finishedAt = timestamp
            snapshot.runs[indexes.run].steps[indexes.step].failureCode = nil
            snapshot.runs[indexes.run].lease = nil
            snapshot.runs[indexes.run].failureCode = nil
            snapshot.runs[indexes.run].status = snapshot.runs[indexes.run].steps.allSatisfy {
                $0.status == .succeeded
            } ? .succeeded : .running
            snapshot.runs[indexes.run].updatedAt = timestamp
        }
    }

    public func markStepFailed(
        _ claim: AutomationRunClaim,
        code: AutomationRunFailureCode,
        outcomeIsKnown: Bool
    ) async throws {
        try await committing { snapshot in
            let indexes = try Self.indexes(for: claim, in: snapshot)
            let timestamp = now()
            let status: AutomationRunStepStatus = outcomeIsKnown ? .failed : .uncertain
            snapshot.runs[indexes.run].steps[indexes.step].status = status
            snapshot.runs[indexes.run].steps[indexes.step].finishedAt = timestamp
            snapshot.runs[indexes.run].steps[indexes.step].failureCode = code
            snapshot.runs[indexes.run].lease = nil
            snapshot.runs[indexes.run].status = outcomeIsKnown ? .failed : .uncertain
            snapshot.runs[indexes.run].failureCode = code
            snapshot.runs[indexes.run].updatedAt = timestamp
        }
    }

    public func cancel(_ runID: UUID) async throws {
        try await committing { snapshot in
            guard let runIndex = snapshot.runs.firstIndex(where: { $0.id == runID }) else {
                throw AutomationRunLedgerError.runNotFound(runID)
            }
            guard ![.succeeded, .cancelled].contains(snapshot.runs[runIndex].status) else { return }
            let timestamp = now()
            for stepIndex in snapshot.runs[runIndex].steps.indices {
                switch snapshot.runs[runIndex].steps[stepIndex].status {
                case .pending, .failed:
                    snapshot.runs[runIndex].steps[stepIndex].status = .cancelled
                    snapshot.runs[runIndex].steps[stepIndex].finishedAt = timestamp
                    snapshot.runs[runIndex].steps[stepIndex].failureCode = .cancelled
                case .running:
                    snapshot.runs[runIndex].steps[stepIndex].status = .uncertain
                    snapshot.runs[runIndex].steps[stepIndex].finishedAt = timestamp
                    snapshot.runs[runIndex].steps[stepIndex].failureCode = .cancelled
                case .succeeded, .uncertain, .cancelled:
                    break
                }
            }
            snapshot.runs[runIndex].lease = nil
            snapshot.runs[runIndex].status = .cancelled
            snapshot.runs[runIndex].failureCode = .cancelled
            snapshot.runs[runIndex].updatedAt = timestamp
        }
    }

    public func reconcile(
        runID: UUID,
        decision: AutomationRunReconciliationDecision
    ) async throws {
        try await committing { snapshot in
            guard let runIndex = snapshot.runs.firstIndex(where: { $0.id == runID }),
                  let stepIndex = snapshot.runs[runIndex].steps.firstIndex(where: {
                      $0.status == .uncertain
                  })
            else { throw AutomationRunLedgerError.reconciliationRequired }
            let timestamp = now()
            switch decision {
            case .markSucceeded:
                snapshot.runs[runIndex].steps[stepIndex].status = .succeeded
                snapshot.runs[runIndex].steps[stepIndex].failureCode = nil
                snapshot.runs[runIndex].steps[stepIndex].finishedAt = timestamp
                snapshot.runs[runIndex].status = snapshot.runs[runIndex].steps.allSatisfy {
                    $0.status == .succeeded
                } ? .succeeded : .needsReview
                snapshot.runs[runIndex].failureCode = nil
            case .cancelRemaining:
                for index in snapshot.runs[runIndex].steps.indices where
                    [.pending, .failed].contains(snapshot.runs[runIndex].steps[index].status)
                {
                    snapshot.runs[runIndex].steps[index].status = .cancelled
                    snapshot.runs[runIndex].steps[index].finishedAt = timestamp
                    snapshot.runs[runIndex].steps[index].failureCode = .cancelled
                }
                snapshot.runs[runIndex].status = .cancelled
                snapshot.runs[runIndex].failureCode = .cancelled
            }
            snapshot.runs[runIndex].lease = nil
            snapshot.runs[runIndex].updatedAt = timestamp
        }
    }

    public func markRunFailed(_ runID: UUID, code: AutomationRunFailureCode) async throws {
        try await committing { snapshot in
            guard let index = snapshot.runs.firstIndex(where: { $0.id == runID }) else {
                throw AutomationRunLedgerError.runNotFound(runID)
            }
            snapshot.runs[index].status = .failed
            snapshot.runs[index].failureCode = code
            snapshot.runs[index].lease = nil
            snapshot.runs[index].updatedAt = now()
        }
    }

    public func setPaused(_ paused: Bool) async throws {
        try await committing { $0.controls.isPaused = paused }
    }

    public func setFlowPaused(_ flowID: UUID, paused: Bool) async throws {
        try await committing {
            if paused { $0.controls.pausedFlowIDs.insert(flowID) }
            else { $0.controls.pausedFlowIDs.remove(flowID) }
        }
    }

    private func committing(
        _ mutation: (inout AutomationRunLedgerSnapshot) throws -> Void
    ) async throws {
        let previous = state
        do {
            try mutation(&state)
            try Self.validate(state)
            try await persistence.save(state)
        } catch {
            state = previous
            throw error
        }
    }

    private func recoverExpiredLease(runID: UUID) async throws {
        try await committing { snapshot in
            guard let runIndex = snapshot.runs.firstIndex(where: { $0.id == runID }),
                  let lease = snapshot.runs[runIndex].lease,
                  lease.expiresAt <= now(),
                  let stepIndex = snapshot.runs[runIndex].steps.firstIndex(where: {
                      $0.id == lease.stepReceiptID && $0.status == .running
                  })
            else { return }
            let timestamp = now()
            if snapshot.runs[runIndex].steps[stepIndex].retrySafety == .retrySafe {
                snapshot.runs[runIndex].steps[stepIndex].status = .failed
                snapshot.runs[runIndex].status = .failed
            } else {
                snapshot.runs[runIndex].steps[stepIndex].status = .uncertain
                snapshot.runs[runIndex].status = .uncertain
            }
            snapshot.runs[runIndex].steps[stepIndex].failureCode = .leaseExpired
            snapshot.runs[runIndex].steps[stepIndex].finishedAt = timestamp
            snapshot.runs[runIndex].failureCode = .leaseExpired
            snapshot.runs[runIndex].lease = nil
            snapshot.runs[runIndex].updatedAt = timestamp
        }
    }

    private static func indexes(
        for claim: AutomationRunClaim,
        in snapshot: AutomationRunLedgerSnapshot
    ) throws -> (run: Int, step: Int) {
        guard let runIndex = snapshot.runs.firstIndex(where: { $0.id == claim.runID }),
              snapshot.runs[runIndex].lease == claim.lease,
              let stepIndex = snapshot.runs[runIndex].steps.firstIndex(where: {
                  $0.id == claim.receipt.id && $0.status == .running
              })
        else { throw AutomationRunLedgerError.invalidLease }
        return (runIndex, stepIndex)
    }

    private static func receipts(for steps: [ClipFlowStep]) throws -> [AutomationRunStepReceipt] {
        guard Set(steps.map(\.id)).count == steps.count else {
            throw AutomationRunLedgerError.duplicateStep
        }
        var receipts: [AutomationRunStepReceipt] = []
        var organizationIDs: [UUID] = []
        for step in steps {
            switch step {
            case .addTags, .moveToFolder:
                organizationIDs.append(step.id)
            default:
                if !organizationIDs.isEmpty {
                    receipts.append(AutomationRunStepReceipt(
                        id: organizationIDs[0],
                        sourceStepIDs: organizationIDs,
                        position: receipts.count,
                        kind: .organizeLibrary,
                        retrySafety: .retrySafe
                    ))
                    organizationIDs.removeAll(keepingCapacity: false)
                }
                let kind: AutomationRunStepKind
                switch step {
                case .openWeb: kind = .openWeb
                case .openApplication: kind = .openApplication
                case .createTaskDraft: kind = .createTaskDraft
                case .enrichWithOnDeviceAI: kind = .enrichWithOnDeviceAI
                case .addTags, .moveToFolder: preconditionFailure()
                }
                receipts.append(AutomationRunStepReceipt(
                    id: step.id,
                    sourceStepIDs: [step.id],
                    position: receipts.count,
                    kind: kind,
                    retrySafety: .requiresReconciliation
                ))
            }
        }
        if !organizationIDs.isEmpty {
            receipts.append(AutomationRunStepReceipt(
                id: organizationIDs[0],
                sourceStepIDs: organizationIDs,
                position: receipts.count,
                kind: .organizeLibrary,
                retrySafety: .retrySafe
            ))
        }
        return receipts
    }

    private static func validate(_ snapshot: AutomationRunLedgerSnapshot) throws {
        guard snapshot.schemaVersion == AutomationRunLedgerSnapshot.currentSchemaVersion,
              Set(snapshot.runs.map(\.id)).count == snapshot.runs.count,
              Set(snapshot.runs.map(\.idempotencyKeyHash)).count == snapshot.runs.count
        else { throw AutomationRunLedgerError.invalidRecord }
        for run in snapshot.runs {
            guard isSHA256(run.flowVersionFingerprint), isSHA256(run.clipFingerprint),
                  isSHA256(run.idempotencyKeyHash), !run.steps.isEmpty,
                  Set(run.steps.map(\.id)).count == run.steps.count,
                  run.steps.enumerated().allSatisfy({ $0.offset == $0.element.position }),
                  run.steps.allSatisfy({ !$0.sourceStepIDs.isEmpty })
            else { throw AutomationRunLedgerError.invalidRecord }
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public actor JSONFileAutomationRunLedgerStore: AutomationRunLedgerPersisting {
    public static let maximumFileBytes = 4 * 1_024 * 1_024

    private struct Envelope: Codable {
        let schemaVersion: Int
        let checksum: String
        let payload: Data
    }

    public let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL) {
        self.fileURL = fileURL.standardizedFileURL
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        decoder = JSONDecoder()
    }

    public func load() async throws -> AutomationRunLedgerSnapshot {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .empty }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path) else {
            throw AutomationRunLedgerError.unreadableFile(fileURL)
        }
        if (attributes[.size] as? NSNumber)?.intValue ?? 0 > Self.maximumFileBytes {
            throw AutomationRunLedgerError.fileTooLarge(fileURL, maximum: Self.maximumFileBytes)
        }
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else {
            throw AutomationRunLedgerError.unreadableFile(fileURL)
        }
        guard let envelope = try? decoder.decode(Envelope.self, from: data),
              envelope.schemaVersion == AutomationRunLedgerSnapshot.currentSchemaVersion,
              envelope.payload.count <= Self.maximumFileBytes
        else { throw AutomationRunLedgerError.undecodableFile(fileURL) }
        guard Self.hash(envelope.payload) == envelope.checksum else {
            throw AutomationRunLedgerError.checksumMismatch(fileURL)
        }
        guard let snapshot = try? decoder.decode(AutomationRunLedgerSnapshot.self, from: envelope.payload) else {
            throw AutomationRunLedgerError.undecodableFile(fileURL)
        }
        return snapshot
    }

    public func save(_ snapshot: AutomationRunLedgerSnapshot) async throws {
        do {
            let payload = try encoder.encode(snapshot)
            guard payload.count <= Self.maximumFileBytes else {
                throw AutomationRunLedgerError.fileTooLarge(fileURL, maximum: Self.maximumFileBytes)
            }
            let data = try encoder.encode(Envelope(
                schemaVersion: AutomationRunLedgerSnapshot.currentSchemaVersion,
                checksum: Self.hash(payload),
                payload: payload
            ))
            guard data.count <= Self.maximumFileBytes else {
                throw AutomationRunLedgerError.fileTooLarge(fileURL, maximum: Self.maximumFileBytes)
            }
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch let error as AutomationRunLedgerError {
            throw error
        } catch {
            throw AutomationRunLedgerError.unwritableFile(fileURL)
        }
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public actor InMemoryAutomationRunLedgerStore: AutomationRunLedgerPersisting {
    private var state: AutomationRunLedgerSnapshot

    public init(snapshot: AutomationRunLedgerSnapshot = .empty) { state = snapshot }
    public func load() async throws -> AutomationRunLedgerSnapshot { state }
    public func save(_ snapshot: AutomationRunLedgerSnapshot) async throws { state = snapshot }
}
