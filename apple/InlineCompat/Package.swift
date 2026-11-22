// swift-tools-version: 6.3
import PackageDescription

// Backports and adoption helpers that let Inline run on iOS 15 while still using the newest
// platform APIs where the running OS has them.
//
// - InlineCompat: Foundation-only. Lock, atomic, Duration/clock and Observation backports.
//   Each backport is marked with the OS version that makes it removable.
// - InlineCompatUI: UIKit helpers that pick the native API at runtime (#available) and fall
//   back to an equivalent on older systems.
let package = Package(
  name: "InlineCompat",
  platforms: [.iOS(.v15), .macOS(.v12)],
  products: [
    .library(name: "InlineCompat", targets: ["InlineCompat"]),
    .library(name: "InlineCompatUI", targets: ["InlineCompatUI"]),
  ],
  targets: [
    .target(name: "InlineCompat", swiftSettings: [.swiftLanguageMode(.v6)]),
    .target(
      name: "InlineCompatUI",
      dependencies: ["InlineCompat"],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .testTarget(
      name: "InlineCompatTests",
      dependencies: ["InlineCompat"],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
  ]
)
