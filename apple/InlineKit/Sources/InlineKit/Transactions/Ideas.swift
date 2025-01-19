//protocol Transaction: Codable, Sendable, Identifiable {
//  associatedtype R: Sendable
//  
//  var id: String { get }
//  var config: TransactionConfig { get }
//  
//  func execute() async throws -> R
//}
//
//struct TransactionConfig: Codable, Sendable {
//  /// How long to keep retrying this transaction
//  let retryDuration: TimeInterval?
//  
//  /// Delay between retries
//  let retryDelay: TimeInterval
//  
//  /// Whether to persist this transaction
//  let shouldPersist: Bool
//  
//  /// Retry only on specific error types
//  let retryableErrors: Set<TransactionError>
//  
//  static let transient = TransactionConfig(
//    retryDuration: nil,
//    retryDelay: 0,
//    shouldPersist: false,
//    retryableErrors: []
//  )
//  
//  static let message = TransactionConfig(
//    retryDuration: 1800, // 30 minutes
//    retryDelay: 5,
//    shouldPersist: true,
//    retryableErrors: [.flood, .internal]
//  )
//  
//  static let persistent = TransactionConfig(
//    retryDuration: .infinity,
//    retryDelay: 30,
//    shouldPersist: true,
//    retryableErrors: [.flood, .internal]
//  )
//}
//
//enum TransactionError: String, Codable {
//  case flood
//  case `internal`
//  case conflict
//  // Add other error types
//}


//struct TransactionSendMessage: Transaction {
//  let id = UUID().uuidString
//  let text: String?
//  let peerId: Peer
//  let chatId: Int64
//  let timestamp: Date
//  
//  var config: TransactionConfig {
//    .message
//  }
//  
//  func optimistic() {
//    MessageCache.shared.add(
//      Message(
//        id: id,
//        text: text,
//        status: .sending,
//        timestamp: timestamp
//      )
//    )
//  }
//  
//  func execute() async throws {
//    let response = try await API.sendMessage(
//      text: text,
//      peerId: peerId,
//      chatId: chatId
//    )
//    
//    guard response.ok else {
//      throw TransactionError(response.error)
//    }
//  }
//  
//  func didSucceed(result: Void) {
//    MessageCache.shared.update(id: id) { message in
//      message.status = .sent
//    }
//  }
//  
//  func didFail() async {
//    MessageCache.shared.update(id: id) { message in
//      message.status = .failed
//    }
//  }
//  
//  func rollback() async {
//    MessageCache.shared.remove(id: id)
//  }
//}
