// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let swiftSettings: [SwiftSetting] = [
  .swiftLanguageMode(.v6),
]

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
    .library(
      name: "RealtimeV2",
      targets: ["RealtimeV2"]
    ),
    .library(
      name: "InlineSearch",
      targets: ["InlineSearch"]
    ),
    .library(
      name: "AnimatedMedia",
      targets: ["AnimatedMedia"]
    ),
    .library(
      name: "InlineAudioPlayback",
      targets: ["InlineAudioPlayback"]
    ),
    .library(
      name: "InlineRTC",
      targets: ["InlineRTC"]
    ),
  ],
  dependencies: [
    .package(url: "https://github.com/inline-chat/GRDB.swift", from: "7.10.0"),
    // Keep SQLCipher exact so every SwiftPM root and Xcode preview resolves
    // the same binary framework used by GRDBSQLCipher.
    .package(url: "https://github.com/sqlcipher/SQLCipher.swift.git", exact: "4.14.0"),
    .package(url: "https://github.com/inline-chat/GRDBQuery", from: "0.11.5"),
    .package(url: "https://github.com/getsentry/sentry-cocoa", from: "9.5.1"),
    .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.38.1"),
    .package(url: "https://github.com/Kuniwak/MultipartFormDataKit", from: "1.0.0"),
    .package(url: "https://github.com/kean/Get", from: "2.2.1"),
    .package(url: "https://github.com/kean/Nuke", from: "12.8.0"),
    .package(
      url: "https://github.com/apple/swift-atomics.git",
      .upToNextMajor(from: "1.2.0")
    ),
    .package(url: "https://github.com/apple/swift-async-algorithms", from: "1.0.0"),
    // LiveKit 2.15.2 plus Inline's muted-track fixes and standard-ADM health
    // readback. The fork consumes LiveKit's official M144 WebRTC binary.
    .package(
      url: "https://github.com/inline-chat/client-sdk-swift.git",
      revision: "9bf267508ec70f00bfeee25180b417968415fe84"
    ),
    .package(
      url: "https://github.com/apple/swift-collections.git",
      .upToNextMajor(from: "1.2.0")
    ),
  ],
  targets: [
    // Targets are the basic building blocks of a package, defining a module or a test suite.
    // Targets can depend on other targets in this package and products from dependencies.

    .target(
      name: "Logger",
      dependencies: [
        .product(name: "Sentry", package: "sentry-cocoa"),
      ],
      swiftSettings: swiftSettings
    ),

    .target(
      name: "InlineKit",
      dependencies: [
        .product(name: "GRDB", package: "GRDB.swift"),
        .product(name: "GRDBQuery", package: "GRDBQuery"),
        .product(name: "Sentry", package: "sentry-cocoa"),
        .product(name: "Atomics", package: "swift-atomics"),
        .product(name: "MultipartFormDataKit", package: "MultipartFormDataKit"),
        .product(name: "Get", package: "Get"),
        .product(name: "Nuke", package: "Nuke"),
        .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
        "InlineConfig",
        "InlineProtocol",
        "AnimatedMedia",
        "InlineAudioPlayback",
        "Logger",
        "Auth",
        "RealtimeV2",
      ],
      swiftSettings: swiftSettings
    ),

    .target(
      name: "InlineRTC",
      dependencies: [
        .product(name: "Atomics", package: "swift-atomics"),
        .product(name: "LiveKit", package: "client-sdk-swift"),
        "Logger",
      ],
      swiftSettings: swiftSettings
    ),

    .target(
      name: "InlineConfig",
      swiftSettings: swiftSettings
    ),

    .target(
      name: "AnimatedMedia",
      swiftSettings: swiftSettings
    ),

    .target(
      name: "InlineAudioPlayback",
      swiftSettings: swiftSettings
    ),

    .target(
      name: "Auth",
      dependencies: [
        .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
        "InlineConfig",
        "Logger",
      ],
      swiftSettings: swiftSettings
    ),

    .target(
      name: "InlineProtocol",
      dependencies: [
        .product(name: "SwiftProtobuf", package: "swift-protobuf"),
        "Logger",
      ],
      swiftSettings: swiftSettings
    ),

    .target(
      name: "FileAttachments",
      dependencies: [
        "InlineKit",
        "Logger",
      ],
      swiftSettings: swiftSettings
    ),

    .target(
      name: "RealtimeV2",
      dependencies: [
        .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
        .product(name: "Collections", package: "swift-collections"),
        "Logger",
        "InlineProtocol",
        "InlineConfig",
        "Auth",
      ],
      exclude: [
        "README.md",
      ],
      swiftSettings: swiftSettings
    ),

    .target(
      name: "InlineSearch",
      dependencies: [
        "InlineKit",
      ],
      swiftSettings: swiftSettings
    ),

    .testTarget(
      name: "InlineKitTests",
      dependencies: ["InlineKit"],
      swiftSettings: swiftSettings
    ),

    .testTarget(
      name: "InlineRTCTests",
      dependencies: ["InlineRTC"],
      swiftSettings: swiftSettings
    ),

    .testTarget(
      name: "InlineSearchTests",
      dependencies: ["InlineSearch", "InlineKit"],
      swiftSettings: swiftSettings
    ),

    .testTarget(
      name: "AnimatedMediaTests",
      dependencies: ["AnimatedMedia"],
      swiftSettings: swiftSettings
    ),

    .testTarget(
      name: "InlineAudioPlaybackTests",
      dependencies: ["InlineAudioPlayback"],
      swiftSettings: swiftSettings
    ),
  ]
)
