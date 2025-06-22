// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let baseDependencies: [PackageDescription.Target.Dependency] = [
  "InlineKit",
]

let package = Package(
  name: "InlineUI",
  platforms: [
    .iOS(.v17),
    .macOS(.v14),
  ],
  
  products: [
    .library(name: "InlineUI", targets: ["InlineUI"]),
    .library(name: "TextProcessing", targets: ["TextProcessing"]),
  ],
  
  dependencies: [
    .package(name: "InlineKit", path: "../InlineKit"),
  ],
  
  targets: [
    .target(
      name: "InlineUI",
      dependencies: baseDependencies,
    ),

    .target(
      name: "TextProcessing",
      dependencies: baseDependencies,
    ),

    .testTarget(
      name: "InlineUITests",
      dependencies: ["InlineUI"]
    ),
  ]
)
