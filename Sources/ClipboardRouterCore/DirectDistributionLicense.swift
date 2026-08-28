import Foundation

public enum DirectLicensePlan: String, Codable, CaseIterable, Sendable {
    case trial
    case lifetime
    case subscription
}

public struct DirectLicenseTokenClaims: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let maximumOfflineGraceDuration: TimeInterval = 7 * 24 * 60 * 60

    public let schemaVersion: Int
    public let licenseID: String
    public let accountID: String
    public let deviceID: String
    public let plan: DirectLicensePlan
    public let issuedAt: Date
    public let expiresAt: Date?
    public let offlineGraceDuration: TimeInterval
    public let revokedAt: Date?

    public init(
        schemaVersion: Int = currentSchemaVersion,
        licenseID: String,
        accountID: String,
        deviceID: String,
        plan: DirectLicensePlan,
        issuedAt: Date,
        expiresAt: Date? = nil,
        offlineGraceDuration: TimeInterval = 0,
        revokedAt: Date? = nil
    ) throws {
        let licenseID = licenseID.trimmingCharacters(in: .whitespacesAndNewlines)
        let accountID = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        let deviceID = deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard schemaVersion == Self.currentSchemaVersion,
              (1...128).contains(licenseID.utf8.count),
              (1...256).contains(accountID.utf8.count),
              (1...128).contains(deviceID.utf8.count),
              [licenseID, accountID, deviceID].allSatisfy({
                  $0.rangeOfCharacter(from: .controlCharacters) == nil
              }),
              offlineGraceDuration.isFinite,
              (0...Self.maximumOfflineGraceDuration).contains(offlineGraceDuration)
        else { throw DirectLicenseError.invalidClaims }

        switch plan {
        case .lifetime:
            guard expiresAt == nil else { throw DirectLicenseError.invalidClaims }
        case .trial, .subscription:
            guard let expiresAt, expiresAt > issuedAt else {
                throw DirectLicenseError.invalidClaims
            }
        }
        if let revokedAt, revokedAt < issuedAt {
            throw DirectLicenseError.invalidClaims
        }

        self.schemaVersion = schemaVersion
        self.licenseID = licenseID
        self.accountID = accountID
        self.deviceID = deviceID
        self.plan = plan
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.offlineGraceDuration = offlineGraceDuration
        self.revokedAt = revokedAt
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, licenseID, accountID, deviceID, plan, issuedAt, expiresAt
        case offlineGraceDuration, revokedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion),
            licenseID: container.decode(String.self, forKey: .licenseID),
            accountID: container.decode(String.self, forKey: .accountID),
            deviceID: container.decode(String.self, forKey: .deviceID),
            plan: container.decode(DirectLicensePlan.self, forKey: .plan),
            issuedAt: container.decode(Date.self, forKey: .issuedAt),
            expiresAt: container.decodeIfPresent(Date.self, forKey: .expiresAt),
            offlineGraceDuration: container.decodeIfPresent(
                TimeInterval.self,
                forKey: .offlineGraceDuration
            ) ?? 0,
            revokedAt: container.decodeIfPresent(Date.self, forKey: .revokedAt)
        )
    }
}

public enum DirectLicenseUnavailableReason: String, Equatable, Sendable {
    case engineeringBuild
    case noLicense
    case verifierUnavailable
    case serviceUnavailable
}

public enum DirectLicenseStatus: Equatable, Sendable {
    case active(plan: DirectLicensePlan, expiresAt: Date?)
    case grace(plan: DirectLicensePlan, endsAt: Date)
    case expired(plan: DirectLicensePlan, expiredAt: Date)
    case revoked(plan: DirectLicensePlan, revokedAt: Date)
    case unavailable(DirectLicenseUnavailableReason)
    case tampered

    public var plan: DirectLicensePlan? {
        switch self {
        case let .active(plan, _), let .grace(plan, _), let .expired(plan, _),
             let .revoked(plan, _): plan
        case .unavailable, .tampered: nil
        }
    }
}

public enum DirectLicenseEvidence: Equatable, Sendable {
    case verified(DirectLicenseTokenClaims)
    case missing
    case verifierUnavailable
    case tampered
}

public struct DirectLicenseClockObservation: Equatable, Sendable {
    public let wallClock: Date
    public let monotonicUptime: TimeInterval

    public init(wallClock: Date, monotonicUptime: TimeInterval) {
        self.wallClock = wallClock
        self.monotonicUptime = monotonicUptime
    }
}

public struct DirectLicenseClockCheckpoint: Codable, Equatable, Sendable {
    public let lastWallClock: Date
    public let lastMonotonicUptime: TimeInterval
    public let lastServerVerifiedAt: Date?

    public init(
        lastWallClock: Date,
        lastMonotonicUptime: TimeInterval,
        lastServerVerifiedAt: Date? = nil
    ) {
        self.lastWallClock = lastWallClock
        self.lastMonotonicUptime = lastMonotonicUptime
        self.lastServerVerifiedAt = lastServerVerifiedAt
    }
}

public struct DirectLicenseEvaluation: Equatable, Sendable {
    public let status: DirectLicenseStatus
    public let effectiveDate: Date
    public let nextCheckpoint: DirectLicenseClockCheckpoint
    public let accountID: String?
    public let licenseID: String?

    public init(
        status: DirectLicenseStatus,
        effectiveDate: Date,
        nextCheckpoint: DirectLicenseClockCheckpoint,
        accountID: String? = nil,
        licenseID: String? = nil
    ) {
        self.status = status
        self.effectiveDate = effectiveDate
        self.nextCheckpoint = nextCheckpoint
        self.accountID = accountID
        self.licenseID = licenseID
    }
}

public enum DirectLicenseCapability: Equatable, Sendable {
    case premiumCreation
    case automation
    case cloud
    case ai
    case search
    case copy
    case export
    case delete
}

public struct DirectLicenseAccessPolicy: Equatable, Sendable {
    public let status: DirectLicenseStatus

    public init(status: DirectLicenseStatus) { self.status = status }

    public func allows(_ capability: DirectLicenseCapability) -> Bool {
        switch capability {
        case .search, .copy, .export, .delete:
            return true
        case .premiumCreation, .automation, .cloud, .ai:
            return switch status {
            case .active, .grace, .unavailable(.engineeringBuild): true
            case .expired, .revoked, .unavailable, .tampered: false
            }
        }
    }
}

public struct DirectLicenseStateMachine: Sendable {
    public static let clockRollbackTolerance: TimeInterval = 5 * 60

    public init() {}

    public func evaluate(
        evidence: DirectLicenseEvidence,
        expectedDeviceID: String,
        observation: DirectLicenseClockObservation,
        checkpoint: DirectLicenseClockCheckpoint?,
        serviceUnavailable: Bool = false,
        serverVerifiedAt: Date? = nil
    ) -> DirectLicenseEvaluation {
        guard observation.monotonicUptime.isFinite, observation.monotonicUptime >= 0 else {
            return tamperedEvaluation(observation: observation, checkpoint: checkpoint)
        }

        let effectiveDate: Date
        if let checkpoint {
            let monotonicDelta = observation.monotonicUptime - checkpoint.lastMonotonicUptime
            if monotonicDelta >= 0 {
                let monotonicFloor = checkpoint.lastWallClock.addingTimeInterval(monotonicDelta)
                guard observation.wallClock.addingTimeInterval(Self.clockRollbackTolerance)
                        >= monotonicFloor
                else { return tamperedEvaluation(observation: observation, checkpoint: checkpoint) }
                effectiveDate = max(observation.wallClock, monotonicFloor)
            } else {
                // A reboot can reset monotonic uptime. Wall time still cannot move materially
                // behind the last secure checkpoint.
                guard observation.wallClock.addingTimeInterval(Self.clockRollbackTolerance)
                        >= checkpoint.lastWallClock
                else { return tamperedEvaluation(observation: observation, checkpoint: checkpoint) }
                effectiveDate = max(observation.wallClock, checkpoint.lastWallClock)
            }
        } else {
            effectiveDate = observation.wallClock
        }

        let nextCheckpoint = DirectLicenseClockCheckpoint(
            lastWallClock: effectiveDate,
            lastMonotonicUptime: observation.monotonicUptime,
            lastServerVerifiedAt: serverVerifiedAt ?? checkpoint?.lastServerVerifiedAt
        )

        switch evidence {
        case .tampered:
            return DirectLicenseEvaluation(
                status: .tampered,
                effectiveDate: effectiveDate,
                nextCheckpoint: nextCheckpoint
            )
        case .verifierUnavailable:
            return DirectLicenseEvaluation(
                status: .unavailable(.verifierUnavailable),
                effectiveDate: effectiveDate,
                nextCheckpoint: nextCheckpoint
            )
        case .missing:
            return DirectLicenseEvaluation(
                status: .unavailable(serviceUnavailable ? .serviceUnavailable : .noLicense),
                effectiveDate: effectiveDate,
                nextCheckpoint: nextCheckpoint
            )
        case let .verified(claims):
            guard claims.deviceID == expectedDeviceID else {
                return DirectLicenseEvaluation(
                    status: .tampered,
                    effectiveDate: effectiveDate,
                    nextCheckpoint: nextCheckpoint
                )
            }
            let status: DirectLicenseStatus
            if let revokedAt = claims.revokedAt, revokedAt <= effectiveDate {
                status = .revoked(plan: claims.plan, revokedAt: revokedAt)
            } else if claims.plan == .lifetime {
                status = .active(plan: .lifetime, expiresAt: nil)
            } else if let expiresAt = claims.expiresAt, effectiveDate < expiresAt {
                status = .active(plan: claims.plan, expiresAt: expiresAt)
            } else if let expiresAt = claims.expiresAt {
                let graceEnd = expiresAt.addingTimeInterval(claims.offlineGraceDuration)
                status = effectiveDate <= graceEnd
                    ? .grace(plan: claims.plan, endsAt: graceEnd)
                    : .expired(plan: claims.plan, expiredAt: expiresAt)
            } else {
                status = .tampered
            }
            return DirectLicenseEvaluation(
                status: status,
                effectiveDate: effectiveDate,
                nextCheckpoint: nextCheckpoint,
                accountID: claims.accountID,
                licenseID: claims.licenseID
            )
        }
    }

    private func tamperedEvaluation(
        observation: DirectLicenseClockObservation,
        checkpoint: DirectLicenseClockCheckpoint?
    ) -> DirectLicenseEvaluation {
        let safeDate = max(observation.wallClock, checkpoint?.lastWallClock ?? observation.wallClock)
        return DirectLicenseEvaluation(
            status: .tampered,
            effectiveDate: safeDate,
            nextCheckpoint: DirectLicenseClockCheckpoint(
                lastWallClock: safeDate,
                lastMonotonicUptime: max(0, observation.monotonicUptime),
                lastServerVerifiedAt: checkpoint?.lastServerVerifiedAt
            )
        )
    }
}

public enum DirectLicenseError: Error, Equatable, LocalizedError, Sendable {
    case invalidClaims
    case invalidToken
    case invalidSignature
    case verifierUnavailable
    case repositoryUnavailable
    case activationRejected
    case restoreRejected
    case deactivationRejected
    case secureStorageFailure
    case operationInProgress
    case premiumLicenseRequired

    public var errorDescription: String? {
        switch self {
        case .invalidClaims: "The license contains invalid claims."
        case .invalidToken: "The license token is malformed."
        case .invalidSignature: "The license signature could not be verified."
        case .verifierUnavailable: "This build has no configured license public key."
        case .repositoryUnavailable: "The licensing service is unavailable. Your current local state was not changed."
        case .activationRejected: "The license could not be activated."
        case .restoreRejected: "No matching license could be restored."
        case .deactivationRejected: "The device could not be deactivated. Your local license remains connected."
        case .secureStorageFailure: "The license could not be stored securely in this Mac's Keychain."
        case .operationInProgress: "A licensing operation is already in progress."
        case .premiumLicenseRequired: "This feature requires an active license or offline grace period. Your existing clips remain available."
        }
    }
}
