// swift-tools-version: 6.3
import PackageDescription

let package = Package(
  name: "InlineMacScripting",
  platforms: [.macOS(.v15)],
  products: [.library(name: "InlineMacScripting", targets: ["InlineMacScripting"])],
  targets: [
    .target(name: "InlineMacScripting", swiftSettings: [.swiftLanguageMode(.v6)]),
    .testTarget(name: "InlineMacScriptingTests", dependencies: ["InlineMacScripting"]),
    .executableTarget(name: "InlineScriptingFixture", dependencies: ["InlineMacScripting"], path: "Tests/Fixture"),
  ]
)
