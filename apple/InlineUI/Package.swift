// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let baseDependencies: [PackageDescription.Target.Dependency] = [
  "InlineKit",
]

let swiftSettings: [SwiftSetting] = [
  .swiftLanguageMode(.v6),
]

let package = Package(
  name: "InlineUI",

  platforms: [
    .iOS(.v18),
    .macOS(.v15),
  ],

  products: [
    .library(name: "InlineTheme", targets: ["InlineTheme"]),
    .library(name: "InlineAvatarRendering", targets: ["InlineAvatarRendering"]),
    .library(name: "InlineIntents", targets: ["InlineIntents"]),
    .library(name: "InlineUI", targets: ["InlineUI"]),
    .library(name: "EmojiAutocomplete", targets: ["EmojiAutocomplete"]),
    .library(name: "ReactionPickerEmojis", targets: ["ReactionPickerEmojis"]),
    .library(name: "TextProcessing", targets: ["TextProcessing"]),
    .library(name: "Translation", targets: ["Translation"]),
    .library(name: "Invite", targets: ["Invite"]),
    .library(name: "ContextMenuAccessoryStructs", targets: ["ContextMenuAccessoryStructs"]),
  ],

  dependencies: [
    .package(name: "InlineKit", path: "../InlineKit"),
    .package(path: "../InlineMath"),
    .package(url: "https://github.com/onevcat/Kingfisher", from: "7.0.0"),
  ],

  targets: [
    .target(
      name: "InlineTheme",
      dependencies: [],
      swiftSettings: swiftSettings
    ),

    .target(
      name: "InlineAvatarRendering",
      dependencies: [
        .product(name: "InlineAvatarCore", package: "InlineKit"),
      ],
      swiftSettings: swiftSettings
    ),

    .target(
      name: "InlineIntents",
      dependencies: ["InlineAvatarRendering"],
      swiftSettings: swiftSettings
    ),

    .target(
      name: "InlineUI",
      dependencies: baseDependencies + [
        .product(name: "Kingfisher", package: "Kingfisher"),
        .product(name: "InlineAvatarCore", package: "InlineKit"),
        "ReactionPickerEmojis",
      ],
      swiftSettings: swiftSettings
    ),

    .target(
      name: "ContextMenuAccessoryStructs",
      dependencies: [],
      publicHeadersPath: "include",
      swiftSettings: swiftSettings
    ),

    .target(
      name: "EmojiAutocomplete",
      dependencies: [],
      swiftSettings: swiftSettings
    ),

    .target(
      name: "ReactionPickerEmojis",
      dependencies: [],
      swiftSettings: swiftSettings
    ),

    .target(
      name: "TextProcessing",
      dependencies: baseDependencies + ["EmojiAutocomplete", .product(name: "InlineMath", package: "InlineMath")],
      swiftSettings: swiftSettings
    ),

    .target(
      name: "Translation",
      dependencies: baseDependencies,
      swiftSettings: swiftSettings
    ),

    .target(
      name: "Invite",
      dependencies: baseDependencies + [
        "InlineUI",
        .product(name: "Logger", package: "InlineKit"),
      ],
      swiftSettings: swiftSettings
    ),

    .testTarget(
      name: "InlineUITests",
      dependencies: ["InlineUI", "EmojiAutocomplete", "TextProcessing", "Translation", "Invite"],
      swiftSettings: swiftSettings
    ),

    .testTarget(
      name: "InlineThemeTests",
      dependencies: ["InlineTheme"],
      swiftSettings: swiftSettings
    ),

    .testTarget(
      name: "InlineIntentsTests",
      dependencies: ["InlineIntents"],
      swiftSettings: swiftSettings
    ),

    .testTarget(
      name: "ReactionPickerEmojisTests",
      dependencies: ["ReactionPickerEmojis"],
      swiftSettings: swiftSettings
    ),
  ]
)
