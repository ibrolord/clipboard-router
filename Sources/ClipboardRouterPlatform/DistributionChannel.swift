import Foundation

public enum DistributionChannel: String, Sendable {
    case direct
    case macAppStore
}

public protocol DistributionChannelProviding: Sendable {
    var channel: DistributionChannel { get }
}

public struct BundleDistributionChannelProvider: DistributionChannelProviding {
    public static let infoKey = "ClipboardRouterDistributionChannel"
    private let bundle: Bundle

    public init(bundle: Bundle = .main) { self.bundle = bundle }

    public var channel: DistributionChannel {
        guard let raw = bundle.object(forInfoDictionaryKey: Self.infoKey) as? String,
              let channel = DistributionChannel(rawValue: raw)
        else { return .direct }
        return channel
    }
}
