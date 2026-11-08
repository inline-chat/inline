import Foundation
import InlineKit
import Logger
import Observation
import RealtimeV2

/// Which sidebar chats are AI agents. A direct chat with a bot heads that
/// agent: its hover + starts a thread with the bot, nested under the row.
@MainActor
@Observable
final class SidebarAgents {
  static let shared = SidebarAgents()

  /// Experimental: a hover + on agent DM rows that starts a nested thread
  /// with the agent. Off by default; plain chats and folders never show it.
  static let rowNewThreadButtonKey = "experimental.sidebarAgentRowNewThread"

  /// The current account's own bots. Only these can carry an agent preset
  /// (project, model, reasoning) on a new thread.
  private(set) var ownedBotIDs: Set<Int64> = []

  @ObservationIgnored private var isLoadingBots = false

  /// The bot's user ID when `peer` is a direct chat with a bot, else nil.
  func agentBotID(for peer: InlineKit.Peer) -> Int64? {
    guard case let .user(userID) = peer else { return nil }
    if ownedBotIDs.contains(userID) { return userID }
    return ObjectCache.shared.getCachedUser(id: userID)?.user.bot == true ? userID : nil
  }

  func isOwnedBot(_ userID: Int64) -> Bool {
    ownedBotIDs.contains(userID)
  }

  func loadBots(using dependencies: AppDependencies) async {
    guard isLoadingBots == false else { return }
    isLoadingBots = true
    defer { isLoadingBots = false }
    do {
      let result = try await dependencies.realtimeV2.send(.listBots())
      guard case let .listBots(response) = result else { return }
      ownedBotIDs = Set(response.bots.map(\.id))
    } catch {
      Log.scoped("SidebarAgents").error("Could not load owned bots", error: error)
    }
  }
}
