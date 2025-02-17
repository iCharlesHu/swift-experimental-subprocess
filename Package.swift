// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Subprocess",
    platforms: [.macOS("15.0"), .iOS("18.0"), .tvOS("18.0"), .watchOS("11.0")],
    products: [
        .library(
            name: "Subprocess",
            targets: ["Subprocess"]
        ),

        .library(
            name: "SubprocessFoundation",
            targets: ["SubprocessFoundation"]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-system",
            from: "1.0.0"
        )

    ],
    targets: [
        .target(
            name: "Subprocess",
            dependencies: [
                "_SubprocessCShims",
                .product(name: "SystemPackage", package: "swift-system"),

            ],
            path: "Sources/Subprocess",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .enableExperimentalFeature("NonescapableTypes"),
                .enableExperimentalFeature("LifetimeDependence"),
                .enableExperimentalFeature("Span")
            ]
        ),
        .testTarget(
            name: "SubprocessTests",
            dependencies: [
                "_SubprocessCShims",
                "Subprocess",
                "TestResources",
                .product(name: "SystemPackage", package: "swift-system"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("Span")
            ]
        ),

        .target(
            name: "SubprocessFoundation",
            dependencies: [
                "Subprocess"
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .enableExperimentalFeature("NonescapableTypes"),
                .enableExperimentalFeature("LifetimeDependence"),
                .enableExperimentalFeature("Span")
            ]
        ),
        .testTarget(
            name: "SubprocessFoundationTests",
            dependencies: [
                "SubprocessFoundation",
                "TestResources"
            ],
            swiftSettings: [
                .enableExperimentalFeature("Span")
            ]
        ),

        .target(
            name: "TestResources",
            dependencies: [
                .product(name: "SystemPackage", package: "swift-system"),
            ],
            path: "Tests/TestResources",
            resources: [
                .copy("Resources")
            ]
        ),

        .target(
            name: "_SubprocessCShims",
            path: "Sources/_SubprocessCShims"
        ),
    ]
)
