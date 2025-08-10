import Foundation

struct TransactionWrapper: Codable {
  let id: UUID

  init(type: String, data: [String: Any]) {
    id = UUID()
  }
}
