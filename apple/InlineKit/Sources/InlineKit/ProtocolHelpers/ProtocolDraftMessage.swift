import Auth
import GRDB
import InlineProtocol
import Logger

// MARK: - Codable

extension InlineProtocol.DraftMessage: Codable {
  private enum CodingKeys: String, CodingKey {
    case text
    case entities
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let text = try container.decode(String.self, forKey: .text)
    let entities = try container.decodeIfPresent(MessageEntities.self, forKey: .entities)

    self.init()
    self.text = text
    if let entities {
      self.entities = entities
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(text, forKey: .text)
    if hasEntities {
      try container.encode(entities, forKey: .entities)
    }
  }
}

// MARK: - DatabaseValueConvertible

extension InlineProtocol.DraftMessage: DatabaseValueConvertible {
  public var databaseValue: DatabaseValue {
    do {
      let data = try serializedData()
      return data.databaseValue
    } catch {
      Log.shared.error("Failed to serialize DraftMessage to database", error: error)
      return DatabaseValue.null
    }
  }

  public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> DraftMessage? {
    guard let data = Data.fromDatabaseValue(dbValue) else {
      return nil
    }

    do {
      return try DraftMessage(serializedBytes: data)
    } catch {
      Log.shared.error("Failed to deserialize DraftMessage from database", error: error)
      return nil
    }
  }
}
