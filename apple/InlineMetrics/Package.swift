// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "InlineMetricsCore",
  platforms: [.macOS(.v14)],
  products: [.library(name: "InlineMetricsCore", targets: ["InlineMetricsCore"])],
  targets: [
    .target(name: "InlineMetricsCore", path: "Shared"),
    .testTarget(name: "InlineMetricsCoreTests", dependencies: ["InlineMetricsCore"], path: "Tests"),
  ]
)
