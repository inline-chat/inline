
// private actor MessageQueue {
//  private var pendingMessages: [(ClientMessage, Task<Void, Error>)] = []
//
//  func enqueue(_ message: WebSocketMessage) async throws {
//    let task = Task { try await send(message) }
//    pendingMessages.append((message, task))
//
//    do {
//      try await task.value
//      pendingMessages.removeAll { $0.1 == task }
//    } catch {
//      // Handle failed send
//      if error is WebSocketError {
//        // Retry later when reconnected
//        throw error
//      }
//    }
//  }
//
//  func retryPendingMessages() async {
//    for (message, _) in pendingMessages {
//      try? await send(message)
//    }
//  }
// }
