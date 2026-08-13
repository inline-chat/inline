// swift-tools-version: 6.3

import PackageDescription

let package = Package(
  name: "InlineMacSidebarModel",
  platforms: [
    .macOS(.v15),
  ],
  products: [
    .library(name: "InlineMacSidebarModel", targets: ["InlineMacSidebarModel"]),
  ],
  targets: [
    .target(
      name: "InlineMacSidebarModel",
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .testTarget(
      name: "InlineMacSidebarModelTests",
      dependencies: ["InlineMacSidebarModel"],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
  ]
)
