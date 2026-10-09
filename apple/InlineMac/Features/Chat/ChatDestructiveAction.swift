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
    guard let chat else { return nil }
    return action(
      peer: peer,
      chatType: chat.type,
      chatCreatedBy: chat.createdBy,
      chatSpaceId: chat.spaceId,
      chatIsPublic: chat.isPublic,
      currentUserId: currentUserId
    )
  }

  static func action(
    peer: Peer,
    chatType: ChatType?,
    chatCreatedBy: Int64?,
    chatSpaceId: Int64?,
    chatIsPublic: Bool?,
    currentUserId: Int64? = Auth.shared.getCurrentUserId()
  ) -> ChatDestructiveAction? {
    guard peer.isThread, chatType == .thread else { return nil }

    guard let currentUserId else {
      return nil
    }

    if chatCreatedBy == nil || chatCreatedBy == currentUserId {
      return .delete
    }

    guard chatSpaceId != nil, chatIsPublic == false else {
      return nil
    }

    return .leave
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
    let auth = dependencies?.auth.handle ?? Auth.shared.handle
    let accountToken: AuthAccountMutationToken
    do {
      accountToken = try auth.beginAccountMutation()
    } catch {
      log.error(action.failureTitle, error: error)
      ToastCenter.shared.showError(action.failureTitle)
      return
    }
    let databaseWriter = (dependencies?.database ?? AppDatabase.shared).dbWriter
    let loadingID = ToastCenter.shared.showLoading(action.loadingTitle)

    Task(priority: .userInitiated) {
      do {
        try await send(action, peer: peer, accountToken: accountToken)
        if action == .leave {
          try await Chat.deleteFromLocalDatabase(
            peerId: peer,
            databaseWriter: databaseWriter,
            auth: auth,
            accountToken: accountToken
          )
        }

        try await MainActor.run {
          try auth.validateAccountMutation(accountToken)
          ToastCenter.shared.dismiss(loading: loadingID)
          if dependencies?.removeChatFromNavigation(peer: peer) != true {
            navigateOut()
          }
          ToastCenter.shared.showSuccess(action.successTitle)
        }
      } catch {
        log.error(action.failureTitle, error: error)

        await MainActor.run {
          ToastCenter.shared.dismiss(loading: loadingID)
          guard (try? auth.validateAccountMutation(accountToken)) != nil else { return }
          ToastCenter.shared.showError(action.failureTitle)
        }
      }
    }
  }

  private static func send(
    _ action: ChatDestructiveAction,
    peer: Peer,
    accountToken: AuthAccountMutationToken
  ) async throws {
    switch action {
    case .delete:
      _ = try await Api.realtime.send(.deleteChat(peerId: peer), expectedAccount: accountToken)

    case .leave:
      guard let chatId = peer.asThreadId() else {
        throw ChatDestructiveActionError.missingCurrentUser
      }

      _ = try await Api.realtime.send(
        .removeChatParticipant(chatID: chatId, userID: accountToken.userID),
        expectedAccount: accountToken
      )
    }
  }

}

private enum ChatDestructiveActionError: Error {
  case missingCurrentUser
}
