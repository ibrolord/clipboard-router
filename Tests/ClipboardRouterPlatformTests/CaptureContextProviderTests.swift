import ClipboardRouterCore
import Foundation
import XCTest
@testable import ClipboardRouterPlatform

@MainActor
final class CaptureContextProviderTests: XCTestCase {
    func testRefreshNeverRequestsPermissionButExplicitAllowDoes() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let sampler = StubLocationSampler(
            authorization: .notDetermined,
            authorizationAfterRequest: .authorized,
            sample: CaptureLocationSample(
                latitude: 43.6532,
                longitude: -79.3832,
                horizontalAccuracy: 1_000,
                observedAt: now
            )
        )
        let provider = SystemCaptureContextProvider(
            sampler: sampler,
            geocoder: StubLocationGeocoder(label: "Toronto, ON")
        )

        do {
            _ = try await provider.refreshLocation(at: now)
            XCTFail("Refresh must not request permission")
        } catch let error as CaptureContextProviderError {
            XCTAssertEqual(error, .locationPermissionRequired)
        }
        XCTAssertEqual(sampler.authorizationRequestCount, 0)
        XCTAssertEqual(sampler.sampleRequestCount, 0)

        let coarse = try await provider.requestLocationPermissionAndRefresh(at: now)
        XCTAssertEqual(sampler.authorizationRequestCount, 1)
        XCTAssertEqual(sampler.sampleRequestCount, 1)
        XCTAssertEqual(coarse.label, "Toronto, ON")
        XCTAssertEqual(coarse.geohash, "dpz83")
    }

    func testStaleOrInaccurateSamplesFailClosedWithoutCaching() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let stale = StubLocationSampler(
            authorization: .authorized,
            sample: CaptureLocationSample(
                latitude: 43.6532,
                longitude: -79.3832,
                horizontalAccuracy: 1_000,
                observedAt: now.addingTimeInterval(-901)
            )
        )
        let staleProvider = SystemCaptureContextProvider(
            sampler: stale,
            geocoder: StubLocationGeocoder(label: "Toronto, ON")
        )
        await XCTAssertThrowsCaptureContext(.staleLocation) {
            _ = try await staleProvider.refreshLocation(at: now)
        }
        XCTAssertNil(staleProvider.cachedCoarseLocation)

        let inaccurate = StubLocationSampler(
            authorization: .authorized,
            sample: CaptureLocationSample(
                latitude: 43.6532,
                longitude: -79.3832,
                horizontalAccuracy: 50_001,
                observedAt: now
            )
        )
        let inaccurateProvider = SystemCaptureContextProvider(
            sampler: inaccurate,
            geocoder: StubLocationGeocoder(label: "Toronto, ON")
        )
        await XCTAssertThrowsCaptureContext(.invalidLocation) {
            _ = try await inaccurateProvider.refreshLocation(at: now)
        }
        XCTAssertNil(inaccurateProvider.cachedCoarseLocation)
    }

    func testOnlyReducedContextCanBePersistedAndCacheExpiresOrClears() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let sampler = StubLocationSampler(
            authorization: .authorized,
            sample: CaptureLocationSample(
                latitude: 43.6532,
                longitude: -79.3832,
                horizontalAccuracy: 1_000,
                observedAt: now
            )
        )
        let provider = SystemCaptureContextProvider(
            sampler: sampler,
            geocoder: StubLocationGeocoder(label: nil)
        )
        let coarse = try await provider.refreshLocation(at: now)

        XCTAssertEqual(coarse.geohash?.count, 5)
        XCTAssertNotNil(provider.currentCoarseLocation(at: now.addingTimeInterval(899)))
        XCTAssertNil(provider.currentCoarseLocation(at: now.addingTimeInterval(901)))
        let json = String(decoding: try JSONEncoder().encode(coarse), as: UTF8.self)
        XCTAssertFalse(json.contains("43.6532"))
        XCTAssertFalse(json.contains("-79.3832"))
        XCTAssertFalse(json.contains("latitude"))
        XCTAssertFalse(json.contains("longitude"))

        provider.clearLocation()
        XCTAssertNil(provider.cachedCoarseLocation)
        XCTAssertNil(provider.cachedLocationDate)
    }
}

@MainActor
private final class StubLocationSampler: CaptureLocationSampling {
    var authorization: CaptureLocationAuthorization
    let authorizationAfterRequest: CaptureLocationAuthorization
    let sample: CaptureLocationSample
    private(set) var authorizationRequestCount = 0
    private(set) var sampleRequestCount = 0

    init(
        authorization: CaptureLocationAuthorization,
        authorizationAfterRequest: CaptureLocationAuthorization? = nil,
        sample: CaptureLocationSample
    ) {
        self.authorization = authorization
        self.authorizationAfterRequest = authorizationAfterRequest ?? authorization
        self.sample = sample
    }

    func requestAuthorization() async -> CaptureLocationAuthorization {
        authorizationRequestCount += 1
        authorization = authorizationAfterRequest
        return authorization
    }

    func requestSample() async throws -> CaptureLocationSample {
        sampleRequestCount += 1
        return sample
    }
}

@MainActor
private final class StubLocationGeocoder: CaptureLocationReverseGeocoding {
    let resolvedLabel: String?

    init(label: String?) { resolvedLabel = label }

    func label(for sample: CaptureLocationSample) async throws -> String? {
        resolvedLabel
    }
}

@MainActor
private func XCTAssertThrowsCaptureContext(
    _ expected: CaptureContextProviderError,
    operation: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await operation()
        XCTFail("Expected \(expected)", file: file, line: line)
    } catch let error as CaptureContextProviderError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("Unexpected error: \(error)", file: file, line: line)
    }
}
