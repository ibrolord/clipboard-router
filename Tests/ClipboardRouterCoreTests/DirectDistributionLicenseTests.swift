import Foundation
import XCTest
@testable import ClipboardRouterCore

final class DirectDistributionLicenseTests: XCTestCase {
    private let machine = DirectLicenseStateMachine()
    private let deviceID = "device-a"
    private let issuedAt = Date(timeIntervalSince1970: 1_700_000_000)

    func testClaimsEnforcePlanExpiryAndBoundOfflineGrace() throws {
        XCTAssertThrowsError(try claims(plan: .trial, expiresAt: nil))
        XCTAssertThrowsError(try claims(plan: .subscription, expiresAt: issuedAt))
        XCTAssertThrowsError(try claims(
            plan: .lifetime,
            expiresAt: issuedAt.addingTimeInterval(60)
        ))
        XCTAssertThrowsError(try claims(
            plan: .trial,
            expiresAt: issuedAt.addingTimeInterval(60),
            grace: DirectLicenseTokenClaims.maximumOfflineGraceDuration + 1
        ))

        XCTAssertNoThrow(try claims(plan: .lifetime, expiresAt: nil))
    }

    func testStateMachineCoversActiveGraceExpiredAndRevoked() throws {
        let expiry = issuedAt.addingTimeInterval(3_600)
        let subscription = try claims(
            plan: .subscription,
            expiresAt: expiry,
            grace: 600
        )

        XCTAssertEqual(evaluate(subscription, at: expiry.addingTimeInterval(-1)).status,
                       .active(plan: .subscription, expiresAt: expiry))
        XCTAssertEqual(evaluate(subscription, at: expiry.addingTimeInterval(1)).status,
                       .grace(plan: .subscription, endsAt: expiry.addingTimeInterval(600)))
        XCTAssertEqual(evaluate(subscription, at: expiry.addingTimeInterval(601)).status,
                       .expired(plan: .subscription, expiredAt: expiry))

        let revokedAt = issuedAt.addingTimeInterval(300)
        let revoked = try claims(
            plan: .subscription,
            expiresAt: expiry,
            grace: 600,
            revokedAt: revokedAt
        )
        XCTAssertEqual(evaluate(revoked, at: revokedAt).status,
                       .revoked(plan: .subscription, revokedAt: revokedAt))
    }

    func testLifetimeIsActiveWithoutExpiry() throws {
        let lifetime = try claims(plan: .lifetime, expiresAt: nil)
        XCTAssertEqual(
            evaluate(lifetime, at: issuedAt.addingTimeInterval(10_000_000)).status,
            .active(plan: .lifetime, expiresAt: nil)
        )
    }

    func testDeviceMismatchAndInvalidEvidenceFailClosed() throws {
        let otherDevice = try claims(
            deviceID: "device-b",
            plan: .lifetime,
            expiresAt: nil
        )
        XCTAssertEqual(evaluate(otherDevice, at: issuedAt).status, .tampered)

        let observation = DirectLicenseClockObservation(
            wallClock: issuedAt,
            monotonicUptime: 100
        )
        XCTAssertEqual(machine.evaluate(
            evidence: .tampered,
            expectedDeviceID: deviceID,
            observation: observation,
            checkpoint: nil
        ).status, .tampered)
        XCTAssertEqual(machine.evaluate(
            evidence: .verifierUnavailable,
            expectedDeviceID: deviceID,
            observation: observation,
            checkpoint: nil
        ).status, .unavailable(.verifierUnavailable))
    }

    func testMissingEvidenceDistinguishesNoLicenseFromServiceOutage() {
        let observation = DirectLicenseClockObservation(
            wallClock: issuedAt,
            monotonicUptime: 100
        )
        XCTAssertEqual(machine.evaluate(
            evidence: .missing,
            expectedDeviceID: deviceID,
            observation: observation,
            checkpoint: nil
        ).status, .unavailable(.noLicense))
        XCTAssertEqual(machine.evaluate(
            evidence: .missing,
            expectedDeviceID: deviceID,
            observation: observation,
            checkpoint: nil,
            serviceUnavailable: true
        ).status, .unavailable(.serviceUnavailable))
    }

    func testClockRollbackResistanceUsesMonotonicFloorAndSurvivesReboot() throws {
        let lifetime = try claims(plan: .lifetime, expiresAt: nil)
        let checkpoint = DirectLicenseClockCheckpoint(
            lastWallClock: issuedAt,
            lastMonotonicUptime: 1_000
        )

        let sameBootRollback = machine.evaluate(
            evidence: .verified(lifetime),
            expectedDeviceID: deviceID,
            observation: DirectLicenseClockObservation(
                wallClock: issuedAt.addingTimeInterval(100),
                monotonicUptime: 2_000
            ),
            checkpoint: checkpoint
        )
        XCTAssertEqual(sameBootRollback.status, .tampered)

        let rebootRollback = machine.evaluate(
            evidence: .verified(lifetime),
            expectedDeviceID: deviceID,
            observation: DirectLicenseClockObservation(
                wallClock: issuedAt.addingTimeInterval(-301),
                monotonicUptime: 10
            ),
            checkpoint: checkpoint
        )
        XCTAssertEqual(rebootRollback.status, .tampered)

        let toleratedReboot = machine.evaluate(
            evidence: .verified(lifetime),
            expectedDeviceID: deviceID,
            observation: DirectLicenseClockObservation(
                wallClock: issuedAt.addingTimeInterval(-299),
                monotonicUptime: 10
            ),
            checkpoint: checkpoint
        )
        XCTAssertEqual(toleratedReboot.status, .active(plan: .lifetime, expiresAt: nil))
        XCTAssertEqual(toleratedReboot.effectiveDate, issuedAt)
    }

    func testNoDataLockoutPolicyAcrossFailureStates() {
        let failureStates: [DirectLicenseStatus] = [
            .expired(plan: .trial, expiredAt: issuedAt),
            .revoked(plan: .lifetime, revokedAt: issuedAt),
            .unavailable(.noLicense),
            .unavailable(.serviceUnavailable),
            .unavailable(.verifierUnavailable),
            .tampered,
        ]

        for status in failureStates {
            let policy = DirectLicenseAccessPolicy(status: status)
            XCTAssertTrue(policy.allows(.search), "search must survive \(status)")
            XCTAssertTrue(policy.allows(.copy), "copy must survive \(status)")
            XCTAssertTrue(policy.allows(.export), "export must survive \(status)")
            XCTAssertTrue(policy.allows(.delete), "delete must survive \(status)")
            XCTAssertFalse(policy.allows(.premiumCreation))
            XCTAssertFalse(policy.allows(.automation))
            XCTAssertFalse(policy.allows(.cloud))
            XCTAssertFalse(policy.allows(.ai))
        }

        let engineering = DirectLicenseAccessPolicy(status: .unavailable(.engineeringBuild))
        XCTAssertTrue(engineering.allows(.premiumCreation))
        XCTAssertTrue(engineering.allows(.automation))
        XCTAssertTrue(engineering.allows(.cloud))
        XCTAssertTrue(engineering.allows(.ai))
    }

    private func claims(
        deviceID: String? = nil,
        plan: DirectLicensePlan,
        expiresAt: Date?,
        grace: TimeInterval = 0,
        revokedAt: Date? = nil
    ) throws -> DirectLicenseTokenClaims {
        try DirectLicenseTokenClaims(
            licenseID: "license-a",
            accountID: "account-a",
            deviceID: deviceID ?? self.deviceID,
            plan: plan,
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            offlineGraceDuration: grace,
            revokedAt: revokedAt
        )
    }

    private func evaluate(
        _ claims: DirectLicenseTokenClaims,
        at date: Date
    ) -> DirectLicenseEvaluation {
        machine.evaluate(
            evidence: .verified(claims),
            expectedDeviceID: deviceID,
            observation: DirectLicenseClockObservation(
                wallClock: date,
                monotonicUptime: max(0, date.timeIntervalSince(issuedAt))
            ),
            checkpoint: nil
        )
    }
}
