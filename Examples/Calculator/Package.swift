// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "Calculator",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(
            name: "CalculatorCore",
            targets: ["CalculatorCore"]
        ),
        .executable(
            name: "calc-repl",
            targets: ["CalculatorREPL"]
        ),
    ],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .target(
            name: "CalculatorCore",
            dependencies: [
                .product(name: "Cambium", package: "cambium"),
                .product(name: "CambiumSyntaxMacros", package: "cambium"),
            ]
        ),
        .executableTarget(
            name: "CalculatorREPL",
            dependencies: ["CalculatorCore"]
        ),
        .testTarget(
            name: "CalculatorCoreTests",
            dependencies: ["CalculatorCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
