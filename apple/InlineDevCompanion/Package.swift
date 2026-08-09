// swift-tools-version: 6.1

import PackageDescription

let package = Package(
  name: "InlineDevCompanion",
  platforms: [
    .macOS("27.0"),
  ],
  products: [
    .executable(
      name: "InlineDevCompanion",
      targets: ["InlineDevCompanion"]
    ),
  ],
  targets: [
    .executableTarget(name: "InlineDevCompanion"),
    .testTarget(
      name: "InlineDevCompanionTests",
      dependencies: ["InlineDevCompanion"]
    ),
  ]
)
