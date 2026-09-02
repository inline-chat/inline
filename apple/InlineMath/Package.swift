// swift-tools-version: 6.3
import PackageDescription

let package = Package(
  name: "InlineMath",
  platforms: [.macOS(.v15), .iOS(.v18)],
  products: [
    .library(name: "InlineMath", targets: ["InlineMath"]),
    .executable(name: "inline-math-probe", targets: ["MathRenderProbe"]),
  ],
  targets: [
    // Upstream mutable types remain inside this implementation target. Only
    // the serial, bounded InlineMath facade is a supported product API.
    .target(name: "SwiftMathCore", resources: [.copy("mathFonts.bundle")],
            swiftSettings: [.swiftLanguageMode(.v5)]),
    .target(name: "InlineMath", dependencies: ["SwiftMathCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]),
    .executableTarget(name: "MathRenderProbe", dependencies: ["InlineMath"],
                       swiftSettings: [.swiftLanguageMode(.v6)]),
    .testTarget(name: "InlineMathTests", dependencies: ["InlineMath"],
                swiftSettings: [.swiftLanguageMode(.v6)]),
  ]
)
