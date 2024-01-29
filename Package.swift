// swift-tools-version: 5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SwiftExperimentalSubprocess",
    platforms: [.macOS("13.3"), .iOS("16.4"), .tvOS("16.4"), .watchOS("9.4")],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "SwiftExperimentalSubprocess",
            targets: ["SwiftExperimentalSubprocess"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-foundation",
            branch: "main"),
        .package(
            url: "https://github.com/apple/swift-system",
            from: "1.0.0")
        
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "SwiftExperimentalSubprocess",
            dependencies: [
                "_Shims",
                .product(name: "FoundationEssentials", package: "swift-foundation"),
                .product(name: "SystemPackage", package: "swift-system"),

            ],
            path: "Sources/Subprocess"),
        .testTarget(
            name: "SwiftExperimentalSubprocessTests",
            dependencies: ["SwiftExperimentalSubprocess"]
        ),

        .target(
            name: "_Shims",
            path: "Sources/_Shims")
    ]
)
