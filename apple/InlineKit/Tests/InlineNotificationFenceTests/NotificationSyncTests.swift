import Foundation
import InlineNotificationFence
import Testing
@preconcurrency import UserNotifications

@Suite("Notification sync ops")
struct NotificationSyncTests {
  private func content(
    thread: String = "chat_7",
    payloadThread: String? = nil,
    messageID: Any? = "10",
    recipient: Any? = "42"
  ) -> UNNotificationContent {
    let content = UNMutableNotificationContent()
    content.threadIdentifier = thread
    var userInfo: [String: Any] = ["kind": "send_message_encrypted"]
    if let payloadThread { userInfo["threadId"] = payloadThread }
    if let messageID { userInfo["messageId"] = messageID }
    if let recipient { userInfo["recipientUserId"] = recipient }
    content.userInfo = userInfo
    return content
  }

  @Test("parses dedicated read and delete pushes")
  func parsesDedicatedPushes() {
    let read: [AnyHashable: Any] = ["kind": "messages_read", "threadId": "chat_7", "readUpToMessageId": "12", "recipientUserId": "42"]
    let deleted: [AnyHashable: Any] = ["kind": "message_deleted", "threadId": "chat_7", "messageIds": ["3", "x", 4]]
    #expect(NotificationSyncOps.isSyncPush(read))
    #expect(NotificationSyncOps.isSyncPush(deleted))
    #expect(!NotificationSyncOps.isSyncPush(["kind": "send_message_encrypted"]))
    #expect(NotificationSyncOps(syncPushUserInfo: read) == NotificationSyncOps(reads: [.init(threadID: "chat_7", upToMessageID: 12)]))
    #expect(NotificationSyncOps(syncPushUserInfo: deleted) == NotificationSyncOps(deletions: [.init(threadID: "chat_7", messageIDs: [3, 4])]))
    #expect(NotificationSyncOps(syncPushUserInfo: ["kind": "messages_read", "threadId": "chat_7"]) == nil)
    #expect(NotificationSyncOps(syncPushUserInfo: ["kind": "message_deleted", "threadId": "chat_7", "messageIds": []]) == nil)
  }

  @Test("parses ops carried in decrypted message content")
  func parsesEmbeddedOps() throws {
    let json = #"{"read":[{"threadId":"chat_1","upTo":"9"},{"threadId":"","upTo":"9"}],"deleted":[{"threadId":"chat_2","ids":["5","0"]}]}"#
    let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
    #expect(NotificationSyncOps(jsonObject: object) == NotificationSyncOps(
      reads: [.init(threadID: "chat_1", upToMessageID: 9)],
      deletions: [.init(threadID: "chat_2", messageIDs: [5])]
    ))
    #expect(NotificationSyncOps(jsonObject: nil) == nil)
    #expect(NotificationSyncOps(jsonObject: ["read": []]) == nil)
  }

  @Test("covers read and deleted messages of the same account only")
  func coversMatchingNotifications() {
    let ops = NotificationSyncOps(
      reads: [.init(threadID: "chat_7", upToMessageID: 10)],
      deletions: [.init(threadID: "chat_8", messageIDs: [20])]
    )
    #expect(ops.covers(content(messageID: "10"), recipientUserID: 42))
    #expect(ops.covers(content(messageID: NSNumber(value: 9)), recipientUserID: 42))
    #expect(!ops.covers(content(messageID: "11"), recipientUserID: 42))
    #expect(!ops.covers(content(messageID: nil), recipientUserID: 42))
    #expect(!ops.covers(content(messageID: "10"), recipientUserID: 43))
    #expect(ops.covers(content(messageID: "10", recipient: nil), recipientUserID: 43))
    #expect(ops.covers(content(thread: "other", payloadThread: "chat_7", messageID: "1"), recipientUserID: 42))
    #expect(ops.covers(content(thread: "chat_8", messageID: "20"), recipientUserID: 42))
    #expect(!ops.covers(content(thread: "chat_8", messageID: "19"), recipientUserID: 42))
  }

  @Test("merging keeps the highest read marker and all deleted ids")
  func mergesOps() {
    var ops = NotificationSyncOps(
      reads: [.init(threadID: "chat_1", upToMessageID: 9)],
      deletions: [.init(threadID: "chat_2", messageIDs: [1])]
    )
    ops.merge(NotificationSyncOps(
      reads: [.init(threadID: "chat_1", upToMessageID: 5), .init(threadID: "chat_3", upToMessageID: 2)],
      deletions: [.init(threadID: "chat_2", messageIDs: [2])]
    ))
    #expect(ops.reads == [.init(threadID: "chat_1", upToMessageID: 9), .init(threadID: "chat_3", upToMessageID: 2)])
    #expect(ops.deletions == [.init(threadID: "chat_2", messageIDs: [1, 2])])
  }
}
