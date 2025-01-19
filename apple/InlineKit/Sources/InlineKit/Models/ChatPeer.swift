import Foundation
import GRDB

public enum Peer: Codable, Hashable, Sendable, Equatable {
  case user(id: Int64)
  case thread(id: Int64)

  public static func ==(lhs: Peer, rhs: Peer) -> Bool {
    switch (lhs, rhs) {
    case (.user(let lhsId), .user(let rhsId)):
      return lhsId == rhsId
    case (.thread(let lhsId), .thread(let rhsId)):
      return lhsId == rhsId
    default:
      return false
    }
  }

  private enum CodingKeys: String, CodingKey {
    case userId
    case threadId
  }

  public var id: Int64 {
    switch self {
    case .user(let id):
      return id
    case .thread(let id):
      return id
    }
  }

  public func asUserId() -> Int64? {
    switch self {
    case .user(let id):
      return id
    case .thread:
      return nil
    }
  }
  
  public func asThreadId() -> Int64? {
    switch self {
    case .user:
      return nil
    case .thread(let id):
      return id
    }
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    if let userId = try container.decodeIfPresent(Int64.self, forKey: .userId) {
      self = .user(id: userId)
    } else if let threadId = try container.decodeIfPresent(Int64.self, forKey: .threadId) {
      self = .thread(id: threadId)
    } else {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(
          codingPath: container.codingPath,
          debugDescription: "Invalid peer type - must contain either userId or threadId"
        )
      )
    }
  }

  public init(userId: Int64) {
    self = .user(id: userId)
  }

  public init(threadId: Int64) {
    self = .thread(id: threadId)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)

    switch self {
    case .user(let id):
      try container.encode(id, forKey: .userId)
    case .thread(let id):
      try container.encode(id, forKey: .threadId)
    }
  }

  public var isPrivate: Bool {
    switch self {
    case .user:
      return true
    case .thread:
      return false
    }
  }

  public var isThread: Bool {
    switch self {
    case .user:
      return false
    case .thread:
      return true
    }
  }
}
