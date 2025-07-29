/// The entry point to use the API from UI code
/// Scope:
/// - Start a connection
/// - Allow calling methods and getting a response back
/// - Allow listening to events???
/// - Integrate update manager?

import Auth
import Combine
import Foundation
import GRDB
import InlineProtocol
import Logger

import SwiftUI

public final actor Realtime: Sendable {
  public static let shared = Realtime()

  private let db = AppDatabase.shared
  private let log = Log.scoped("RealtimeWrapper", enableTracing: false)
  private var api: RealtimeAPI
  private var eventsTask: Task<Void, Never>?
  private var started = false

  @MainActor private var cancellable: AnyCancellable? = nil
  @MainActor public let apiStatePublisher = CurrentValueSubject<RealtimeAPIState, Never>(
    .connecting
  )
  @MainActor public var apiState: RealtimeAPIState {
    apiStatePublisher.value
  }

  private init() {
    api = RealtimeAPI()

    Task {
      if Auth.shared.isLoggedIn {
        await ensureStarted()
      }
    }

    Task { @MainActor in
      cancellable = Auth.shared.$isLoggedIn.sink { [weak self] isLoggedIn in
        guard let self else { return }
        if isLoggedIn {
          DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            Task {
              self?.log.debug("user logged in, starting realtime")
              await self?.ensureStarted()
            }
          }
        }
      }
    }
  }

  /// Apply updates as a result of an operation
  public func applyUpdates(_ updates: [InlineProtocol.Update]) {
    // TODO: connect to sync client
  }

  private func ensureStarted() {
    if started {
      return
    }
    started = true
    start()
  }

  public func start() {
    log.debug("Starting realtime connection")

    // Init
    // updates = UpdatesEngine()
    // self.api = RealtimeAPI(updatesEngine: updates!)

//    guard let api else {
//      return
//    }

    // Setup listener
    eventsTask = Task { [weak self] in
      guard let self else { return }
      for await event in await api.eventsChannel {
        guard !Task.isCancelled else { break }
        log.debug("Received api event: \(event)")
        switch event {
          case let .stateUpdate(state):
            Task { @MainActor in
              apiStatePublisher.send(state)
            }
        }
      }
    }

    // Reset state first
    Task { @MainActor in
      apiStatePublisher.send(.connecting)
    }

    // Start the connection
    Task {
      do {
        try await api.start()
        log.debug("Realtime API started successfully")
      } catch {
        log.error("Error starting realtime", error: error)

        // Update state on failure
        Task { @MainActor in
          apiStatePublisher.send(.waitingForNetwork)
        }

        // Retry after delay if still logged in
        if Auth.shared.isLoggedIn {
          try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
          if Auth.shared.isLoggedIn {
            self.start()
          }
        }
      }
    }
  }

  public func invoke(
    _ method: InlineProtocol.Method,
    input: RpcCall.OneOf_Input?,
    discardIfNotConnected: Bool = false
  ) async throws
    -> RpcResult.OneOf_Result?
  {
    try await api.invoke(method, input: input, discardIfNotConnected: discardIfNotConnected)
  }

  public func loggedOut() {
    log.debug("User logged out, stopping realtime")

    // Reset state on main actor first
    Task { @MainActor in
      apiStatePublisher.send(.waitingForNetwork)
    }

    started = false

    // Then stop the API completely
    eventsTask?.cancel()
    eventsTask = nil

    Task {
      await api.stopAndReset()
    }
    log.debug("Realtime API stopped after logout")
  }
}

public extension Realtime {
  @discardableResult
  func invokeWithHandler(_ method: InlineProtocol.Method, input: RpcCall.OneOf_Input?) async throws -> RpcResult
    .OneOf_Result?
  {
    do {
      log.trace("calling \(method)")
      let response = try await invoke(method, input: input)

      switch response {
        case let .getMe(result):
          try handleResult_getMe(result)

        case let .deleteMessages(result):
          try handleResult_deleteMessages(result)

        case let .getChatHistory(result):
          try handleResult_getChatHistory(input!, result)

        case let .createChat(result):
          try handleResult_createChat(result)

        case let .getSpaceMembers(result):
          try await handleResult_getSpaceMembers(result)

        case let .inviteToSpace(result):
          try await handleResult_inviteToSpace(result)

        case .deleteChat:
          try await handleResult_deleteChat()

        case let .getChatParticipants(result):
          try await handleResult_getChatParticipants(input!, result)

        case let .addChatParticipant(result):
          try await handleResult_addChatParticipant(result, input: input!)

        case let .removeChatParticipant(result):
          try await handleResult_removeChatParticipant(result, input: input!)

        case let .translateMessages(result):
          try await handleResult_translateMessages(result, input: input!)

        case let .getChats(result):
          try await handleResult_getChats(result)

        case let .updateUserSettings(result):
          try await handleResult_updateUserSettings(result)

        case let .markAsUnread(result):
          try await handleResult_markAsUnread(result)

        default:
          break
      }

      return response
    } catch {
      log.error("Failed to invoke \(method) with handler", error: error)
      throw error
    }
  }

  private func handleResult_getMe(_ result: GetMeResult) throws {
    log.trace("getMe result: \(result)")
    guard result.hasUser else { return }

    _ = try db.dbWriter.write { db in
      try User.save(db, user: result.user)
    }

    log.trace("getMe saved")
  }

  private func handleResult_deleteMessages(_ result: DeleteMessagesResult) throws {
    log.trace("deleteMessages result: \(result)")

    applyUpdates(result.updates)
  }

  private func handleResult_getChatHistory(_ input: RpcCall.OneOf_Input, _ result: GetChatHistoryResult) throws {
    log.trace("saving getChatHistory result")

    // need to extract peer id from input
    guard case let .getChatHistory(getChatHistoryInput) = input else {
      log.error("could not infer peerId")
      return
    }

    let peerId = getChatHistoryInput.peerID.toPeer()

    Task.detached(priority: .userInitiated) {
      _ = try await self.db.dbWriter.write { db in
        for message in result.messages {
          do {
            _ = try Message.save(db, protocolMessage: message, publishChanges: false) // we reload below
          } catch {
            self.log.error("Failed to save message", error: error)
          }
        }
      }

      // Publish and reload messages
      Task.detached(priority: .userInitiated) { @MainActor in
        MessagesPublisher.shared.messagesReload(peer: peerId, animated: false)
      }
    }
  }

  private func handleResult_createChat(_ result: CreateChatResult) throws {
    log.trace("createChat result: \(result)")

    do {
      // Save chat and dialog to database
      try AppDatabase.shared.dbWriter.write { db in
        do {
          let chat = Chat(from: result.chat)
          try chat.save(db)
        } catch {
          Log.shared.error("Failed to save chat", error: error)
        }

        do {
          let dialog = Dialog(from: result.dialog)
          try dialog.save(db)
        } catch {
          Log.shared.error("Failed to save dialog", error: error)
        }
      }
    } catch {
      Log.shared.error("Failed to save chat in transaction", error: error)
    }

    log.trace("createChat saved")
  }

  private func handleResult_getSpaceMembers(_ result: GetSpaceMembersResult) async throws {
    log.trace("getSpaceMembers")
    try await db.dbWriter.write { db in
      for user in result.users {
        do {
          _ = try User.save(db, user: user)
        } catch {
          Log.shared.error("Failed to save user", error: error)
        }
      }

      for member in result.members {
        do {
          let member = Member(from: member)
          try member.save(db)
        } catch {
          Log.shared.error("Failed to save member", error: error)
        }
      }
    }
    log.trace("getSpaceMembers saved")
  }

  private func handleResult_inviteToSpace(_ result: InviteToSpaceResult) async throws {
    log.trace("inviteToSpace result: \(result)")
    try await db.dbWriter.write { db in
      do {
        let user = User(from: result.user)
        try user.save(db)
      } catch {
        Log.shared.error("Failed to save user", error: error)
      }
      do {
        let member = Member(from: result.member)
        // print("member: \(member)")
        try member.save(db)
      } catch {
        Log.shared.error("Failed to save member", error: error)
      }

      do {
        let chat = Chat(from: result.chat)
        // print("chat: \(chat)")
        try chat.save(db)
      } catch {
        Log.shared.error("Failed to save chat", error: error)
      }

      do {
        let dialog = Dialog(from: result.dialog)
        // print("dialog: \(dialog)")
        try dialog.save(db)
      } catch {
        Log.shared.error("Failed to save dialog", error: error)
      }
    }
  }

  private func handleResult_getChatParticipants(
    _ input: RpcCall.OneOf_Input,
    _ result: GetChatParticipantsResult
  ) async throws {
    log.trace("getChatParticipants result: \(result)")

    guard case let .getChatParticipants(getChatParticipantsInput) = input else {
      log.error("could not infer chatId")
      return
    }

    try await db.dbWriter.write { db in
      // Save users
      for user in result.users {
        do {
          _ = try User.save(db, user: user)
        } catch {
          Log.shared.error("Failed to save user", error: error)
        }
      }

      for participant in result.participants {
        do {
          ChatParticipant.save(db, from: participant, chatId: getChatParticipantsInput.chatID)
        } catch {
          Log.shared.error("Failed to save chat participant", error: error)
        }
      }
    }
    log.trace("getChatParticipants saved")
  }

  private func handleResult_addChatParticipant(
    _ result: AddChatParticipantResult,
    input: RpcCall.OneOf_Input
  ) async throws {
    log.trace("addChatParticipant result: \(result)")

    guard case let .addChatParticipant(addInput) = input else {
      log.error("could not infer chatId")
      return
    }

    try await db.dbWriter.write { db in
      try ChatParticipant.save(db, from: result.participant, chatId: addInput.chatID)
    }
  }

  private func handleResult_removeChatParticipant(
    _ result: RemoveChatParticipantResult,
    input: RpcCall.OneOf_Input
  ) async throws {
    log.trace("removeChatParticipant result: \(result)")

    guard case let .removeChatParticipant(removeInput) = input else {
      log.error("could not infer chatId and userId")
      return
    }

    try await db.dbWriter.write { db in
      let participant = try ChatParticipant
        .filter(Column("chatId") == removeInput.chatID)
        .filter(Column("userId") == removeInput.userID)
        .deleteAll(db)
    }
  }

  private func handleResult_deleteChat() async throws {
    log.trace("deleteChat done")
  }

  private func handleResult_translateMessages(
    _ result: InlineProtocol.TranslateMessagesResult,
    input: RpcCall.OneOf_Input
  ) async throws {
    log.trace("translate result: \(result)")

    guard case let .translateMessages(input) = input else {
      log.error("could not infer chatId and userId")
      return
    }

    let peerID = input.peerID

    try await db.dbWriter.write { db in
      guard let chat = try Chat.getByPeerId(peerId: peerID.toPeer()) else {
        self.log.error("could not find chat")
        return
      }
      let chatID = chat.id
      for translation in result.translations {
        do {
          _ = try Translation.save(db, protocolTranslation: translation, chatId: chatID)
        } catch {
          Log.shared.error("Failed to save one translation", error: error)
        }
      }

      // TODO: reload messages???
    }
  }

  private func handleResult_getChats(
    _ result: InlineProtocol.GetChatsResult,
  ) async throws {
    log.trace("getChats result: \(result)")

    try await db.dbWriter.write { db in
      // Save spaces
      for space in result.spaces {
        do {
          let spaceModel = Space(from: space)
          try spaceModel.save(db)
        } catch {
          Log.shared.error("Failed to save space", error: error)
        }
      }

      // Save users
      for user in result.users {
        do {
          _ = try User.save(db, user: user)
        } catch {
          Log.shared.error("Failed to save user", error: error)
        }
      }

      // First save chats without lastMsgId to avoid foreign key constraint
      var chatsToUpdate: [(Chat, Int64?)] = []
      for chat in result.chats {
        do {
          var chatModel = Chat(from: chat)
          let lastMsgId = chatModel.lastMsgId
          chatModel.lastMsgId = nil // Temporarily remove lastMsgId
          try chatModel.save(db)
          chatsToUpdate.append((chatModel, lastMsgId))
        } catch {
          Log.shared.error("Failed to save chat", error: error)
        }
      }

      // Save messages
      for message in result.messages {
        do {
          _ = try Message.save(db, protocolMessage: message, publishChanges: false)
        } catch {
          Log.shared.error("Failed to save message", error: error)
        }
      }

      // Now update chats with lastMsgId since messages exist
      for (chat, lastMsgId) in chatsToUpdate {
        do {
          var updatedChat = chat
          updatedChat.lastMsgId = lastMsgId
          try updatedChat.save(db)
        } catch {
          Log.shared.error("Failed to update chat with lastMsgId", error: error)
        }
      }

      // Save dialogs
      for dialog in result.dialogs {
        do {
          let existing = try Dialog.fetchOne(
            db,
            id: Dialog.getDialogId(peerId: dialog.peer.toPeer())
          )
          var newDialog = Dialog(from: dialog)

          if let existing {
            print("🌴 Dialog draft \(newDialog.draftMessage)")
            print("🌴 Existing draftMessage \(existing.draftMessage)")
            newDialog.draftMessage = existing.draftMessage
            try newDialog.save(db)
          } else {
            try newDialog.save(db, onConflict: .replace)
          }

        } catch {
          Log.shared.error("Failed to save dialog", error: error)
        }
      }
    }

    log.trace("getChats saved successfully")
  }

  private func handleResult_updateUserSettings(
    _ result: InlineProtocol.UpdateUserSettingsResult,
  ) async throws {
    log.trace("updateNotificationSettings result: \(result)")

    applyUpdates(result.updates)
  }

  private func handleResult_markAsUnread(
    _ result: InlineProtocol.MarkAsUnreadResult
  ) async throws {
    log.trace("markAsUnread result: \(result)")
    
    applyUpdates(result.updates)
  }
}
