// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "InlineSyntaxHighlighting",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "InlineSyntaxHighlighting", targets: ["InlineSyntaxHighlighting"]),
  ],
  dependencies: [
    .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter.git", exact: "0.9.0"),
    .package(url: "https://github.com/alex-pinkus/tree-sitter-swift.git", exact: "0.7.3-with-generated-files"),
    .package(url: "https://github.com/tree-sitter/tree-sitter-typescript.git", exact: "0.23.2"),
    .package(url: "https://github.com/tree-sitter/tree-sitter-python.git", exact: "0.23.6"),
    .package(url: "https://github.com/tree-sitter/tree-sitter-bash.git", exact: "0.23.3"),
    .package(url: "https://github.com/tree-sitter/tree-sitter-html.git", exact: "0.23.2"),
    .package(url: "https://github.com/tree-sitter/tree-sitter-css.git", exact: "0.23.2"),
    .package(url: "https://github.com/tree-sitter/tree-sitter-json.git", exact: "0.24.8"),
    .package(url: "https://github.com/tree-sitter/tree-sitter-go.git", exact: "0.23.4"),
    .package(url: "https://github.com/tree-sitter/tree-sitter-rust.git", exact: "0.24.2"),
    .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-yaml.git", exact: "0.7.0"),
  ],
  targets: [
    .target(
      name: "InlineSyntaxHighlighting",
      dependencies: [
        .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
        .product(name: "TreeSitterSwift", package: "tree-sitter-swift"),
        .product(name: "TreeSitterTypeScript", package: "tree-sitter-typescript"),
        .product(name: "TreeSitterPython", package: "tree-sitter-python"),
        .product(name: "TreeSitterBash", package: "tree-sitter-bash"),
        .product(name: "TreeSitterHTML", package: "tree-sitter-html"),
        .product(name: "TreeSitterCSS", package: "tree-sitter-css"),
        .product(name: "TreeSitterJSON", package: "tree-sitter-json"),
        .product(name: "TreeSitterGo", package: "tree-sitter-go"),
        .product(name: "TreeSitterRust", package: "tree-sitter-rust"),
        .product(name: "TreeSitterYAML", package: "tree-sitter-yaml"),
      ]
    ),
    .testTarget(
      name: "InlineSyntaxHighlightingTests",
      dependencies: ["InlineSyntaxHighlighting"]
    ),
  ]
)
