import Foundation
import InlineProtocol
import RealtimeV2

public enum LocalThreadCommandError: LocalizedError, Sendable {
  case invalidCreateResponse

  public var errorDescription: String? {
    switch self {
      case .invalidCreateResponse:
        "Couldn’t create thread."
    }
  }
}

public struct LocalThreadCommandResult: Equatable, Sendable {
  public let peer: Peer
  public let didOpenInSidebar: Bool

  public init(peer: Peer, didOpenInSidebar: Bool) {
    self.peer = peer
    self.didOpenInSidebar = didOpenInSidebar
  }
}

/// Executes the platform-neutral `/thread` mutation sequence. Navigation and
/// user-facing warnings remain owned by the invoking Compose surface.
public enum LocalThreadCommandService {
  public typealias Sender = @Sendable (any Transaction2) async throws -> RpcResult.OneOf_Result?

  public static func createAndOpen(
    parentChatId: Int64,
    send: Sender
  ) async throws -> LocalThreadCommandResult {
    let result = try await send(CreateSubthreadTransaction(
      parentChatId: parentChatId,
      parentMessageId: nil
    ))
    guard case let .createSubthread(response) = result, response.hasChat else {
      throw LocalThreadCommandError.invalidCreateResponse
    }

    let peer = Peer.thread(id: response.chat.id)
    let sidebarTransactions: [any Transaction2] = [
      UpdateDialogFollowModeTransaction(peerId: peer, selection: .following),
      ShowInChatListTransaction(peerId: peer),
      UpdateDialogOpenTransaction(peerId: peer, open: true),
    ]

    var didOpenInSidebar = true
    for transaction in sidebarTransactions {
      do {
        _ = try await send(transaction)
      } catch {
        didOpenInSidebar = false
      }
    }

    return LocalThreadCommandResult(
      peer: peer,
      didOpenInSidebar: didOpenInSidebar
    )
  }
}
