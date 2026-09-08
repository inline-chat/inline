import InlineSyntaxHighlighting
import Testing

@Suite("iOS bundled code highlighting", .serialized)
struct CodeSyntaxHighlighterDeviceTests {
  struct Sample {
    let language: String
    let source: String
  }

  @Test("Every grammar loads its query resources from the device app", arguments: [
    Sample(language: "swift", source: "let value = \"hello\""),
    Sample(language: "typescript", source: "const value: string = 'hello';"),
    Sample(language: "tsx", source: "const view = <div>Hello</div>;"),
    Sample(language: "python", source: "def greet():\n    return 'hello'"),
    Sample(language: "bash", source: "echo \"hello\""),
    Sample(language: "html", source: "<div class=\"greeting\">Hello</div>"),
    Sample(language: "css", source: ".greeting { color: red; }"),
    Sample(language: "json", source: "{\"greeting\": true}"),
    Sample(language: "yaml", source: "greeting: true"),
    Sample(language: "go", source: "package main\nfunc main() { println(\"hello\") }"),
    Sample(language: "rust", source: "fn main() { let value = \"hello\"; }"),
  ])
  func bundledGrammar(sample: Sample) async throws {
    let tokens = try #require(try await CodeSyntaxHighlighter().tokens(for: sample.source, language: sample.language))
    #expect(!tokens.isEmpty)
    for token in tokens {
      #expect(token.range.location >= 0)
      #expect(token.range.length > 0)
      #expect(token.range.location + token.range.length <= sample.source.utf16.count)
    }
  }

  @Test("Canonically equivalent source does not share incompatible UTF-16 token offsets")
  func literalSourceCache() async throws {
    let composed = "let value = \"é\"\nlet result = 42"
    let decomposed = "let value = \"e\u{301}\"\nlet result = 42"
    let shared = CodeSyntaxHighlighter()
    _ = try await shared.tokens(for: composed, language: "swift")
    let cached = try #require(try await shared.tokens(for: decomposed, language: "swift"))
    let fresh = try #require(try await CodeSyntaxHighlighter().tokens(for: decomposed, language: "swift"))
    #expect(cached == fresh)
  }
}
