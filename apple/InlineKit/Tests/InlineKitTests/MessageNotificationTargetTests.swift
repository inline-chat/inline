import Foundation
import Testing
@preconcurrency import UserNotifications
@testable import InlineKit

@Suite("Message notification identity and foreground presentation")
struct MessageNotificationTargetTests {
  @Test func recipientAccountBoundaryAndLegacyCompatibility() {
    #expect(MessageNotificationAccount.matchesRecipient(userInfo: ["recipientUserId": "42"], currentUserID: 42))
    #expect(MessageNotificationAccount.matchesRecipient(userInfo: ["recipientUserId": NSNumber(value: 42)], currentUserID: 42))
    #expect(!MessageNotificationAccount.matchesRecipient(userInfo: ["recipientUserId": "42"], currentUserID: 43))
    #expect(!MessageNotificationAccount.matchesRecipient(userInfo: ["recipientUserId": "42"], currentUserID: nil))
    #expect(!MessageNotificationAccount.matchesRecipient(userInfo: ["recipientUserId": true], currentUserID: 1))
    #expect(!MessageNotificationAccount.matchesRecipient(userInfo: ["recipientUserId": "invalid"], currentUserID: 42))
    #expect(MessageNotificationAccount.matchesRecipient(userInfo: [:], currentUserID: 42))
    #expect(!MessageNotificationAccount.matchesRecipient(userInfo: [:], currentUserID: nil))
  }

  @Test func directAndReplyThreadTargets() {
    let direct = MessageNotificationTarget(userInfo: ["userId": 42, "threadId": "chat_9", "messageId": "123"])
    #expect(direct?.peer == .user(id: 42))
    #expect(direct?.chatID == 9)
    #expect(direct?.messageID == 123)
    let reply = MessageNotificationTarget(userInfo: [
      "userId": 42, "isThread": NSNumber(value: true), "isReplyThread": true,
      "threadId": Int64(19), "messageId": NSNumber(value: 456),
    ])
    #expect(reply?.peer == .thread(id: 19))
    #expect(reply?.messageID == 456)
    let stringFlag = MessageNotificationTarget(userInfo: ["isThread": "true", "threadId": "chat_19"])
    #expect(stringFlag?.peer == .thread(id: 19))
    let replyWithParent = MessageNotificationTarget(userInfo: ["isThread": true, "threadId": "chat_19", "chatId": "9"])
    #expect(replyWithParent?.peer == .thread(id: 19))
  }

  @Test func encryptedFallbackDoesNotInventPeer() {
    let target = MessageNotificationTarget(userInfo: ["kind": "send_message_encrypted", "messageId": "9"], threadIdentifier: "chat_20")
    #expect(target?.chatID == 20)
    #expect(target?.peer == nil)
    #expect(target?.messageID == 9)
  }

  @Test func invalidIDsAndNonMessageEvents() {
    for invalid: Any in [true, NSNumber(value: 1.5), -1, 0, "9223372036854775808", "chat_chat_2"] {
      #expect(MessageNotificationTarget(userInfo: ["isThread": true, "threadId": invalid]) == nil)
      let target = MessageNotificationTarget(userInfo: ["userId": "2", "messageId": invalid])
      #expect(target?.messageID == nil)
    }
    #expect(MessageNotificationTarget(userInfo: ["type": "gridScreenShare", "userId": 2]) == nil)
    #expect(MessageNotificationTarget(userInfo: ["kind": "messages_read", "threadId": "chat_2"]) == nil)
  }

  @Test func foregroundMatrix() {
    let content = UNMutableNotificationContent()
    content.userInfo = ["userId": 2, "messageId": "3"]
    #expect(MessageNotificationPresentation.foregroundOptions(for: content, isViewingConversation: false) == [.banner, .list])
    content.sound = .default
    #expect(MessageNotificationPresentation.foregroundOptions(for: content, isViewingConversation: false) == [.banner, .list, .sound])
    #expect(MessageNotificationPresentation.foregroundOptions(for: content, isViewingConversation: true).isEmpty)
    content.interruptionLevel = .timeSensitive
    #expect(MessageNotificationPresentation.foregroundOptions(for: content, isViewingConversation: true) == [.banner, .list, .sound])
    content.interruptionLevel = .active
    content.userInfo = ["kind": "messages_read", "threadId": "chat_2"]
    #expect(MessageNotificationPresentation.foregroundOptions(for: content, isViewingConversation: false).isEmpty)
  }
}
