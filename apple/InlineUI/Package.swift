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
    .package(url: "https://github.com/kean/Nuke", from: "12.8.0"),
  ],
  
  targets: [
    .target(
      name: "InlineUI",
      dependencies: baseDependencies + [
        .product(name: "Nuke", package: "Nuke"),
        .product(name: "NukeUI", package: "Nuke"),
      ],
    ),

    .target(
      name: "TextProcessing",
      dependencies: baseDependencies,
    ),

    .testTarget(
      name: "InlineUITests",
      dependencies: ["InlineUI", "TextProcessing"]
    ),
  ]
)
