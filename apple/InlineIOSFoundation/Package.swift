// swift-tools-version: 6.3
import PackageDescription

// UIKit building blocks for the iOS app: declarative form/list screens, shared components and
// navigation helpers. iOS 15+, no app models, so it can be tested on its own.
let package = Package(
  name: "InlineIOSFoundation",
  platforms: [.iOS(.v15), .macOS(.v12)],
  products: [
    .library(name: "InlineIOSFoundation", targets: ["InlineIOSFoundation"]),
  ],
  dependencies: [
    .package(path: "../InlineCompat"),
  ],
  targets: [
    .target(
      name: "InlineIOSFoundation",
      dependencies: [.product(name: "InlineCompatUI", package: "InlineCompat")],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .testTarget(
      name: "InlineIOSFoundationTests",
      dependencies: ["InlineIOSFoundation"],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
  ]
)
