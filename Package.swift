// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Kaname",
    platforms: [
        .macOS(.v13),
        .iOS(.v17),
    ],
    products: [
        .library(name: "KanameDomain", targets: ["KanameDomain"]),
        .library(name: "KanameLocalCore", targets: ["KanameLocalCore"]),
        .library(name: "KanameProtocol", targets: ["KanameProtocol"]),
        .library(name: "KanameConnectivity", targets: ["KanameConnectivity"]),
        .library(name: "KanameMobileSync", targets: ["KanameMobileSync"]),
        .library(name: "KanameDesktop", targets: ["KanameDesktop"]),
        .library(name: "KanameWorkflowHost", targets: ["KanameWorkflowHost"]),
        .library(name: "KanameFixtures", targets: ["KanameFixtures"]),
        .library(name: "KanamePrototypeUI", targets: ["KanamePrototypeUI"]),
        .executable(name: "KanamePrototype", targets: ["KanamePrototype"]),
        .executable(name: "KanameProviderProbe", targets: ["KanameProviderProbe"]),
        .executable(name: "KanameCodexSessionProbe", targets: ["KanameCodexSessionProbe"]),
        .executable(name: "KanameXPCQualification", targets: ["KanameXPCQualification"]),
        .executable(name: "KanameLocalControlService", targets: ["KanameLocalControlService"]),
        .executable(name: "KanameLocalCoreXPCMeasure", targets: ["KanameLocalCoreXPCMeasure"]),
        .executable(name: "KanameUpdateHelper", targets: ["KanameUpdateHelper"]),
        .executable(name: "KanameDogfoodUpdatePublisher", targets: ["KanameDogfoodUpdatePublisher"]),
        .executable(name: "KanameConversationWorker", targets: ["KanameConversationWorker"]),
        .executable(name: "KanameWorkflowWorker", targets: ["KanameWorkflowWorker"]),
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
            ]
        ),
        .target(
            name: "KanameConnectivity",
            dependencies: [
                "KanameDomain",
                "KanameLocalCore",
                "KanameProtocol",
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
            name: "KanameFixtures",
            dependencies: ["KanameDomain"]
        ),
        .target(
            name: "KanamePrototypeUI",
            dependencies: ["KanameDomain", "KanameFixtures", "KanameMobileSync", "KanameProtocol"]
        ),
        .target(
            name: "KanameDesktop",
            dependencies: ["KanameDomain", "KanameLocalCore", "KanameMobileSync"]
        ),
        .target(
            name: "KanameWorkflowHost",
            dependencies: ["KanameDesktop", "KanameConnectivity"]
        ),
        .executableTarget(
            name: "KanamePrototype",
            dependencies: [
                "KanameDesktop",
                "KanameDomain",
                "KanameFixtures",
                "KanamePrototypeUI",
                "KanameLocalCore",
                "KanameConnectivity",
                "KanameWorkflowHost",
            ]
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
            dependencies: ["KanameWorkflowHost", "KanameConnectivity", "KanameDesktop"]
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
            name: "KanameDesktopTests",
            dependencies: ["KanameConnectivity", "KanameDesktop", "KanameWorkflowHost"]
        ),
    ]
)
