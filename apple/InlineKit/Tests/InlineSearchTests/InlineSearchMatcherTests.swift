import Testing

@testable import InlineSearch

@Suite("Inline search matcher")
struct InlineSearchMatcherTests {
  @Test("normalization collapses whitespace and punctuation")
  func normalizationCollapsesSeparators() throws {
    let prepared = try #require(InlineSearchMatcher.prepare("  Mo’s\t Chat\n"))

    #expect(prepared.normalized == "mo s chat")
    #expect(prepared.compact == "moschat")
    #expect(prepared.tokens == ["mo", "s", "chat"])
  }

  @Test("compact matching tolerates inserted whitespace")
  func compactMatchingToleratesInsertedWhitespace() throws {
    let query = try #require(InlineSearchMatcher.prepare("de \t na"))
    let match = try #require(InlineSearchMatcher.match(
      query: query,
      fields: [InlineSearchField("Dena", priority: 400)]
    ))

    #expect(match.tier == .compact)
  }

  @Test("every token is required for multi-token matches")
  func everyTokenIsRequired() throws {
    let query = try #require(InlineSearchMatcher.prepare("deploy message"))

    #expect(InlineSearchMatcher.match(
      query: query,
      fields: [InlineSearchField("message", priority: 400)]
    ) == nil)
    #expect(InlineSearchMatcher.match(
      query: query,
      fields: [InlineSearchField("deploy status message", priority: 400)]
    )?.tier == .tokenPrefix)
  }

  @Test("text tier precedes field priority")
  func textTierPrecedesFieldPriority() throws {
    let query = try #require(InlineSearchMatcher.prepare("alex"))
    let exact = try #require(InlineSearchMatcher.match(
      query: query,
      fields: [InlineSearchField("Alex", priority: 100)]
    ))
    let prefix = try #require(InlineSearchMatcher.match(
      query: query,
      fields: [InlineSearchField("Alexander", priority: 500)]
    ))

    #expect(exact.tier == .exact)
    #expect(prefix.tier == .fieldPrefix)
    #expect(InlineSearchMatch.isBetter(exact, than: prefix))
  }
}
