import Foundation
import GRDB
import InlineProtocol

extension InlineProtocol.DialogFollowMode: Codable {
  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let rawValue = try container.decode(Int.self)
    self = InlineProtocol.DialogFollowMode(rawValue: rawValue) ?? .UNRECOGNIZED(rawValue)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

extension InlineProtocol.DialogFollowMode: DatabaseValueConvertible {
  public var databaseValue: DatabaseValue {
    switch self {
      case .following:
        return "following".databaseValue
      case .unspecified, .UNRECOGNIZED(_):
        return DatabaseValue.null
    }
  }

  public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> DialogFollowMode? {
    guard let value = String.fromDatabaseValue(dbValue) else {
      return nil
    }

    switch value {
      case "following":
        return .following
      default:
        return nil
    }
  }
}
