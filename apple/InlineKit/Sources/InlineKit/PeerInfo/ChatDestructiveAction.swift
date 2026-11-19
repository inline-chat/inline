import Auth
import Foundation

/// The one destructive way out of a thread: its creator deletes it, anyone
/// else in a private space thread leaves it.
public enum ChatDestructiveAction: Equatable, Sendable {
  case delete
  case leave

  public var title: String {
    switch self {
    case .delete:
      "Delete Chat"
    case .leave:
      "Leave Chat"
    }
  }

  public var shortTitle: String {
    switch self {
    case .delete:
      "Delete"
    case .leave:
      "Leave"
    }
  }

  public var systemImage: String {
    switch self {
    case .delete:
      "trash"
    case .leave:
      "rectangle.portrait.and.arrow.right"
    }
  }

  public var loadingTitle: String {
    switch self {
    case .delete:
      "Deleting chat..."
    case .leave:
      "Leaving chat..."
    }
  }

  public var successTitle: String {
    switch self {
    case .delete:
      "Chat deleted"
    case .leave:
      "Left chat"
    }
  }

  public var failureTitle: String {
    switch self {
    case .delete:
      "Failed to delete chat"
    case .leave:
      "Failed to leave chat"
    }
  }

  public func confirmationMessage(chatTitle: String) -> String {
    switch self {
    case .delete:
      "Delete \"\(chatTitle)\"? This removes it from your chat list."
    case .leave:
      "Leave \"\(chatTitle)\"? This removes it from your chat list."
    }
  }
}

public enum ChatDestructiveActionResolver {
  public static func action(
    peer: Peer,
    chat: Chat?,
    currentUserId: Int64? = Auth.shared.getCurrentUserId()
  ) -> ChatDestructiveAction? {
    guard let chat else { return nil }
    return action(
      peer: peer,
      chatType: chat.type,
      chatCreatedBy: chat.createdBy,
      chatSpaceId: chat.spaceId,
      chatIsPublic: chat.isPublic,
      currentUserId: currentUserId
    )
  }

  public static func action(
    peer: Peer,
    chatType: ChatType?,
    chatCreatedBy: Int64?,
    chatSpaceId: Int64?,
    chatIsPublic: Bool?,
    currentUserId: Int64? = Auth.shared.getCurrentUserId()
  ) -> ChatDestructiveAction? {
    guard peer.isThread, chatType == .thread else { return nil }

    guard let currentUserId else {
      return nil
    }

    if chatCreatedBy == nil || chatCreatedBy == currentUserId {
      return .delete
    }

    guard chatSpaceId != nil, chatIsPublic == false else {
      return nil
    }

    return .leave
  }
}
