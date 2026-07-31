// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "MemojiKit",
  platforms: [
    .iOS(.v18),
    .macOS(.v15),
  ],
  products: [
    .library(name: "MemojiKit", targets: ["MemojiKit"]),
    .library(name: "MemojiPickerUI", targets: ["MemojiPickerUI"]),
  ],
  targets: [
    .target(
      name: "MemojiKit",
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .target(
      name: "MemojiPickerUI",
      dependencies: ["MemojiKit"],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .testTarget(
      name: "MemojiKitTests",
      dependencies: ["MemojiKit"],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
  ]
)
