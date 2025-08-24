import Foundation

public struct TransactionId: Sendable, Hashable, Codable {
  let id: UUID

  public func toString() -> String {
    id.uuidString
  }

  static func generate() -> TransactionId {
    TransactionId(id: UUID())
  }

  static func fromString(string: String) -> TransactionId {
    TransactionId(id: UUID(uuidString: string)!)
  }
}
