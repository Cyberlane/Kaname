// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Kaname",
    products: [
        .library(name: "KanameDomain", targets: ["KanameDomain"]),
    ],
    targets: [
        .target(name: "KanameDomain"),
        .testTarget(
            name: "KanameDomainTests",
            dependencies: ["KanameDomain"]
        ),
    ]
)
