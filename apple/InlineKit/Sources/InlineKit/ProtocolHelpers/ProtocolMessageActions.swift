import Foundation
import GRDB
import InlineProtocol
import Logger

extension InlineProtocol.MessageActions: Codable {
  private enum CodingKeys: String, CodingKey {
    case rows
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    self.init()
    rows = try container.decodeIfPresent([MessageActionRow].self, forKey: .rows) ?? []
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(rows, forKey: .rows)
  }
}

extension InlineProtocol.MessageActionRow: Codable {
  private enum CodingKeys: String, CodingKey {
    case actions
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    self.init()
    actions = try container.decodeIfPresent([MessageAction].self, forKey: .actions) ?? []
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(actions, forKey: .actions)
  }
}

extension InlineProtocol.MessageAction: Codable {
  private enum CodingKeys: String, CodingKey {
    case actionID
    case text
    case action
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    self.init()
    actionID = try container.decode(String.self, forKey: .actionID)
    text = try container.decode(String.self, forKey: .text)
    action = try container.decodeIfPresent(OneOf_Action.self, forKey: .action)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(actionID, forKey: .actionID)
    try container.encode(text, forKey: .text)
    try container.encodeIfPresent(action, forKey: .action)
  }
}

extension InlineProtocol.MessageAction.OneOf_Action: Codable {
  private enum CodingKeys: String, CodingKey {
    case callback
    case copyText
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    if let callback = try container.decodeIfPresent(MessageActionCallback.self, forKey: .callback) {
      self = .callback(callback)
    } else if let copyText = try container.decodeIfPresent(MessageActionCopyText.self, forKey: .copyText) {
      self = .copyText(copyText)
    } else {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(
          codingPath: container.codingPath,
          debugDescription: "Invalid message action payload"
        )
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)

    switch self {
    case let .callback(callback):
      try container.encode(callback, forKey: .callback)
    case let .copyText(copyText):
      try container.encode(copyText, forKey: .copyText)
    }
  }
}

extension InlineProtocol.MessageActionCallback: Codable {
  private enum CodingKeys: String, CodingKey {
    case data
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    self.init()
    data = try container.decode(Data.self, forKey: .data)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(data, forKey: .data)
  }
}

extension InlineProtocol.MessageActionCopyText: Codable {
  private enum CodingKeys: String, CodingKey {
    case text
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    self.init()
    text = try container.decode(String.self, forKey: .text)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(text, forKey: .text)
  }
}

extension InlineProtocol.MessageActions: DatabaseValueConvertible {
  public var databaseValue: DatabaseValue {
    do {
      let data = try serializedData()
      return data.databaseValue
    } catch {
      Log.shared.error("Failed to serialize MessageActions to database", error: error)
      return DatabaseValue.null
    }
  }

  public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> MessageActions? {
    guard let data = Data.fromDatabaseValue(dbValue) else {
      return nil
    }

    do {
      return try MessageActions(serializedBytes: data)
    } catch {
      Log.shared.error("Failed to deserialize MessageActions from database", error: error)
      return nil
    }
  }
}
