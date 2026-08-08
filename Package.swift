// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Kaname",
    products: [
        .library(name: "KanameDomain", targets: ["KanameDomain"]),
        .library(name: "KanameFixtures", targets: ["KanameFixtures"]),
    ],
    targets: [
        .target(name: "KanameDomain"),
        .target(
            name: "KanameFixtures",
            dependencies: ["KanameDomain"]
        ),
        .testTarget(
            name: "KanameDomainTests",
            dependencies: ["KanameDomain", "KanameFixtures"]
        ),
    ]
)
