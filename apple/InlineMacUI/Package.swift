// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let baseDependencies: [PackageDescription.Target.Dependency] = [
  "InlineKit",
  "InlineUI",
]

let swiftSettings: [SwiftSetting] = [
  .swiftLanguageMode(.v6),
]

let package = Package(
  name: "InlineMacUI",

  platforms: [
    // TODO: Update to macOS 15 when main app target is updated to macOS 15
    .macOS(.v14),
  ],

  products: [
    .library(name: "InlineMacUI", targets: ["InlineMacUI"]),
    .library(name: "InlineMacTabStrip", targets: ["InlineMacTabStrip"]),
    .library(name: "InlineMacHotkeys", targets: ["InlineMacHotkeys"]),
    .library(name: "InlineMacWindow", targets: ["InlineMacWindow"]),
    .library(name: "MacTheme", targets: ["MacTheme"]),
  ],

  dependencies: [
    .package(name: "InlineKit", path: "../InlineKit"),
    .package(name: "InlineUI", path: "../InlineUI"),
    // .package(url: "https://github.com/kean/Nuke", from: "12.8.0"),
  ],

  targets: [
    .target(
      name: "InlineMacTabStrip",
      dependencies: ["MacTheme"],
      swiftSettings: swiftSettings
    ),

    .target(
      name: "InlineMacUI",
      dependencies: baseDependencies + ["InlineMacHotkeys", "InlineMacTabStrip"],
      swiftSettings: swiftSettings
    ),

    .target(
      name: "InlineMacHotkeys",
      dependencies: [],
      swiftSettings: swiftSettings
    ),

    .target(
      name: "InlineMacWindow",
      dependencies: [],
      swiftSettings: swiftSettings
    ),

    .target(
      name: "MacTheme",
      dependencies: [],
      swiftSettings: swiftSettings
    ),

    .testTarget(
      name: "InlineMacUITests",
      dependencies: ["InlineMacUI"],
      swiftSettings: swiftSettings
    ),

    .testTarget(
      name: "InlineMacHotkeysTests",
      dependencies: ["InlineMacHotkeys"],
      swiftSettings: swiftSettings
    ),
  ]
)
