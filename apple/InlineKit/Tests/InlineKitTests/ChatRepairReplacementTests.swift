import Foundation
import GRDB
import InlineProtocol
import RealtimeV2
import Testing

@testable import InlineKit

@Suite("Chat bucket repair")
struct ChatRepairReplacementTests {
  @Test("overlays authoritative chat state without deleting cached history")
  func replacesStaleChatBucket() async throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    let appDatabase = try AppDatabase(queue)
    let engine = UpdatesEngine(database: appDatabase)

    try await queue.write { db in
      try User(
        id: 1,
        email: "repair@example.com",
        firstName: "Repair",
        lastName: nil,
        username: "repair"
      ).insert(db)
      try Chat(
        id: 7,
        date: Date(timeIntervalSince1970: 10),
        type: .thread,
        title: "Stale",
        spaceId: nil,
        lastMsgId: 10,
        participantRosterComplete: true
      ).insert(db)
      try ChatParticipant(
        chatId: 7,
        userId: 1,
        date: Date(timeIntervalSince1970: 10)
      ).insert(db)
      var stale = Message(
        messageId: 10,
        fromId: 1,
        date: Date(timeIntervalSince1970: 10),
        text: "stale",
        peerUserId: nil,
        peerThreadId: 7,
        chatId: 7
      )
      try stale.saveMessage(db)
      var localDialogProto = InlineProtocol.Dialog()
      localDialogProto.peer = chatPeer(7)
      localDialogProto.chatID = 7
      var localDialog = Dialog(from: localDialogProto)
      localDialog.open = true
      localDialog.order = "local-order"
      localDialog.pinnedOrder = "local-pin"
      localDialog.collapsedMaxId = 4
      try localDialog.save(db)
      _ = try GRDBSyncStorage.advanceBucketState(
        for: .chat(peer: chatPeer(7)),
        state: BucketState(date: 10, seq: 1),
        in: db
      )
    }

    let target = BucketState(date: 20, seq: 5)
    let committed = await engine.applyChatRepair(ChatRepairSnapshot(
      peer: chatPeer(7),
      chat: repairedChatResult(),
      participants: repairedParticipantsResult(),
      history: InlineProtocol.GetChatHistoryResult(),
      targetState: target,
      reason: "test"
    ))

    #expect(committed?.seq == target.seq)
    #expect(committed?.date == target.date)
    try await queue.read { db in
      #expect(try Chat.fetchOne(db, id: 7)?.title == "Repaired")
      #expect(try Message.filter(Message.Columns.chatId == 7).fetchCount(db) == 1)
      #expect(try Chat.fetchOne(db, id: 7)?.participantRosterComplete == true)
      #expect(try ChatParticipant.fetchAll(db).map(\.userId) == [2])
      let dialog = try #require(try Dialog.fetchOne(db, id: Dialog.getDialogId(peerId: .thread(id: 7))))
      #expect(dialog.open)
      #expect(dialog.order == "local-order")
      #expect(dialog.pinnedOrder == "local-pin")
      #expect(dialog.collapsedMaxId == 4)
      let state = try #require(try DbBucketState.fetchOne(db))
      #expect(state.seq == 5)
      #expect(state.date == 20)
    }

    try await queue.write { db in
      var newer = Message(
        messageId: 11,
        fromId: 1,
        date: Date(timeIntervalSince1970: 21),
        text: "newer",
        peerUserId: nil,
        peerThreadId: 7,
        chatId: 7
      )
      try newer.saveMessage(db)
    }
    _ = await engine.applyChatRepair(ChatRepairSnapshot(
      peer: chatPeer(7),
      chat: repairedChatResult(),
      participants: repairedParticipantsResult(),
      history: InlineProtocol.GetChatHistoryResult(),
      targetState: target,
      reason: "stale-repeat"
    ))
    try await queue.read { db in
      let preserved = try Message
        .filter(Message.Columns.chatId == 7 && Message.Columns.messageId == 11)
        .fetchOne(db)
      #expect(preserved != nil)
    }
  }

  private func chatPeer(_ chatID: Int64) -> InlineProtocol.Peer {
    .with { $0.chat.chatID = chatID }
  }

  private func repairedChatResult() -> InlineProtocol.GetChatResult {
    let peer = chatPeer(7)
    var chat = InlineProtocol.Chat()
    chat.id = 7
    chat.title = "Repaired"
    chat.peerID = peer
    chat.seq = 5

    var dialog = InlineProtocol.Dialog()
    dialog.chatID = 7
    dialog.peer = peer

    var result = InlineProtocol.GetChatResult()
    result.chat = chat
    result.dialog = dialog
    return result
  }

  private func repairedParticipantsResult() -> InlineProtocol.GetChatParticipantsResult {
    var user = InlineProtocol.User()
    user.id = 2
    user.firstName = "Current"
    var participant = InlineProtocol.ChatParticipant()
    participant.userID = 2
    participant.date = 20
    var result = InlineProtocol.GetChatParticipantsResult()
    result.users = [user]
    result.participants = [participant]
    return result
  }
}

@Suite("Space bucket repair")
struct SpaceRepairReplacementTests {
  @Test("replaces stale member rows and advances the cursor atomically")
  func replacesStaleMemberRoster() async throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    let appDatabase = try AppDatabase(queue)
    let engine = UpdatesEngine(database: appDatabase)

    try await queue.write { db in
      try User(id: 1, email: "stale@example.com", firstName: "Stale").insert(db)
      try Space(
        id: 7,
        name: "Stale Space",
        date: Date(timeIntervalSince1970: 10),
        seq: 1,
        memberRosterComplete: true
      ).insert(db)
      try Member(
        id: 101,
        date: Date(timeIntervalSince1970: 10),
        userId: 1,
        spaceId: 7
      ).insert(db)
      _ = try GRDBSyncStorage.advanceBucketState(
        for: .space(id: 7),
        state: BucketState(date: 10, seq: 1),
        in: db
      )
    }

    var space = InlineProtocol.Space()
    space.id = 7
    space.name = "Repaired Space"
    space.date = 20
    space.seq = 5
    var membership = InlineProtocol.Member()
    membership.id = 202
    membership.spaceID = 7
    membership.userID = 2
    membership.date = 20
    var snapshot = InlineProtocol.GetSpaceResult()
    snapshot.space = space
    snapshot.membership = membership

    var currentUser = InlineProtocol.User()
    currentUser.id = 2
    currentUser.firstName = "Current"
    var members = InlineProtocol.GetSpaceMembersResult()
    members.users = [currentUser]
    members.members = [membership]

    let committed = await engine.applySpaceRepair(SpaceRepairSnapshot(
      spaceID: 7,
      snapshot: snapshot,
      members: members,
      targetState: BucketState(date: 20, seq: 5),
      reason: "test"
    ))

    #expect(committed?.date == 20)
    #expect(committed?.seq == 5)
    try await queue.read { db in
      #expect(try Space.fetchOne(db, id: 7)?.name == "Repaired Space")
      #expect(try Space.fetchOne(db, id: 7)?.memberRosterComplete == true)
      #expect(try Member.fetchAll(db).map(\.userId) == [2])
      let state = try #require(try DbBucketState.fetchOne(db))
      #expect(state.seq == 5)
      #expect(state.date == 20)
    }
  }
}
