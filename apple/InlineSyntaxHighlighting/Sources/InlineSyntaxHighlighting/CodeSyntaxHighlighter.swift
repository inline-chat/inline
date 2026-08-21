import Foundation
import SwiftTreeSitter
import TreeSitterBash
import TreeSitterCSS
import TreeSitterGo
import TreeSitterHTML
import TreeSitterJSON
import TreeSitterPython
import TreeSitterRust
import TreeSitterSwift
import TreeSitterTSX
import TreeSitterTypeScript
import TreeSitterYAML

public enum CodeTokenKind: String, Sendable, Hashable {
  case keyword
  case type
  case function
  case property
  case string
  case number
  case comment
  case operatorSymbol
  case constant
  case punctuation
}

public struct CodeToken: Sendable, Hashable {
  public let range: NSRange
  public let kind: CodeTokenKind

  public init(range: NSRange, kind: CodeTokenKind) {
    self.range = range
    self.kind = kind
  }
}

public actor CodeSyntaxHighlighter {
  private final class BundleAnchor: NSObject {}

  private struct CacheEntry {
    let text: String
    let language: LanguageKind
    let tokens: [CodeToken]
  }

  private enum LanguageKind: Hashable {
    case swift
    case typeScript
    case tsx
    case python
    case bash
    case html
    case css
    case json
    case yaml
    case go
    case rust
  }

  private var parsers: [LanguageKind: Parser] = [:]
  private var configurations: [LanguageKind: LanguageConfiguration] = [:]
  private var cache: [CacheEntry] = []
  private let cacheLimit = 8
  private let maximumUTF16Length = 100_000
  private let maximumLines = 5_000

  public init() {}

  public func tokens(for text: String, language: String?) throws -> [CodeToken]? {
    guard let language = Self.languageKind(for: language),
          text.utf16.count <= maximumUTF16Length,
          text.lazy.filter({ $0 == "\n" }).prefix(maximumLines).count < maximumLines
    else { return nil }
    if let entry = cache.first(where: { $0.text == text && $0.language == language }) {
      return entry.tokens
    }
    try Task.checkCancellation()
    let (parser, configuration) = try configuredParser(for: language)
    parser.timeout = 0.03
    guard let tree = parser.parse(text),
          let query = configuration.queries[.highlights]
    else { return nil }
    try Task.checkCancellation()
    let textLength = (text as NSString).length
    let tokens = query
      .execute(in: tree)
      .resolve(with: .init(string: text))
      .highlights()
      .compactMap { highlight -> CodeToken? in
        guard highlight.range.location != NSNotFound,
              highlight.range.location >= 0,
              highlight.range.length > 0,
              highlight.range.location <= textLength,
              highlight.range.length <= textLength - highlight.range.location,
              let kind = Self.kind(for: highlight.name)
        else { return nil }
        return CodeToken(range: highlight.range, kind: kind)
      }
    try Task.checkCancellation()
    cache.removeAll { $0.text == text && $0.language == language }
    cache.insert(.init(text: text, language: language, tokens: tokens), at: 0)
    if cache.count > cacheLimit {
      cache.removeLast(cache.count - cacheLimit)
    }
    return tokens
  }

  public static func supports(language: String?) -> Bool {
    languageKind(for: language) != nil
  }

  private static func languageKind(for language: String?) -> LanguageKind? {
    guard let language else { return nil }
    return switch language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "swift", "swift5", "swift6": .swift
    case "typescript", "ts", "javascript", "js": .typeScript
    case "tsx", "jsx": .tsx
    case "python", "py", "python3": .python
    case "bash", "sh", "shell", "zsh": .bash
    case "html", "htm": .html
    case "css", "scss": .css
    case "json", "jsonc": .json
    case "yaml", "yml": .yaml
    case "go", "golang": .go
    case "rust", "rs": .rust
    default: nil
    }
  }

  private func configuredParser(for language: LanguageKind) throws -> (Parser, LanguageConfiguration) {
    if let parser = parsers[language], let configuration = configurations[language] {
      return (parser, configuration)
    }
    let configuration: LanguageConfiguration = switch language {
    case .swift:
      try LanguageConfiguration(
        tree_sitter_swift(),
        name: "Swift",
        queriesURL: try Self.queriesURL(bundleName: "TreeSitterSwift_TreeSitterSwift")
      )
    case .typeScript:
      try LanguageConfiguration(
        tree_sitter_typescript(),
        name: "TypeScript",
        queriesURL: try Self.queriesURL(bundleName: "TreeSitterTypeScript_TreeSitterTypeScript")
      )
    case .tsx:
      try LanguageConfiguration(
        tree_sitter_tsx(),
        name: "TSX",
        queriesURL: try Self.queriesURL(bundleName: "TreeSitterTSX_TreeSitterTSX")
      )
    case .python:
      try LanguageConfiguration(
        tree_sitter_python(),
        name: "Python",
        queriesURL: try Self.queriesURL(bundleName: "TreeSitterPython_TreeSitterPython")
      )
    case .bash:
      try LanguageConfiguration(
        tree_sitter_bash(),
        name: "Bash",
        queriesURL: try Self.queriesURL(bundleName: "TreeSitterBash_TreeSitterBash")
      )
    case .html:
      try LanguageConfiguration(
        tree_sitter_html(),
        name: "HTML",
        queriesURL: try Self.queriesURL(bundleName: "TreeSitterHTML_TreeSitterHTML")
      )
    case .css:
      try LanguageConfiguration(
        tree_sitter_css(),
        name: "CSS",
        queriesURL: try Self.queriesURL(bundleName: "TreeSitterCSS_TreeSitterCSS")
      )
    case .json:
      try LanguageConfiguration(
        tree_sitter_json(),
        name: "JSON",
        queriesURL: try Self.queriesURL(bundleName: "TreeSitterJSON_TreeSitterJSON")
      )
    case .yaml:
      try LanguageConfiguration(
        tree_sitter_yaml(),
        name: "YAML",
        queriesURL: try Self.queriesURL(bundleName: "TreeSitterYAML_TreeSitterYAML")
      )
    case .go:
      try LanguageConfiguration(
        tree_sitter_go(),
        name: "Go",
        queriesURL: try Self.queriesURL(bundleName: "TreeSitterGo_TreeSitterGo")
      )
    case .rust:
      try LanguageConfiguration(
        tree_sitter_rust(),
        name: "Rust",
        queriesURL: try Self.queriesURL(bundleName: "TreeSitterRust_TreeSitterRust")
      )
    }
    let parser = Parser()
    try parser.setLanguage(configuration.language)
    parsers[language] = parser
    configurations[language] = configuration
    return (parser, configuration)
  }

  private static func queriesURL(bundleName: String) throws -> URL {
    let bundles = [Bundle(for: BundleAnchor.self), Bundle.main] + Bundle.allBundles + Bundle.allFrameworks
    let candidates = bundles.flatMap { bundle in
      [
        bundle.url(forResource: bundleName, withExtension: "bundle"),
        bundle.resourceURL?.appendingPathComponent("\(bundleName).bundle", isDirectory: true),
      ]
    }

    for candidate in candidates.compactMap({ $0 }) {
      let short = candidate.appendingPathComponent("queries", isDirectory: true)
      if FileManager.default.fileExists(atPath: short.path) { return short }
      let macOS = candidate.appendingPathComponent("Contents/Resources/queries", isDirectory: true)
      if FileManager.default.fileExists(atPath: macOS.path) { return macOS }
    }

    throw QueryResourcesError.notFound
  }

  private enum QueryResourcesError: Error {
    case notFound
  }

  private static func kind(for capture: String) -> CodeTokenKind? {
    let root = capture.split(separator: ".").first.map(String.init) ?? capture
    return switch root {
    case "keyword", "conditional", "repeat", "include", "exception": .keyword
    case "type", "constructor": .type
    case "function", "method": .function
    case "property", "field", "variable", "parameter": .property
    case "string", "character": .string
    case "number", "float": .number
    case "comment": .comment
    case "operator": .operatorSymbol
    case "constant", "boolean": .constant
    case "punctuation": .punctuation
    default: nil
    }
  }
}
