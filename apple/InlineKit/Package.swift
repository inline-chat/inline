// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "InlineKit",
  defaultLocalization: "en",
  platforms: [
    .iOS(.v17),
    .macOS(.v14),
  ],
  products: [
    // Products define the executables and libraries a package produces, making them visible to other packages.
    .library(
      name: "InlineKit",
      targets: ["InlineKit"]
    ),
    .library(
      name: "InlineConfig",
      targets: ["InlineConfig"]
    ),
    .library(
      name: "Logger",
      targets: ["Logger"]
    ),
    .library(
      name: "InlineProtocol",
      targets: ["InlineProtocol"]
    ),
    .library(
      name: "FileAttachments",
      targets: ["FileAttachments"]
    ),
  ],
  dependencies: [
    .package(url: "https://github.com/inline-chat/GRDB.swift", from: "3.2.0"),
    .package(url: "https://github.com/inline-chat/GRDBQuery", from: "0.11.4"),
    .package(url: "https://github.com/getsentry/sentry-cocoa", from: "8.36.0"),
    .package(url: "https://github.com/evgenyneu/keychain-swift.git", from: "24.0.0"),
    .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.28.2"),
    .package(url: "https://github.com/Kuniwak/MultipartFormDataKit", from: "1.0.0"),
    .package(url: "https://github.com/kean/Get", from: "2.2.1"),
    .package(url: "https://github.com/kean/Nuke", from: "12.8.0"),
    .package(
      url: "https://github.com/apple/swift-atomics.git",
      .upToNextMajor(from: "1.2.0")
    ),
    .package(url: "https://github.com/apple/swift-async-algorithms", from: "1.0.0"),
  ],
  targets: [
    // Targets are the basic building blocks of a package, defining a module or a test suite.
    // Targets can depend on other targets in this package and products from dependencies.

    .target(
      name: "Logger",
      dependencies: [
        .product(name: "Sentry", package: "sentry-cocoa"),
      ]
    ),

    .target(
      name: "InlineKit",
      dependencies: [
        .product(name: "GRDB", package: "GRDB.swift"),
        .product(name: "GRDBQuery", package: "GRDBQuery"),
        .product(name: "Sentry", package: "sentry-cocoa"),
        .product(name: "KeychainSwift", package: "keychain-swift"),
        .product(name: "Atomics", package: "swift-atomics"),
        .product(name: "MultipartFormDataKit", package: "MultipartFormDataKit"),
        .product(name: "Get", package: "Get"),
        .product(name: "Nuke", package: "Nuke"),
        .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
        "InlineConfig",
        "InlineProtocol",
        "Logger",
        "Auth",
      ],
      swiftSettings: [
        .swiftLanguageMode(.v6),
      ]
    ),

    .target(
      name: "InlineConfig"
    ),

    .target(
      name: "Auth",
      dependencies: [
        .product(name: "KeychainSwift", package: "keychain-swift"),
        .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
        "InlineConfig",
        "Logger",
      ]
    ),

    .target(
      name: "InlineProtocol",
      dependencies: [
        .product(name: "SwiftProtobuf", package: "swift-protobuf"),
      ]
    ),

    .target(
      name: "FileAttachments",
      dependencies: [
        "InlineKit",
        "Logger",
      ]
    ),

    .testTarget(
      name: "InlineKitTests",
      dependencies: ["InlineKit"]
    ),
  ]
)
