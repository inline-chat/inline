/// The entry point to use the API from UI code
/// Scope:
/// - Start a connection
/// - Allow calling methods and getting a response back
/// - Allow listening to events???
/// - Integrate update manager?

import Auth
import Combine
import Foundation
import InlineProtocol
import Logger
import RealtimeAPI
import SwiftUI

public final actor Realtime: Sendable {
  public static let shared = Realtime()

  private let db = AppDatabase.shared
  private let log = Log.scoped("RealtimeWrapper", enableTracing: true)
  public var updates: UpdatesEngine
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
    updates = UpdatesEngine()
    api = RealtimeAPI(updatesEngine: updates)

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

  public func invoke(_ method: InlineProtocol.Method, input: RpcCall.OneOf_Input?) async throws
    -> RpcResult.OneOf_Result?
  {
    try await api.invoke(method, input: input)
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
  func invokeWithHandler(_ method: InlineProtocol.Method, input: RpcCall.OneOf_Input?) {
    Task {
      do {
        log.trace("calling \(method)")
        let response = try await invoke(method, input: input)

        switch response {
          case let .getMe(result):
            try self.handleResult_getMe(result)

          case let .deleteMessages(result):
            try self.handleResult_deleteMessages(result)

          case let .getChatHistory(result):
            try self.handleResult_getChatHistory(input!, result)

          default:
            break
        }
      } catch {
        log.error("Failed to invoke \(method) with handler", error: error)
      }
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

    Task {
      await api.updatesEngine.applyBatch(updates: result.updates)
    }
  }

  private func handleResult_getChatHistory(_ input: RpcCall.OneOf_Input, _ result: GetChatHistoryResult) throws {
    log.trace("saving getChatHistory result")

    // need to extract peer id from input
    guard case let .getChatHistory(getChatHistoryInput) = input else {
      log.error("could not infer peerId")
      return
    }

    let peerId = getChatHistoryInput.peerID.toPeer()

    _ = try db.dbWriter.write { db in
      for message in result.messages {
        _ = try Message.save(db, protocolMessage: message)
      }
    }

    // Publish and reload messages
    Task { @MainActor in
      MessagesPublisher.shared.messagesReload(peer: peerId, animated: false)
    }
  }
}
