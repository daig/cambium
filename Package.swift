// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "cambium",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(
            name: "Cambium",
            targets: ["Cambium"]
        ),
        .library(
            name: "CambiumCore",
            targets: ["CambiumCore"]
        ),
        .library(
            name: "CambiumBuilder",
            targets: ["CambiumBuilder"]
        ),
        .library(
            name: "CambiumIncremental",
            targets: ["CambiumIncremental"]
        ),
        .library(
            name: "CambiumAnalysis",
            targets: ["CambiumAnalysis"]
        ),
        .library(
            name: "CambiumASTSupport",
            targets: ["CambiumASTSupport"]
        ),
        .library(
            name: "CambiumOwnedTraversal",
            targets: ["CambiumOwnedTraversal"]
        ),
        .library(
            name: "CambiumTesting",
            targets: ["CambiumTesting"]
        ),
    ],
    targets: [
        .target(
            name: "Cambium",
            dependencies: [
                "CambiumCore",
                "CambiumBuilder",
                "CambiumIncremental",
                "CambiumAnalysis",
                "CambiumASTSupport",
                "CambiumOwnedTraversal",
            ]
        ),
        .target(
            name: "CambiumCore"
        ),
        .target(
            name: "CambiumBuilder",
            dependencies: ["CambiumCore"]
        ),
        .target(
            name: "CambiumIncremental",
            dependencies: ["CambiumCore"]
        ),
        .target(
            name: "CambiumAnalysis",
            dependencies: ["CambiumCore"]
        ),
        .target(
            name: "CambiumASTSupport",
            dependencies: ["CambiumCore"]
        ),
        .target(
            name: "CambiumOwnedTraversal",
            dependencies: ["CambiumCore"]
        ),
        .target(
            name: "CambiumTesting",
            dependencies: ["CambiumCore"]
        ),
        .testTarget(
            name: "CambiumCoreTests",
            dependencies: [
                "CambiumCore",
                "CambiumBuilder",
                "CambiumIncremental",
                "CambiumAnalysis",
                "CambiumASTSupport",
                "CambiumOwnedTraversal",
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
