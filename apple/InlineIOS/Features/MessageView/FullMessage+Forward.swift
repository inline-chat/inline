import Auth
import InlineKit

/// The "Forwarded from" header, shared by both message views.
extension FullMessage {
  /// Forwards out of your own DM carry no header.
  var showsForwardHeader: Bool {
    message.forwardFromUserId != nil && !isForwardFromSelfDm
  }

  /// The original chat is one you can't open.
  var forwardHeaderIsPrivate: Bool {
    if message.forwardFromPeerThreadId != nil {
      return forwardFromChatInfo == nil
    }
    if message.forwardFromPeerUserId != nil {
      return forwardFromUserInfo == nil && forwardFromPeerUserInfo == nil
    }
    return true
  }

  var forwardHeaderText: String {
    forwardHeaderIsPrivate ? "Forwarded from a private chat" : "Forwarded from: \(forwardHeaderTitle)"
  }

  private var forwardHeaderTitle: String {
    if message.forwardFromPeerThreadId != nil {
      let title = forwardFromChatInfo?.title
      return (title?.isEmpty == false) ? title! : "Chat"
    }
    if message.forwardFromPeerUserId != nil {
      if let forwardUserInfo = forwardFromUserInfo {
        return forwardUserInfo.user.shortDisplayName
      }
      if let peerUserInfo = forwardFromPeerUserInfo {
        return peerUserInfo.user.shortDisplayName
      }
    }
    return "User"
  }

  private var isForwardFromSelfDm: Bool {
    guard let forwardFromUserId = message.forwardFromUserId else { return false }
    let currentUserId = Auth.shared.getCurrentUserId() ?? 0
    guard forwardFromUserId == currentUserId else { return false }
    if message.forwardFromPeerUserId != nil {
      return true
    }
    if let forwardChat = forwardFromChatInfo, forwardChat.type == .privateChat {
      return true
    }
    return false
  }
}
