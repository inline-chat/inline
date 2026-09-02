// swift-tools-version: 6.3
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
    .iOS(.v18),
    .macOS(.v15),
  ],

  products: [
    .library(name: "InlineIOSUI", targets: ["InlineIOSUI"]),
    .library(name: "Onboarding", targets: ["Onboarding"]),
    .library(name: "InlineAppIntents", targets: ["InlineAppIntents"]),
  ],

  dependencies: [
    .package(name: "InlineKit", path: "../InlineKit"),
    .package(name: "InlineUI", path: "../InlineUI"),
  ],

  targets: [
    .target(
      name: "InlineAppIntents",
      dependencies: [
        .product(name: "InlineKit", package: "InlineKit"),
        .product(name: "RealtimeV2", package: "InlineKit"),
      ],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .testTarget(
      name: "InlineAppIntentsTests",
      dependencies: ["InlineAppIntents"],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .target(
      name: "InlineIOSUI",
      dependencies: baseDependencies,
      swiftSettings: [
        .swiftLanguageMode(.v6),
      ]
    ),

    .target(
      name: "Onboarding",
      path: "Sources/Onborading",
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
