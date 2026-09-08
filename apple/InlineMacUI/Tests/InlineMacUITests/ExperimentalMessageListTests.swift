import Foundation
import InlineKit
@testable import InlineMacUI
import Testing

struct ExperimentalMessageListTests {
  @Test func contentReloadKeepsSyntheticRowsAndUnchangedMessagesOutOfTheUpdate() {
    let rows: [ExperimentalMessageListRow] = [
      .parentMessage(id: 20), .repliesSeparator, .message(id: 10),
      .message(id: 20), .unreadSeparator, .message(id: 30), .message(id: 40),
    ]
    #expect(ExperimentalMessageListRowProjection.rowsToReload(changedMessageIDs: [], in: rows).isEmpty)
    #expect(ExperimentalMessageListRowProjection.rowsToReload(changedMessageIDs: [20], in: rows) == IndexSet([0, 2, 3]))
    #expect(ExperimentalMessageListRowProjection.rowsToReload(changedMessageIDs: [30], in: rows) == IndexSet([5, 6]))
    #expect(ExperimentalMessageListRowProjection.rowsToReload(changedMessageIDs: [99], in: rows).isEmpty)
  }

  @Test func optimisticRowsDoNotHideUnknownHistory() {
    let rows = project([message(10), message(-1), message(30)], coverage: .unknown)
    #expect(rows.contains(.historyHole(afterID: 10, beforeID: 30)))
    #expect(rows.count(where: { if case .message = $0 { true } else { false } }) == 3)
  }

  @Test func certifiedHistoryHasNoSyntheticHole() {
    let messages = [message(10), message(30)]
    let coverage = MessagesProgressiveViewModel.LoadedWindowMetadata(messages: messages, holes: []).historyCoverage
    #expect(!project(messages, coverage: coverage).contains(.historyHole(afterID: 10, beforeID: 30)))
  }

  @Test func syntheticIdentityDoesNotCollideWithMessageIdentity() throws {
    let rows = ExperimentalMessageListRowProjection.makeRows(
      messages: [message(10), message(30)], showUnreadAfter: 10,
      showsCollapsedHistory: true, parentMessageStableId: 10, coverage: .unknown
    )
    #expect(rows.prefix(3) == [.parentMessage(id: 10), .repliesSeparator, .collapsedHistory])
    #expect(rows.count(where: { $0 == .unreadSeparator }) == 1)
    #expect(Set(rows).count == rows.count)
    #expect(try #require(rows.firstIndex(of: .unreadSeparator)) < rows.firstIndex(of: .message(id: 30))!)
  }

  @Test func checkpointsSurviveStoreRecreationAndRejectStaleWriters() async throws {
    let suite = "chat.inline.tests.message-list.\(UUID().uuidString)"
    let store = MessageListPositionStore(suiteName: suite)
    let anchor = try #require(MessageListViewportAnchor(messageID: 9_007_199_254_740_993, offsetY: -18.25))
    await store.save(.anchor(anchor), accountID: 1, chatID: 2, issuedAt: 200)
    await store.save(.latest, accountID: 1, chatID: 2, issuedAt: 100)
    let reopened = MessageListPositionStore(suiteName: suite)
    #expect(await reopened.load(accountID: 1, chatID: 2) == .anchor(anchor))
    #expect(await reopened.load(accountID: 2, chatID: 2) == nil)
    #expect(await reopened.load(accountID: 1, chatID: 3) == nil)
    await store.save(.latest, accountID: 1, chatID: 2, issuedAt: 300)
    #expect(await reopened.load(accountID: 1, chatID: 2) == .latest)
  }

  @Test func malformedAndInvalidScopeStateDoesNotRestore() async {
    let suite = "chat.inline.tests.message-list.\(UUID().uuidString)"
    UserDefaults(suiteName: suite)?.set(Data("broken".utf8), forKey: "experimental.macMessageListV2.position.1.2")
    let store = MessageListPositionStore(suiteName: suite)
    #expect(await store.load(accountID: 1, chatID: 2) == nil)
    await store.save(.latest, accountID: 0, chatID: 2, issuedAt: 1)
    #expect(await store.load(accountID: 0, chatID: 2) == nil)
  }

  private func project(
    _ messages: [FullMessage],
    coverage: MessageHistoryCoverageProjection
  ) -> [ExperimentalMessageListRow] {
    ExperimentalMessageListRowProjection.makeRows(
      messages: messages, showUnreadAfter: nil, showsCollapsedHistory: false,
      parentMessageStableId: nil, coverage: coverage
    )
  }

  private func message(_ id: Int64) -> FullMessage {
    var message = Message(
      messageId: id, fromId: 1, date: Date(timeIntervalSince1970: 100), text: "Fixture",
      peerUserId: nil, peerThreadId: 1, chatId: 1
    )
    message.globalId = id
    return FullMessage(senderInfo: nil, message: message, reactions: [], repliedToMessage: nil, attachments: [])
  }
}
