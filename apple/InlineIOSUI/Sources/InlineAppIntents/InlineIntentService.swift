import AppIntents
import Auth
import Foundation
import InlineKit
import InlineProtocol
import RealtimeV2
#if os(iOS)
import UIKit
#endif

/// Stateless adapters over the app's existing account, connection, sync, and transaction owner.
enum InlineIntentService {
  static func account() async throws -> AuthAccountMutationToken {
    #if os(iOS)
    guard await MainActor.run(body: { UIApplication.shared.isProtectedDataAvailable }) else {
      throw InlineIntentError.locked
    }
    #endif
    let auth = Auth.shared.handle
    if !auth.snapshot().didHydrate { await auth.refreshFromStorage() }
    guard auth.isLoggedIn(), !auth.hasPendingAccountTransition() else {
      throw AppIntentError.UserActionRequired.signin
    }
    return try auth.beginAccountMutation()
  }

  static func validate(_ account: AuthAccountMutationToken) throws {
    do { try Auth.shared.handle.validateAccountMutation(account) }
    catch { throw InlineIntentError.accountChanged }
  }

  static func chats(identifiers: [String]? = nil, search: String = "") async throws -> [InlineIntentChat] {
    let account = try await account()
    let ids = identifiers.map { values in
      values.compactMap(InlineIntentChatID.init).filter { $0.accountID == account.userID }.map(\.chatID)
    }
    if ids?.isEmpty == true { return [] }
    guard (ids?.count ?? 0) <= 50 else { throw InlineIntentError.tooManyMessages }
    return try await InlineIntentMessaging.connected(account: account) { realtime in
      var inbox = try await InlineIntentMessaging.inbox(on: realtime, account: account)
      if let ids {
        let existing = Set(inbox.conversations.map { $0.chat.id.chatID })
        let missing = Array(Set(ids).subtracting(existing))
        guard missing.count <= 8 else { throw InlineIntentError.tooManyConversations }
        for chatID in missing {
          let identifier = InlineIntentChatID(accountID: account.userID, chatID: chatID).rawValue
          do {
            inbox = try await InlineIntentMessaging.conversation(
              identifier,
              on: realtime,
              inbox: inbox,
              account: account
            ).inbox
          } catch let error as RealtimeDirectRpcError where error.isUnavailableEntity {
            continue
          }
        }
      }
      return InlineIntentChatStore.fetch(in: inbox, chatIDs: ids, search: search)
    }
  }

  static func resolve(_ identifier: String) async throws -> InlineIntentChat {
    let account = try await account()
    return try await InlineIntentMessaging.connected(account: account) { realtime in
      let inbox = try await InlineIntentMessaging.inbox(on: realtime, account: account)
      return try await InlineIntentMessaging.authorizedConversation(
        identifier,
        on: realtime,
        inbox: inbox,
        account: account
      ).conversation.chat
    }
  }

  static func validateMessage(_ text: String) throws {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw InlineIntentError.emptyMessage
    }
  }

  static func send(text: String, to identifier: String, account: AuthAccountMutationToken) async throws {
    try validateMessage(text)
    // Keep the pre-confirmation generation, including across logout/login to the same user.
    try validate(account)
    // Resolve again after the system's confirmation UI; never trust serialized titles/peers.
    let chat = try await resolve(identifier)
    guard chat.id.accountID == account.userID else { throw InlineIntentError.accountChanged }
    try validate(account)
    try await sendConnected(text: text, chat: chat, account: account)
  }

  static func saveNote(_ text: String) async throws {
    try validateMessage(text)
    let account = try await account()
    // The existing transaction owns first-use self-chat persistence and sync projection.
    try await sendConnected(text: text, chat: nil, account: account)
  }

  private static func sendConnected(text: String, chat: InlineIntentChat?, account: AuthAccountMutationToken) async throws {
    do {
      try await Api.realtime.withUserInitiatedConnection(accountToken: account) { realtime in
        let destination: InlineIntentChat
        if let chat {
          destination = chat
        } else {
          let result = try await realtime.send(
            .getChat(peer: .user(id: account.userID)),
            expectedAccount: account
          )
          guard case let .getChat(response)? = result else { throw InlineIntentError.unavailable }
          let resolved = try InlineIntentInbox.empty(accountID: account.userID).addingConversation(response)
          destination = try resolved.conversation(
            InlineIntentChatID(accountID: account.userID, chatID: response.chat.id).rawValue
          ).chat
        }
        try validate(account)
        let transaction = InlineIntentSendTransaction(text: text, chat: destination, account: account)
        let result = try await realtime.send(transaction, expectedAccount: account)
        guard case .sendMessage? = result else { throw InlineIntentError.sendNotConfirmed }
      }
    } catch is CancellationError {
      // Cancellation can race an already admitted transaction. Never invite an automatic retry.
      throw InlineIntentError.sendNotConfirmed
    } catch let error as InlineIntentError {
      throw error
    } catch {
      // A timeout/disconnect can happen after server commit. Never say “not sent” or retry here.
      throw InlineIntentError.sendNotConfirmed
    }
  }
}

/// Uses the existing send payload and transaction owner, without a durable offline queue or an
/// optimistic message. This action must finish within the system invocation that requested it.
struct InlineIntentSendTransaction: Transaction2 {
  var method: InlineProtocol.Method = .sendMessage
  var type: TransactionKindType = .ephemeral(.init(maxQueueAge: 5))
  var context: SendMessageTransaction.Context
  private var account: AuthAccountMutationToken?
  var reconnectReplayPolicy: TransactionReconnectPolicy? { .neverReplay }

  private enum CodingKeys: String, CodingKey { case context }

  init(text: String, chat: InlineIntentChat, account: AuthAccountMutationToken) {
    context = SendMessageTransaction(text: text, peerId: chat.peer, chatId: chat.id.chatID).context
    self.account = account
  }

  func input(from context: SendMessageTransaction.Context) -> RpcCall.OneOf_Input? {
    .sendMessage(.with {
      $0.peerID = context.peerId.toInputPeer()
      $0.message = context.text ?? ""
      $0.randomID = context.randomId
    })
  }

  func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard let account, case let .sendMessage(response)? = result else { throw .invalid }
    do {
      try await Api.realtime.applyUpdatesAndWait(response.updates, accountToken: account)
    } catch {
      throw .invalid
    }
  }
}
