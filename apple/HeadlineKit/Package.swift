// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "HeadlineKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v12),
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "HeadlineKit",
            targets: ["HeadlineKit"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/duckduckgo/GRDB.swift", branch: "main"),
        .package(url: "https://github.com/getsentry/sentry-cocoa", from: "8.36.0"),

    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "HeadlineKit",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Sentry", package: "Sentry"),
            ]
        ),

        .testTarget(
            name: "HeadlineKitTests",
            dependencies: ["HeadlineKit"]
        ),
    ]
)
