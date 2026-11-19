import Auth
import GRDB
import InlineKit
import Logger

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
