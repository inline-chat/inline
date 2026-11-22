// swift-tools-version: 6.3
import PackageDescription

// Pure message layout: Foundation, CoreGraphics and CoreText only. No UIKit, no app models,
// so plans can be prepared off the main thread and tested with `swift test` on a Mac.
let package = Package(
  name: "InlineMessageLayout",
  platforms: [.iOS(.v15), .macOS(.v15)],
  products: [
    .library(name: "InlineMessageLayout", targets: ["InlineMessageLayout"]),
  ],
  dependencies: [
    .package(path: "../InlineCompat"),
  ],
  targets: [
    .target(
      name: "InlineMessageLayout",
      dependencies: [.product(name: "InlineCompat", package: "InlineCompat")],
      swiftSettings: [.swiftLanguageMode(.v6)]),
    .testTarget(
      name: "InlineMessageLayoutTests",
      dependencies: ["InlineMessageLayout"],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
  ]
)
