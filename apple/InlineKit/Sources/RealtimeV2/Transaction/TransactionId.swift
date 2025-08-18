import Foundation

struct TransactionId: Hashable {
  let id: UUID

  func toString() -> String {
    id.uuidString
  }

  static func generate() -> TransactionId {
    TransactionId(id: UUID())
  }

  static func fromString(string: String) -> TransactionId {
    TransactionId(id: UUID(uuidString: string)!)
  }
}
