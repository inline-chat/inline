import Auth
import Foundation
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
    case pre
    case thread
    case threadTitle
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    if let mention = try container.decodeIfPresent(MessageEntity.MessageEntityMention.self, forKey: .mention) {
      self = .mention(mention)
    } else if let textURL = try container.decodeIfPresent(MessageEntity.MessageEntityTextUrl.self, forKey: .textURL) {
      self = .textURL(textURL)
    } else if let pre = try container.decodeIfPresent(MessageEntity.MessageEntityPre.self, forKey: .pre) {
      self = .pre(pre)
    } else if let thread = try container.decodeIfPresent(MessageEntity.MessageEntityThread.self, forKey: .thread) {
      self = .thread(thread)
    } else if let threadTitle = try container.decodeIfPresent(MessageEntity.MessageEntityThreadTitle.self, forKey: .threadTitle) {
      self = .threadTitle(threadTitle)
    } else {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(
          codingPath: container.codingPath,
          debugDescription: "Invalid entity type - missing supported entity payload"
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
      case let .pre(pre):
        try container.encode(pre, forKey: .pre)
      case let .thread(thread):
        try container.encode(thread, forKey: .thread)
      case let .threadTitle(threadTitle):
        try container.encode(threadTitle, forKey: .threadTitle)
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

extension InlineProtocol.MessageEntity.MessageEntityPre: Codable {
  private enum CodingKeys: String, CodingKey {
    case language
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let language = try container.decode(String.self, forKey: .language)

    self.init()
    self.language = language
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(language, forKey: .language)
  }
}

extension InlineProtocol.MessageEntity.MessageEntityThread: Codable {
  private enum CodingKeys: String, CodingKey {
    case chatID
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let chatID = try container.decode(Int64.self, forKey: .chatID)

    self.init()
    self.chatID = chatID
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(chatID, forKey: .chatID)
  }
}

extension InlineProtocol.MessageEntity.MessageEntityThreadTitle: Codable {
  private enum CodingKeys: String, CodingKey {
    case spaceID
    case title
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let spaceID = try container.decode(Int64.self, forKey: .spaceID)
    let title = try container.decode(String.self, forKey: .title)

    self.init()
    self.spaceID = spaceID
    self.title = title
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(spaceID, forKey: .spaceID)
    try container.encode(title, forKey: .title)
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
