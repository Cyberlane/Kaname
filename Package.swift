// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Kaname",
    platforms: [
        .macOS(.v26),
        .iOS(.v17),
    ],
    products: [
        .library(name: "KanameDomain", targets: ["KanameDomain"]),
        .library(name: "KanameLocalCore", targets: ["KanameLocalCore"]),
        .library(name: "KanameProtocol", targets: ["KanameProtocol"]),
        .library(name: "KanameConnectivity", targets: ["KanameConnectivity"]),
        .library(name: "KanameMobileSync", targets: ["KanameMobileSync"]),
        .library(name: "KanameLinkProtocol", targets: ["KanameLinkProtocol"]),
        .library(name: "KanameLinkHost", targets: ["KanameLinkHost"]),
        .library(name: "KanameLinkTunnelHost", targets: ["KanameLinkTunnelHost"]),
        .library(name: "KanameDesignSystem", targets: ["KanameDesignSystem"]),
        .library(name: "KanameDesktop", targets: ["KanameDesktop"]),
        .library(name: "KanameDesktopUI", targets: ["KanameDesktopUI"]),
        .library(name: "KanameWorkflowHost", targets: ["KanameWorkflowHost"]),
        .library(name: "KanameFixtures", targets: ["KanameFixtures"]),
        .library(name: "KanamePrototypeUI", targets: ["KanamePrototypeUI"]),
        .executable(name: "KanamePrototype", targets: ["KanamePrototype"]),
        .executable(name: "KanameLink", targets: ["KanameLinkMac"]),
        .executable(name: "KanameDesignCatalog", targets: ["KanameDesignCatalog"]),
        .executable(name: "KanameLinkTunnelTool", targets: ["KanameLinkTunnelTool"]),
        .executable(name: "KanameProviderProbe", targets: ["KanameProviderProbe"]),
        .executable(name: "KanameCodexSessionProbe", targets: ["KanameCodexSessionProbe"]),
        .executable(name: "KanameXPCQualification", targets: ["KanameXPCQualification"]),
        .executable(name: "KanameLocalControlService", targets: ["KanameLocalControlService"]),
        .executable(name: "KanameLocalCoreXPCMeasure", targets: ["KanameLocalCoreXPCMeasure"]),
        .executable(name: "KanameUpdateHelper", targets: ["KanameUpdateHelper"]),
        .executable(name: "KanameDogfoodUpdatePublisher", targets: ["KanameDogfoodUpdatePublisher"]),
        .executable(name: "KanameConversationWorker", targets: ["KanameConversationWorker"]),
        .executable(name: "KanameWorkflowWorker", targets: ["KanameWorkflowWorker"]),
        .executable(name: "KanameWorkflowLlmHost", targets: ["KanameWorkflowLlmHost"]),
        .executable(name: "KanameWorkflowCapabilityHost", targets: ["KanameWorkflowCapabilityHost"]),
        .executable(name: "KanameWorkflowConnectorHost", targets: ["KanameWorkflowConnectorHost"]),
        .executable(name: "KanameProtocolFixtureTool", targets: ["KanameProtocolFixtureTool"]),
        .executable(name: "KanamePhase3Qualification", targets: ["KanamePhase3Qualification"]),
        .library(
            name: "KanameToolchainQualificationSupport",
            targets: ["KanameToolchainQualificationSupport"]
        ),
        .executable(
            name: "KanameWorkflowSchemaQualification",
            targets: ["KanameWorkflowSchemaQualification"]
        ),
        .executable(
            name: "KanameWorkflowCanonicalQualification",
            targets: ["KanameWorkflowCanonicalQualification"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.38.1"),
        .package(url: "https://github.com/1amageek/swift-flow.git", exact: "0.20.3"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", exact: "2.13.7"),
    ],
    targets: [
        .target(name: "KanameDomain"),
        .target(
            name: "KanameLocalCore",
            dependencies: [
                "KanameProtocol",
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ]
        ),
        .target(
            name: "KanameProtocol",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            path: "proto",
            exclude: ["kaname/qualification"],
            plugins: [
                .plugin(name: "SwiftProtobufPlugin", package: "swift-protobuf"),
            ]
        ),
        .target(
            name: "KanameConnectivity",
            dependencies: [
                "KanameDomain",
                "KanameLocalCore",
                "KanameProtocol",
                "SwiftSoup",
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ]
        ),
        .target(
            name: "KanameMobileSync",
            dependencies: [
                "KanameProtocol",
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ]
        ),
        .target(
            name: "KanameLinkProtocol",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            path: "proto-link",
            plugins: [
                .plugin(name: "SwiftProtobufPlugin", package: "swift-protobuf"),
            ]
        ),
        .target(name: "KanameLinkHost"),
        .target(name: "KanameDesignSystem"),
        .target(
            name: "KanameLinkTunnelHost",
            path: "Sources/KanameLinkTunnelHost",
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("LocalAuthentication"),
            ]
        ),
        .executableTarget(
            name: "KanameLinkTunnelTool",
            dependencies: ["KanameLinkTunnelHost"],
            path: "Sources/KanameLinkTunnelTool"
        ),
        .target(
            name: "KanameFixtures",
            dependencies: ["KanameDomain"]
        ),
        .target(
            name: "KanamePrototypeUI",
            dependencies: ["KanameDesignSystem", "KanameDomain", "KanameFixtures", "KanameMobileSync", "KanameProtocol"]
        ),
        .target(
            name: "KanameDesktop",
            dependencies: ["KanameDomain", "KanameLocalCore", "KanameMobileSync", "KanameProtocol", "KanameConnectivity"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "KanameDesktopUI",
            dependencies: ["KanameDesignSystem", "KanameDesktop", "KanameLinkHost"]
        ),
        .target(
            name: "KanameWorkflowHost",
            dependencies: [
                "KanameDesktop", "KanameConnectivity", "KanameLocalCore", "KanameProtocol",
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ]
        ),
        .executableTarget(
            name: "KanamePrototype",
            dependencies: [
                "KanameDesktop",
                "KanameDesktopUI",
                "KanameDesignSystem",
                "KanameDomain",
                "KanameFixtures",
                "KanamePrototypeUI",
                "KanameLinkHost",
                "KanameLocalCore",
                "KanameConnectivity",
                "KanameWorkflowHost",
                .product(name: "SwiftFlow", package: "swift-flow"),
            ]
        ),
        .executableTarget(
            name: "KanameLinkMac",
            dependencies: ["KanameDesignSystem"],
            path: "Sources/KanameLinkMac"
        ),
        .executableTarget(
            name: "KanameDesignCatalog",
            dependencies: ["KanameDesignSystem"]
        ),
        .executableTarget(
            name: "KanameProviderProbe",
            dependencies: ["KanameConnectivity", "KanameDomain"]
        ),
        .executableTarget(
            name: "KanameCodexSessionProbe",
            dependencies: ["KanameConnectivity", "KanameDomain"]
        ),
        .executableTarget(name: "KanameXPCQualification"),
        .executableTarget(
            name: "KanameLocalControlService",
            dependencies: ["KanameLocalCore"]
        ),
        .executableTarget(
            name: "KanameLocalCoreXPCMeasure",
            dependencies: ["KanameLocalCore", "KanameMobileSync", "KanameProtocol"]
        ),
        .executableTarget(name: "KanameUpdateHelper"),
        .executableTarget(
            name: "KanameDogfoodUpdatePublisher",
            dependencies: ["KanameConnectivity"]
        ),
        .executableTarget(
            name: "KanameConversationWorker",
            dependencies: ["KanameConnectivity", "KanameDomain", "KanameLocalCore"]
        ),
        .executableTarget(
            name: "KanameWorkflowWorker",
            dependencies: ["KanameWorkflowHost", "KanameConnectivity", "KanameDesktop", "KanameLocalCore"]
        ),
        .executableTarget(
            name: "KanameWorkflowLlmHost",
            dependencies: []
        ),
        .executableTarget(
            name: "KanameWorkflowCapabilityHost",
            dependencies: ["KanameDesktop"]
        ),
        .executableTarget(
            name: "KanameWorkflowConnectorHost",
            dependencies: []
        ),
        .executableTarget(
            name: "KanameProtocolFixtureTool",
            dependencies: [
                "KanameProtocol",
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ]
        ),
        .executableTarget(
            name: "KanamePhase3Qualification",
            dependencies: ["KanameMobileSync", "KanameProtocol"]
        ),
        .executableTarget(
            name: "KanameWorkflowSchemaQualification",
            dependencies: ["KanameDesktop", "KanameToolchainQualificationSupport"]
        ),
        .executableTarget(
            name: "KanameWorkflowCanonicalQualification",
            dependencies: ["KanameToolchainQualificationSupport"]
        ),
        .target(name: "KanameToolchainQualificationSupport"),
        .testTarget(
            name: "KanameDomainTests",
            dependencies: ["KanameDomain", "KanameFixtures", "KanameConnectivity", "KanameLocalCore", "KanameProtocol"]
        ),
        .testTarget(
            name: "KanameProtocolTests",
            dependencies: ["KanameProtocol"]
        ),
        .testTarget(
            name: "KanameMobileSyncTests",
            dependencies: ["KanameMobileSync", "KanameProtocol"]
        ),
        .testTarget(
            name: "KanameLinkProtocolTests",
            dependencies: ["KanameLinkProtocol"]
        ),
        .testTarget(
            name: "KanameLinkHostTests",
            dependencies: ["KanameLinkHost"]
        ),
        .testTarget(
            name: "KanameLinkTunnelHostTests",
            dependencies: ["KanameLinkTunnelHost"],
            path: "Tests/KanameLinkTunnelHostTests"
        ),
        .testTarget(
            name: "KanameLinkTunnelToolTests",
            dependencies: ["KanameLinkTunnelTool", "KanameLinkTunnelHost"],
            path: "Tests/KanameLinkTunnelToolTests"
        ),
        .testTarget(
            name: "KanameDesignSystemTests",
            dependencies: ["KanameDesignSystem"]
        ),
        .testTarget(
            name: "KanameDesktopTests",
            dependencies: ["KanameConnectivity", "KanameDesktop", "KanameProtocol", "KanameWorkflowHost"]
        ),
        .testTarget(
            name: "KanameDesktopUITests",
            dependencies: ["KanameDesktopUI", "KanameDesignSystem", "KanameDesktop", "KanameLinkHost"]
        ),
        .testTarget(
            name: "KanamePrototypeUITests",
            dependencies: ["KanamePrototypeUI", "KanameDesignSystem"]
        ),
    ]
)
