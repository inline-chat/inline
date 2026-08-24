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
      $0.emoji = "🚀"
    }]
    result.dialogs = [makeDialog(chatID: 10, folderID: 7, order: "b")]

    try queue.write { db in
      let imported = try GetChatsTransaction.applySnapshot(result, in: db)

      #expect(imported.failures.isEmpty)
      #expect(try DialogFolder.fetchOne(db, key: 7)?.title == "Favorites")
      #expect(try DialogFolder.fetchOne(db, key: 7)?.emoji == "🚀")
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

  @Test("folder emoji updates use the existing mutation lane")
  func emojiUpdateInput() {
    let transaction = UpdateDialogFolderTransaction(folderId: 7, emoji: .set("🚀"))

    guard case let .updateDialogFolder(input)? = transaction.input(from: transaction.context) else {
      Issue.record("Expected an updateDialogFolder input")
      return
    }
    #expect(input.folderID == 7)
    #expect(input.emoji == "🚀")
    #expect(input.titleUpdate == nil)
  }

  @Test("folder updates queued before emoji support still decode")
  func legacyUpdateContextDecodes() throws {
    let legacy = LegacyDialogFolderUpdateContext(
      folderId: 7,
      title: .set("Favorites"),
      order: nil
    )
    let decoded = try JSONDecoder().decode(
      UpdateDialogFolderTransaction.Context.self,
      from: JSONEncoder().encode(legacy)
    )

    #expect(decoded.emoji == nil)
    let transaction = UpdateDialogFolderTransaction(folderId: 7)
    guard case let .updateDialogFolder(input)? = transaction.input(from: decoded) else {
      Issue.record("Expected a legacy updateDialogFolder input")
      return
    }
    #expect(input.title == "Favorites")
    #expect(input.emojiUpdate == nil)
  }

  @Test("new threads created from an empty folder wait before joining it")
  func newFolderThreadWaitsForCreation() {
    let transaction = UpdateDialogOrderTransaction(
      peerId: .thread(id: 44),
      pinned: false,
      destination: .folder(7),
      requiresChatCreated: true
    )

    #expect(transaction.blockers == [.chatCreated(chatId: 44)])
    guard case let .updateDialogOrder(input)? = transaction.input(from: transaction.context) else {
      Issue.record("Expected an updateDialogOrder input")
      return
    }
    #expect(input.peerID.chat.chatID == 44)
    #expect(input.destination.folderID == 7)
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

private struct LegacyDialogFolderUpdateContext: Codable {
  let folderId: Int64
  let title: UpdateDialogFolderTransaction.TitleUpdate
  let order: String?
}
