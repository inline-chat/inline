import GRDB
import InlineProtocol
import Logger

// MARK: - Codable

extension InlineProtocol.DialogNotificationSettings: Codable {
  private enum CodingKeys: String, CodingKey {
    case mode
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let mode = try container.decodeIfPresent(Mode.self, forKey: .mode)

    self.init()
    if let mode {
      self.mode = mode
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    if hasMode {
      try container.encode(mode, forKey: .mode)
    }
  }
}

extension InlineProtocol.DialogNotificationSettings.Mode: Codable {
  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let rawValue = try container.decode(Int.self)
    self = InlineProtocol.DialogNotificationSettings.Mode(rawValue: rawValue) ?? .UNRECOGNIZED(rawValue)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

// MARK: - DatabaseValueConvertible

extension InlineProtocol.DialogNotificationSettings: DatabaseValueConvertible {
  public var databaseValue: DatabaseValue {
    do {
      let data = try serializedData()
      return data.databaseValue
    } catch {
      Log.shared.error("Failed to serialize DialogNotificationSettings to database", error: error)
      return DatabaseValue.null
    }
  }

  public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> DialogNotificationSettings? {
    guard let data = Data.fromDatabaseValue(dbValue) else {
      return nil
    }

    do {
      return try DialogNotificationSettings(serializedBytes: data)
    } catch {
      Log.shared.error("Failed to deserialize DialogNotificationSettings from database", error: error)
      return nil
    }
  }
}
