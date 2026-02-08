// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let baseDependencies: [PackageDescription.Target.Dependency] = [
  "InlineKit",
]

let swiftSettings: [SwiftSetting] = [
  .swiftLanguageMode(.v6),
]

let package = Package(
  name: "InlineUI",

  platforms: [
    .iOS(.v17),
    .macOS(.v14),
  ],

  products: [
    .library(name: "InlineUI", targets: ["InlineUI"]),
    .library(name: "TextProcessing", targets: ["TextProcessing"]),
    .library(name: "Translation", targets: ["Translation"]),
    .library(name: "Invite", targets: ["Invite"]),
    .library(name: "ContextMenuAccessoryStructs", targets: ["ContextMenuAccessoryStructs"]),
  ],

  dependencies: [
    .package(name: "InlineKit", path: "../InlineKit"),
    .package(url: "https://github.com/kean/Nuke", from: "12.8.0"),
    .package(url: "https://github.com/onevcat/Kingfisher", from: "7.0.0"),
  ],

  targets: [
    .target(
      name: "InlineUI",
      dependencies: baseDependencies + [
        .product(name: "Nuke", package: "Nuke"),
        .product(name: "NukeUI", package: "Nuke"),
        .product(name: "Kingfisher", package: "Kingfisher"),
      ],
      swiftSettings: swiftSettings
    ),

    .target(
      name: "ContextMenuAccessoryStructs",
      dependencies: [],
      publicHeadersPath: "include",
      swiftSettings: swiftSettings
    ),

    .target(
      name: "TextProcessing",
      dependencies: baseDependencies,
      swiftSettings: swiftSettings
    ),

    .target(
      name: "Translation",
      dependencies: baseDependencies,
      swiftSettings: swiftSettings
    ),

    .target(
      name: "Invite",
      dependencies: baseDependencies + ["InlineUI"],
      swiftSettings: swiftSettings
    ),

    .testTarget(
      name: "InlineUITests",
      dependencies: ["InlineUI", "TextProcessing"],
      swiftSettings: swiftSettings
    ),
  ]
)
