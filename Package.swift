// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ClipboardRouter",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "ClipboardRouterCore",
            targets: ["ClipboardRouterCore"]
        ),
        .library(
            name: "ClipboardRouterPlatform",
            targets: ["ClipboardRouterPlatform"]
        ),
        .library(
            name: "ClipboardRouterSecurity",
            targets: ["ClipboardRouterSecurity"]
        ),
        .library(
            name: "ClipboardRouterSync",
            targets: ["ClipboardRouterSync"]
        ),
        .executable(
            name: "ClipboardRouter",
            targets: ["ClipboardRouterApp"]
        ),
        .executable(
            name: "cr",
            targets: ["ClipboardRouterCLI"]
        ),
        .executable(
            name: "cr-ui-acceptance",
            targets: ["ClipboardRouterUIAcceptance"]
        ),
    ],
    targets: [
        .target(
            name: "ClipboardRouterCore",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .target(
            name: "ClipboardRouterPlatform",
            dependencies: ["ClipboardRouterCore"],
            linkerSettings: [
                .linkedFramework("Contacts"),
                .linkedFramework("CoreLocation"),
                .linkedFramework("EventKit"),
                .linkedFramework("ImageIO"),
                .linkedFramework("Network"),
                .linkedFramework("Security"),
            ]
        ),
        .target(
            name: "ClipboardRouterSecurity",
            dependencies: ["ClipboardRouterCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CryptoKit"),
                .linkedFramework("LocalAuthentication"),
                .linkedFramework("Security"),
            ]
        ),
        .target(
            name: "ClipboardRouterSync",
            dependencies: ["ClipboardRouterCore"],
            linkerSettings: [
                .linkedFramework("CloudKit"),
                .linkedFramework("CryptoKit"),
            ]
        ),
        .executableTarget(
            name: "ClipboardRouterApp",
            dependencies: [
                "ClipboardRouterCore",
                "ClipboardRouterPlatform",
                "ClipboardRouterSecurity",
                "ClipboardRouterSync",
            ]
        ),
        .executableTarget(
            name: "ClipboardRouterCLI",
            dependencies: ["ClipboardRouterCore", "ClipboardRouterSecurity"]
        ),
        .executableTarget(
            name: "ClipboardRouterUIAcceptance"
        ),
        .testTarget(
            name: "ClipboardRouterCoreTests",
            dependencies: ["ClipboardRouterCore"]
        ),
        .testTarget(
            name: "ClipboardRouterPlatformTests",
            dependencies: ["ClipboardRouterCore", "ClipboardRouterPlatform"]
        ),
        .testTarget(
            name: "ClipboardRouterSecurityTests",
            dependencies: ["ClipboardRouterCore", "ClipboardRouterSecurity"]
        ),
        .testTarget(
            name: "ClipboardRouterSyncTests",
            dependencies: ["ClipboardRouterCore", "ClipboardRouterSync"]
        ),
        .testTarget(
            name: "ClipboardRouterAppTests",
            dependencies: [
                "ClipboardRouterApp",
                "ClipboardRouterCore",
                "ClipboardRouterPlatform",
                "ClipboardRouterSecurity",
                "ClipboardRouterSync",
            ]
        ),
        .testTarget(
            name: "ClipboardRouterCLITests",
            dependencies: ["ClipboardRouterCLI", "ClipboardRouterCore", "ClipboardRouterSecurity"]
        )
    ],
    swiftLanguageModes: [.v6]
)
