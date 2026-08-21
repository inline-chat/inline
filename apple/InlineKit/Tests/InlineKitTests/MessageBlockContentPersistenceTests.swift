import Foundation
import GRDB
import InlineProtocol
import Testing

@testable import InlineKit

@Suite("Message Block Content Persistence")
struct MessageBlockContentPersistenceTests {
  private func makeInMemoryDB() throws -> DatabaseQueue {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    _ = try AppDatabase(queue)
    return queue
  }

  private func seedChat(_ db: Database) throws {
    try User(id: 1, email: "author@example.com", firstName: "Author").insert(db)
    try Chat(
      id: 44,
      date: Date(timeIntervalSince1970: 1),
      type: .thread,
      title: "Blocks",
      spaceId: nil
    ).insert(db)
  }

  private func protocolMessage(
    revision: Int64?,
    text: String,
    includesBlocks: Bool,
    entities: MessageEntities? = nil
  ) -> InlineProtocol.Message {
    InlineProtocol.Message.with {
      $0.id = 7
      $0.chatID = 44
      $0.fromID = 1
      $0.date = 1
      if let revision {
        $0.rev = revision
      }
      $0.peerID = .with { $0.chat.chatID = 44 }
      $0.message = text
      if let entities {
        $0.entities = entities
      }
      if includesBlocks {
        $0.blockContent = .with {
          $0.blocks = [
            .with {
              $0.paragraph = .with {
                $0.offset = 0
                $0.length = Int64(text.utf16.count)
              }
            },
          ]
        }
      }
    }
  }

  private func textEntities(_ type: MessageEntity.TypeEnum, length: Int) -> MessageEntities {
    .with {
      $0.entities = [
        .with {
          $0.type = type
          $0.offset = 0
          $0.length = Int64(length)
        },
      ]
    }
  }

  private func editUpdate(_ message: InlineProtocol.Message) -> InlineProtocol.UpdateEditMessage {
    .with { $0.message = message }
  }

  private func translation(_ db: Database) throws -> Translation? {
    try Translation
      .filter(Translation.Columns.messageId == 7)
      .filter(Translation.Columns.chatId == 44)
      .fetchOne(db)
  }

  @Test("persists blocks, rejects a stale projection, and accepts an authoritative clear")
  func revisionGatedBlockProjection() throws {
    let queue = try makeInMemoryDB()
    try queue.write { db in
      try seedChat(db)
      let bold = textEntities(.bold, length: 6)
      let italic = textEntities(.italic, length: 5)
      let incoming = protocolMessage(
        revision: 2,
        text: "newest",
        includesBlocks: true,
        entities: bold
      )
      let boundaryMessage = Message(from: incoming)
      let boundaryPayload = try #require(boundaryMessage.blockContentPayload)
      #expect(boundaryPayload.content.blocks.count == 1)

      _ = try Message.save(
        db,
        protocolMessage: incoming
      )
      var saved = try #require(try Message.fetchOne(db, key: ["messageId": 7, "chatId": 44]))
      #expect(saved.blockContentPayload?.cacheSignature == boundaryPayload.cacheSignature)
      #expect(saved.blockContent?.blocks.count == 1)
      #expect(saved.blockContent?.blocks.first?.paragraph.length == 6)
      #expect(saved.text == "newest")
      #expect(saved.entities == bold)

      var stale = protocolMessage(
        revision: 1,
        text: "stale",
        includesBlocks: false,
        entities: italic
      )
      stale.blockContent = .with {
        $0.blocks = [
          .with {
            $0.image = .with {
              $0.ready = .with {
                $0.id = 100
                $0.date = 1
                $0.format = .jpeg
              }
            }
          },
        ]
      }
      let staleResult = try Message.saveWithResult(
        db,
        protocolMessage: stale
      )
      #expect(staleResult.disposition == .stale)
      saved = try #require(try Message.fetchOne(db, key: ["messageId": 7, "chatId": 44]))
      #expect(saved.rev == 2)
      #expect(saved.text == "newest")
      #expect(saved.entities == bold)
      #expect(saved.blockContent?.blocks.count == 1)
      #expect(try Photo.filter(Photo.Columns.photoId == 100).fetchOne(db) == nil)

      let unversionedResult = try Message.saveWithResult(
        db,
        protocolMessage: protocolMessage(
          revision: nil,
          text: "legacy stale",
          includesBlocks: false,
          entities: italic
        )
      )
      #expect(unversionedResult.disposition == .stale)
      saved = try #require(try Message.fetchOne(db, key: ["messageId": 7, "chatId": 44]))
      #expect(saved.rev == 2)
      #expect(saved.text == "newest")
      #expect(saved.entities == bold)
      #expect(saved.blockContent?.blocks.count == 1)

      let equalResult = try Message.saveWithResult(
        db,
        protocolMessage: protocolMessage(
          revision: 2,
          text: "equal",
          includesBlocks: false,
          entities: italic
        )
      )
      #expect(equalResult.disposition == .equal)
      #expect(equalResult.textOrEntitiesChanged)
      saved = try #require(try Message.fetchOne(db, key: ["messageId": 7, "chatId": 44]))
      #expect(saved.rev == 2)
      #expect(saved.text == "equal")
      #expect(saved.entities == italic)
      #expect(saved.blockContent == nil)

      let newerResult = try Message.saveWithResult(
        db,
        protocolMessage: protocolMessage(revision: 3, text: "plain", includesBlocks: false)
      )
      #expect(newerResult.disposition == .newer)
      saved = try #require(try Message.fetchOne(db, key: ["messageId": 7, "chatId": 44]))
      #expect(saved.rev == 3)
      #expect(saved.text == "plain")
      #expect(saved.entities == nil)
      #expect(saved.blockContent == nil)
      #expect(saved.blockContent == nil)
    }
  }

  @Test("unversioned snapshots remain compatible while the stored revision is zero")
  func unversionedSnapshotsRemainCompatibleAtRevisionZero() throws {
    let queue = try makeInMemoryDB()
    try queue.write { db in
      try seedChat(db)

      let inserted = try Message.saveWithResult(
        db,
        protocolMessage: protocolMessage(
          revision: nil,
          text: "legacy one",
          includesBlocks: true
        )
      )
      #expect(inserted.disposition == .inserted)

      let equal = try Message.saveWithResult(
        db,
        protocolMessage: protocolMessage(
          revision: nil,
          text: "legacy two",
          includesBlocks: false
        )
      )
      #expect(equal.disposition == .equal)
      #expect(equal.textOrEntitiesChanged)

      let saved = try #require(try Message.fetchOne(db, key: ["messageId": 7, "chatId": 44]))
      #expect(saved.rev == 0)
      #expect(saved.text == "legacy two")
      #expect(saved.blockContent == nil)
    }
  }

  @Test("edit side effects follow accepted content revisions")
  func editSideEffectsFollowAcceptedContentRevisions() throws {
    let queue = try makeInMemoryDB()
    try queue.write { db in
      try seedChat(db)
      let bold = textEntities(.bold, length: 6)

      _ = try Message.save(
        db,
        protocolMessage: protocolMessage(
          revision: 2,
          text: "newest",
          includesBlocks: true,
          entities: bold
        )
      )
      try Translation(
        messageId: 7,
        chatId: 44,
        translation: "latest",
        entities: nil,
        language: "es",
        date: Date(timeIntervalSince1970: 1),
        msgRev: 2
      ).insert(db)

      let staleAccepted = try editUpdate(
        protocolMessage(revision: 1, text: "stale", includesBlocks: false)
      ).apply(db, publishChanges: false)
      #expect(!staleAccepted)
      #expect(try translation(db)?.translation == "latest")
      #expect(try translation(db)?.msgRev == 2)

      let equalAccepted = try editUpdate(
        protocolMessage(
          revision: 2,
          text: "newest",
          includesBlocks: true,
          entities: bold
        )
      ).apply(db, publishChanges: false)
      #expect(equalAccepted)
      #expect(try translation(db)?.translation == "latest")
      #expect(try translation(db)?.msgRev == 2)

      let newerBlockOnlyAccepted = try editUpdate(
        protocolMessage(
          revision: 3,
          text: "newest",
          includesBlocks: false,
          entities: bold
        )
      ).apply(db, publishChanges: false)
      #expect(newerBlockOnlyAccepted)
      #expect(try translation(db)?.translation == "latest")
      #expect(try translation(db)?.msgRev == 3)

      let newerTextAccepted = try editUpdate(
        protocolMessage(revision: 4, text: "changed", includesBlocks: false)
      ).apply(db, publishChanges: false)
      #expect(newerTextAccepted)
      #expect(try translation(db) == nil)
    }
  }

  @Test("materializes ready photos nested inside structural blocks")
  func materializesNestedReadyPhotos() throws {
    let queue = try makeInMemoryDB()
    try queue.write { db in
      try seedChat(db)

      var message = protocolMessage(revision: 1, text: "photos", includesBlocks: false)
      message.blockContent = .with {
        $0.blocks = [
          .with {
            $0.disclosure = .with {
              $0.summary = .with { $0.length = 6 }
              $0.children = [
                .with {
                  $0.album = .with {
                    $0.images = [
                      .with {
                        $0.ready = .with {
                          $0.id = 99
                          $0.date = 1
                          $0.format = .jpeg
                          $0.sizes = [
                            .with {
                              $0.type = "f"
                              $0.w = 640
                              $0.h = 480
                              $0.size = 1_024
                              $0.cdnURL = "https://cdn.example.com/photo.jpg"
                            },
                          ]
                        }
                      },
                    ]
                  }
                },
              ]
            }
          },
        ]
      }

      _ = try Message.save(db, protocolMessage: message)

      let savedMessage = try #require(try Message.fetchOne(db, key: ["messageId": 7, "chatId": 44]))
      #expect(savedMessage.blockContent?.blocks.count == 1)
      let photo = try #require(try Photo.filter(Photo.Columns.photoId == 99).fetchOne(db))
      let localPhotoID = try #require(photo.id)
      let size = try #require(
        try PhotoSize
          .filter(PhotoSize.Columns.photoId == localPhotoID)
          .filter(PhotoSize.Columns.type == "f")
          .fetchOne(db)
      )
      #expect(size.width == 640)
      #expect(size.height == 480)
    }
  }
}
