import Foundation
import GRDB
@testable import InlineKit
import InlineProtocol
import Testing

@Suite("App badge count")
struct AppBadgeCountTests {
  private struct Case {
    let chatID: Int64
    let type: ChatType
    var peerUserID: Int64?
    var unreadCount = 0
    var unreadMentionsCount = 0
    var followMode: DialogFollowMode?
    var muted = false
    var archived = false
    let counted: Bool
  }

  @Test("Counts chats shown in blue: prominent unread, or any unseen mention or reply")
  func countsBlueChats() throws {
    let cases: [Case] = [
      Case(chatID: 1, type: .privateChat, peerUserID: 901, unreadCount: 3, counted: true),
      Case(chatID: 2, type: .privateChat, peerUserID: 902, unreadCount: 3, muted: true, counted: false),
      Case(chatID: 3, type: .privateChat, peerUserID: 903, unreadMentionsCount: 1, muted: true, counted: true),
      Case(chatID: 4, type: .thread, unreadCount: 5, counted: false),
      Case(chatID: 5, type: .thread, unreadCount: 5, unreadMentionsCount: 1, counted: true),
      Case(chatID: 6, type: .thread, unreadMentionsCount: 2, counted: true),
      Case(chatID: 7, type: .thread, unreadCount: 1, followMode: .following, counted: true),
      Case(chatID: 8, type: .privateChat, peerUserID: 908, unreadCount: 1, archived: true, counted: false),
      Case(chatID: 9, type: .privateChat, peerUserID: 909, counted: false),
    ]

    let database = AppDatabase.empty()
    try database.dbWriter.write { db in
      for item in cases {
        if let userID = item.peerUserID {
          try User(id: userID, email: nil, firstName: "User \(userID)").insert(db)
        }
        let chat = Chat(
          id: item.chatID,
          date: Date(timeIntervalSince1970: 1_790_000_000),
          type: item.type,
          title: item.type == .thread ? "Thread \(item.chatID)" : nil,
          spaceId: nil,
          peerUserId: item.peerUserID
        )
        try chat.insert(db)
        var dialog = Dialog(optimisticForChat: chat)
        dialog.chatId = item.chatID
        dialog.open = true
        dialog.unreadCount = item.unreadCount
        dialog.unreadMentionsCount = item.unreadMentionsCount
        dialog.followMode = item.followMode
        dialog.archived = item.archived
        dialog.notificationSettings = item.muted ? .with { $0.mode = .none } : nil
        try dialog.insert(db)
      }
    }

    let count = try database.dbWriter.read { db in try Dialog.fetchAppBadgeCount(db) }
    #expect(count == cases.filter(\.counted).count)
  }
}
