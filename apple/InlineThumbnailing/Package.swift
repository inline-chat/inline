// swift-tools-version: 6.3

import PackageDescription

let package = Package(
  name: "InlineThumbnailing",
  platforms: [
    .iOS(.v15),
    .macOS(.v15),
  ],
  products: [
    .library(name: "InlineThumbnailing", targets: ["InlineThumbnailing"]),
  ],
  dependencies: [
    .package(path: "../InlineCompat"),
  ],
  targets: [
    .target(
      name: "InlineThumbnailing",
      dependencies: [.product(name: "InlineCompat", package: "InlineCompat")],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .testTarget(
      name: "InlineThumbnailingTests",
      dependencies: ["InlineThumbnailing"],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
  ]
)
