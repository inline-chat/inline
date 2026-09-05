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
  private let log = Log.scoped("RealtimeWrapper")
  private var api: RealtimeAPI
  private var eventsTask: Task<Void, Never>?
  private var connectionTask: Task<Void, Never>?
  private var started = false
  private var automaticStartsSuspended = false

  @MainActor public let apiStatePublisher = CurrentValueSubject<RealtimeAPIState, Never>(
    .connecting
  )
  @MainActor public var apiState: RealtimeAPIState {
    apiStatePublisher.value
  }

  private init() {
    api = RealtimeAPI()
  }

  /// Apply updates as a result of an operation
  public func applyUpdates(
    _ updates: [InlineProtocol.Update],
    mutationToken: AuthAccountMutationToken
  ) async {
    await api.sync.handle(updates: updates, mutationToken: mutationToken)
  }

  private func writeAccountProjection<Result: Sendable>(
    token: AuthAccountMutationToken,
    _ operation: @escaping @Sendable (Database) throws -> Result
  ) async throws -> Result {
    try await db.dbWriter.write { database in
      try Auth.shared.handle.validateAccountMutation(token)
      return try operation(database)
    }
  }

  private func ensureStarted() {
    if started || automaticStartsSuspended || Auth.shared.getToken() == nil {
      return
    }
    started = true
    startConnection()
  }

  public func start() {
    guard Auth.shared.getToken() != nil else {
      log.info("Legacy realtime start skipped because no legacy bearer credential is active")
      return
    }
    automaticStartsSuspended = false
    ensureStarted()
  }

  private func startConnection() {
    guard started, !automaticStartsSuspended else { return }
    log.info("Starting realtime connection")

    // Init
    // updates = UpdatesEngine()
    // self.api = RealtimeAPI(updatesEngine: updates!)

//    guard let api else {
//      return
//    }

    startEventListenerIfNeeded()

    // Reset state first
    Task { @MainActor in
      apiStatePublisher.send(.connecting)
    }

    // Start the connection
    connectionTask = Task {
      do {
        try await api.start()
        log.info("Realtime API started successfully")
      } catch is CancellationError {
        return
      } catch {
        log.error("Error starting realtime", error: error)

        // Update state on failure
        Task { @MainActor in
          apiStatePublisher.send(.waitingForNetwork)
        }

        // Retry after delay if still logged in
        if Auth.shared.getToken() != nil {
          try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
          if started, !automaticStartsSuspended, Auth.shared.getToken() != nil {
            startConnection()
          }
        }
      }
    }
  }

  private func startEventListenerIfNeeded() {
    guard eventsTask == nil else { return }

    eventsTask = Task { [weak self] in
      guard let self else { return }
      for await event in await api.eventsChannel {
        guard !Task.isCancelled else { break }
        log.trace("Received api event: \(event)")
        switch event {
          case let .stateUpdate(state):
            await MainActor.run {
              apiStatePublisher.send(state)
            }
        }
      }
    }
  }

  private func stopEventListener() async {
    let endingEventsTask = eventsTask
    eventsTask = nil
    endingEventsTask?.cancel()
    await endingEventsTask?.value
  }

  /// Stops realtime work and suppresses automatic auth-driven starts until the next explicit start.
  /// Share-extension processes can be reused, so a later session may resume via `start()`.
  public func suspendForSessionEnd() async {
    guard started || !automaticStartsSuspended else { return }
    automaticStartsSuspended = true
    started = false

    await stopEventListener()
    let endingConnectionTask = connectionTask
    connectionTask = nil
    endingConnectionTask?.cancel()
    await endingConnectionTask?.value
    await api.stopAndReset()

    await MainActor.run {
      apiStatePublisher.send(.waitingForNetwork)
    }
    log.info("Realtime API suspended for session end")
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

  public func loggedOut() async {
    log.info("User logged out, stopping realtime")
    automaticStartsSuspended = true

    // Reset state on main actor first
    await MainActor.run {
      apiStatePublisher.send(.waitingForNetwork)
    }

    started = false

    // Then stop the API completely
    await stopEventListener()
    let endingConnectionTask = connectionTask
    connectionTask = nil
    endingConnectionTask?.cancel()
    await endingConnectionTask?.value

    await api.stopAndReset()
    log.info("Realtime API stopped after logout")
  }
}

public extension Realtime {
  @discardableResult
  func invokeWithHandler(_ method: InlineProtocol.Method, input: RpcCall.OneOf_Input?) async throws -> RpcResult
    .OneOf_Result?
  {
    do {
      let mutationToken = try Auth.shared.handle.beginAccountMutation()
      log.trace("calling \(method)")
      let response = try await invoke(method, input: input)

      switch response {
        case let .getMe(result):
          try handleResult_getMe(result, mutationToken: mutationToken)

        case let .deleteMessages(result):
          await handleResult_deleteMessages(result, mutationToken: mutationToken)

        case let .getChatHistory(result):
          try handleResult_getChatHistory(input!, result, mutationToken: mutationToken)

        case let .createChat(result):
          try handleResult_createChat(result, mutationToken: mutationToken)

        case let .getSpaceMembers(result):
          try await handleResult_getSpaceMembers(input!, result, mutationToken: mutationToken)

        case let .inviteToSpace(result):
          try await handleResult_inviteToSpace(result, mutationToken: mutationToken)

        case .deleteChat:
          try await handleResult_deleteChat()

        case let .getChatParticipants(result):
          try await handleResult_getChatParticipants(input!, result, mutationToken: mutationToken)

        case let .addChatParticipant(result):
          try await handleResult_addChatParticipant(result, input: input!, mutationToken: mutationToken)

        case let .removeChatParticipant(result):
          try await handleResult_removeChatParticipant(result, input: input!, mutationToken: mutationToken)

        case let .translateMessages(result):
          try await handleResult_translateMessages(result, input: input!, mutationToken: mutationToken)

        case let .getChats(result):
          try await handleResult_getChats(result, mutationToken: mutationToken)

        case let .updateUserSettings(result):
          await handleResult_updateUserSettings(result, mutationToken: mutationToken)

        case let .markAsUnread(result):
          await handleResult_markAsUnread(result, mutationToken: mutationToken)

        default:
          break
      }

      return response
    } catch {
      log.error("Failed to invoke \(method) with handler", error: error)
      throw error
    }
  }

  private func handleResult_getMe(
    _ result: GetMeResult,
    mutationToken: AuthAccountMutationToken
  ) throws {
    log.trace("getMe result: \(result)")
    guard result.hasUser else { return }

    _ = try db.dbWriter.write { db in
      try Auth.shared.handle.validateAccountMutation(mutationToken)
      try User.save(db, user: result.user)
    }

    log.trace("getMe saved")
  }

  private func handleResult_deleteMessages(
    _ result: DeleteMessagesResult,
    mutationToken: AuthAccountMutationToken
  ) async {
    log.trace("deleteMessages result: \(result)")

    await applyUpdates(result.updates, mutationToken: mutationToken)
  }

  private func handleResult_getChatHistory(
    _ input: RpcCall.OneOf_Input,
    _ result: GetChatHistoryResult,
    mutationToken: AuthAccountMutationToken
  ) throws {
    log.trace("saving getChatHistory result")

    // need to extract peer id from input
    guard case let .getChatHistory(getChatHistoryInput) = input else {
      log.error("could not infer peerId")
      return
    }

    let peerId = getChatHistoryInput.peerID.toPeer()
    let context = GetChatHistoryTransaction.Context(
      peer: peerId,
      offsetID: getChatHistoryInput.hasOffsetID ? getChatHistoryInput.offsetID : nil,
      limit: getChatHistoryInput.hasLimit ? getChatHistoryInput.limit : nil,
      modeRawValue: getChatHistoryInput.hasMode ? getChatHistoryInput.mode.rawValue : nil,
      anchorID: getChatHistoryInput.hasAnchorID ? getChatHistoryInput.anchorID : nil,
      beforeID: getChatHistoryInput.hasBeforeID ? getChatHistoryInput.beforeID : nil,
      afterID: getChatHistoryInput.hasAfterID ? getChatHistoryInput.afterID : nil,
      beforeLimit: getChatHistoryInput.hasBeforeLimit ? getChatHistoryInput.beforeLimit : nil,
      afterLimit: getChatHistoryInput.hasAfterLimit ? getChatHistoryInput.afterLimit : nil,
      includeAnchor: getChatHistoryInput.hasIncludeAnchor ? getChatHistoryInput.includeAnchor : nil
    )

    Task.detached(priority: .userInitiated) {
      do {
        _ = try await self.db.dbWriter.write { db in
          try Auth.shared.handle.validateAccountMutation(mutationToken)
          try GetChatHistoryTransaction.apply(result, context: context, db: db)
        }

        await MainActor.run {
          MessagesPublisher.shared.messagesReload(peer: peerId, animated: false)
        }
      } catch {
        self.log.error("Failed to save chat history", error: error)
      }
    }
  }

  private func handleResult_createChat(
    _ result: CreateChatResult,
    mutationToken: AuthAccountMutationToken
  ) throws {
    log.trace("createChat result: \(result)")

    do {
      // Save chat and dialog to database
      try AppDatabase.shared.dbWriter.write { db in
        try Auth.shared.handle.validateAccountMutation(mutationToken)
        do {
          let chat = Chat(from: result.chat)
          _ = try chat.saveFull(db)
        } catch {
          Log.shared.error("Failed to save chat", error: error)
        }

        do {
          _ = try result.dialog.saveFull(db)
        } catch {
          Log.shared.error("Failed to save dialog", error: error)
        }
      }
    } catch {
      Log.shared.error("Failed to save chat in transaction", error: error)
    }

    log.trace("createChat saved")
  }

  private func handleResult_getSpaceMembers(
    _ input: RpcCall.OneOf_Input,
    _ result: GetSpaceMembersResult,
    mutationToken: AuthAccountMutationToken
  ) async throws {
    log.trace("getSpaceMembers")
    guard case let .getSpaceMembers(getSpaceMembersInput) = input else {
      throw InlineRPCClientError.unexpectedResponse
    }
    try await writeAccountProjection(token: mutationToken) { db in
      try Member
        .filter(Member.Columns.spaceId == getSpaceMembersInput.spaceID)
        .deleteAll(db)
      for user in result.users {
        _ = try User.save(db, user: user)
      }

      for member in result.members {
        try Member(from: member).save(db)
      }
      try Space
        .filter(Space.Columns.id == getSpaceMembersInput.spaceID)
        .updateAll(db, [Space.Columns.memberRosterComplete.set(to: true)])
    }
    log.trace("getSpaceMembers saved")
  }

  private func handleResult_inviteToSpace(
    _ result: InviteToSpaceResult,
    mutationToken: AuthAccountMutationToken
  ) async throws {
    log.trace("inviteToSpace result: \(result)")
    try await writeAccountProjection(token: mutationToken) { db in
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
        _ = try chat.saveFull(db)
      } catch {
        Log.shared.error("Failed to save chat", error: error)
      }

      do {
        _ = try result.dialog.saveFull(db)
      } catch {
        Log.shared.error("Failed to save dialog", error: error)
      }
    }
  }

  private func handleResult_getChatParticipants(
    _ input: RpcCall.OneOf_Input,
    _ result: GetChatParticipantsResult,
    mutationToken: AuthAccountMutationToken
  ) async throws {
    log.trace("getChatParticipants result: \(result)")

    guard case let .getChatParticipants(getChatParticipantsInput) = input else {
      log.error("could not infer chatId")
      return
    }

    try await writeAccountProjection(token: mutationToken) { db in
      try ChatParticipant.filter(Column("chatId") == getChatParticipantsInput.chatID).deleteAll(db)
      try ChatParticipantGroup.filter(ChatParticipantGroup.Columns.chatId == getChatParticipantsInput.chatID)
        .deleteAll(db)

      for user in result.users {
        _ = try User.save(db, user: user)
      }

      for participant in result.participants {
        try ChatParticipant.save(db, from: participant, chatId: getChatParticipantsInput.chatID)
      }
      for group in result.groups {
        try UserGroup.save(db, from: group)
      }
      for participant in result.groupParticipants {
        try ChatParticipantGroup.save(db, from: participant, chatId: getChatParticipantsInput.chatID)
      }
      try Chat
        .filter(Chat.Columns.id == getChatParticipantsInput.chatID)
        .updateAll(db, [Chat.Columns.participantRosterComplete.set(to: true)])
    }
    log.trace("getChatParticipants saved")
  }

  private func handleResult_addChatParticipant(
    _ result: AddChatParticipantResult,
    input: RpcCall.OneOf_Input,
    mutationToken: AuthAccountMutationToken
  ) async throws {
    log.trace("addChatParticipant result: \(result)")

    guard case let .addChatParticipant(addInput) = input else {
      log.error("could not infer chatId")
      return
    }

    try await writeAccountProjection(token: mutationToken) { db in
      for user in result.users {
        _ = try User.save(db, user: user)
      }

      if result.hasParticipant {
        try ChatParticipant.save(db, from: result.participant, chatId: addInput.chatID)
      }

      if result.hasGroup {
        try UserGroup.save(db, from: result.group)
      }

      if result.hasGroupParticipant {
        try ChatParticipantGroup.save(db, from: result.groupParticipant, chatId: addInput.chatID)
      }
    }
  }

  private func handleResult_removeChatParticipant(
    _ result: RemoveChatParticipantResult,
    input: RpcCall.OneOf_Input,
    mutationToken: AuthAccountMutationToken
  ) async throws {
    log.trace("removeChatParticipant result: \(result)")

    guard case let .removeChatParticipant(removeInput) = input else {
      log.error("could not infer chatId and userId")
      return
    }

    try await writeAccountProjection(token: mutationToken) { db in
      _ = try ChatParticipant
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
    input: RpcCall.OneOf_Input,
    mutationToken: AuthAccountMutationToken
  ) async throws {
    log.trace("translate result: \(result)")

    guard case let .translateMessages(input) = input else {
      log.error("could not infer chatId and userId")
      return
    }

    let peerID = input.peerID

    try await writeAccountProjection(token: mutationToken) { db in
      guard let chat = try Chat.getByPeerId(db: db, peerId: peerID.toPeer()) else {
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
    mutationToken: AuthAccountMutationToken
  ) async throws {
    log.trace("getChats result: \(result)")

    let imported = try await writeAccountProjection(token: mutationToken) { db in
      let imported = try GetChatsTransaction.applySnapshot(result, in: db)
      // The legacy handler has no safe partial-import contract. Throwing from
      // the outer writer rolls back every savepoint committed by the shared
      // importer, so callers never observe a divergent half snapshot.
      if let failure = imported.failures.first {
        throw failure
      }
      return imported
    }
    if !imported.catchUpTargets.isEmpty {
      // A generic account snapshot is catalog-only. The shared importer left
      // populated children untouched; exceptional user repair is the sole
      // owner allowed to launch these child demands.
      log.debug(
        "legacy getChats ignored \(imported.catchUpTargets.count) child catch-up targets"
      )
    }
    _ = try await Api.realtime.installSnapshotOutcome(
      seededStates: imported.seededStates,
      catchUpTargets: [:],
      expectedAccount: mutationToken
    )

    log.trace("getChats saved successfully")
  }

  private func handleResult_updateUserSettings(
    _ result: InlineProtocol.UpdateUserSettingsResult,
    mutationToken: AuthAccountMutationToken
  ) async {
    log.trace("updateNotificationSettings result: \(result)")

    await applyUpdates(result.updates, mutationToken: mutationToken)
  }

  private func handleResult_markAsUnread(
    _ result: InlineProtocol.MarkAsUnreadResult,
    mutationToken: AuthAccountMutationToken
  ) async {
    log.trace("markAsUnread result: \(result)")

    await applyUpdates(result.updates, mutationToken: mutationToken)
  }
}
