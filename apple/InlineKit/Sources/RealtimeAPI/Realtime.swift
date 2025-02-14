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
import SwiftUI

public final class Realtime: Sendable {
  public static let shared = Realtime()

  private let api: RealtimeAPI = .init()

  private init() {
    if Auth.shared.isLoggedIn {
      start()
    }

    // not ever cancelled for now
    let _ = Auth.shared.$isLoggedIn.sink { [weak self] isLoggedIn in
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
}
