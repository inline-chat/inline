import Auth
import GRDB
import InlineProtocol
import Logger

extension InlineProtocol.MessageEntities: Codable {
  private enum CodingKeys: String, CodingKey {
    case entities
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let entities = try container.decode([MessageEntity].self, forKey: .entities)

    self.init()
    self.entities = entities
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(entities, forKey: .entities)
  }
}

extension InlineProtocol.MessageEntity: Codable {
  enum CodingKeys: String, CodingKey {
    case type
    case offset
    case length
    case entity
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let type = try container.decode(TypeEnum.self, forKey: .type)
    let offset = try container.decode(Int64.self, forKey: .offset)
    let length = try container.decode(Int64.self, forKey: .length)
    let entity = try container.decodeIfPresent(OneOf_Entity.self, forKey: .entity)

    self.init()
    self.type = type
    self.offset = offset
    self.length = length
    self.entity = entity
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(type, forKey: .type)
    try container.encode(offset, forKey: .offset)
    try container.encode(length, forKey: .length)
    try container.encodeIfPresent(entity, forKey: .entity)
  }
}

extension InlineProtocol.MessageEntity.TypeEnum: Codable {
  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let rawValue = try container.decode(Int.self)
    self = InlineProtocol.MessageEntity
      .TypeEnum(rawValue: rawValue) ??
      .UNRECOGNIZED(rawValue)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

extension InlineProtocol.MessageEntity.OneOf_Entity: Codable {
  private enum CodingKeys: String, CodingKey {
    case mention
    case textURL
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    if let mention = try container.decodeIfPresent(MessageEntity.MessageEntityMention.self, forKey: .mention) {
      self = .mention(mention)
    } else if let textURL = try container.decodeIfPresent(MessageEntity.MessageEntityTextUrl.self, forKey: .textURL) {
      self = .textURL(textURL)
    } else {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(
          codingPath: container.codingPath,
          debugDescription: "Invalid entity type - must contain either mention or textURL"
        )
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)

    switch self {
      case let .mention(mention):
        try container.encode(mention, forKey: .mention)
      case let .textURL(textURL):
        try container.encode(textURL, forKey: .textURL)
    }
  }
}

extension InlineProtocol.MessageEntity.MessageEntityMention: Codable {
  private enum CodingKeys: String, CodingKey {
    case userID
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let userID = try container.decode(Int64.self, forKey: .userID)

    self.init()
    self.userID = userID
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(userID, forKey: .userID)
  }
}

extension InlineProtocol.MessageEntity.MessageEntityTextUrl: Codable {
  private enum CodingKeys: String, CodingKey {
    case url
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let url = try container.decode(String.self, forKey: .url)

    self.init()
    self.url = url
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(url, forKey: .url)
  }
}

// MARK: - DatabaseValueConvertible

extension InlineProtocol.MessageEntities: DatabaseValueConvertible {
  public var databaseValue: DatabaseValue {
    do {
      let data = try serializedData()
      return data.databaseValue
    } catch {
      Log.shared.error("Failed to serialize MessageEntities to database", error: error)
      return DatabaseValue.null
    }
  }

  public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> MessageEntities? {
    guard let data = Data.fromDatabaseValue(dbValue) else {
      return nil
    }

    do {
      return try MessageEntities(serializedBytes: data)
    } catch {
      Log.shared.error("Failed to deserialize MessageEntities from database", error: error)
      return nil
    }
  }
}
