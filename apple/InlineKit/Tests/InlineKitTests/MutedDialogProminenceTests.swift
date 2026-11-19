import Foundation
import GRDB
@testable import InlineKit
import InlineProtocol
import Testing

@Suite("Muted dialog prominence")
struct MutedDialogProminenceTests {
  @Test("Muted settings serialize with the mode field first, as Dialog.mutedSQL reads it")
  func mutedBlobPrefix() throws {
    let muted: InlineProtocol.DialogNotificationSettings = .with { $0.mode = .none }
    #expect(try muted.serializedData() == Data([0x08, 0x03]))
  }

  @Test("Muted chats are not prominent unread, in the counts and on the row")
  func mutedChatsAreNotProminent() throws {
    let database = AppDatabase.empty()
    let cases: [(userID: Int64, settings: InlineProtocol.DialogNotificationSettings?, prominent: Bool)] = [
      (921, nil, true),
      (922, .with { $0.mode = .all }, true),
      (923, .with { $0.mode = .mentions }, true),
      (924, .with { $0.mode = .none }, false),
    ]

    try database.dbWriter.write { db in
      for item in cases {
        try User(id: item.userID, email: nil, firstName: "User \(item.userID)").insert(db)
        try Chat(
          id: item.userID + 1_000,
          date: Date(timeIntervalSince1970: 1_790_000_000),
          type: .privateChat,
          title: nil,
          spaceId: nil,
          peerUserId: item.userID
        ).insert(db)
        var dialog = Dialog(optimisticForUserId: item.userID)
        dialog.chatId = item.userID + 1_000
        dialog.open = true
        dialog.unreadCount = 2
        dialog.notificationSettings = item.settings
        try dialog.insert(db)
      }
    }

    let prominentByDialogID = try database.dbWriter.read { db in
      try Dictionary(
        uniqueKeysWithValues: Row.fetchAll(db, sql: """
          SELECT "dialog"."id" AS "id", \(Dialog.prominentUnreadSQL) AS "isProminent"
          FROM "dialog"
          LEFT JOIN "chat" ON "chat"."id" = "dialog"."chatId"
          """).map { row -> (Int64, Bool) in (row["id"], row["isProminent"]) }
      )
    }
    let snapshots = try database.dbWriter.read { db in
      try ChatListDatabaseQuery.fetchSnapshots(
        db,
        spaceID: nil,
        includeSpaceChatsInHome: true,
        translationLanguage: "en",
        includeTimestampText: false
      )
    }

    for item in cases {
      let dialogID = Dialog.getDialogId(peerUserId: item.userID)
      #expect(prominentByDialogID[dialogID] == item.prominent, "dialog \(item.userID)")
      let snapshot = snapshots.first { $0.dialogID == dialogID }
      #expect(snapshot?.isProminent == item.prominent, "row \(item.userID)")
    }
  }
}
