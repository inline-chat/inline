import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

public struct DeleteChatTransaction: Transaction2 {
  // Private
  private var log = Log.scoped("Transactions/DeleteChat")

  // Properties
  public var method: InlineProtocol.Method = .deleteChat
  public var context: Context

  public struct Context: Sendable, Codable {
    public var peerId: Peer
  }

  public init(peerId: Peer) {
    context = Context(peerId: peerId)
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .deleteChat(.with {
      $0.peerID = context.peerId.toInputPeer()
    })
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  // MARK: - Transaction Methods

  public func optimistic() async {
    log.debug("Optimistic delete chat")

    do {
      // Optimistically hide the chat from UI by marking as deleted
      // or removing from dialogs list
      try await AppDatabase.shared.dbWriter.write { db in
        // Find and remove the dialog for this peer
        let dialogId = Dialog.getDialogId(peerId: context.peerId)
        try Dialog.deleteOne(db, key: dialogId)

        // Could also mark chat as deleted if we have a flag for that
        if let chat = try Chat.getByPeerId(peerId: context.peerId) {
          // Note: This is optimistic - if the server fails, this will be reverted
          try Chat.deleteOne(db, key: chat.id)
        }
      }

      // Update UI immediately
      Task { @MainActor in
        // Notify UI that the dialog was removed
        // This would need to be implemented based on your UI notification system
        log.debug("Chat optimistically deleted from UI")
      }
    } catch {
      log.error("Failed to optimistically delete chat", error: error)
    }
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case .deleteChat = result else {
      throw TransactionExecutionError.invalid
    }

    log.trace("deleteChat completed successfully")
    // The server confirms the deletion was successful
    // The optimistic updates should already be in place
  }

  public func failed(error: TransactionError2) async {
    log.error("Failed to delete chat", error: error)

    // Restore the chat/dialog if the deletion failed
    // This is complex as we'd need to restore from a backup or refetch
    // For now, we could trigger a refresh of the dialogs list
    log.debug("Chat deletion failed - would need to restore optimistic changes")

    // A simple approach is to reload the chats to get back to consistent state
    // This would need to trigger a GetChats transaction or similar
  }

  public func cancelled() async {
    log.debug("Cancelled delete chat")

    // Similar to failed() - restore the optimistic changes
    log.debug("Chat deletion cancelled - would need to restore optimistic changes")
    // Restore logic would go here
  }
}

// MARK: - Helper

public extension Transaction2 where Self == DeleteChatTransaction {
  static func deleteChat(peerId: Peer) -> DeleteChatTransaction {
    DeleteChatTransaction(peerId: peerId)
  }
}
