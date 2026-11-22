// swift-tools-version: 6.3
import PackageDescription

// The iOS message list core.
// `TimelineCore` is pure (Foundation and CoreGraphics only): the solver and the scroll physics, so
// every placement and motion decision is testable with `swift test` on a Mac.
// `TimelineUIKit` is the view that realises rows, plays motion on the render server and scrolls.
let package = Package(
  name: "InlineTimeline",
  platforms: [.iOS(.v15), .macOS(.v15)],
  products: [
    .library(name: "TimelineCore", targets: ["TimelineCore"]),
    .library(name: "TimelineUIKit", targets: ["TimelineUIKit"]),
  ],
  dependencies: [
    .package(path: "../InlineCompat"),
  ],
  targets: [
    .target(name: "TimelineCore", swiftSettings: [.swiftLanguageMode(.v6)]),
    .target(
      name: "TimelineUIKit",
      dependencies: ["TimelineCore", .product(name: "InlineCompat", package: "InlineCompat")],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .testTarget(
      name: "TimelineCoreTests",
      dependencies: ["TimelineCore"],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
  ]
)
