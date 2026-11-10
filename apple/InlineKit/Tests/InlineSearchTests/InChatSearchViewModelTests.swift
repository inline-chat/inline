import Foundation
import Testing

@testable import InlineKit
@testable import InlineSearch

@Suite("In-chat search view model", .timeLimit(.minutes(1)))
@MainActor
struct InChatSearchViewModelTests {
  @Test("selects the newest match first and counts loaded matches")
  func selectsNewestFirst() async throws {
    let source = ScriptedSource(local: [100, 80], remote: [100, 90, 70])
    let model = makeModel(source)

    model.setQuery("deploy")
    try await waitUntil { !model.isSearching }

    #expect(model.matches.map(\.messageId) == [100, 90, 80, 70])
    #expect(model.currentMessageId == 100)
    #expect(model.counterText == "1 of 4")
  }

  @Test("stepping older never skips a server hit between local hits")
  func olderStepsMergeSources() async throws {
    // Local knows 100 and 80; the server pages two at a time and also has 90 and 70.
    let source = ScriptedSource(local: [100, 80], remote: [100, 90, 70])
    let model = makeModel(source, pageLimit: 2)

    model.setQuery("deploy")
    try await waitUntil { model.currentMessageId == 100 && !model.isSearching }

    var visited: [Int64] = [100]
    for _ in 0 ..< 3 {
      model.goOlder()
      let previous = visited.last!
      try await waitUntil { (model.currentMessageId ?? .max) < previous }
      visited.append(model.currentMessageId!)
    }

    #expect(visited == [100, 90, 80, 70])
    model.goNewer()
    #expect(model.currentMessageId == 80)
  }

  @Test("pages load on demand and the total comes from the server count")
  func pagesOnDemandWithServerTotal() async throws {
    let source = ScriptedSource(local: [], remote: [50, 45, 40, 35, 30, 25, 20])
    let model = makeModel(source, pageLimit: 2)

    model.setQuery("deploy")
    try await waitUntil { !model.isSearching && model.totalCount != nil }

    // Only the first page is loaded, but the counter already shows the exact total.
    #expect(model.matches.map(\.messageId) == [50, 45])
    #expect(model.counterText == "1 of 7")
    #expect(model.resultsText == "7 messages")

    // A list showing one of its last rows loads the next page.
    model.loadMoreIfNeeded(after: model.matches[1])
    try await waitUntil { model.matches.count == 4 }
    #expect(model.matches.map(\.messageId) == [50, 45, 40, 35])
    #expect(model.counterText == "1 of 7")
  }

  @Test("no matches says so")
  func noMatches() async throws {
    let source = ScriptedSource(local: [], remote: [])
    let model = makeModel(source)

    model.setQuery("deploy")
    try await waitUntil { !model.isSearching }

    #expect(model.counterText == "No results")
    #expect(model.resultsText == "No results")
    #expect(model.canGoOlder == false)
  }

  @Test("a failed server keeps local matches")
  func remoteFailureKeepsLocal() async throws {
    let source = ScriptedSource(local: [12, 5], remote: nil)
    let model = makeModel(source)

    model.setQuery("deploy")
    try await waitUntil { !model.isSearching }

    #expect(model.remoteFailed)
    #expect(model.matches.map(\.messageId) == [12, 5])
    #expect(model.hasMore == false)
    #expect(model.counterText == "1 of 2")
  }

  @Test("an older press before results arrive lands on the newest match")
  func earlyOlderPressSelectsNewest() async throws {
    let source = ScriptedSource(local: [30, 20], remote: [30, 20])
    let model = makeModel(source)

    model.setQuery("deploy")
    model.goOlder()
    try await waitUntil { !model.isSearching }

    #expect(model.currentMessageId == 30)
  }

  @Test("cleared history hides older matches")
  func collapsedHistoryHidesMatches() async throws {
    let source = ScriptedSource(local: [40, 30, 10], remote: [40, 30, 10])
    let model = makeModel(source)
    model.collapsedMaxId = 30

    model.setQuery("deploy")
    try await waitUntil { !model.isSearching }

    #expect(model.matches.map(\.messageId) == [40])
    #expect(model.canGoOlder == false)
  }

  @Test("a new query drops the old results")
  func newQueryResets() async throws {
    let source = ScriptedSource(local: [9], remote: [9])
    let model = makeModel(source)

    model.setQuery("deploy")
    try await waitUntil { !model.isSearching }
    model.setQuery("")

    #expect(model.matches.isEmpty)
    #expect(model.currentMessageId == nil)
    #expect(model.counterText == nil)
  }

  @Test("typing a new query keeps the old results until new ones arrive")
  func newQueryKeepsOldResultsWhileLoading() async throws {
    let source = ScriptedSource(local: [9, 7], remote: [9, 7])
    let model = makeModel(source)

    model.setQuery("deploy")
    try await waitUntil { !model.isSearching }
    model.setQuery("deployed")

    // Same run loop turn: nothing new has loaded, the old list is still shown.
    #expect(model.matches.map(\.messageId) == [9, 7])
    #expect(model.currentMessageId == nil)
    try await waitUntil { !model.isSearching && model.currentMessageId != nil }
    #expect(model.currentMessageId == 9)
  }

  @Test("highlight keeps the message's own casing and accents")
  func highlightUsesMessageText() {
    #expect(InChatSearchText.highlight(in: "Ship the Café menu", query: "cafe") == "Café")
    #expect(InChatSearchText.highlight(in: "Deploy at noon", query: "noon deploy") == "Deploy")
    #expect(InChatSearchText.highlight(in: "nothing here", query: "deploy") == nil)
  }

  @Test("a file name match previews the file name, not the caption")
  func fileNameMatchPreviewsFileName() {
    let hit = InChatSearchHit(
      messageId: 1, date: .now, senderId: 1, sender: nil,
      text: "here is the report", fileName: "Q3-budget.pdf", isOutgoing: false
    )
    #expect(InChatSearchText.matchedText(of: hit, query: "budget") == "Q3-budget.pdf")
    #expect(InChatSearchText.matchedText(of: hit, query: "report") == "here is the report")
    #expect(InChatSearchText.highlight(in: hit.text, query: "budget") == nil)
  }

  @Test("snippet centers on the match")
  func snippetCentersOnMatch() {
    let text = String(repeating: "filler ", count: 40) + "the deploy failed"
    let snippet = InChatSearchText.snippet(text, query: "deploy")
    #expect(snippet.hasPrefix("…"))
    #expect(snippet.contains("deploy failed"))
  }

  // MARK: Helpers

  private func makeModel(_ source: ScriptedSource, pageLimit: Int = 50) -> InChatSearchViewModel {
    InChatSearchViewModel(source: source, timing: .immediate, pageLimit: pageLimit)
  }

  private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0 ..< 2_000 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("condition not met in time")
  }
}

/// Serves newest-first pages from fixed message IDs. A nil remote list fails every request.
private struct ScriptedSource: InChatSearchSource {
  let localIds: [Int64]
  let remoteIds: [Int64]?

  init(local: [Int64], remote: [Int64]?) {
    localIds = local.sorted(by: >)
    remoteIds = remote?.sorted(by: >)
  }

  struct Failure: Error {}

  func local(query _: String, beforeMessageId: Int64?, limit: Int) async throws -> InChatSearchPage {
    page(localIds, before: beforeMessageId, limit: limit)
  }

  func remote(query _: String, beforeMessageId: Int64?, limit: Int) async throws -> InChatSearchPage {
    guard let remoteIds else { throw Failure() }
    return page(remoteIds, before: beforeMessageId, limit: limit)
  }

  func remoteCount(query _: String) async throws -> Int {
    guard let remoteIds else { throw Failure() }
    return remoteIds.count
  }

  private func page(_ ids: [Int64], before: Int64?, limit: Int) -> InChatSearchPage {
    let remaining = ids.filter { $0 < (before ?? .max) }
    let slice = Array(remaining.prefix(limit))
    let hits = slice.map {
      InChatSearchHit(
        messageId: $0,
        date: Date(timeIntervalSince1970: TimeInterval($0)),
        senderId: 1,
        sender: nil,
        text: "deploy \($0)",
        isOutgoing: false
      )
    }
    return InChatSearchPage(hits: hits, oldestMessageId: slice.last, hasMore: remaining.count > limit)
  }
}
