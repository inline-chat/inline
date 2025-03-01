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

public final class Realtime: Sendable {
  public static let shared = Realtime(updatesEngine: UpdatesEngine.shared)

  private let api: RealtimeAPI
  private let db = AppDatabase.shared
  private let log = Log.scoped("RealtimeWrapper", enableTracing: true)

  @MainActor public let apiStatePublisher = CurrentValueSubject<RealtimeAPIState, Never>(
    .connecting
  )
  @MainActor public var apiState: RealtimeAPIState {
    apiStatePublisher.value
  }

  private init(updatesEngine: RealtimeUpdatesProtocol) {
    api = .init(updatesEngine: updatesEngine)

    Task { [weak self] in
      guard let self else { return }
      for await event in await api.eventsChannel {
        log.debug("Received api event: \(event)")
        switch event {
          case let .stateUpdate(state):
            Task { @MainActor in
              apiStatePublisher.send(state)
            }
        }
      }
    }

    if Auth.shared.isLoggedIn {
      start()
    }

    // not ever cancelled for now
    _ = Auth.shared.$isLoggedIn.sink { [weak self] isLoggedIn in
      guard let self else { return }
      if isLoggedIn {
        ensureStarted()
      }
    }
  }

  private func ensureStarted() {
    start()
  }

  public func start() {
    // Start the connection
    Task {
      do {
        try await self.api.start()
      } catch {
        Log.shared.error("Error starting realtime", error: error)
      }
    }
  }

  public func invoke(_ method: InlineProtocol.Method, input: RpcCall.OneOf_Input?) async throws
    -> RpcResult.OneOf_Result?
  {
    try await api.invoke(method, input: input)
  }

  public func loggedOut() {
    // todo
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
}
