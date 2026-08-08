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
        .library(name: "KanameProtocol", targets: ["KanameProtocol"]),
        .library(name: "KanameConnectivity", targets: ["KanameConnectivity"]),
        .library(name: "KanameFixtures", targets: ["KanameFixtures"]),
        .library(name: "KanamePrototypeUI", targets: ["KanamePrototypeUI"]),
        .executable(name: "KanamePrototype", targets: ["KanamePrototype"]),
        .executable(name: "KanameProviderProbe", targets: ["KanameProviderProbe"]),
        .executable(name: "KanameXPCQualification", targets: ["KanameXPCQualification"]),
        .executable(name: "KanameProtocolFixtureTool", targets: ["KanameProtocolFixtureTool"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.38.1"),
    ],
    targets: [
        .target(name: "KanameDomain"),
        .target(
            name: "KanameProtocol",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ]
        ),
        .target(name: "KanameConnectivity", dependencies: ["KanameDomain"]),
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
            dependencies: ["KanameDomain", "KanameFixtures", "KanamePrototypeUI"]
        ),
        .executableTarget(
            name: "KanameProviderProbe",
            dependencies: ["KanameConnectivity", "KanameDomain"]
        ),
        .executableTarget(name: "KanameXPCQualification"),
        .executableTarget(
            name: "KanameProtocolFixtureTool",
            dependencies: [
                "KanameProtocol",
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ]
        ),
        .testTarget(
            name: "KanameDomainTests",
            dependencies: ["KanameDomain", "KanameFixtures", "KanameConnectivity"]
        ),
        .testTarget(
            name: "KanameProtocolTests",
            dependencies: ["KanameProtocol"]
        ),
    ]
)
