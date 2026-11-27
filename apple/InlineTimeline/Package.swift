// swift-tools-version: 6.3
import PackageDescription

// The message list core for iOS and macOS.
// `TimelineCore` is pure (Foundation and CoreGraphics only): the solver and the scroll physics, so
// every placement and motion decision is testable with `swift test` on a Mac.
// `TimelineUIKit` is the iOS view that realises rows, plays motion on the render server and scrolls.
// `TimelineAppKit` is the macOS view: the same solver, scrolled by the system's wheel and trackpad events.
let package = Package(
  name: "InlineTimeline",
  platforms: [.iOS(.v18), .macOS(.v15)],
  products: [
    .library(name: "TimelineCore", targets: ["TimelineCore"]),
    .library(name: "TimelineUIKit", targets: ["TimelineUIKit"]),
    .library(name: "TimelineAppKit", targets: ["TimelineAppKit"]),
  ],
  targets: [
    .target(name: "TimelineCore", swiftSettings: [.swiftLanguageMode(.v6)]),
    .target(name: "TimelineUIKit", dependencies: ["TimelineCore"], swiftSettings: [.swiftLanguageMode(.v6)]),
    .target(name: "TimelineAppKit", dependencies: ["TimelineCore"], swiftSettings: [.swiftLanguageMode(.v6)]),
    .testTarget(
      name: "TimelineCoreTests",
      dependencies: ["TimelineCore"],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .testTarget(
      name: "TimelineAppKitTests",
      dependencies: ["TimelineCore", "TimelineAppKit"],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
  ]
)
