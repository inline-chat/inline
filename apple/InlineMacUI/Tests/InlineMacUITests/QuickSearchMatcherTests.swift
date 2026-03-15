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
