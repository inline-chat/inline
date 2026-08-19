import RealtimeV2

extension TransactionExecutionKey {
  /// Preserves user-visible mutation order for one conversation without
  /// serializing unrelated chats or account-wide reads.
  static func chatMutation(chatID: Int64) -> TransactionExecutionKey {
    TransactionExecutionKey(namespace: "chat-mutation", value: "thread:\(chatID)")
  }

  static func peerMutation(_ peer: Peer) -> TransactionExecutionKey {
    switch peer {
      case let .user(id):
        TransactionExecutionKey(namespace: "chat-mutation", value: "user:\(id)")
      case let .thread(id):
        chatMutation(chatID: id)
    }
  }

  static func spaceMutation(spaceID: Int64) -> TransactionExecutionKey {
    TransactionExecutionKey(namespace: "space-mutation", value: String(spaceID))
  }
}
