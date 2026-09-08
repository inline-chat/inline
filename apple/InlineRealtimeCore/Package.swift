// swift-tools-version: 6.3
import PackageDescription

let package = Package(
  name: "InlineRealtimeCore",
  platforms: [.macOS(.v15), .iOS(.v18)],
  products: [.library(name: "RealtimeCore", targets: ["RealtimeCore"])],
  targets: [
    .target(name: "RealtimeCore"),
    .testTarget(name: "RealtimeCoreTests", dependencies: ["RealtimeCore"]),
  ]
)
