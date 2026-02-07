// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let baseDependencies: [Target.Dependency] = [
  "InlineKit",
  "InlineUI",
]

let package = Package(
  name: "InlineIOSUI",

  platforms: [
    // Keep macOS here so `swift build`/`swift test` works on dev machines without needing an iOS destination.
    // iOS-only code should be gated with `#if os(iOS)` / `#if canImport(UIKit)` as needed.
    .iOS(.v17),
    .macOS(.v14),
  ],

  products: [
    .library(name: "InlineIOSUI", targets: ["InlineIOSUI"]),
  ],

  dependencies: [
    .package(name: "InlineKit", path: "../InlineKit"),
    .package(name: "InlineUI", path: "../InlineUI"),
  ],

  targets: [
    .target(
      name: "InlineIOSUI",
      dependencies: baseDependencies,
      swiftSettings: [
        .swiftLanguageMode(.v6),
      ]
    ),

    .testTarget(
      name: "InlineIOSUITests",
      dependencies: ["InlineIOSUI"]
    ),
  ]
)
