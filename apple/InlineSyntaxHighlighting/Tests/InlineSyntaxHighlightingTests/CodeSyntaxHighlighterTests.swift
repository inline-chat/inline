import Foundation
import Testing
@testable import InlineSyntaxHighlighting

@Suite("Code syntax highlighting")
struct CodeSyntaxHighlighterTests {
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
    #expect(try await highlighter.tokens(for: "let value = 1", language: "python") == nil)
    #expect(try await highlighter.tokens(for: String(repeating: "x", count: 100_001), language: "swift") == nil)
  }
}
