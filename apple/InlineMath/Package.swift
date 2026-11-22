// swift-tools-version: 6.3
import PackageDescription

let package = Package(
  name: "InlineMath",
  platforms: [.macOS(.v15), .iOS(.v15)],
  products: [
    .library(name: "InlineMath", targets: ["InlineMath"]),
    .executable(name: "inline-math-probe", targets: ["MathRenderProbe"]),
  ],
  dependencies: [
    .package(path: "../InlineCompat"),
  ],
  targets: [
    // Upstream mutable types remain inside this implementation target. Only
    // the serial, bounded InlineMath facade is a supported product API.
    .target(name: "SwiftMathCore", resources: [.copy("mathFonts.bundle")],
            swiftSettings: [.swiftLanguageMode(.v5)]),
    .target(name: "InlineMath", dependencies: [
      "SwiftMathCore",
      .product(name: "InlineCompat", package: "InlineCompat"),
    ],
            swiftSettings: [.swiftLanguageMode(.v6)]),
    .executableTarget(name: "MathRenderProbe", dependencies: [
      "InlineMath",
      .product(name: "InlineCompat", package: "InlineCompat"),
    ],
                       swiftSettings: [.swiftLanguageMode(.v6)]),
    .testTarget(name: "InlineMathTests", dependencies: ["InlineMath"],
                swiftSettings: [.swiftLanguageMode(.v6)]),
  ]
)
