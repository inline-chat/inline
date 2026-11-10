import Foundation
@testable import InlineSyntaxHighlighting
import SwiftTreeSitter
import Testing
import TreeSitterSwift

@Suite("Code syntax highlighting")
struct CodeSyntaxHighlighterTests {
  @Test("A timed-out document does not contaminate the next code block")
  func timeoutRecovery() throws {
    let parser = Parser()
    try parser.setLanguage(Language(tree_sitter_swift()))
    parser.timeout = 0.000_001
    let large = String(repeating: "struct TimedOut { let values = [1, 2, 3] }\n", count: 2_000)
    #expect(CodeSyntaxHighlighter.parseCompleteDocument(large, with: parser) == nil)

    parser.timeout = 1
    let source = "let globe = \"🌍\""
    let recovered = try #require(CodeSyntaxHighlighter.parseCompleteDocument(source, with: parser)?.rootNode)
    let fresh = Parser()
    try fresh.setLanguage(Language(tree_sitter_swift()))
    let expected = try #require(fresh.parse(source)?.rootNode)
    #expect(recovered.range == NSRange(location: 0, length: source.utf16.count))
    #expect(recovered.sExpressionString == expected.sExpressionString)
  }

  @Test("Swift captures preserve UTF-16 ranges")
  func swiftUTF16Ranges() async throws {
    let source = "let globe = \"🌍\"\nstruct Demo {}"
    let tokens = try #require(try await CodeSyntaxHighlighter().tokens(for: source, language: "swift"))
    #expect(tokens.contains { token in
      token.kind == .keyword && (source as NSString).substring(with: token.range) == "let"
    })
    #expect(tokens.contains { token in
      token.kind == .keyword && (source as NSString).substring(with: token.range) == "struct"
    })
  }

  @Test("Unknown and oversized inputs fall back to plain")
  func fallback() async throws {
    let highlighter = CodeSyntaxHighlighter()
    #expect(try await highlighter.tokens(for: "let value = 1", language: "unknown-language") == nil)
    #expect(try await highlighter.tokens(for: String(repeating: "x", count: 100_001), language: "swift") == nil)
  }

  @Test("JavaScript base queries and JSX queries are included", arguments: ["javascript", "typescript", "tsx"])
  func javaScriptQueries(language: String) async throws {
    let source = language == "tsx" ? "const view = <div title=\"hello\" />;" : "const value = \"hello\";"
    let tokens = try #require(try await CodeSyntaxHighlighter().tokens(for: source, language: language))
    #expect(tokens.contains { $0.kind == .keyword && (source as NSString).substring(with: $0.range) == "const" })
    #expect(tokens.contains { $0.kind == .string && (source as NSString).substring(with: $0.range) == "\"hello\"" })
    if language == "tsx" {
      #expect(tokens.contains { $0.kind == .type && (source as NSString).substring(with: $0.range) == "div" })
      #expect(tokens.contains { $0.kind == .property && (source as NSString).substring(with: $0.range) == "title" })
    }
  }

  @Test("Rust grammar is compatible with the pinned parser ABI")
  func rustGrammar() async throws {
    let source = "fn main() { let value = 42; }"
    let tokens = try #require(try await CodeSyntaxHighlighter().tokens(for: source, language: "rust"))
    #expect(tokens.contains { $0.kind == .keyword && (source as NSString).substring(with: $0.range) == "fn" })
    // Rust's upstream query groups numeric literals with built-in constants.
    #expect(tokens.contains { $0.kind == .constant && (source as NSString).substring(with: $0.range) == "42" })
  }

  // Sources carry a UUID so parallel tests never see each other's cache entries.
  @Test("Computed tokens are readable synchronously")
  func cachedAfterCompute() async throws {
    let source = "let id = \"\(UUID().uuidString)\""
    #expect(CodeSyntaxHighlighter.cachedTokens(for: source, language: "swift") == nil)
    let computed = try #require(try await CodeSyntaxHighlighter().tokens(for: source, language: "swift"))
    #expect(CodeSyntaxHighlighter.cachedTokens(for: source, language: "swift") == computed)
    // Aliases resolve to the same grammar and share the entry.
    #expect(CodeSyntaxHighlighter.cachedTokens(for: source, language: " Swift6 ") == computed)
  }

  @Test("Instances share one token cache")
  func sharedAcrossInstances() async throws {
    let source = "const id = \"\(UUID().uuidString)\";"
    let first = try #require(try await CodeSyntaxHighlighter().tokens(for: source, language: "ts"))
    #expect(CodeSyntaxHighlighter.cachedTokens(for: source, language: "javascript") == first)
    let second = try #require(try await CodeSyntaxHighlighter.shared.tokens(for: source, language: "typescript"))
    #expect(second == first)
  }

  @Test("Unsupported languages and uncomputed sources are not cached")
  func cacheMisses() async throws {
    let source = "let id = \"\(UUID().uuidString)\""
    _ = try await CodeSyntaxHighlighter().tokens(for: source, language: "swift")
    #expect(CodeSyntaxHighlighter.cachedTokens(for: source, language: "unknown-language") == nil)
    #expect(CodeSyntaxHighlighter.cachedTokens(for: source, language: nil) == nil)
    #expect(CodeSyntaxHighlighter.cachedTokens(for: source, language: "python") == nil)
    #expect(CodeSyntaxHighlighter.cachedTokens(for: source + " ", language: "swift") == nil)
  }

  @Test("Canonically equivalent sources do not share UTF-16 token offsets")
  func literalSourceKey() async throws {
    let id = UUID().uuidString
    let composed = "let value = \"é\(id)\"\nlet result = 42"
    let decomposed = "let value = \"e\u{301}\(id)\"\nlet result = 42"
    let highlighter = CodeSyntaxHighlighter()
    _ = try await highlighter.tokens(for: composed, language: "swift")
    #expect(CodeSyntaxHighlighter.cachedTokens(for: decomposed, language: "swift") == nil)
    let cached = try #require(try await highlighter.tokens(for: decomposed, language: "swift"))
    let fresh = try #require(try await CodeSyntaxHighlighter().tokens(for: decomposed, language: "swift"))
    #expect(cached == fresh)
  }

  @Test("Eviction keeps the total source length within the bound, oldest first")
  func evictionBound() {
    let cache = CodeTokenCache(costLimit: 100)
    let token = [CodeToken(range: NSRange(location: 0, length: 1), kind: .keyword)]
    let sources = (0 ..< 5).map { String(repeating: Character(String($0)), count: 30) }
    for source in sources.prefix(3) {
      cache.insert(token, for: source, language: .swift)
    }
    #expect(cache.totalCost == 90)
    // A hit makes the first source the most recently used.
    #expect(cache.tokens(for: sources[0], language: .swift) == token)
    cache.insert(token, for: sources[3], language: .swift)
    #expect(cache.totalCost <= 100)
    #expect(cache.tokens(for: sources[1], language: .swift) == nil)
    #expect(cache.tokens(for: sources[0], language: .swift) == token)
    #expect(cache.tokens(for: sources[2], language: .swift) == token)
    #expect(cache.tokens(for: sources[3], language: .swift) == token)

    // Reinserting the same source replaces its cost instead of adding to it.
    cache.insert(token, for: sources[3], language: .swift)
    #expect(cache.totalCost == 90)
    #expect(cache.count == 3)

    // A source larger than the whole budget is skipped, not cached alone.
    cache.insert(token, for: String(repeating: "x", count: 101), language: .swift)
    #expect(cache.count == 3)

    // Many hits without inserts must not leave stale recency items behind.
    for _ in 0 ..< 1_000 {
      _ = cache.tokens(for: sources[0], language: .swift)
    }
    cache.insert(token, for: sources[4], language: .swift)
    #expect(cache.totalCost <= 100)
    #expect(cache.tokens(for: sources[4], language: .swift) == token)
    #expect(cache.tokens(for: sources[0], language: .swift) == token)
  }
}
