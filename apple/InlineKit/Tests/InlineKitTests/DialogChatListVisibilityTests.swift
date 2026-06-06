import Foundation
import GRDB
import InlineProtocol
import RealtimeV2
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

  @Test("sidebar inbox hides hidden open and pinned dialogs")
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

      #expect(chatIds == [11])
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
      #expect(saved.chatListHidden == true)
    }
  }

  @Test("new thread open can wait for local chat creation")
  func updateDialogOpenCanWaitForLocalChatCreation() {
    let transaction = UpdateDialogOpenTransaction(
      peerId: .thread(id: 44),
      open: true,
      requiresChatCreated: true
    )
    let defaultTransaction = UpdateDialogOpenTransaction(
      peerId: .thread(id: 45),
      open: true
    )
    let userTransaction = UpdateDialogOpenTransaction(
      peerId: .user(id: 46),
      open: true,
      requiresChatCreated: true
    )

    #expect(transaction.blockers == [.chatCreated(chatId: 44)])
    #expect(defaultTransaction.blockers.isEmpty)
    #expect(userTransaction.blockers.isEmpty)
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

  @Test("new chat update preserves local open state")
  func newChatUpdatePreservesLocalOpenState() throws {
    let dbQueue = try makeInMemoryDB()

    try dbQueue.write { db in
      try seedDialog(db, chatId: 18, chatListHidden: nil, open: true)
      try db.execute(
        sql: """
        UPDATE dialog
        SET "order" = ?
        WHERE id = ?
        """,
        arguments: ["m", Dialog.getDialogId(peerId: .thread(id: 18))]
      )

      var chat = InlineProtocol.Chat()
      chat.id = 18
      chat.title = "Thread 18"
      chat.peerID = makeChatPeer(chatId: 18)
      chat.date = 1_700_000_000

      var update = InlineProtocol.UpdateNewChat()
      update.chat = chat
      try update.apply(db)

      let saved = try #require(try Dialog.get(peerId: .thread(id: 18)).fetchOne(db))
      #expect(saved.open == true)
      #expect(saved.order == "m")
      #expect(saved.chatListHidden == nil)
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

  @Test("private chat save creates placeholder user when user is missing")
  func privateChatSaveCreatesMissingPeerUserPlaceholder() throws {
    let dbQueue = try makeInMemoryDB()

    try dbQueue.write { db in
      var chat = Chat(
        id: 50,
        date: Date(timeIntervalSince1970: 50),
        type: .privateChat,
        title: nil,
        spaceId: nil,
        peerUserId: 42
      )

      try chat.saveWithValidLastMsg(db)

      let user = try #require(try User.fetchOne(db, id: 42))
      let savedChat = try #require(try Chat.getByPeerId(db: db, peerId: .user(id: 42)))

      #expect(user.needsDisplayNameFetch)
      #expect(savedChat.id == 50)
      #expect(savedChat.peerUserId == 42)
    }
  }

  @Test("placeholder user requires display name refresh")
  func placeholderUserRequiresDisplayNameRefresh() {
    let placeholder = UserInfo.placeholder(id: 42).user
    let named = User(id: 43, email: nil, firstName: "Riley", lastName: "Stone", username: nil)

    #expect(placeholder.needsDisplayNameFetch)
    #expect(placeholder.displayName == "User")
    #expect(named.needsDisplayNameFetch == false)
    #expect(named.displayName == "Riley Stone")
  }

  @Test("protocol dialog omission preserves hidden state")
  func protocolDialogOmissionPreservesHiddenState() throws {
    let dbQueue = try makeInMemoryDB()

    try dbQueue.write { db in
      try seedDialog(db, chatId: 21, chatListHidden: true)

      var dialog = InlineProtocol.Dialog()
      dialog.peer = makeChatPeer(chatId: 21)
      dialog.chatID = 21

      _ = try dialog.saveFull(db)

      let saved = try #require(try Dialog.get(peerId: .thread(id: 21)).fetchOne(db))
      #expect(saved.chatListHidden == true)
    }
  }

  @Test("protocol dialog omission preserves follow mode")
  func protocolDialogOmissionPreservesFollowMode() throws {
    let dbQueue = try makeInMemoryDB()

    try dbQueue.write { db in
      try seedDialog(db, chatId: 22, chatListHidden: true, followMode: .following)

      var dialog = InlineProtocol.Dialog()
      dialog.peer = makeChatPeer(chatId: 22)
      dialog.chatID = 22

      _ = try dialog.saveFull(db)

      let saved = try #require(try Dialog.get(peerId: .thread(id: 22)).fetchOne(db))
      #expect(saved.followMode == .following)
      #expect(saved.isFollowingReplyThread)
    }
  }

  @Test("dialog follow mode update applies and clears")
  func dialogFollowModeUpdateAppliesAndClears() throws {
    let dbQueue = try makeInMemoryDB()

    try dbQueue.write { db in
      try seedDialog(db, chatId: 23, chatListHidden: true)

      var follow = InlineProtocol.UpdateDialogFollowMode()
      follow.peerID = makeChatPeer(chatId: 23)
      follow.followMode = .following
      try follow.apply(db)

      var saved = try #require(try Dialog.get(peerId: .thread(id: 23)).fetchOne(db))
      #expect(saved.followMode == .following)

      var clear = InlineProtocol.UpdateDialogFollowMode()
      clear.peerID = makeChatPeer(chatId: 23)
      try clear.apply(db)

      saved = try #require(try Dialog.get(peerId: .thread(id: 23)).fetchOne(db))
      #expect(saved.followMode == nil)
    }
  }

  @Test("dialog follow local state opens on manual follow")
  func dialogFollowLocalStateOpensOnManualFollow() throws {
    let dbQueue = try makeInMemoryDB()

    try dbQueue.write { db in
      try seedDialog(db, chatId: 24, chatListHidden: true)

      var saved = try #require(try Dialog.get(peerId: .thread(id: 24)).fetchOne(db))
      saved.followMode = .following
      try UpdateDialogFollowModeTransaction.applyManualFollowOpenState(&saved, db: db)
      try saved.save(db)

      saved = try #require(try Dialog.get(peerId: .thread(id: 24)).fetchOne(db))
      #expect(saved.followMode == .following)
      #expect(saved.open == true)
      #expect(saved.archived == false)
      #expect(saved.chatListHidden == nil)
      #expect(saved.order != nil)

      let order = saved.order
      saved.followMode = nil
      try saved.save(db)

      saved = try #require(try Dialog.get(peerId: .thread(id: 24)).fetchOne(db))

      #expect(saved.followMode == nil)
      #expect(saved.open == true)
      #expect(saved.chatListHidden == nil)
      #expect(saved.order == order)
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
    open: Bool = false,
    followMode: InlineProtocol.DialogFollowMode? = nil
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
      chatListHidden: chatListHidden,
      followMode: followMode
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
