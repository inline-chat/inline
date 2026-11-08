// swift-tools-version: 6.3

import PackageDescription

let package = Package(
  name: "InlineWebWidget",
  platforms: [
    .iOS(.v18),
    .macOS(.v15),
  ],
  products: [
    .library(name: "InlineWebWidget", targets: ["InlineWebWidget"]),
    .executable(name: "InlineWebWidgetSpike", targets: ["InlineWebWidgetSpike"]),
  ],
  targets: [
    .target(
      name: "InlineWebWidget",
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    // macOS harness that measures the host in a message-list-shaped table.
    .executableTarget(
      name: "InlineWebWidgetSpike",
      dependencies: ["InlineWebWidget"],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .testTarget(
      name: "InlineWebWidgetTests",
      dependencies: ["InlineWebWidget"],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
  ]
)
