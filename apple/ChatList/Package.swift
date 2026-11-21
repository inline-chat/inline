// swift-tools-version: 6.3
import PackageDescription

let package = Package(
  name: "ChatList",
  platforms: [.macOS(.v15), .iOS(.v18)],
  products: [
    .library(name: "ChatListCore", targets: ["ChatListCore"]),
    .library(name: "ChatListAppKit", targets: ["ChatListAppKit"]),
    .library(name: "ChatListUIKit", targets: ["ChatListUIKit"]),
  ],
  targets: [
    .target(name: "ChatListCore"),
    .target(name: "ChatListAppKit", dependencies: ["ChatListCore"]),
    .target(name: "ChatListUIKit", dependencies: ["ChatListCore"]),
    .testTarget(name: "ChatListCoreTests", dependencies: ["ChatListCore"]),
    .testTarget(name: "ChatListAppKitTests", dependencies: ["ChatListAppKit", "ChatListCore"]),
    .testTarget(name: "ChatListUIKitTests", dependencies: ["ChatListUIKit", "ChatListCore"]),
  ]
)
