import Combine
import Foundation

/// How an Agent publishes its work in a thread (spec §6). Detailed posts every
/// harness item as progress; Friendly posts only short prose updates.
public enum AgentOutputMode: String, Codable, Equatable, Sendable, CaseIterable {
  case detailed
  case friendly

  public var title: String {
    switch self {
    case .detailed: "Detailed"
    case .friendly: "Friendly"
    }
  }

  public var summary: String {
    switch self {
    case .detailed: "Shows every step the agent takes, with tool calls you can expand."
    case .friendly: "Shows only short updates and the final answer."
    }
  }
}

public enum AgentWaitingKind: String, Codable, Equatable, Sendable {
  case approval
  case question
  case dialog
  case limit
  case setup
}

/// Thin run state the server keeps per (chat, agent, work). Unknown or missing
/// state is never presented as idle.
public enum AgentRunState: Codable, Equatable, Sendable {
  case idle
  case working
  case waiting(AgentWaitingKind)
  case stopping
  case paused
  case heldElsewhere(label: String?)
  case offline
  case unknown

  public var isActive: Bool {
    switch self {
    case .working, .waiting, .stopping: true
    case .idle, .paused, .heldElsewhere, .offline, .unknown: false
    }
  }
}

public struct AgentWorkState: Codable, Equatable, Sendable, Identifiable {
  public struct Key: Hashable, Codable, Sendable {
    public let chatID: Int64
    public let botUserID: Int64

    public init(chatID: Int64, botUserID: Int64) {
      self.chatID = chatID
      self.botUserID = botUserID
    }
  }

  public var id: Key { key }
  public let key: Key
  public var runState: AgentRunState
  /// People the current wait is for (approvals: owner and delegates).
  public var attentionForUserIDs: [Int64]
  public var queueCount: Int
  public var outputMode: AgentOutputMode
  public var updatedAt: Date
  public var revision: Int64

  public init(
    key: Key,
    runState: AgentRunState,
    attentionForUserIDs: [Int64] = [],
    queueCount: Int = 0,
    outputMode: AgentOutputMode = .detailed,
    updatedAt: Date = Date(),
    revision: Int64 = 0
  ) {
    self.key = key
    self.runState = runState
    self.attentionForUserIDs = attentionForUserIDs
    self.queueCount = queueCount
    self.outputMode = outputMode
    self.updatedAt = updatedAt
    self.revision = revision
  }

  public func isWaiting(for userID: Int64?) -> Bool {
    guard case .waiting = runState, let userID else { return false }
    return attentionForUserIDs.isEmpty || attentionForUserIDs.contains(userID)
  }
}

/// Render-ready Agent work state for chats. Reads are synchronous so Compose,
/// the work bar and the sidebar render the last known state on their first
/// frame; the server's realtime updates replace it as they arrive.
@MainActor
public final class AgentWorkStateStore: ObservableObject {
  public static let shared = AgentWorkStateStore()

  @Published public private(set) var states: [AgentWorkState.Key: AgentWorkState] = [:]

  public init() {}

  public func state(chatID: Int64, botUserID: Int64) -> AgentWorkState? {
    states[.init(chatID: chatID, botUserID: botUserID)]
  }

  public func states(chatID: Int64) -> [AgentWorkState] {
    states.values
      .filter { $0.key.chatID == chatID }
      .sorted { $0.key.botUserID < $1.key.botUserID }
  }

  /// The effective output mode for an Agent in a chat. Detailed is the
  /// documented default until the server reports otherwise.
  public func outputMode(chatID: Int64, botUserID: Int64) -> AgentOutputMode {
    state(chatID: chatID, botUserID: botUserID)?.outputMode ?? .detailed
  }

  /// Applies a server state, ignoring anything older than what is held.
  public func apply(_ state: AgentWorkState) {
    if let current = states[state.key], current.revision > state.revision { return }
    guard states[state.key] != state else { return }
    states[state.key] = state
  }

  public func remove(_ key: AgentWorkState.Key) {
    states[key] = nil
  }

  public func removeAll() {
    states.removeAll()
  }
}
