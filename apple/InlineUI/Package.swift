// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "InlineUI",
  defaultLocalization: "en",
  platforms: [
    .iOS(.v17),
    .macOS(.v13),
  ],
  products: [
    // Products define the executables and libraries a package produces, making them visible to other packages.
    .library(
      name: "InlineUI",
      targets: ["InlineUI"]
    )
  ],
  dependencies: [
    .package(path: "../InlineKit")
  ],
  targets: [
    // Targets are the basic building blocks of a package, defining a module or a test suite.
    // Targets can depend on other targets in this package and products from dependencies.
    .target(
      name: "InlineUI",
      dependencies: [
        .product(name: "InlineKit", package: "InlineKit")
      ],
      swiftSettings: [
        .swiftLanguageMode(.v6)
      ]
    ),
    .testTarget(
      name: "InlineUITests",
      dependencies: ["InlineUI"]
    ),
  ]
)
