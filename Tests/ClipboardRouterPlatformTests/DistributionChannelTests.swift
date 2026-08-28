import Foundation
import XCTest
@testable import ClipboardRouterPlatform

final class DistributionChannelTests: XCTestCase {
    func testUnconfiguredBundleDefaultsToDirectDistribution() {
        // The test bundle never embeds ClipboardRouterDistributionChannel, matching every
        // build produced before this key existed and any build that omits --distribution-channel.
        let provider = BundleDistributionChannelProvider(bundle: .main)
        XCTAssertEqual(provider.channel, .direct)
    }

    func testRawValuesMatchThePackagingScriptsContract() {
        // Scripts/package_app.sh and Scripts/package_mas.sh write these exact raw values into
        // Info.plist and the release manifest; changing them would silently desync packaging
        // from runtime UI behavior.
        XCTAssertEqual(DistributionChannel.direct.rawValue, "direct")
        XCTAssertEqual(DistributionChannel.macAppStore.rawValue, "macAppStore")
    }
}
