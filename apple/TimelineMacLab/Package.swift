// swift-tools-version: 6.3
import PackageDescription

// A dumb lab for the macOS message list: no Inline app, no database. Rows are structs.
// `swift run TimelineMacLab --scenario <name> --out <file.json>` runs a scripted experiment and exits;
// with no scenario it opens an interactive chat-like window.
let package = Package(
  name: "TimelineMacLab",
  platforms: [.macOS(.v15)],
  dependencies: [
    .package(name: "InlineTimeline", path: "../InlineTimeline"),
  ],
  targets: [
    .executableTarget(
      name: "TimelineMacLab",
      dependencies: [
        .product(name: "TimelineCore", package: "InlineTimeline"),
        .product(name: "TimelineAppKit", package: "InlineTimeline"),
      ],
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
  ]
)
