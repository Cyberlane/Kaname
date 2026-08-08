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
        .library(name: "KanameFixtures", targets: ["KanameFixtures"]),
        .executable(name: "KanamePrototype", targets: ["KanamePrototype"]),
    ],
    targets: [
        .target(name: "KanameDomain"),
        .target(
            name: "KanameFixtures",
            dependencies: ["KanameDomain"]
        ),
        .executableTarget(
            name: "KanamePrototype",
            dependencies: ["KanameDomain", "KanameFixtures"]
        ),
        .testTarget(
            name: "KanameDomainTests",
            dependencies: ["KanameDomain", "KanameFixtures"]
        ),
    ]
)
