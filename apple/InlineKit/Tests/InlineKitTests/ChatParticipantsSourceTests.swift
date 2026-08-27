import Foundation
import GRDB
import Testing

@testable import InlineKit

@Suite("Chat participant inheritance source")
struct ChatParticipantsSourceTests {
  @Test("participant and mention projections use the top parent")
  func inheritedSource() async throws {
    let database = AppDatabase.empty()
    try await database.dbWriter.write { db in
      try Chat(
        id: 10,
        date: Date(timeIntervalSince1970: 1),
        type: .thread,
        title: "Parent",
        spaceId: nil
      ).insert(db)
      try Chat(
        id: 11,
        date: Date(timeIntervalSince1970: 2),
        type: .thread,
        title: nil,
        spaceId: nil,
        parentChatId: 10
      ).insert(db)
      try Chat(
        id: 12,
        date: Date(timeIntervalSince1970: 3),
        type: .thread,
        title: nil,
        spaceId: nil,
        parentChatId: 11
      ).insert(db)

      let participantSource = try ChatParticipantsWithMembersViewModel.participantsSourceChat(
        db,
        chatId: 12,
        purpose: .participantsList
      )
      let mentionSource = try ChatParticipantsWithMembersViewModel.participantsSourceChat(
        db,
        chatId: 12,
        purpose: .mentionCandidates
      )

      #expect(participantSource?.id == 10)
      #expect(mentionSource?.id == 10)
    }
  }

  @Test("effective access includes target and root grants but excludes intermediate grants")
  func effectiveAccess() async throws {
    let database = AppDatabase.empty()
    try await database.dbWriter.write { db in
      let date = Date(timeIntervalSince1970: 1)
      try Space(id: 1, name: "Space", date: date).insert(db)
      try Space(id: 2, name: "Other Space", date: date).insert(db)
      for userId in 20 ... 26 {
        try User(id: Int64(userId), email: nil, firstName: "User \(userId)").insert(db)
      }

      try Chat(id: 10, date: date, type: .thread, title: "Parent", spaceId: 1).insert(db)
      try Chat(id: 11, date: date, type: .thread, title: nil, spaceId: 1, parentChatId: 10).insert(db)
      try Chat(id: 12, date: date, type: .thread, title: nil, spaceId: 1, parentChatId: 11).insert(db)

      try ChatParticipant(chatId: 10, userId: 20, date: date).insert(db)
      try ChatParticipant(chatId: 11, userId: 22, date: date).insert(db)
      try ChatParticipant(chatId: 12, userId: 24, date: date).insert(db)

      try UserGroup(
        id: 30,
        spaceId: 1,
        name: "Parent Group",
        description: nil,
        memberCount: 1,
        currentUserIsMember: false,
        date: date
      ).insert(db)
      try UserGroup(
        id: 31,
        spaceId: 1,
        name: "Intermediate Group",
        description: nil,
        memberCount: 1,
        currentUserIsMember: false,
        date: date
      ).insert(db)
      try UserGroup(
        id: 32,
        spaceId: 1,
        name: "Target Group",
        description: nil,
        memberCount: 1,
        currentUserIsMember: false,
        date: date
      ).insert(db)
      try UserGroupMember(groupId: 30, userId: 21).insert(db)
      try UserGroupMember(groupId: 30, userId: 26).insert(db)
      try UserGroupMember(groupId: 31, userId: 23).insert(db)
      try UserGroupMember(groupId: 32, userId: 25).insert(db)
      try Member(id: 121, date: date, userId: 21, spaceId: 1).insert(db)
      try Member(id: 123, date: date, userId: 23, spaceId: 1).insert(db)
      try Member(id: 125, date: date, userId: 25, spaceId: 1).insert(db)
      try Member(id: 126, date: date, userId: 26, spaceId: 2).insert(db)
      try ChatParticipantGroup(chatId: 10, groupId: 30, date: date).insert(db)
      try ChatParticipantGroup(chatId: 11, groupId: 31, date: date).insert(db)
      try ChatParticipantGroup(chatId: 12, groupId: 32, date: date).insert(db)

      let chat = try #require(try Chat.fetchOne(db, id: 12))
      let access = try ChatParticipantsWithMembersViewModel.effectiveParticipantAccess(db, for: chat)

      #expect(access.sourceChat.id == 10)
      #expect(access.userIds == Set<Int64>([20, 21, 24, 25]))
      #expect(access.groupIds == Set<Int64>([30, 32]))
      #expect(!access.userIds.contains(22))
      #expect(!access.userIds.contains(23))
      #expect(!access.userIds.contains(26))
      #expect(!access.groupIds.contains(31))

      // v0.1 autocomplete projects the top-level roster only. Child-direct
      // access remains valid at send time but is intentionally not suggested.
      let projectedUserIds = Set(try ChatParticipant
        .filter(ChatParticipant.Columns.chatId == access.sourceChat.id)
        .fetchAll(db)
        .map(\.userId))
      #expect(projectedUserIds == Set<Int64>([20]))
    }
  }

  @Test("DM-derived subthreads inherit the root peer")
  func dmRootPeer() async throws {
    let database = AppDatabase.empty()
    try await database.dbWriter.write { db in
      let date = Date(timeIntervalSince1970: 1)
      try User(id: 42, email: nil, firstName: "Peer").insert(db)
      try User(id: 43, email: nil, firstName: "DM Direct").insert(db)
      try Chat(id: 10, date: date, type: .privateChat, title: nil, spaceId: nil, peerUserId: 42).insert(db)
      try Chat(id: 11, date: date, type: .thread, title: nil, spaceId: nil, parentChatId: 10).insert(db)
      try ChatParticipant(chatId: 10, userId: 43, date: date).insert(db)

      let child = try #require(try Chat.fetchOne(db, id: 11))
      let access = try ChatParticipantsWithMembersViewModel.effectiveParticipantAccess(db, for: child)

      #expect(access.sourceChat.id == 10)
      #expect(access.userIds == Set<Int64>([42]))

      let root = try #require(try Chat.fetchOne(db, id: 10))
      let rootAccess = try ChatParticipantsWithMembersViewModel.effectiveParticipantAccess(db, for: root)
      #expect(rootAccess.userIds == Set<Int64>([42, 43]))
    }
  }

  @Test("public root inherits eligible members while a child still adds outsiders")
  func publicParent() async throws {
    let database = AppDatabase.empty()
    try await database.dbWriter.write { db in
      let date = Date(timeIntervalSince1970: 1)
      try Space(id: 1, name: "Space", date: date).insert(db)
      for userId in 40 ... 43 {
        try User(id: Int64(userId), email: nil, firstName: "User \(userId)").insert(db)
      }
      try Member(
        id: 140,
        date: date,
        userId: 40,
        spaceId: 1,
        canAccessPublicChats: true
      ).insert(db)
      try Member(
        id: 141,
        date: date,
        userId: 41,
        spaceId: 1,
        canAccessPublicChats: false
      ).insert(db)
      try Chat(
        id: 10,
        date: date,
        type: .thread,
        title: "Public",
        spaceId: 1,
        isPublic: true
      ).insert(db)
      try Chat(id: 11, date: date, type: .thread, title: nil, spaceId: 1, parentChatId: 10).insert(db)
      try Chat(id: 12, date: date, type: .thread, title: nil, spaceId: 1, parentChatId: 11).insert(db)
      try ChatParticipant(chatId: 10, userId: 42, date: date).insert(db)
      try ChatParticipant(chatId: 12, userId: 43, date: date).insert(db)

      let child = try #require(try Chat.fetchOne(db, id: 12))
      let access = try ChatParticipantsWithMembersViewModel.effectiveParticipantAccess(db, for: child)

      #expect(access.sourceChat.id == 10)
      #expect(access.sourceChat.isPublic == true)
      #expect(access.userIds == Set<Int64>([40, 43]))

      let root = try #require(try Chat.fetchOne(db, id: 10))
      let rootAccess = try ChatParticipantsWithMembersViewModel.effectiveParticipantAccess(db, for: root)
      #expect(rootAccess.userIds == Set<Int64>([40, 42]))

      let action = MentionedParticipantAddPolicy.action(
        for: [40, 41, 43],
        context: MentionedParticipantAddContext(
          chatType: child.type,
          isPublic: child.isPublic == true && child.parentChatId == nil,
          isReplyThread: child.isReplyThread,
          currentUserId: 99,
          messageCount: 1,
          participantIds: access.userIds
        )
      )
      #expect(action == .autoAdd([41]))

      let rootDirectAction = MentionedParticipantAddPolicy.action(
        for: [42],
        context: MentionedParticipantAddContext(
          chatType: child.type,
          isPublic: child.isPublic == true && child.parentChatId == nil,
          isReplyThread: child.isReplyThread,
          currentUserId: 99,
          messageCount: 1,
          participantIds: access.userIds
        )
      )
      #expect(rootDirectAction == .autoAdd([42]))
    }
  }

  @Test("missing parents and cycles terminate safely")
  func malformedParentChains() async throws {
    let database = AppDatabase.empty()
    try await database.dbWriter.write { db in
      let date = Date(timeIntervalSince1970: 1)
      try Chat(id: 10, date: date, type: .thread, title: nil, spaceId: nil).insert(db)
      try Chat(id: 11, date: date, type: .thread, title: nil, spaceId: nil, parentChatId: 10).insert(db)

      var first = try #require(try Chat.fetchOne(db, id: 10))
      first.parentChatId = 11
      try first.update(db)

      let cycleSource = try ChatParticipantsWithMembersViewModel.participantsSourceChat(
        db,
        chatId: 10,
        purpose: .mentionCandidates
      )
      #expect(cycleSource?.id == 11)

      let orphan = Chat(
        id: 12,
        date: date,
        type: .thread,
        title: nil,
        spaceId: nil,
        parentChatId: 999
      )
      let missingAccess = try ChatParticipantsWithMembersViewModel.effectiveParticipantAccess(db, for: orphan)
      #expect(missingAccess.sourceChat.id == 12)
    }
  }
}
