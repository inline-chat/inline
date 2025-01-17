import Foundation
import GRDB

public struct TransactionSendMessage: Transaction {
  // Properties
  var text: String? = nil
  var peerId: Peer
  var chatId: Int64
  
  // Config
  public var id = UUID().uuidString
  var config = TransactionConfig.default
  var date = Date()
  
  // State
  var randomId: Int64
  var peerUserId: Int64? = nil
  var peerThreadId: Int64? = nil
  var temporaryMessageId: Int64
  
  public init(text: String?, peerId: Peer, chatId: Int64) {
    self.text = text
    self.peerId = peerId
    self.chatId = chatId
    
    randomId = Int64.random(in: Int64.min ... Int64.max)
    peerUserId = if case .user(let id) = peerId { id } else { nil }
    peerThreadId = if case .thread(let id) = peerId { id } else { nil }
    temporaryMessageId = randomId
  }
  
  // Methods
  func optimistic() {
    let message = Message(
      messageId: temporaryMessageId,
      randomId: randomId,
      fromId: Auth.shared.getCurrentUserId()!,
      date: date,
      text: text,
      peerUserId: peerUserId,
      peerThreadId: peerThreadId,
      chatId: chatId,
      out: true,
      status: .sending
    )
    
    // When I remove this task, or make it a sync call, I get frame drops in very fast sending
    // Task { @MainActor in
    DispatchQueue.main.async {
      let newMessage = try? (AppDatabase.shared.dbWriter.write { db in
        try message.saveAndFetch(db)
      })
      
      if let message = newMessage {
        MessagesPublisher.shared.messageAdded(message: message, peer: peerId)
      }
    } //
  }
  
  func execute() async throws -> SendMessage {
    let result = try await ApiClient.shared.sendMessage(
      peerUserId: peerUserId,
      peerThreadId: peerThreadId,
      text: text,
      randomId: randomId,
      repliedToMessageId: nil,
      date: date.timeIntervalSince1970
    )
    return result
  }
  
  func didSucceed(result: SendMessage) async {
    if let updates = result.updates {
      await UpdatesManager.shared.applyBatch(updates: updates)
    } else {
      Log.shared.error("No updates in send message response")
    }
  }
  
  func didFail(error: Error?) async {
    Log.shared.error("Failed to send message", error: error)
    
    // Mark as failed
    
    let _ = try? await AppDatabase.shared.dbWriter.write { db in
      try Message
        .filter(Column("randomId") == randomId && Column("fromId") == Auth.shared.getCurrentUserId()!)
        .updateAll(
          db,
          Column("status").set(to: MessageSendingStatus.failed.rawValue)
        )
    }
  }
  
  func rollback() async {
    // Remove from database
    let _ = try? await AppDatabase.shared.dbWriter.write { db in
      try Message
        .filter(Column("randomId") == randomId)
        .filter(Column("messageId") == temporaryMessageId)
        .deleteAll(db)
    }
    
    // Remove from cache
    await MessagesPublisher.shared
      .messagesDeleted(messageIds: [temporaryMessageId], peer: peerId)
  }
}
