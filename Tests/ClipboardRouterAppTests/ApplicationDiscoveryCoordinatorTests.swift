import Foundation
import ClipboardRouterPlatform
import XCTest
@testable import ClipboardRouterApp

final class ApplicationDiscoveryCoordinatorTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 10_000)

    func testRequestsCoalesceWhileDiscoveryIsInFlightEvenWhenForced() {
        var coordinator = ApplicationDiscoveryCoordinator(cacheTTL: 300)

        XCTAssertEqual(coordinator.request(at: start, force: false), .start(generation: 1))
        XCTAssertEqual(coordinator.request(at: start.addingTimeInterval(1), force: false), .coalesced)
        XCTAssertEqual(coordinator.request(at: start.addingTimeInterval(2), force: true), .coalesced)
        XCTAssertEqual(coordinator.inFlightGeneration, 1)
    }

    func testCompletedSnapshotIsReusedOnlyWithinBoundedTTL() {
        var coordinator = ApplicationDiscoveryCoordinator(cacheTTL: 300)
        XCTAssertEqual(coordinator.request(at: start, force: false), .start(generation: 1))
        XCTAssertTrue(coordinator.complete(generation: 1, at: start.addingTimeInterval(10)))

        XCTAssertEqual(
            coordinator.request(at: start.addingTimeInterval(309), force: false),
            .reuseCached
        )
        XCTAssertEqual(
            coordinator.request(at: start.addingTimeInterval(310), force: false),
            .start(generation: 2)
        )
    }

    func testForceRefreshBypassesFreshCompletedSnapshot() {
        var coordinator = ApplicationDiscoveryCoordinator(
            cacheTTL: 300,
            lastCompletedAt: start
        )

        XCTAssertEqual(
            coordinator.request(at: start.addingTimeInterval(1), force: true),
            .start(generation: 1)
        )
    }

    func testCancellationClearsInFlightStateAndAllowsNewGeneration() {
        var coordinator = ApplicationDiscoveryCoordinator(cacheTTL: 300)
        XCTAssertEqual(coordinator.request(at: start, force: false), .start(generation: 1))

        XCTAssertTrue(coordinator.cancel(generation: 1))
        XCTAssertNil(coordinator.inFlightGeneration)
        XCTAssertEqual(
            coordinator.request(at: start.addingTimeInterval(1), force: false),
            .start(generation: 2)
        )
    }

    func testStaleCompletionCannotClearOrCacheNewerGeneration() {
        var coordinator = ApplicationDiscoveryCoordinator(cacheTTL: 300)
        XCTAssertEqual(coordinator.request(at: start, force: false), .start(generation: 1))
        XCTAssertTrue(coordinator.cancel(generation: 1))
        XCTAssertEqual(
            coordinator.request(at: start.addingTimeInterval(1), force: true),
            .start(generation: 2)
        )

        XCTAssertFalse(coordinator.complete(generation: 1, at: start.addingTimeInterval(2)))
        XCTAssertEqual(coordinator.inFlightGeneration, 2)
        XCTAssertNil(coordinator.lastCompletedAt)
    }

    func testClockRollbackDoesNotExtendCacheLifetime() {
        var coordinator = ApplicationDiscoveryCoordinator(
            cacheTTL: 300,
            lastCompletedAt: start
        )

        XCTAssertEqual(
            coordinator.request(at: start.addingTimeInterval(-1), force: false),
            .start(generation: 1)
        )
    }
}

final class ApplicationVerificationTests: XCTestCase {
    func testDiscoveryRootsUseRealUserHomeInsteadOfSandboxContainerHome() {
        let roots = AppModel.applicationDiscoveryRoots(
            userHomeDirectory: URL(fileURLWithPath: "/Users/example", isDirectory: true)
        )

        XCTAssertEqual(roots.map(\.path), [
            "/Applications",
            "/System/Applications",
            "/Users/example/Applications",
        ])
        XCTAssertFalse(roots.map(\.path).contains {
            $0.contains("/Library/Containers/")
        })
    }

    func testDiscoveryRootsRemainUsefulWhenLoginUserHomeCannotBeResolved() {
        XCTAssertEqual(
            AppModel.applicationDiscoveryRoots(userHomeDirectory: nil).map(\.path),
            ["/Applications", "/System/Applications"]
        )
    }

    func testVerificationPreservesDiscoveryOrderAndDropsUnverifiedApplications() async {
        let options = (0..<5).map(makeOption)

        let verified = await AppModel.verifyApplications(
            options,
            maximumConcurrentChecks: 2
        ) { url in
            let index = Int(url.deletingPathExtension().lastPathComponent)!
            return InstalledApplicationMetadata(
                url: url,
                bundleIdentifier: index == 2 ? "wrong.bundle" : "test.bundle.\(index)",
                bundleName: nil,
                displayName: nil,
                executableName: nil,
                signature: index == 3 ? .invalid : .valid(teamIdentifier: "TEAM123")
            )
        }

        XCTAssertEqual(verified.map(\.bundleIdentifier), [
            "test.bundle.0", "test.bundle.1", "test.bundle.4",
        ])
    }

    func testVerificationBoundsConcurrentSignatureChecks() async {
        let options = (0..<24).map(makeOption)
        let counter = ConcurrentCheckCounter()

        let verified = await AppModel.verifyApplications(
            options,
            maximumConcurrentChecks: 4
        ) { url in
            counter.begin()
            Thread.sleep(forTimeInterval: 0.01)
            counter.end()
            let index = Int(url.deletingPathExtension().lastPathComponent)!
            return InstalledApplicationMetadata(
                url: url,
                bundleIdentifier: "test.bundle.\(index)",
                bundleName: nil,
                displayName: nil,
                executableName: nil,
                signature: .valid(teamIdentifier: "TEAM123")
            )
        }

        XCTAssertEqual(verified.count, options.count)
        XCTAssertGreaterThan(counter.maximumObserved, 1)
        XCTAssertLessThanOrEqual(counter.maximumObserved, 4)
    }

    func testVerificationPreservesDistinctInstalledCopiesWithTheSameBundleIdentifier() async {
        let firstURL = URL(fileURLWithPath: "/Applications/Primary/Duplicate.app")
        let secondURL = URL(fileURLWithPath: "/Applications/Secondary/Duplicate.app")
        let options = [firstURL, secondURL].map { url in
            ApplicationExclusionOption(
                bundleIdentifier: "test.duplicate",
                displayName: "Duplicate",
                applicationURL: url,
                teamIdentifier: nil,
                isRunning: false
            )
        }

        let verified = await AppModel.verifyApplications(options) { url in
            InstalledApplicationMetadata(
                url: url,
                bundleIdentifier: "test.duplicate",
                bundleName: "Duplicate",
                displayName: "Duplicate",
                executableName: "Duplicate",
                signature: .valid(teamIdentifier: "TEAM123")
            )
        }

        XCTAssertEqual(verified.map(\.applicationURL), [firstURL, secondURL])
        XCTAssertEqual(Set(verified.map(\.id)).count, 2)
    }

    func testVerificationKeepsValidPlatformSignedApplicationWithoutTeamIdentifier() async {
        let option = makeOption(0)

        let verified = await AppModel.verifyApplications([option]) { url in
            InstalledApplicationMetadata(
                url: url,
                bundleIdentifier: option.bundleIdentifier,
                bundleName: "Apple Platform App",
                displayName: "Apple Platform App",
                executableName: "PlatformApp",
                signature: .valid(teamIdentifier: nil)
            )
        }

        XCTAssertEqual(verified.count, 1)
        XCTAssertEqual(verified.first?.applicationURL, option.applicationURL)
        XCTAssertNil(verified.first?.teamIdentifier)
    }

    private func makeOption(_ index: Int) -> ApplicationExclusionOption {
        ApplicationExclusionOption(
            bundleIdentifier: "test.bundle.\(index)",
            displayName: "Application \(index)",
            applicationURL: URL(fileURLWithPath: "/Applications/\(index).app"),
            teamIdentifier: nil,
            isRunning: index.isMultiple(of: 2)
        )
    }
}

private final class ConcurrentCheckCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private var maximum = 0

    var maximumObserved: Int {
        lock.lock()
        defer { lock.unlock() }
        return maximum
    }

    func begin() {
        lock.lock()
        current += 1
        maximum = max(maximum, current)
        lock.unlock()
    }

    func end() {
        lock.lock()
        current -= 1
        lock.unlock()
    }
}
