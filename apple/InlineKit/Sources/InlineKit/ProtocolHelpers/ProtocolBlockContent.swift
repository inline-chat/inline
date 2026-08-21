import Foundation
import GRDB
import InlineProtocol
import Logger

/// One durable protobuf payload plus its decoded value. Live protocol messages
/// create this at the transport/model boundary; GRDB recreates it once when a
/// persisted message is materialized. Rendering never decodes or serializes it.
public struct BlockContentPayload: Codable, Hashable, Sendable {
  public let content: InlineProtocol.BlockContent
  public let cacheSignature: Int
  public var byteCount: Int { payload.count }

  private let payload: Data

  public init?(_ content: InlineProtocol.BlockContent) {
    do {
      let payload = try content.serializedData()
      self.init(content: content, payload: payload)
    } catch {
      Log.shared.error("Failed to serialize BlockContent at protocol boundary", error: error)
      return nil
    }
  }

  private init(content: InlineProtocol.BlockContent, payload: Data) {
    self.content = content
    self.payload = payload
    cacheSignature = payload.hashValue
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let payload = try container.decode(Data.self)
    content = try InlineProtocol.BlockContent(serializedBytes: payload)
    self.payload = payload
    cacheSignature = payload.hashValue
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(payload)
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.payload == rhs.payload
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(cacheSignature)
    hasher.combine(payload.count)
  }
}

extension BlockContentPayload: DatabaseValueConvertible {
  public var databaseValue: DatabaseValue {
    payload.databaseValue
  }

  public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> BlockContentPayload? {
    guard let payload = Data.fromDatabaseValue(dbValue) else { return nil }
    do {
      let content = try InlineProtocol.BlockContent(serializedBytes: payload)
      return BlockContentPayload(content: content, payload: payload)
    } catch {
      Log.shared.error("Failed to decode persisted BlockContent", error: error)
      return nil
    }
  }
}
