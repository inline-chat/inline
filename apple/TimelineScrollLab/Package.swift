// swift-tools-version: 6.3
import PackageDescription

// A prototype of the macOS message list hosted in a real NSScrollView, measured against the custom engine.
// `ScrollTimeline` is the prototype: TimelineCore places the rows, a stock NSScrollView scrolls them (responsive
// scrolling, native momentum and elasticity, the system scroller). It depends on TimelineCore only.
// `TimelineScrollLab` drives both lists with the same lab rows and the same events (posted through the window server)
// and prints the comparison: `swift build -c release && .build/release/TimelineScrollLab --compare`.
let package = Package(
  name: "TimelineScrollLab",
  platforms: [.macOS(.v15)],
  dependencies: [
    .package(name: "InlineTimeline", path: "../InlineTimeline"),
  ],
  targets: [
    .target(
      name: "ScrollTimeline",
      dependencies: [.product(name: "TimelineCore", package: "InlineTimeline")],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    // A snapshot of TimelineAppKit (the engine), copied to try a change without touching the engine session's files:
    // the render-server flight braking to the rows it has placed (`brakesToRows`). See Sources/EngineBrake/SNAPSHOT.txt.
    .target(
      name: "EngineBrake",
      dependencies: [.product(name: "TimelineCore", package: "InlineTimeline")],
      exclude: ["SNAPSHOT.txt"],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .executableTarget(
      name: "TimelineScrollLab",
      dependencies: [
        "ScrollTimeline",
        "EngineBrake",
        .product(name: "TimelineCore", package: "InlineTimeline"),
        // Only to measure the current engine side by side; the prototype does not use it.
        .product(name: "TimelineAppKit", package: "InlineTimeline"),
      ],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
  ]
)
