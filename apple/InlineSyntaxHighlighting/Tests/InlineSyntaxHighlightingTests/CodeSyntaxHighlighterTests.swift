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
}
