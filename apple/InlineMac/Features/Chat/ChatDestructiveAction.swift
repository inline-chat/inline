import Auth
import GRDB
import InlineKit
import Logger

enum ChatDestructiveAction: Equatable {
  case delete
  case leave

  var title: String {
    switch self {
    case .delete:
      "Delete Chat"
    case .leave:
      "Leave Chat"
    }
  }

  var shortTitle: String {
    switch self {
    case .delete:
      "Delete"
    case .leave:
      "Leave"
    }
  }

  var systemImage: String {
    switch self {
    case .delete:
      "trash"
    case .leave:
      "rectangle.portrait.and.arrow.right"
    }
  }

  var loadingTitle: String {
    switch self {
    case .delete:
      "Deleting chat..."
    case .leave:
      "Leaving chat..."
    }
  }

  var successTitle: String {
    switch self {
    case .delete:
      "Chat deleted"
    case .leave:
      "Left chat"
    }
  }

  var failureTitle: String {
    switch self {
    case .delete:
      "Failed to delete chat"
    case .leave:
      "Failed to leave chat"
    }
  }

  func confirmationMessage(chatTitle: String) -> String {
    switch self {
    case .delete:
      "Delete \"\(chatTitle)\"? This removes it from your chat list."
    case .leave:
      "Leave \"\(chatTitle)\"? This removes it from your chat list."
    }
  }
}

enum ChatDestructiveActionResolver {
  static func action(
    peer: Peer,
    chat: Chat?,
    currentUserId: Int64? = Auth.shared.getCurrentUserId()
  ) -> ChatDestructiveAction? {
    guard peer.isThread, let chat, chat.type == .thread else { return nil }

    guard let currentUserId else {
      return nil
    }

    if chat.createdBy == nil || chat.createdBy == currentUserId {
      return .delete
    }

    guard canLeave(chat) else {
      return nil
    }

    return .leave
  }

  private static func canLeave(_ chat: Chat) -> Bool {
    chat.spaceId != nil && chat.isPublic == false
  }
}

enum ChatDestructiveActionRunner {
  private static let log = Log.scoped("ChatDestructiveAction")

  @MainActor
  static func perform(
    _ action: ChatDestructiveAction,
    peer: Peer,
    dependencies: AppDependencies?,
    navigateOut: @escaping @MainActor () -> Void
  ) {
    let currentUserId = dependencies?.auth.getCurrentUserId() ?? Auth.shared.getCurrentUserId()
    ToastCenter.shared.showLoading(action.loadingTitle)

    Task(priority: .userInitiated) {
      do {
        try await send(action, peer: peer, currentUserId: currentUserId)
        try await deleteLocalChat(peer: peer)

        await MainActor.run {
          ToastCenter.shared.dismiss()
          navigateOut()
          ToastCenter.shared.showSuccess(action.successTitle)
        }
      } catch {
        log.error(action.failureTitle, error: error)

        await MainActor.run {
          ToastCenter.shared.dismiss()
          ToastCenter.shared.showError(action.failureTitle)
        }
      }
    }
  }

  private static func send(
    _ action: ChatDestructiveAction,
    peer: Peer,
    currentUserId: Int64?
  ) async throws {
    switch action {
    case .delete:
      _ = try await Api.realtime.send(.deleteChat(peerId: peer))

    case .leave:
      guard let chatId = peer.asThreadId(), let currentUserId else {
        throw ChatDestructiveActionError.missingCurrentUser
      }

      _ = try await Api.realtime.send(.removeChatParticipant(chatID: chatId, userID: currentUserId))
    }
  }

  private static func deleteLocalChat(peer: Peer) async throws {
    if let chat = try Chat.getByPeerId(peerId: peer) {
      try await chat.deleteFromLocalDatabase()
      return
    }

    guard let chatId = peer.asThreadId() else { return }

    try await AppDatabase.shared.dbWriter.write { db in
      try Message.filter(Column("chatId") == chatId).deleteAll(db)
      try Dialog.filter(Column("peerThreadId") == chatId).deleteAll(db)
      try Chat.filter(Column("id") == chatId).deleteAll(db)
    }
  }
}

private enum ChatDestructiveActionError: Error {
  case missingCurrentUser
}
