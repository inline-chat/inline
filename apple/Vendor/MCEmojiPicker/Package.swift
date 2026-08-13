// swift-tools-version: 5.7

// Vendored from MCEmojiPicker 1.2.3 (e0b4903b75ae1cc418d276d84d1cb946b8a1d73c).
// Inline keeps view-hierarchy setup idempotent because 1.2.5 and upstream main
// still configure category controls and constraints from every draw(_:) call.

import PackageDescription

let package = Package(
    name: "MCEmojiPicker",
    defaultLocalization: "en",
    platforms: [.iOS("11.1")],
    products: [.library(name: "MCEmojiPicker", targets: ["MCEmojiPicker"])],
    dependencies: [],
    targets: [.target(
        name: "MCEmojiPicker",
        dependencies: [],
        path: "Sources/MCEmojiPicker",
        resources: [.process("Resources")]
    )],
    swiftLanguageVersions: [.v4_2]
)
