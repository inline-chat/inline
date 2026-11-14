// swift-tools-version: 6.3
import PackageDescription

// The iOS message list core. `TimelineCore` is the pure solver: Foundation and CoreGraphics only,
// no UIKit, so every placement and motion decision is testable with `swift test` on a Mac.
let package = Package(
  name: "InlineTimeline",
  platforms: [.iOS(.v18), .macOS(.v15)],
  products: [
    .library(name: "TimelineCore", targets: ["TimelineCore"]),
  ],
  targets: [
    .target(name: "TimelineCore", swiftSettings: [.swiftLanguageMode(.v6)]),
    .testTarget(
      name: "TimelineCoreTests",
      dependencies: ["TimelineCore"],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
  ]
)
