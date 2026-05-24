import Foundation
import GRDB
import InlineProtocol
import Testing

@testable import InlineKit

@Suite("Dialog chat list visibility")
struct DialogChatListVisibilityTests {
  private func makeInMemoryDB() throws -> DatabaseQueue {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    _ = try AppDatabase(queue)
    return queue
  }

  @Test("home chat query excludes hidden dialogs and keeps visible dialogs")
  func homeChatQueryFiltersHiddenDialogs() throws {
    let dbQueue = try makeInMemoryDB()

    try dbQueue.write { db in
      try seedDialog(db, chatId: 1, chatListHidden: nil)
      try seedDialog(db, chatId: 2, chatListHidden: false)
      try seedDialog(db, chatId: 3, chatListHidden: true)

      let chatIds = try HomeChatItem
        .all()
        .fetchAll(db)
        .compactMap(\.chat?.id)
        .sorted()

      #expect(chatIds == [1, 2])
    }
  }

  @Test("sidebar inbox hides hidden open dialogs but keeps pinned dialogs")
  func sidebarInboxFiltersHiddenOpenDialogsAndKeepsPinned() throws {
    let dbQueue = try makeInMemoryDB()

    try dbQueue.write { db in
      try seedDialog(db, chatId: 11, chatListHidden: nil, open: true)
      try seedDialog(db, chatId: 12, chatListHidden: true, open: true)
      try seedDialog(db, chatId: 13, chatListHidden: true, pinned: true)

      let chatIds = try HomeChatItem
        .sidebarInbox(spaceId: nil)
        .fetchAll(db)
        .compactMap(\.chat?.id)
        .sorted()

      #expect(chatIds == [11, 13])
    }
  }

  @Test("dialog open transaction close wins over stale open result")
  func updateDialogOpenCloseOverridesStaleOpenResult() throws {
    let dbQueue = try makeInMemoryDB()

    try dbQueue.write { db in
      try seedDialog(db, chatId: 14, chatListHidden: nil, open: true)

      var stale = InlineProtocol.Dialog()
      stale.peer = makeChatPeer(chatId: 14)
      stale.chatID = 14
      stale.open = true
      stale.openedDate = 1_700_000_000
      stale.order = "m"

      _ = try stale.saveFull(db)
      try UpdateDialogOpenTransaction.applyLocalOpenState(
        peerId: .thread(id: 14),
        open: false,
        db: db
      )

      let saved = try #require(try Dialog.get(peerId: .thread(id: 14)).fetchOne(db))
      #expect(saved.open == false)
      #expect(saved.openedDate == nil)
      #expect(saved.order == nil)
    }
  }

  @Test("dialog open transaction assigns local sidebar order")
  func updateDialogOpenAssignsLocalOrder() throws {
    let dbQueue = try makeInMemoryDB()

    try dbQueue.write { db in
      try seedDialog(db, chatId: 15, chatListHidden: true, open: false)

      try UpdateDialogOpenTransaction.applyLocalOpenState(
        peerId: .thread(id: 15),
        open: true,
        order: "m",
        db: db
      )

      let saved = try #require(try Dialog.get(peerId: .thread(id: 15)).fetchOne(db))
      #expect(saved.open == true)
      #expect(saved.order == "m")
      #expect(saved.archived == false)
      #expect(saved.chatListHidden == nil)
    }
  }

  @Test("protocol dialog omission preserves local open state")
  func protocolDialogOmissionPreservesLocalOpenState() throws {
    let dbQueue = try makeInMemoryDB()

    try dbQueue.write { db in
      try seedDialog(db, chatId: 17, chatListHidden: nil, open: true)
      try db.execute(
        sql: """
        UPDATE dialog
        SET "order" = ?
        WHERE id = ?
        """,
        arguments: ["m", Dialog.getDialogId(peerId: .thread(id: 17))]
      )

      var dialog = InlineProtocol.Dialog()
      dialog.peer = makeChatPeer(chatId: 17)
      dialog.chatID = 17

      _ = try dialog.saveFull(db)

      let saved = try #require(try Dialog.get(peerId: .thread(id: 17)).fetchOne(db))
      #expect(saved.open == true)
      #expect(saved.order == "m")
    }
  }

  @Test("protocol close clears stale sidebar order")
  func protocolCloseClearsStaleSidebarOrder() throws {
    let dbQueue = try makeInMemoryDB()

    try dbQueue.write { db in
      try seedDialog(db, chatId: 16, chatListHidden: nil, open: true)
      try db.execute(
        sql: """
        UPDATE dialog
        SET "order" = ?, "openedDate" = ?
        WHERE id = ?
        """,
        arguments: ["m", Date(timeIntervalSince1970: 1_700_000_000), Dialog.getDialogId(peerId: .thread(id: 16))]
      )

      var closed = InlineProtocol.Dialog()
      closed.peer = makeChatPeer(chatId: 16)
      closed.chatID = 16
      closed.open = false

      _ = try closed.saveFull(db)

      let saved = try #require(try Dialog.get(peerId: .thread(id: 16)).fetchOne(db))
      #expect(saved.open == false)
      #expect(saved.openedDate == nil)
      #expect(saved.order == nil)
    }
  }

  @Test("space sidebar inbox includes pinned member user dialogs")
  func spaceSidebarInboxIncludesPinnedMemberUserDialogs() throws {
    let dbQueue = try makeInMemoryDB()

    try dbQueue.write { db in
      try Space(id: 41, name: "Design", date: Date(timeIntervalSince1970: 1), creator: true)
        .insert(db)
      try User(id: 42, email: "member@example.com", firstName: "Member")
        .insert(db)
      try Member(
        id: 43,
        date: Date(timeIntervalSince1970: 1),
        userId: 42,
        spaceId: 41,
        role: .member
      )
      .insert(db)
      try seedUserDialog(db, userId: 42, pinned: true, archived: true)

      let userIds = try HomeChatItem
        .sidebarInbox(spaceId: 41)
        .fetchAll(db)
        .compactMap(\.user?.user.id)

      #expect(userIds == [42])
    }
  }

  @Test("protocol dialog omission clears stale hidden state")
  func protocolDialogOmissionClearsHiddenState() throws {
    let dbQueue = try makeInMemoryDB()

    try dbQueue.write { db in
      try seedDialog(db, chatId: 21, chatListHidden: true)

      var dialog = InlineProtocol.Dialog()
      dialog.peer = makeChatPeer(chatId: 21)
      dialog.chatID = 21

      _ = try dialog.saveFull(db)

      let saved = try #require(try Dialog.get(peerId: .thread(id: 21)).fetchOne(db))
      #expect(saved.chatListHidden == nil)
    }
  }

  @Test("legacy sidebar visible true heals stale hidden state")
  func legacySidebarVisibleTrueHealsHiddenState() throws {
    let dbQueue = try makeInMemoryDB()

    try dbQueue.write { db in
      try seedDialog(db, chatId: 31, chatListHidden: true)

      var dialog = InlineProtocol.Dialog()
      dialog.peer = makeChatPeer(chatId: 31)
      dialog.chatID = 31
      dialog.sidebarVisible = true

      _ = try dialog.saveFull(db)

      let saved = try #require(try Dialog.get(peerId: .thread(id: 31)).fetchOne(db))
      #expect(saved.chatListHidden == nil)
    }
  }

  @Test("legacy sidebar visible false hides dialog")
  func legacySidebarVisibleFalseHidesDialog() throws {
    let dbQueue = try makeInMemoryDB()

    try dbQueue.write { db in
      try seedDialog(db, chatId: 32, chatListHidden: nil)

      var dialog = InlineProtocol.Dialog()
      dialog.peer = makeChatPeer(chatId: 32)
      dialog.chatID = 32
      dialog.sidebarVisible = false

      _ = try dialog.saveFull(db)

      let saved = try #require(try Dialog.get(peerId: .thread(id: 32)).fetchOne(db))
      #expect(saved.chatListHidden == true)
    }
  }

  @Test("new chat list hidden field wins over legacy sidebar visible")
  func chatListHiddenWinsOverLegacySidebarVisible() throws {
    let dbQueue = try makeInMemoryDB()

    try dbQueue.write { db in
      try seedDialog(db, chatId: 33, chatListHidden: nil)

      var dialog = InlineProtocol.Dialog()
      dialog.peer = makeChatPeer(chatId: 33)
      dialog.chatID = 33
      dialog.sidebarVisible = false
      dialog.chatListHidden = false

      _ = try dialog.saveFull(db)

      let saved = try #require(try Dialog.get(peerId: .thread(id: 33)).fetchOne(db))
      #expect(saved.chatListHidden == false)
    }
  }

  private func seedDialog(
    _ db: Database,
    chatId: Int64,
    chatListHidden: Bool?,
    pinned: Bool = false,
    open: Bool = false
  ) throws {
    try Chat(
      id: chatId,
      date: Date(timeIntervalSince1970: TimeInterval(chatId)),
      type: .thread,
      title: "Thread \(chatId)",
      spaceId: nil
    ).insert(db)

    try Dialog(
      id: Dialog.getDialogId(peerId: .thread(id: chatId)),
      peerUserId: nil,
      peerThreadId: chatId,
      spaceId: nil,
      unreadCount: 0,
      readInboxMaxId: nil,
      readOutboxMaxId: nil,
      pinned: pinned,
      draftMessage: nil,
      archived: false,
      chatId: chatId,
      unreadMark: false,
      notificationSettings: nil,
      open: open,
      openedDate: open ? Date(timeIntervalSince1970: TimeInterval(chatId)) : nil,
      chatListHidden: chatListHidden
    ).insert(db)
  }

  private func seedUserDialog(
    _ db: Database,
    userId: Int64,
    pinned: Bool = false,
    open: Bool = false,
    archived: Bool = false
  ) throws {
    try Dialog(
      id: Dialog.getDialogId(peerId: .user(id: userId)),
      peerUserId: userId,
      peerThreadId: nil,
      spaceId: nil,
      unreadCount: 0,
      readInboxMaxId: nil,
      readOutboxMaxId: nil,
      pinned: pinned,
      draftMessage: nil,
      archived: archived,
      chatId: nil,
      unreadMark: false,
      notificationSettings: nil,
      open: open,
      openedDate: open ? Date(timeIntervalSince1970: TimeInterval(userId)) : nil,
      chatListHidden: nil
    ).insert(db)
  }

  private func makeChatPeer(chatId: Int64) -> InlineProtocol.Peer {
    var peer = InlineProtocol.Peer()
    var chat = InlineProtocol.PeerChat()
    chat.chatID = chatId
    peer.chat = chat
    return peer
  }
}
