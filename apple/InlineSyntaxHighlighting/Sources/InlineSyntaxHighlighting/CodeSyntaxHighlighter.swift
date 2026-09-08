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
    if let entry = cache.first(where: { $0.text.utf8.elementsEqual(text.utf8) && $0.language == language }) {
      return entry.tokens
    }
    try Task.checkCancellation()
    let (parser, configuration) = try configuredParser(for: language)
    parser.timeout = 0.03
    guard let tree = Self.parseCompleteDocument(text, with: parser),
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
    cache.removeAll { $0.text.utf8.elementsEqual(text.utf8) && $0.language == language }
    cache.insert(.init(text: text, language: language, tokens: tokens), at: 0)
    if cache.count > cacheLimit {
      cache.removeLast(cache.count - cacheLimit)
    }
    return tokens
  }

  static func parseCompleteDocument(_ text: String, with parser: Parser) -> MutableTree? {
    guard let tree = parser.parse(text) else {
      // Tree-sitter resumes a timed-out parse by default. Each request here is
      // a complete document, so the next code block must start from scratch.
      parser.reset()
      return nil
    }
    return tree
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
    let definition: (pointer: OpaquePointer, name: String, bundle: String) = switch language {
      case .swift: (tree_sitter_swift(), "Swift", "TreeSitterSwift_TreeSitterSwift")
      case .typeScript: (tree_sitter_typescript(), "TypeScript", "TreeSitterTypeScript_TreeSitterTypeScript")
      case .tsx: (tree_sitter_tsx(), "TSX", "TreeSitterTypeScript_TreeSitterTSX")
      case .python: (tree_sitter_python(), "Python", "TreeSitterPython_TreeSitterPython")
      case .bash: (tree_sitter_bash(), "Bash", "TreeSitterBash_TreeSitterBash")
      case .html: (tree_sitter_html(), "HTML", "TreeSitterHTML_TreeSitterHTML")
      case .css: (tree_sitter_css(), "CSS", "TreeSitterCSS_TreeSitterCSS")
      case .json: (tree_sitter_json(), "JSON", "TreeSitterJSON_TreeSitterJSON")
      case .yaml: (tree_sitter_yaml(), "YAML", "TreeSitterYAML_TreeSitterYAML")
      case .go: (tree_sitter_go(), "Go", "TreeSitterGo_TreeSitterGo")
      case .rust: (tree_sitter_rust(), "Rust", "TreeSitterRust_TreeSitterRust")
    }
    let grammar = Language(definition.pointer)
    var queryData = Data()
    if language == .typeScript || language == .tsx {
      guard let resources = Bundle.module.resourceURL else { throw QueryResourcesError.notFound }
      let queries = resources.appendingPathComponent("Queries", isDirectory: true)
      try queryData.append(Data(contentsOf: queries.appendingPathComponent("javascript-highlights.scm")))
      queryData.append(0x0A)
      if language == .tsx {
        try queryData.append(Data(contentsOf: queries.appendingPathComponent("javascript-highlights-jsx.scm")))
        queryData.append(0x0A)
      }
    }
    let highlightsURL = try Self.queriesURL(bundleName: definition.bundle)
      .appendingPathComponent("highlights.scm")
    try queryData.append(Data(contentsOf: highlightsURL))
    // Message rendering needs only highlights, not tags, locals, or injection queries.
    let configuration = try LanguageConfiguration(
      grammar, name: definition.name, queries: [.highlights: Query(language: grammar, data: queryData)]
    )
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

    for candidate in candidates.compactMap(\.self) {
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
      case "type", "constructor", "tag": .type
      case "function", "method": .function
      case "property", "field", "variable", "parameter", "attribute": .property
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
