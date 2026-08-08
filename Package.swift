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
        .library(name: "KanameConnectivity", targets: ["KanameConnectivity"]),
        .library(name: "KanameFixtures", targets: ["KanameFixtures"]),
        .library(name: "KanamePrototypeUI", targets: ["KanamePrototypeUI"]),
        .executable(name: "KanamePrototype", targets: ["KanamePrototype"]),
        .executable(name: "KanameProviderProbe", targets: ["KanameProviderProbe"]),
        .executable(name: "KanameXPCQualification", targets: ["KanameXPCQualification"]),
    ],
    targets: [
        .target(name: "KanameDomain"),
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
        .testTarget(
            name: "KanameDomainTests",
            dependencies: ["KanameDomain", "KanameFixtures", "KanameConnectivity"]
        ),
    ]
)
