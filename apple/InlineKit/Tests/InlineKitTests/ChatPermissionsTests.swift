import Foundation
import InlineProtocol
import Testing

@testable import InlineKit

@Suite("Chat permissions")
struct ChatPermissionsTests {
  @Test("chat visibility follows creator and space-admin authorization")
  func chatVisibilityAuthorization() {
    let creatorId: Int64 = 7
    let spaceId: Int64 = 11
    let thread = Chat(
      date: Date(),
      type: .thread,
      title: "Thread",
      spaceId: spaceId,
      createdBy: creatorId
    )

    #expect(ChatVisibilityPolicy.canChange(
      chat: thread,
      currentUserId: creatorId,
      membership: Member(
        date: Date(),
        userId: creatorId,
        spaceId: spaceId,
        role: .member
      )
    ))

    for role in [MemberRole.owner, .admin] {
      #expect(ChatVisibilityPolicy.canChange(
        chat: thread,
        currentUserId: 8,
        membership: Member(
          date: Date(),
          userId: 8,
          spaceId: spaceId,
          role: role
        )
      ))
    }

    #expect(!ChatVisibilityPolicy.canChange(
      chat: thread,
      currentUserId: 8,
      membership: Member(
        date: Date(),
        userId: 8,
        spaceId: spaceId,
        role: .member
      )
    ))
  }

  @Test("chat visibility rejects mismatched or ineligible contexts")
  func chatVisibilityRejectsIneligibleContexts() {
    let userId: Int64 = 7
    let spaceId: Int64 = 11
    let member = Member(
      date: Date(),
      userId: userId,
      spaceId: spaceId,
      role: .owner
    )
    let thread = Chat(
      date: Date(),
      type: .thread,
      title: "Thread",
      spaceId: spaceId,
      createdBy: userId
    )

    #expect(!ChatVisibilityPolicy.canChange(chat: thread, currentUserId: userId, membership: nil))
    #expect(!ChatVisibilityPolicy.canChange(chat: thread, currentUserId: nil, membership: member))
    #expect(!ChatVisibilityPolicy.canChange(
      chat: thread,
      currentUserId: userId + 1,
      membership: member
    ))
    #expect(!ChatVisibilityPolicy.canChange(
      chat: thread,
      currentUserId: userId,
      membership: Member(
        date: Date(),
        userId: userId,
        spaceId: spaceId + 1,
        role: .owner
      )
    ))
    #expect(!ChatVisibilityPolicy.canChange(
      chat: Chat(date: Date(), type: .privateChat, title: nil, spaceId: nil),
      currentUserId: userId,
      membership: member
    ))
  }

  @Test("protocol chat preserves permission presence")
  func protocolChatPermissionPresence() {
    var permissions = InlineProtocol.ChatPermissions()
    permissions.canUpdateInfo = true

    var protocolChat = InlineProtocol.Chat()
    protocolChat.id = 1
    protocolChat.peerID = .with { $0.chat.chatID = 1 }
    protocolChat.permissions = permissions

    #expect(Chat(from: protocolChat).canUpdateInfo == true)

    protocolChat.clearPermissions()
    #expect(Chat(from: protocolChat).canUpdateInfo == nil)
  }

  @Test("permission update changes the persisted chat capability")
  func permissionUpdateChangesPersistedChat() async throws {
    let database = AppDatabase.empty()

    try await database.dbWriter.write { db in
      let chat = Chat(
        id: 1,
        date: Date(),
        type: .thread,
        title: "Thread",
        spaceId: nil,
        canUpdateInfo: false
      )
      try chat.insert(db)

      var permissions = InlineProtocol.ChatPermissions()
      permissions.canUpdateInfo = true
      var update = InlineProtocol.UpdateChatPermissions()
      update.chatID = chat.id
      update.permissions = permissions
      try update.apply(db)

      #expect(try Chat.fetchOne(db, id: chat.id)?.canUpdateInfo == true)
    }
  }
}
