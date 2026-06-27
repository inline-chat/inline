import Foundation
import InlineProtocol
import Testing

@testable import InlineKit

@Suite("Message Service Persistence")
struct MessageServicePersistenceTests {
  @Test("protocol service payload is persisted and exposed via helpers")
  func protocolServicePayloadPersistedAndReadable() {
    var proto = InlineProtocol.Message()
    proto.id = 101
    proto.chatID = 44
    proto.fromID = 9
    proto.date = 1
    proto.out = false
    proto.peerID = .with {
      $0.chat.chatID = 44
    }
    proto.message = "Pinned a message"
    proto.serviceMessage = .with {
      $0.pinnedMessage = .with {
        $0.messageID = 55
      }
    }

    let msg = Message(from: proto)

    #expect(msg.contentPayload?.hasServiceMessage == true)
    #expect(msg.isServiceMessage == true)
    #expect(msg.servicePinnedMessageId == 55)
    #expect(msg.serviceFallbackText == "Pinned a message")
    #expect(msg.stringRepresentationPlain == "Pinned a message")
  }

  @Test("actor-aware service text uses sender and outgoing state")
  func actorAwareServiceText() {
    let sender = User(id: 9, email: "sender@example.com", firstName: "Ada")
    let incoming = Message(
      messageId: 1,
      fromId: 9,
      date: Date(timeIntervalSince1970: 1),
      text: "Linked from Source",
      peerUserId: nil,
      peerThreadId: 44,
      chatId: 44,
      out: false,
      contentPayload: .with {
        $0.serviceMessage = .with {
          $0.threadBacklink = .with {
            $0.sourceChatID = 44
            $0.sourceTitle = "Source"
          }
        }
      }
    )
    let outgoing = Message(
      messageId: 2,
      fromId: 9,
      date: Date(timeIntervalSince1970: 2),
      text: "Pinned a message",
      peerUserId: nil,
      peerThreadId: 44,
      chatId: 44,
      out: true,
      contentPayload: .with {
        $0.serviceMessage = .with {
          $0.pinnedMessage = .with {
            $0.messageID = 1
          }
        }
      }
    )

    let fullIncoming = FullMessage(
      senderInfo: UserInfo(user: sender),
      message: incoming,
      reactions: [],
      repliedToMessage: nil,
      attachments: []
    )
    let fullOutgoing = FullMessage(
      senderInfo: UserInfo(user: sender),
      message: outgoing,
      reactions: [],
      repliedToMessage: nil,
      attachments: []
    )

    #expect(fullIncoming.serviceDisplayText == "Ada linked from [[Source]]")
    #expect(fullIncoming.message.serviceFallbackText == "Linked from Source")
    #expect(fullOutgoing.serviceDisplayText == "You pinned a message")
    #expect(fullIncoming.serviceDisplaySegments == [
      MessageServiceDisplaySegment(text: "Ada", link: .user(9)),
      MessageServiceDisplaySegment(text: " linked from "),
      MessageServiceDisplaySegment(text: "[[", link: .thread(44), tone: .tertiary),
      MessageServiceDisplaySegment(text: "Source", link: .thread(44)),
      MessageServiceDisplaySegment(text: "]]", link: .thread(44), tone: .tertiary),
    ])
    #expect(fullOutgoing.serviceDisplaySegments == [
      MessageServiceDisplaySegment(text: "You", link: .user(9)),
      MessageServiceDisplaySegment(text: " pinned a message"),
    ])
    #expect(fullIncoming.canReply == false)
    #expect(fullOutgoing.canReply == false)
  }

  @Test("setVoiceContent preserves service payload")
  func setVoiceContentPreservesServicePayload() {
    var msg = Message(
      messageId: 12,
      fromId: 4,
      date: Date(timeIntervalSince1970: 1),
      text: "Pinned a message",
      peerUserId: nil,
      peerThreadId: 88,
      chatId: 88,
      contentPayload: .with {
        $0.serviceMessage = .with {
          $0.pinnedMessage = .with {
            $0.messageID = 99
          }
        }
      }
    )

    msg.setVoiceContent(nil)

    #expect(msg.contentPayload?.hasServiceMessage == true)
    #expect(msg.servicePinnedMessageId == 99)
    #expect(msg.isServiceMessage == true)
  }

  @Test("backlink source fields survive content payload persistence")
  func backlinkSourceFieldsSurvivePayloadPersistence() throws {
    let payload = Client_MessageContentPayload.with {
      $0.serviceMessage = .with {
        $0.threadBacklink = .with {
          $0.sourceChatID = 44
          $0.sourceTitle = "Source"
        }
      }
    }

    let data = try JSONEncoder().encode(payload)
    let decoded = try JSONDecoder().decode(Client_MessageContentPayload.self, from: data)
    let backlink = decoded.serviceMessage.threadBacklink

    #expect(decoded.hasServiceMessage == true)
    #expect(backlink.hasSourceChatID == true)
    #expect(backlink.sourceChatID == 44)
    #expect(backlink.sourceTitle == "Source")
  }

  @Test("content payload JSON keeps actions and replies with service messages")
  func contentPayloadJSONKeepsActionsAndRepliesWithServiceMessages() throws {
    let payload = Client_MessageContentPayload.with {
      $0.actions = .with {
        $0.rows = [
          .with {
            $0.actions = [
              .with {
                $0.actionID = "copy"
                $0.text = "Copy"
                $0.copyText = .with {
                  $0.text = "hello"
                }
              },
            ]
          },
        ]
      }
      $0.replies = .with {
        $0.chatID = 77
        $0.replyCount = 2
        $0.hasUnread_p = true
        $0.recentReplierUserIds = [3, 2]
      }
      $0.serviceMessage = .with {
        $0.pinnedMessage = .with {
          $0.messageID = 99
        }
      }
    }

    let data = try JSONEncoder().encode(payload)
    let decoded = try JSONDecoder().decode(Client_MessageContentPayload.self, from: data)

    #expect(decoded.hasActions == true)
    #expect(decoded.actions.rows.first?.actions.first?.actionID == "copy")
    #expect(decoded.hasReplies == true)
    #expect(decoded.replies.chatID == 77)
    #expect(decoded.replies.replyCount == 2)
    #expect(decoded.replies.hasUnread_p == true)
    #expect(decoded.replies.recentReplierUserIds == [3, 2])
    #expect(decoded.hasServiceMessage == true)
    #expect(decoded.serviceMessage.pinnedMessage.messageID == 99)
  }

  @Test("unknown persisted service payload falls back to message text")
  func unknownPersistedServicePayloadFallsBackToMessageText() throws {
    let data = #"{"serviceMessage":{"event":"futureEvent"}}"#.data(using: .utf8)!
    let payload = try JSONDecoder().decode(Client_MessageContentPayload.self, from: data)
    let msg = Message(
      messageId: 20,
      fromId: 4,
      date: Date(timeIntervalSince1970: 1),
      text: "Server fallback text",
      peerUserId: nil,
      peerThreadId: 88,
      chatId: 88,
      contentPayload: payload
    )

    #expect(msg.contentPayload?.hasServiceMessage == true)
    #expect(msg.isServiceMessage == false)
    #expect(msg.serviceFallbackText == nil)
    #expect(msg.stringRepresentationPlain == "Server fallback text")
  }
}
