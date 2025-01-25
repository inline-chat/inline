import Combine
import SwiftUI

public struct ComposeActionInfo {
  public var userId: Int64
  public var action: ApiComposeAction
  var expiresAt: Date
}

@MainActor
public class ComposeActions: ObservableObject {
  public static let shared = ComposeActions()

  // for now support only one action per chat (peer)
  @Published public var actions: [Peer: ComposeActionInfo] = [:]

  private var cancelTasks: [Peer: Task<Void, Never>] = [:]
  private var log = Log.scoped("ComposeActions", enableTracing: true)

  public init() {}

  public func getComposeAction(for peer: Peer) -> ComposeActionInfo? {
    actions[peer]
  }

  public func addComposeAction(for peer: Peer, action: ApiComposeAction, userId: Int64) {
    log.trace("action added for \(peer)")
    cancelTasks[peer]?.cancel()

    actions[peer] = ComposeActionInfo(userId: userId, action: action, expiresAt: Date().addingTimeInterval(6))

    // Expire after 6s if not updated
    cancelTasks[peer] = Task {
      self.log.trace("typing action expired for \(peer)")
      try? await Task.sleep(for: .seconds(6))
      guard !Task.isCancelled else { return }
      removeComposeAction(for: peer)
    }
  }

  public func removeComposeAction(for peer: Peer) {
    log.trace("removed action for \(peer)")
    actions[peer] = nil
    cancelTasks[peer]?.cancel()
  }

  // Sending side
  private func sendComposeAction(for peerId: Peer, action: ApiComposeAction?) async throws {
    let _ = try await ApiClient.shared.sendComposeAction(peerId: peerId, action: action)
  }

  private var lastTypingSent: [Peer: Date] = [:]

  public func startedTyping(for peerId: Peer) async {
    if let lastSent = lastTypingSent[peerId], lastSent.timeIntervalSinceNow > -3 {
      // Previous one still valid since it hasn't been 6s
      return
    }

    // Send stop typing action immediately
    do {
      lastTypingSent[peerId] = Date()
      log.trace("sending typing status for \(peerId)")
      try await sendComposeAction(for: peerId, action: .typing)
    } catch {
      log.error("Failed to send stop typing status: \(error)")
    }
  }

  public func stoppedTyping(for peerId: Peer) async {
    lastTypingSent[peerId] = nil

    // Send stop typing action immediately
    do {
      try await sendComposeAction(for: peerId, action: nil)
    } catch {
      log.error("Failed to send stop typing status: \(error)")
    }
  }
}
