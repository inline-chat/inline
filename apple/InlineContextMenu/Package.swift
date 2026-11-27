// swift-tools-version: 6.3

import PackageDescription

// Inline's own context menu: presents any NSMenu in our panels so it can look like the system menu
// (and better), carry an accessory view such as quick reactions, and keep every NSMenu behavior.
// `apple/ContextMenuLab` is its harness: self-test, real-event probe and native comparisons.
let package = Package(
  name: "InlineContextMenu",
  platforms: [
    .macOS(.v15),
  ],
  products: [
    .library(name: "InlineContextMenu", targets: ["InlineContextMenu"]),
  ],
  targets: [
    .target(
      name: "InlineContextMenu",
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .testTarget(
      name: "InlineContextMenuTests",
      dependencies: ["InlineContextMenu"],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
  ]
)
