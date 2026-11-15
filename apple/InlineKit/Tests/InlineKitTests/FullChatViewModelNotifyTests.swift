import Foundation
@testable import InlineKit
import Testing

@Suite("Chat screen notifications from FullChatViewModel")
struct FullChatViewModelNotifyTests {
  @Test("the first item notifies")
  func firstItem() {
    #expect(FullChatViewModel.notifies(from: nil, to: item(unreadCount: 3, readInboxMaxId: 10)))
  }

  @Test("read progress inside an unread chat stays quiet")
  func readProgressWhileUnread() {
    let old = item(unreadCount: 30, readInboxMaxId: 100, mentions: 2, reactions: 1)
    let new = item(unreadCount: 12, readInboxMaxId: 118, readOutboxMaxId: 90, mentions: 1, reactions: 3)
    #expect(!FullChatViewModel.notifies(from: old, to: new))
  }

  @Test("reaching zero unread notifies, and so does a new unread")
  func unreadFlips() {
    let unread = item(unreadCount: 2, readInboxMaxId: 100)
    let read = item(unreadCount: 0, readInboxMaxId: 102)
    #expect(FullChatViewModel.notifies(from: unread, to: read))
    #expect(FullChatViewModel.notifies(from: read, to: unread))
  }

  @Test("mentions and reactions flip on their own")
  func activityFlips() {
    let base = item(unreadCount: 0, readInboxMaxId: 100)
    #expect(FullChatViewModel.notifies(from: base, to: item(unreadCount: 0, readInboxMaxId: 100, mentions: 1)))
    #expect(FullChatViewModel.notifies(from: base, to: item(unreadCount: 0, readInboxMaxId: 100, reactions: 1)))
  }

  @Test("marking unread notifies")
  func unreadMark() {
    let old = item(unreadCount: 0, readInboxMaxId: 100)
    var new = old
    new.dialog.unreadMark = true
    #expect(FullChatViewModel.notifies(from: old, to: new))
  }

  @Test("other dialog fields, the header and the peer still notify")
  func screenFields() {
    let old = item(unreadCount: 4, readInboxMaxId: 100)

    var pinned = old
    pinned.dialog.pinned = true
    #expect(FullChatViewModel.notifies(from: old, to: pinned))

    var collapsed = old
    collapsed.dialog.collapsedMaxId = 50
    #expect(FullChatViewModel.notifies(from: old, to: collapsed))

    var renamed = old
    renamed.chat?.title = "Renamed"
    #expect(FullChatViewModel.notifies(from: old, to: renamed))

    var withoutChat = old
    withoutChat.chat = nil
    #expect(FullChatViewModel.notifies(from: withoutChat, to: old))
  }

  @Test("a new last message alone stays quiet")
  func lastMessage() {
    let old = item(unreadCount: 4, readInboxMaxId: 100)
    var new = old
    new.chat?.lastMsgId = 200
    #expect(!FullChatViewModel.notifies(from: old, to: new))
  }

  private func item(
    unreadCount: Int,
    readInboxMaxId: Int64,
    readOutboxMaxId: Int64? = nil,
    mentions: Int = 0,
    reactions: Int = 0
  ) -> SpaceChatItem {
    var dialog = Dialog.previewThread
    dialog.chatId = 1
    dialog.unreadCount = unreadCount
    dialog.readInboxMaxId = readInboxMaxId
    dialog.readOutboxMaxId = readOutboxMaxId
    dialog.unreadMentionsCount = mentions
    dialog.unreadReactionsCount = reactions
    let chat = Chat(
      id: 1,
      date: Date(timeIntervalSince1970: 1),
      type: .thread,
      title: "Thread",
      spaceId: nil
    )
    return SpaceChatItem(dialog: dialog, chat: chat)
  }
}
