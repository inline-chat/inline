import Foundation

/// A button in the row under the chat info header.
public enum PeerInfoAction: String, Hashable, Identifiable, Sendable {
  /// Opens the DM or thread. Leads when chat info was opened from somewhere
  /// else, such as an avatar or a member list.
  case open
  /// Searches this chat. Leads when chat info sits over its own chat.
  case search
  /// Chooses how this chat notifies.
  case notifications
  /// Follows or unfollows a thread in the sidebar.
  case follow
  /// How a bridge agent writes its replies in this chat.
  case output
  /// Who can message a bot. Owners and admins only.
  case share
  /// Adds people or groups to a private thread.
  case addMembers

  public var id: String { rawValue }
}

/// Facts the action row needs beyond the subject.
public struct PeerInfoActionContext: Equatable, Sendable {
  /// Chat info covers the chat it describes, so Open would do nothing.
  public var isOverOwnChat: Bool
  /// The platform can search inside a chat.
  public var supportsInChatSearch: Bool
  public var canAddMembers: Bool
  /// The viewer owns or admins this bot.
  public var canShareBot: Bool
  /// The bot is a bridge agent with an output choice.
  public var offersOutputMode: Bool

  public init(
    isOverOwnChat: Bool,
    supportsInChatSearch: Bool,
    canAddMembers: Bool = false,
    canShareBot: Bool = false,
    offersOutputMode: Bool = false
  ) {
    self.isOverOwnChat = isOverOwnChat
    self.supportsInChatSearch = supportsInChatSearch
    self.canAddMembers = canAddMembers
    self.canShareBot = canShareBot
    self.offersOutputMode = offersOutputMode
  }
}

public extension PeerInfoAction {
  /// The action row for a subject, at most four buttons, most used first.
  static func actions(for subject: PeerInfoSubject, context: PeerInfoActionContext) -> [PeerInfoAction] {
    var actions: [PeerInfoAction] = []

    if !context.isOverOwnChat {
      actions.append(.open)
    } else if context.supportsInChatSearch {
      actions.append(.search)
    }

    switch subject.kind {
    case .selfChat:
      break
    case .person:
      actions.append(.notifications)
    case .bot:
      actions.append(.notifications)
      if context.offersOutputMode { actions.append(.output) }
      if context.canShareBot { actions.append(.share) }
    case .thread, .subthread:
      actions.append(.notifications)
      actions.append(.follow)
      if context.canAddMembers { actions.append(.addMembers) }
    }

    return Array(actions.prefix(4))
  }
}
