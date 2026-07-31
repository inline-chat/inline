// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let baseDependencies: [PackageDescription.Target.Dependency] = [
  "InlineKit",
  .product(name: "InlineRTC", package: "InlineKit"),
  "InlineUI",
]

let swiftSettings: [SwiftSetting] = [
  .swiftLanguageMode(.v6),
]

let package = Package(
  name: "InlineMacUI",

  platforms: [
    .macOS(.v15),
  ],

  products: [
    .library(name: "InlineCLIInstaller", targets: ["InlineCLIInstaller"]),
    .library(name: "InlineMacUI", targets: ["InlineMacUI"]),
    .library(name: "InlineMacTabStrip", targets: ["InlineMacTabStrip"]),
    .library(name: "InlineMacHotkeys", targets: ["InlineMacHotkeys"]),
    .library(name: "InlineMacWindow", targets: ["InlineMacWindow"]),
    .library(name: "MacDevtools", targets: ["MacDevtools"]),
    .library(name: "MacTheme", targets: ["MacTheme"]),
  ],

  dependencies: [
    .package(name: "InlineKit", path: "../InlineKit"),
    .package(name: "InlineUI", path: "../InlineUI"),
    // .package(url: "https://github.com/kean/Nuke", from: "12.8.0"),
  ],

  targets: [
    .target(
      name: "InlineCLIInstaller",
      dependencies: [],
      swiftSettings: swiftSettings
    ),

    .target(
      name: "InlineMacTabStrip",
      dependencies: ["MacTheme"],
      swiftSettings: swiftSettings
    ),

    .target(
      name: "InlineMacUI",
      dependencies: baseDependencies + ["InlineMacHotkeys", "InlineMacTabStrip", "MacTheme"],
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
      name: "MacDevtools",
      dependencies: [
        .product(name: "InlineConfig", package: "InlineKit"),
        .product(name: "Logger", package: "InlineKit"),
      ],
      swiftSettings: swiftSettings
    ),

    .target(
      name: "MacTheme",
      dependencies: [],
      swiftSettings: swiftSettings
    ),

    .testTarget(
      name: "InlineCLIInstallerTests",
      dependencies: ["InlineCLIInstaller"],
      swiftSettings: swiftSettings
    ),

    .testTarget(
      name: "InlineMacUITests",
      dependencies: ["InlineMacUI", "MacTheme"],
      swiftSettings: swiftSettings
    ),

    .testTarget(
      name: "InlineMacHotkeysTests",
      dependencies: ["InlineMacHotkeys"],
      swiftSettings: swiftSettings
    ),
  ]
)
