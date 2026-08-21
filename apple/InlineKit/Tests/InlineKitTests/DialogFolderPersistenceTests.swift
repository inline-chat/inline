import Foundation
import GRDB
import InlineProtocol
import Testing

@testable import InlineKit

@Suite("Dialog folder persistence")
struct DialogFolderPersistenceTests {
  private func makeDatabase() throws -> DatabaseQueue {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    _ = try AppDatabase(queue)
    return queue
  }

  @Test("getChats imports folders before their child dialogs")
  func snapshotImportsFolderMembership() throws {
    let queue = try makeDatabase()
    var result = InlineProtocol.GetChatsResult()
    result.chats = [makeChat(id: 10)]
    result.folders = [.with {
      $0.id = 7
      $0.title = "Favorites"
      $0.order = "a"
    }]
    result.dialogs = [makeDialog(chatID: 10, folderID: 7, order: "b")]

    try queue.write { db in
      let imported = try GetChatsTransaction.applySnapshot(result, in: db)

      #expect(imported.failures.isEmpty)
      #expect(try DialogFolder.fetchOne(db, key: 7)?.title == "Favorites")
      #expect(try Dialog.fetchOne(db, key: 10)?.folderId == 7)
    }
  }

  @Test("folder deletion applies authoritative dialogs before removing the folder")
  func deleteUpdateKeepsUngroupedDialogs() throws {
    let queue = try makeDatabase()
    try queue.write { db in
      try DialogFolder(id: 7, title: nil, order: "a").insert(db)
      try Chat(id: 10, date: Date(), type: .thread, title: "Test", spaceId: nil).insert(db)
      try makeDialog(chatID: 10, folderID: 7, order: "b").saveFull(db)

      var update = InlineProtocol.UpdateDialogFolder()
      update.deletedFolderID = 7
      update.dialogs = [makeDialog(chatID: 10, folderID: nil, order: "b")]
      try update.apply(db)

      #expect(try DialogFolder.fetchOne(db, key: 7) == nil)
      let dialog = try Dialog.fetchOne(db, key: 10)
      #expect(dialog?.folderId == nil)
      #expect(dialog?.open == true)
      #expect(dialog?.order == "b")
    }
  }

  @Test("root order allocation includes folder positions")
  func rootOrderUsesSharedCoordinate() throws {
    let queue = try makeDatabase()
    try queue.write { db in
      try DialogFolder(id: 7, title: nil, order: "z").insert(db)
      let order = try Dialog.nextSidebarOrder(db)
      #expect(order > "z")
    }
  }

  private func makeDialog(
    chatID: Int64,
    folderID: Int64?,
    order: String
  ) -> InlineProtocol.Dialog {
    var dialog = InlineProtocol.Dialog()
    dialog.peer = .with { $0.chat.chatID = chatID }
    dialog.open = true
    dialog.order = order
    if let folderID { dialog.folderID = folderID }
    return dialog
  }

  private func makeChat(id: Int64) -> InlineProtocol.Chat {
    var chat = InlineProtocol.Chat()
    chat.id = id
    chat.title = "Test"
    chat.date = 100
    chat.peerID = .with { $0.chat.chatID = id }
    chat.seq = 1
    return chat
  }
}
