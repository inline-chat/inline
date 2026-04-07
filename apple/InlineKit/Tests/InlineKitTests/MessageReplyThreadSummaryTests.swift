import Foundation
import InlineProtocol
import Testing

@testable import InlineKit

@Suite("Message Reply Thread Summary")
struct MessageReplyThreadSummaryTests {
  @Test("protocol replies are persisted in content payload and exposed via helpers")
  func protocolRepliesPersistedAndReadable() {
    var proto = InlineProtocol.Message()
    proto.id = 101
    proto.chatID = 44
    proto.fromID = 9
    proto.date = 1
    proto.out = false
    proto.peerID = .with {
      $0.chat.chatID = 44
    }
    proto.message = "hello"
    proto.replies = .with {
      $0.chatID = 77
      $0.replyCount = 3
      $0.hasUnread_p = true
      $0.recentReplierUserIds = [2, 3]
    }

    let msg = Message(from: proto)

    #expect(msg.contentPayload?.hasReplies == true)
    #expect(msg.replyThreadSummary?.chatID == 77)
    #expect(msg.replyThreadSummary?.replyCount == 3)
    #expect(msg.replyThreadSummary?.hasUnread_p == true)
    #expect(msg.replyThreadRecentReplierUserIds == [2, 3])
    #expect(msg.replyThreadPeer == .thread(id: 77))
    #expect(msg.hasReplyThreadSummary == true)
  }

  @Test("setVoiceContent preserves replies in payload")
  func setVoiceContentPreservesReplies() {
    var msg = Message(
      messageId: 12,
      fromId: 4,
      date: Date(timeIntervalSince1970: 1),
      text: "x",
      peerUserId: 4,
      peerThreadId: nil,
      chatId: 88,
      contentPayload: .with {
        $0.replies = .with {
          $0.chatID = 99
          $0.replyCount = 1
        }
      }
    )

    msg.setVoiceContent(nil)

    #expect(msg.contentPayload?.hasReplies == true)
    #expect(msg.replyThreadRecentReplierUserIds.isEmpty)
    #expect(msg.replyThreadPeer == .thread(id: 99))
    #expect(msg.hasReplyThreadSummary == true)
  }

  @Test("summary is hidden when replyCount is zero")
  func summaryHiddenWhenReplyCountIsZero() {
    var proto = InlineProtocol.Message()
    proto.id = 102
    proto.chatID = 44
    proto.fromID = 9
    proto.date = 1
    proto.out = false
    proto.peerID = .with {
      $0.chat.chatID = 44
    }
    proto.message = "hello"
    proto.replies = .with {
      $0.chatID = 88
      $0.replyCount = 0
      $0.hasUnread_p = false
    }

    let msg = Message(from: proto)

    #expect(msg.replyThreadSummary != nil)
    #expect(msg.hasReplyThreadSummary == false)
    #expect(msg.replyThreadPeer == .thread(id: 88))
  }
}
