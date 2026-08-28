import SwiftUI
import XCTest
@testable import ClipboardRouterApp

@MainActor
final class DeferredContextMenuContentTests: XCTestCase {
    func testCreatingOneThousandMenuWrappersDoesNotResolveTheirContent() {
        var resolutionCount = 0

        let wrappers = (0 ..< 1_000).map { index in
            DeferredContextMenuContent {
                resolutionCount += 1
                return Text("Clip \(index)")
            }
        }

        XCTAssertEqual(wrappers.count, 1_000)
        XCTAssertEqual(
            resolutionCount,
            0,
            "Library row construction must not resolve action inventories for unopened menus"
        )

        _ = wrappers[437].body

        XCTAssertEqual(
            resolutionCount,
            1,
            "Resolving one opened menu must not resolve any other row's menu content"
        )
    }
}
