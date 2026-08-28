import CoreLocation
import ClipboardRouterCore
import Foundation

public struct DeviceCaptureContext: Equatable, Sendable {
    public let label: String
    public let operatingSystem: String

    public init(label: String, operatingSystem: String) {
        self.label = label
        self.operatingSystem = operatingSystem
    }
}

public enum CaptureLocationAuthorization: String, Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
    case restricted
    case servicesDisabled
}

public struct CaptureLocationSample: Equatable, Sendable {
    public let latitude: Double
    public let longitude: Double
    public let horizontalAccuracy: Double
    public let observedAt: Date

    public init(
        latitude: Double,
        longitude: Double,
        horizontalAccuracy: Double,
        observedAt: Date
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracy = horizontalAccuracy
        self.observedAt = observedAt
    }
}

public enum CaptureContextProviderError: Error, Equatable, LocalizedError, Sendable {
    case locationServicesDisabled
    case locationPermissionDenied
    case locationPermissionRestricted
    case locationPermissionRequired
    case requestInProgress
    case invalidLocation
    case staleLocation
    case locationUnavailable

    public var errorDescription: String? {
        switch self {
        case .locationServicesDisabled:
            "Location Services are disabled. Clipboard capture will continue without location."
        case .locationPermissionDenied:
            "Location permission was denied. Clipboard capture will continue without location."
        case .locationPermissionRestricted:
            "Location access is restricted. Clipboard capture will continue without location."
        case .locationPermissionRequired:
            "Allow Location in Settings before refreshing approximate location."
        case .requestInProgress:
            "A location request is already in progress."
        case .invalidLocation:
            "macOS returned an invalid location."
        case .staleLocation:
            "macOS returned a stale location. Try refreshing again."
        case .locationUnavailable:
            "Approximate location is temporarily unavailable."
        }
    }
}

@MainActor
public protocol CaptureLocationSampling: AnyObject {
    var authorization: CaptureLocationAuthorization { get }
    func requestAuthorization() async -> CaptureLocationAuthorization
    func requestSample() async throws -> CaptureLocationSample
}

@MainActor
public protocol CaptureLocationReverseGeocoding: AnyObject {
    func label(for sample: CaptureLocationSample) async throws -> String?
}

/// Default privacy-preserving reducer. It never sends coordinates to a geocoder or network.
@MainActor
public final class LocalOnlyCaptureLocationLabeler: CaptureLocationReverseGeocoding {
    public init() {}
    public func label(for sample: CaptureLocationSample) async throws -> String? { nil }
}

@MainActor
public protocol CaptureContextProviding: AnyObject {
    var deviceContext: DeviceCaptureContext { get }
    var locationAuthorization: CaptureLocationAuthorization { get }
    var cachedCoarseLocation: CoarseLocationContext? { get }
    var cachedLocationDate: Date? { get }

    /// This is the only provider operation that may ask macOS for location permission.
    func requestLocationPermissionAndRefresh(at date: Date) async throws -> CoarseLocationContext
    /// Refreshes only after permission has already been granted and never prompts.
    func refreshLocation(at date: Date) async throws -> CoarseLocationContext
    func currentCoarseLocation(at date: Date) -> CoarseLocationContext?
    func clearLocation()
}

@MainActor
public final class SystemCaptureContextProvider: CaptureContextProviding {
    public static let defaultMaximumLocationAge: TimeInterval = 15 * 60
    public static let defaultMaximumHorizontalAccuracy: Double = 50_000
    public static let futureTimestampTolerance: TimeInterval = 60

    private let sampler: any CaptureLocationSampling
    private let geocoder: any CaptureLocationReverseGeocoding
    private let maximumLocationAge: TimeInterval
    private let maximumHorizontalAccuracy: Double
    private let deviceContextValue: DeviceCaptureContext

    public private(set) var cachedCoarseLocation: CoarseLocationContext?
    public private(set) var cachedLocationDate: Date?

    public init(
        sampler: any CaptureLocationSampling = SystemCaptureLocationSampler(),
        geocoder: any CaptureLocationReverseGeocoding = LocalOnlyCaptureLocationLabeler(),
        maximumLocationAge: TimeInterval = SystemCaptureContextProvider.defaultMaximumLocationAge,
        maximumHorizontalAccuracy: Double = SystemCaptureContextProvider.defaultMaximumHorizontalAccuracy,
        deviceContext: DeviceCaptureContext? = nil
    ) {
        self.sampler = sampler
        self.geocoder = geocoder
        self.maximumLocationAge = max(1, maximumLocationAge)
        self.maximumHorizontalAccuracy = max(1, maximumHorizontalAccuracy)
        self.deviceContextValue = deviceContext ?? DeviceCaptureContext(
            label: Host.current().localizedName ?? "This Mac",
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString
        )
    }

    public var deviceContext: DeviceCaptureContext { deviceContextValue }
    public var locationAuthorization: CaptureLocationAuthorization { sampler.authorization }

    public func requestLocationPermissionAndRefresh(
        at date: Date = Date()
    ) async throws -> CoarseLocationContext {
        let status = await sampler.requestAuthorization()
        try validateAuthorization(status)
        return try await acquireCoarseLocation(at: date)
    }

    public func refreshLocation(at date: Date = Date()) async throws -> CoarseLocationContext {
        try validateAuthorization(sampler.authorization)
        return try await acquireCoarseLocation(at: date)
    }

    public func currentCoarseLocation(at date: Date = Date()) -> CoarseLocationContext? {
        guard let cachedCoarseLocation, let cachedLocationDate else { return nil }
        let age = date.timeIntervalSince(cachedLocationDate)
        guard age >= -Self.futureTimestampTolerance, age <= maximumLocationAge else {
            return nil
        }
        return cachedCoarseLocation
    }

    public func clearLocation() {
        cachedCoarseLocation = nil
        cachedLocationDate = nil
    }

    private func acquireCoarseLocation(at date: Date) async throws -> CoarseLocationContext {
        let sample = try await sampler.requestSample()
        guard sample.latitude.isFinite,
              sample.longitude.isFinite,
              (-90...90).contains(sample.latitude),
              (-180...180).contains(sample.longitude),
              sample.horizontalAccuracy.isFinite,
              sample.horizontalAccuracy >= 0,
              sample.horizontalAccuracy <= maximumHorizontalAccuracy
        else { throw CaptureContextProviderError.invalidLocation }

        let age = date.timeIntervalSince(sample.observedAt)
        guard age >= -Self.futureTimestampTolerance, age <= maximumLocationAge else {
            throw CaptureContextProviderError.staleLocation
        }

        let geohash = Self.geohash(
            latitude: sample.latitude,
            longitude: sample.longitude,
            precision: 5
        )
        let resolved = try await geocoder.label(for: sample)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let label = (resolved?.isEmpty == false) ? resolved! : "Approximate area \(geohash)"
        let coarse = try CoarseLocationContext(label: label, geohash: geohash)

        // The exact sample deliberately falls out of scope here. Only the reduced label,
        // maximum-five-character geohash, and observation time remain in memory.
        cachedCoarseLocation = coarse
        cachedLocationDate = sample.observedAt
        return coarse
    }

    private func validateAuthorization(_ status: CaptureLocationAuthorization) throws {
        switch status {
        case .authorized:
            return
        case .notDetermined:
            throw CaptureContextProviderError.locationPermissionRequired
        case .denied:
            throw CaptureContextProviderError.locationPermissionDenied
        case .restricted:
            throw CaptureContextProviderError.locationPermissionRestricted
        case .servicesDisabled:
            throw CaptureContextProviderError.locationServicesDisabled
        }
    }

    public static func geohash(
        latitude: Double,
        longitude: Double,
        precision: Int = 5
    ) -> String {
        let alphabet = Array("0123456789bcdefghjkmnpqrstuvwxyz")
        let boundedPrecision = min(max(1, precision), 5)
        var latitudeRange = (-90.0, 90.0)
        var longitudeRange = (-180.0, 180.0)
        var value = 0
        var bits = 0
        var usesLongitude = true
        var result = ""

        while result.count < boundedPrecision {
            if usesLongitude {
                let midpoint = (longitudeRange.0 + longitudeRange.1) / 2
                value = (value << 1) | (longitude >= midpoint ? 1 : 0)
                if longitude >= midpoint { longitudeRange.0 = midpoint }
                else { longitudeRange.1 = midpoint }
            } else {
                let midpoint = (latitudeRange.0 + latitudeRange.1) / 2
                value = (value << 1) | (latitude >= midpoint ? 1 : 0)
                if latitude >= midpoint { latitudeRange.0 = midpoint }
                else { latitudeRange.1 = midpoint }
            }
            usesLongitude.toggle()
            bits += 1
            if bits == 5 {
                result.append(alphabet[value])
                bits = 0
                value = 0
            }
        }
        return result
    }
}

@MainActor
public final class SystemCaptureLocationSampler: NSObject, CaptureLocationSampling,
    @preconcurrency CLLocationManagerDelegate
{
    private let manager: CLLocationManager
    private var authorizationContinuation: CheckedContinuation<CaptureLocationAuthorization, Never>?
    private var sampleContinuation: CheckedContinuation<CaptureLocationSample, any Error>?

    public override init() {
        manager = CLLocationManager()
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    public var authorization: CaptureLocationAuthorization {
        guard CLLocationManager.locationServicesEnabled() else { return .servicesDisabled }
        return switch manager.authorizationStatus {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .authorizedAlways, .authorizedWhenInUse: .authorized
        @unknown default: .denied
        }
    }

    public func requestAuthorization() async -> CaptureLocationAuthorization {
        guard authorization == .notDetermined else { return authorization }
        guard authorizationContinuation == nil else { return authorization }
        return await withCheckedContinuation { continuation in
            authorizationContinuation = continuation
            manager.requestWhenInUseAuthorization()
        }
    }

    public func requestSample() async throws -> CaptureLocationSample {
        let currentAuthorization = authorization
        guard currentAuthorization == .authorized else {
            switch currentAuthorization {
            case .notDetermined: throw CaptureContextProviderError.locationPermissionRequired
            case .denied: throw CaptureContextProviderError.locationPermissionDenied
            case .restricted: throw CaptureContextProviderError.locationPermissionRestricted
            case .servicesDisabled: throw CaptureContextProviderError.locationServicesDisabled
            case .authorized: throw CaptureContextProviderError.locationUnavailable
            }
        }
        guard sampleContinuation == nil else { throw CaptureContextProviderError.requestInProgress }
        return try await withCheckedThrowingContinuation { continuation in
            sampleContinuation = continuation
            manager.requestLocation()
        }
    }

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard authorization != .notDetermined, let continuation = authorizationContinuation else {
            return
        }
        authorizationContinuation = nil
        continuation.resume(returning: authorization)
    }

    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let continuation = sampleContinuation else { return }
        sampleContinuation = nil
        guard let location = locations.max(by: { $0.timestamp < $1.timestamp }) else {
            continuation.resume(throwing: CaptureContextProviderError.locationUnavailable)
            return
        }
        continuation.resume(returning: CaptureLocationSample(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            horizontalAccuracy: location.horizontalAccuracy,
            observedAt: location.timestamp
        ))
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        guard let continuation = sampleContinuation else { return }
        sampleContinuation = nil
        continuation.resume(throwing: CaptureContextProviderError.locationUnavailable)
    }
}
