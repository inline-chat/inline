import Testing

@testable import InlineKit

@Suite("Chat info pagination trigger")
struct ChatInfoPaginationTriggerTests {
  @Test("media triggers when current item is near oldest loaded IDs")
  func mediaTriggersNearOldestWindow() {
    let shouldLoad = ChatMediaViewModel.shouldLoadMore(
      currentMessageId: 120,
      loadedMessageIds: [500, 400, 300, 200, 150, 140, 130, 120, 110, 100],
      triggerWindow: 3
    )

    #expect(shouldLoad)
  }

  @Test("media does not trigger for newer IDs")
  func mediaDoesNotTriggerForNewerIds() {
    let shouldLoad = ChatMediaViewModel.shouldLoadMore(
      currentMessageId: 300,
      loadedMessageIds: [500, 400, 300, 200, 150, 140, 130, 120, 110, 100],
      triggerWindow: 3
    )

    #expect(!shouldLoad)
  }

  @Test("links dedupes IDs before selecting oldest trigger window")
  func linksDedupesIdsBeforeTriggering() {
    let shouldLoad = ChatLinksViewModel.shouldLoadMore(
      currentMessageId: 100,
      loadedMessageIds: [300, 200, 200, 150, 100, 100],
      triggerWindow: 2
    )

    #expect(shouldLoad)
  }

  @Test("links does not trigger for empty loaded IDs")
  func linksDoesNotTriggerForEmptyState() {
    let shouldLoad = ChatLinksViewModel.shouldLoadMore(
      currentMessageId: 1,
      loadedMessageIds: [],
      triggerWindow: 2
    )

    #expect(!shouldLoad)
  }
}
