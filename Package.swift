// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription
import CompilerPluginSupport

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
            name: "CambiumSerialization",
            targets: ["CambiumSerialization"]
        ),
        .library(
            name: "CambiumTesting",
            targets: ["CambiumTesting"]
        ),
        .library(
            name: "CambiumSyntaxMacros",
            targets: ["CambiumSyntaxMacros"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "603.0.0"),
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
                "CambiumSerialization",
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
            name: "CambiumSerialization",
            dependencies: [
                "CambiumCore",
                "CambiumBuilder",
            ]
        ),
        .target(
            name: "CambiumTesting",
            dependencies: ["CambiumCore"]
        ),
        .target(
            name: "CambiumSyntaxMacros",
            dependencies: [
                "CambiumCore",
                "CambiumSyntaxMacrosPlugin",
            ]
        ),
        .macro(
            name: "CambiumSyntaxMacrosPlugin",
            dependencies: [
                "CambiumCore",
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "SwiftDiagnostics", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
            ]
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
                "CambiumSerialization",
            ]
        ),
        .testTarget(
            name: "CambiumSyntaxMacrosTests",
            dependencies: [
                "CambiumBuilder",
                "CambiumCore",
                "CambiumSyntaxMacros",
                "CambiumSyntaxMacrosPlugin",
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
