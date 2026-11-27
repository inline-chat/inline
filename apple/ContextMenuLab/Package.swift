// swift-tools-version: 6.0
import PackageDescription

// A lab for a custom macOS context menu. No Inline app, no database.
// `InlineContextMenu` (../InlineContextMenu, shipped in the app) is the engine: it presents any NSMenu in our own panels, so callers keep
// building NSMenu/NSMenuItem as today, and an accessory view (the reaction bar) can sit beside the menu.
// `swift run ContextMenuLab` opens a chat-like window where every approach can be tried by hand;
// `swift run ContextMenuLab --selftest --out <file.json>` runs the scripted checks and exits;
// `swift run ContextMenuLab --probe native --out <file.json>` drives the native menu with posted events.
let package = Package(
  name: "ContextMenuLab",
  platforms: [.macOS(.v15)],
  dependencies: [
    .package(name: "InlineContextMenu", path: "../InlineContextMenu"),
  ],
  targets: [
    .executableTarget(
      name: "ContextMenuLab",
      dependencies: [.product(name: "InlineContextMenu", package: "InlineContextMenu")],
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
  ]
)
