import Foundation
import GRDB
import InlineProtocol

/// Text and semantic entities carried on the pasteboard between Inline composers.
public struct ComposeTextPayload: Equatable, Sendable {
  public let text: String
  public let entities: MessageEntities

  private struct Wire: Codable {
    let text: String
    let entities: Data
  }

  public init(text: String, entities: MessageEntities) {
    self.text = text
    self.entities = entities
  }

  public init?(data: Data) {
    guard let wire = try? JSONDecoder().decode(Wire.self, from: data),
          let entities = try? MessageEntities(serializedBytes: wire.entities)
    else { return nil }
    self.init(text: wire.text, entities: entities)
  }

  public func encoded() -> Data? {
    guard let entities = try? entities.serializedData() else { return nil }
    return try? JSONEncoder().encode(Wire(text: text, entities: entities))
  }
}

public extension AppDatabase {
  /// A pasted mention only keeps its identity when this account already knows the target.
  func containsMentionTarget(_ entity: MessageEntity) -> Bool {
    (try? reader.read { db in
      switch entity.type {
      case .mention: try User.exists(db, id: entity.mention.userID)
      case .groupMention: try UserGroup.exists(db, id: entity.groupMention.groupID)
      default: true
      }
    }) == true
  }
}
