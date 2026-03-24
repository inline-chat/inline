import Foundation
import GRDB
import InlineProtocol
import Testing

@testable import InlineKit

@Suite("Reply Thread Models")
struct ReplyThreadModelsTests {
  private let parentChatId: Int64 = 901

  private func seedParentChat(in db: Database) throws {
    try Chat(
      id: parentChatId,
      date: Date(),
      type: .thread,
      title: "Parent",
      spaceId: nil
    ).save(db)
  }

  @Test("chat model maps parent thread metadata from protocol")
  func chatMapsParentMetadata() {
    let proto = InlineProtocol.Chat.with {
      $0.id = 2_001
      $0.date = Int64(Date().timeIntervalSince1970)
      $0.title = "Replies"
      $0.parentChatID = 901
      $0.parentMessageID = 77
      $0.peerID = .with {
        $0.chat.chatID = 2_001
      }
    }

    let chat = Chat(from: proto)

    #expect(chat.id == 2_001)
    #expect(chat.parentChatId == 901)
    #expect(chat.parentMessageId == 77)
  }

  @Test("message model maps replies from protocol")
  func messageMapsReplies() {
    let proto = InlineProtocol.Message.with {
      $0.id = 44
      $0.chatID = 901
      $0.fromID = 1
      $0.date = Int64(Date().timeIntervalSince1970)
      $0.message = "Parent"
      $0.peerID = .with {
        $0.chat.chatID = 901
      }
      $0.replies = .with {
        $0.chatID = 2_001
        $0.replyCount = 3
        $0.hasUnread_p = true
        $0.recentReplierUserIds = [12, 34]
      }
    }

    let message = Message(from: proto)

    #expect(message.replyThreadChatId == 2_001)
    #expect(message.replyThreadReplyCount == 3)
    #expect(message.hasUnreadReplyThread)
    #expect(message.replyThreadRecentReplierUserIds == [12, 34])
  }

  @Test("replies persist through local database save")
  func repliesPersistLocally() throws {
    let database = AppDatabase.empty()
    let parentChatId: Int64 = 901

    try database.dbWriter.write { db in
      try User(
        id: 1,
        email: "reply-thread@example.com",
        firstName: "Reply",
        lastName: "Thread",
        username: "replythread"
      ).save(db)

      try Chat(
        id: parentChatId,
        date: Date(),
        type: .thread,
        title: "Parent",
        spaceId: nil
      ).save(db)

      let message = Message(
        messageId: 44,
        fromId: 1,
        date: Date(),
        text: "Parent",
        peerUserId: nil,
        peerThreadId: parentChatId,
        chatId: parentChatId,
        replies: .with {
          $0.chatID = 2_001
          $0.replyCount = 5
          $0.hasUnread_p = true
          $0.recentReplierUserIds = [22, 11]
        }
      )
      try message.save(db)
    }

    let savedMessage = try database.dbWriter.read { db in
      try Message.fetchOne(db, key: ["messageId": 44, "chatId": parentChatId])
    }

    #expect(savedMessage?.replyThreadChatId == 2_001)
    #expect(savedMessage?.replyThreadReplyCount == 5)
    #expect(savedMessage?.hasUnreadReplyThread == true)
    #expect(savedMessage?.replyThreadRecentReplierUserIds == [22, 11])
  }

  @Test("newChat does not create a visible dialog for linked reply threads")
  func linkedReplyThreadNewChatSkipsOptimisticDialog() throws {
    let database = AppDatabase.empty()

    let update = InlineProtocol.UpdateNewChat.with {
      $0.chat = .with {
        $0.id = 2_001
        $0.date = Int64(Date().timeIntervalSince1970)
        $0.title = "Replies"
        $0.parentChatID = 901
        $0.parentMessageID = 77
        $0.peerID = .with {
          $0.chat.chatID = 2_001
        }
      }
    }

    try database.dbWriter.write { db in
      try seedParentChat(in: db)
      try update.apply(db)
    }

    let savedDialog = try database.dbWriter.read { db in
      try Dialog.fetchOne(db, id: Dialog.getDialogId(peerThreadId: 2_001))
    }

    #expect(savedDialog == nil)
  }

  @Test("newChat creates an optimistic dialog for child threads without anchor messages")
  func ordinarySubthreadNewChatCreatesOptimisticDialog() throws {
    let database = AppDatabase.empty()

    let update = InlineProtocol.UpdateNewChat.with {
      $0.chat = .with {
        $0.id = 2_101
        $0.date = Int64(Date().timeIntervalSince1970)
        $0.title = "Child Thread"
        $0.parentChatID = 901
        $0.peerID = .with {
          $0.chat.chatID = 2_101
        }
      }
    }

    try database.dbWriter.write { db in
      try seedParentChat(in: db)
      try update.apply(db)
    }

    let savedDialog = try database.dbWriter.read { db in
      try Dialog.fetchOne(db, id: Dialog.getDialogId(peerThreadId: 2_101))
    }

    #expect(savedDialog?.peerThreadId == 2_101)
    #expect(savedDialog?.chatId == 2_101)
    #expect(savedDialog?.sidebarVisible == true)
  }

  @Test("spaceChatItemQueryForChat includes hidden linked reply thread dialogs")
  func hiddenLinkedReplyThreadDialogRemainsQueryable() throws {
    let database = AppDatabase.empty()
    let threadId: Int64 = 2_102

    try database.dbWriter.write { db in
      try seedParentChat(in: db)

      let chat = Chat(
        id: threadId,
        date: Date(),
        type: .thread,
        title: "Replies",
        spaceId: nil,
        parentChatId: parentChatId,
        parentMessageId: 77
      )
      try chat.save(db)

      var dialog = Dialog(optimisticForChat: chat)
      dialog.sidebarVisible = false
      try dialog.save(db)
    }

    let chatItem = try database.dbWriter.read { db in
      try Dialog
        .spaceChatItemQueryForChat()
        .filter(id: Dialog.getDialogId(peerThreadId: threadId))
        .fetchOne(db)
    }

    #expect(chatItem?.dialog.sidebarVisible == false)
    #expect(chatItem?.chat?.id == threadId)
  }

  @Test("chatOpen preserves local draft and notification settings when the payload omits them")
  func chatOpenPreservesLocalDialogState() throws {
    let database = AppDatabase.empty()
    let threadId: Int64 = 2_103

    try database.dbWriter.write { db in
      try seedParentChat(in: db)

      let chat = Chat(
        id: threadId,
        date: Date(),
        type: .thread,
        title: "Replies",
        spaceId: nil,
        parentChatId: parentChatId,
        parentMessageId: 77
      )
      try chat.save(db)

      var dialog = Dialog(optimisticForChat: chat)
      dialog.draftMessage = .with {
        $0.text = "local draft"
      }
      dialog.notificationSettings = .with {
        $0.mode = .mentions
      }
      dialog.sidebarVisible = false
      try dialog.save(db)
    }

    let update = InlineProtocol.UpdateChatOpen.with {
      $0.chat = .with {
        $0.id = threadId
        $0.date = Int64(Date().timeIntervalSince1970)
        $0.title = "Replies"
        $0.parentChatID = parentChatId
        $0.parentMessageID = 77
        $0.peerID = .with {
          $0.chat.chatID = threadId
        }
      }
      $0.dialog = .with {
        $0.peer = .with {
          $0.chat.chatID = threadId
        }
        $0.chatID = threadId
        $0.unreadCount = 0
        $0.pinned = false
        $0.archived = false
        $0.unreadMark = false
        $0.sidebarVisible = true
      }
    }

    try database.dbWriter.write { db in
      try update.apply(db)
    }

    let savedDialog = try database.dbWriter.read { db in
      try Dialog.fetchOne(db, id: Dialog.getDialogId(peerThreadId: threadId))
    }

    #expect(savedDialog?.draftMessage?.text == "local draft")
    #expect(savedDialog?.notificationSettings?.mode == .mentions)
    #expect(savedDialog?.sidebarVisible == true)
  }
}
