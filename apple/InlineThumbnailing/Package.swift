// swift-tools-version: 6.3

import PackageDescription

let package = Package(
  name: "InlineThumbnailing",
  platforms: [
    .iOS(.v18),
    .macOS(.v15),
  ],
  products: [
    .library(name: "InlineThumbnailing", targets: ["InlineThumbnailing"]),
  ],
  targets: [
    .target(
      name: "InlineThumbnailing",
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .testTarget(
      name: "InlineThumbnailingTests",
      dependencies: ["InlineThumbnailing"],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
  ]
)
