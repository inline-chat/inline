import Auth
import Foundation
import InlineProtocol
import RealtimeV2

/// The one Delete flow for sent messages, single or bulk, on both platforms: the same
/// confirmation copy, a server-first delete, and the same failure notice. Each platform
/// presents `confirmation(count:)` in its own alert.
public enum MessageDeletion {
  public struct Confirmation: Equatable, Sendable {
    public let title: String
    public let message: String
    public let confirmTitle: String
    public let cancelTitle: String
  }

  public static func confirmation(count: Int) -> Confirmation {
    let single = count <= 1
    return Confirmation(
      title: single ? "Delete this message?" : "Delete \(count) messages?",
      message: single
        ? "This message will be deleted for everyone in this chat. This cannot be undone."
        : "These messages will be deleted for everyone in this chat. This cannot be undone.",
      confirmTitle: "Delete for Everyone",
      cancelTitle: "Cancel"
    )
  }

  /// Deletes sent messages on the server and removes them locally only once it acknowledges:
  /// the response carries the delete update. A rejected or failed delete leaves the rows where
  /// they were, so there is nothing to roll back. Throws the transaction's error.
  public static func delete(
    messageIds: [Int64],
    peerId: Peer,
    chatId: Int64,
    expectedAccount: AuthAccountMutationToken? = nil,
    realtime: RealtimeV2 = Api.realtime
  ) async throws {
    guard !messageIds.isEmpty else { return }
    try await realtime.send(
      DeleteMessageTransaction(messageIds: messageIds, peerId: peerId, chatId: chatId, deferLocalDeletion: true),
      expectedAccount: expectedAccount
    )
  }

  /// What to tell the person when `delete` throws.
  public static func failureMessage(for error: any Error, count: Int = 1, isGridTranscript: Bool = false) -> String {
    if case let .rpcError(rpc) = error as? TransactionError2, rpc.errorCode == .spaceAdminRequired {
      if isGridTranscript {
        return "Only the person who started transcription or a space admin can delete this message."
      }
      return count <= 1
        ? "Only the author or a space admin can delete this message."
        : "Only the authors or a space admin can delete these messages."
    }
    if case .commitOutcomeUnknownAfterReconnect = error as? TransactionError2 {
      return "Could not confirm the deletion. Check again once you're back online."
    }
    return count <= 1
      ? "Could not delete the message. Please try again."
      : "Could not delete the messages. Please try again."
  }
}
