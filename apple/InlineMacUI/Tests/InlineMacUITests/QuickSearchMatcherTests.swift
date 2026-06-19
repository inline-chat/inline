import Testing
@testable import InlineMacUI

@Test func quickSearchMatcher_matchesApostropheVariants() {
  let exactScore = QuickSearchMatcher.score(
    query: "mo's chat",
    fields: [.init(value: "mo's chat", boost: 0)]
  )
  let asciiApostropheScore = QuickSearchMatcher.score(
    query: "mos chat",
    fields: [.init(value: "mo's chat", boost: 0)]
  )
  let curlyApostropheScore = QuickSearchMatcher.score(
    query: "mo’s chat",
    fields: [.init(value: "mo's chat", boost: 0)]
  )

  #expect(exactScore != nil)
  #expect(asciiApostropheScore == exactScore)
  #expect(curlyApostropheScore == exactScore)
}

@Test func quickSearchMatcher_matchesCompactOmittedSpaces() {
  let score = QuickSearchMatcher.score(
    query: "xy",
    fields: [.init(value: "x y", boost: 0)]
  )

  #expect(score != nil)
  #expect((score ?? 0) > 8_000)
}

@Test func quickSearchMatcher_rejectsWeakPartialMultiTokenMatches() {
  let partialScore = QuickSearchMatcher.score(
    query: "deploy message",
    fields: [.init(value: "message", boost: 0)]
  )
  let completeScore = QuickSearchMatcher.score(
    query: "deploy message",
    fields: [.init(value: "deploy message", boost: 0)]
  )

  #expect(partialScore == nil)
  #expect(completeScore != nil)
}
