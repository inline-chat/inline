import Foundation
import InlineProtocol
import Testing

@testable import InlineKit

@Suite("Chat permissions")
struct ChatPermissionsTests {
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
