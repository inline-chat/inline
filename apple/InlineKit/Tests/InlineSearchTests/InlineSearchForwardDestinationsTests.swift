import Foundation
import InlineKit
import Testing

@testable import InlineSearch

@Suite("Recent forward destinations")
struct InlineSearchForwardDestinationsTests {
  @Test("recency takes priority over pinned sidebar order and duplicates are removed")
  func recentOrder() async {
    let catalog = InlineSearchChatCatalog()
    await catalog.replace([
      snapshot(id: 1, date: 10, pinned: true),
      snapshot(id: 2, date: 30),
      snapshot(id: 3, date: 20),
      snapshot(id: 2, date: 30),
    ])
    let recent = await catalog.recentForwardDestinations(limit: 2)
    #expect(recent.map(\.peerId) == [.user(id: 2), .user(id: 3)])
  }

  @Test("archived chats and destinations without a chat are excluded")
  func excludesUnavailable() async {
    let catalog = InlineSearchChatCatalog()
    await catalog.replace([
      snapshot(id: 1, date: 40, archived: true),
      snapshot(id: 2, date: 30, hasChat: false),
      snapshot(id: 3, date: 20),
    ])
    let recent = await catalog.recentForwardDestinations()
    #expect(recent.map(\.peerId) == [.user(id: 3)])
    #expect(await catalog.recentForwardDestinations(limit: 0).isEmpty)
    #expect(await catalog.recentForwardDestinations(limit: -1).isEmpty)
  }

  @Test("equal dates have a stable order and reset removes old account destinations")
  func stableOrderAndReset() async {
    let catalog = InlineSearchChatCatalog()
    await catalog.replace([snapshot(id: 2, date: 10), snapshot(id: 1, date: 10)])
    #expect(await catalog.recentForwardDestinations().map(\.peerId) == [.user(id: 1), .user(id: 2)])
    await catalog.replace([])
    #expect(await catalog.recentForwardDestinations().isEmpty)
  }

  private func snapshot(
    id: Int64, date: TimeInterval, pinned: Bool = false, archived: Bool = false, hasChat: Bool = true
  ) -> HomeChatListItemSnapshot {
    var dialog = Dialog(optimisticForUserId: id)
    dialog.chatId = hasChat ? id + 100 : nil
    dialog.pinned = pinned
    dialog.archived = archived
    return HomeChatListItemSnapshot(
      item: HomeChatItem(
        dialog: dialog,
        user: UserInfo(user: User(id: id, email: nil, firstName: "Person \(id)")),
        chat: nil, lastMessage: nil, space: nil
      ),
      sortDateOverride: Date(timeIntervalSince1970: date)
    )
  }
}
