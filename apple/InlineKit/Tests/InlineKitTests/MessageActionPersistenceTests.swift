import Foundation
import GRDB
import InlineProtocol
import Testing

@testable import InlineKit

@Suite("Message Action Persistence")
struct MessageActionPersistenceTests {
  private func makeInMemoryDB() throws -> DatabaseQueue {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration())
    _ = try AppDatabase(queue)
    return queue
  }

  @Test("protocol updates without actions clear stale actions while preserving voice payload")
  func protocolUpdatesWithoutActionsClearStaleActions() throws {
    let dbQueue = try makeInMemoryDB()
    try dbQueue.write { db in
      var stale = Message(
        messageId: 7,
        fromId: 1,
        date: Date(timeIntervalSince1970: 1),
        text: "before",
        peerUserId: 9,
        peerThreadId: nil,
        chatId: 44,
        contentPayload: .with {
          $0.voice = .with {
            $0.voiceID = 123
            $0.duration = 8
          }
          $0.actions = .with {
            $0.rows = [
              .with {
                $0.actions = [
                  .with {
                    $0.actionID = "pick"
                    $0.text = "Pick"
                    $0.callback = .with {
                      $0.data = Data([1, 2, 3])
                    }
                  },
                ]
              },
            ]
          }
        }
      )
      stale.globalId = 1
      _ = try stale.saveMessage(db)

      var proto = InlineProtocol.Message()
      proto.id = 7
      proto.chatID = 44
      proto.fromID = 1
      proto.date = 2
      proto.out = true
      proto.rev = 2
      proto.peerID = .with {
        $0.user.userID = 9
      }
      proto.message = "after"

      _ = try Message.save(db, protocolMessage: proto, publishChanges: false)

      let saved = try #require(Message.fetchOne(db, key: ["messageId": 7, "chatId": 44]))
      #expect(saved.text == "after")
      #expect(saved.actions == nil)
      #expect(saved.voiceContent?.voiceID == 123)
      #expect(saved.voiceContent?.duration == 8)
    }
  }
}
