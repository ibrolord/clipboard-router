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
        .library(
            name: "ClipboardRouterAgentAccess",
            targets: ["ClipboardRouterAgentAccess"]
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
    dependencies: [
        // Official MCP Swift SDK, pinned exactly (tag 0.12.1 =
        // a0ae212ebf6eab5f754c3129608bc5557637e605). 0.11.0 does not compile with the
        // Swift 6.4 toolchain (region-isolation errors in NetworkTransport.swift).
        // Linked only into the `cr` CLI.
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
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
        .target(
            name: "ClipboardRouterAgentAccess",
            linkerSettings: [
                .linkedFramework("Security"),
            ]
        ),
        .executableTarget(
            name: "ClipboardRouterApp",
            dependencies: [
                "ClipboardRouterAgentAccess",
                "ClipboardRouterCore",
                "ClipboardRouterPlatform",
                "ClipboardRouterSecurity",
                "ClipboardRouterSync",
            ]
        ),
        .executableTarget(
            name: "ClipboardRouterCLI",
            dependencies: [
                "ClipboardRouterAgentAccess",
                "ClipboardRouterCore",
                "ClipboardRouterSecurity",
                .product(name: "MCP", package: "swift-sdk"),
            ]
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
                "ClipboardRouterAgentAccess",
                "ClipboardRouterApp",
                "ClipboardRouterCore",
                "ClipboardRouterPlatform",
                "ClipboardRouterSecurity",
                "ClipboardRouterSync",
            ]
        ),
        .testTarget(
            name: "ClipboardRouterCLITests",
            dependencies: [
                "ClipboardRouterAgentAccess",
                "ClipboardRouterCLI",
                "ClipboardRouterCore",
                "ClipboardRouterSecurity",
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
        .testTarget(
            name: "ClipboardRouterAgentAccessTests",
            dependencies: ["ClipboardRouterAgentAccess"]
        )
    ],
    swiftLanguageModes: [.v6]
)
