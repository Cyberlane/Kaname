// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Kaname",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
    ],
    products: [
        .library(name: "KanameDomain", targets: ["KanameDomain"]),
        .library(name: "KanameLocalCore", targets: ["KanameLocalCore"]),
        .library(name: "KanameProtocol", targets: ["KanameProtocol"]),
        .library(name: "KanameConnectivity", targets: ["KanameConnectivity"]),
        .library(name: "KanameFixtures", targets: ["KanameFixtures"]),
        .library(name: "KanamePrototypeUI", targets: ["KanamePrototypeUI"]),
        .executable(name: "KanamePrototype", targets: ["KanamePrototype"]),
        .executable(name: "KanameProviderProbe", targets: ["KanameProviderProbe"]),
        .executable(name: "KanameCodexSessionProbe", targets: ["KanameCodexSessionProbe"]),
        .executable(name: "KanameXPCQualification", targets: ["KanameXPCQualification"]),
        .executable(name: "KanameLocalControlService", targets: ["KanameLocalControlService"]),
        .executable(name: "KanameLocalCoreXPCMeasure", targets: ["KanameLocalCoreXPCMeasure"]),
        .executable(name: "KanameProtocolFixtureTool", targets: ["KanameProtocolFixtureTool"]),
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
            name: "KanameFixtures",
            dependencies: ["KanameDomain"]
        ),
        .target(
            name: "KanamePrototypeUI",
            dependencies: ["KanameDomain", "KanameFixtures"]
        ),
        .executableTarget(
            name: "KanamePrototype",
            dependencies: ["KanameDomain", "KanameFixtures", "KanamePrototypeUI", "KanameLocalCore", "KanameConnectivity"]
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
            dependencies: ["KanameLocalCore"]
        ),
        .executableTarget(
            name: "KanameProtocolFixtureTool",
            dependencies: [
                "KanameProtocol",
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ]
        ),
        .testTarget(
            name: "KanameDomainTests",
            dependencies: ["KanameDomain", "KanameFixtures", "KanameConnectivity", "KanameLocalCore", "KanameProtocol"]
        ),
        .testTarget(
            name: "KanameProtocolTests",
            dependencies: ["KanameProtocol"]
        ),
    ]
)
