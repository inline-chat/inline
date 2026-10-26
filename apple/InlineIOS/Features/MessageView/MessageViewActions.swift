import Auth
import InlineKit
import struct InlineProtocol.MessageEntities
import struct InlineProtocol.MessageEntity
import InlineUI
import Logger
import TextProcessing
import UIKit

/// What tapping or holding parts of a message does. Mirrors the current view's behavior; the
/// current view's copy goes away with it.
@MainActor
enum MessageViewActions {
  /// True when the character carries something tappable.
  static func isInteractive(_ text: NSAttributedString, at index: Int) -> Bool {
    guard index >= 0, index < text.length else { return false }
    let keys: [NSAttributedString.Key] = [
      .mentionUserId, .mentionGroupId, .threadLink, .inlineCode, .botCommand, .emailAddress, .phoneNumber,
    ]
    if keys.contains(where: { text.attribute($0, at: index, effectiveRange: nil) != nil }) {
      return true
    }
    return linkURL(in: text, at: index) != nil
  }

  static func handleTap(
    in text: NSAttributedString,
    at index: Int,
    message: FullMessage,
    spaceId: Int64?,
    presenter: UIViewController?
  ) {
    guard index >= 0, index < text.length else { return }
    let peer = message.message.peerId

    if let userId = text.attribute(.mentionUserId, at: index, effectiveRange: nil) as? Int64 {
      let agentId = text.attribute(.mentionAgentId, at: index, effectiveRange: nil) as? Int64
      openUser(userId, agentId: agentId, peer: peer)
      return
    }
    if let groupId = text.attribute(.mentionGroupId, at: index, effectiveRange: nil) as? Int64 {
      NotificationCenter.default.post(
        name: .userGroupMentionTapped,
        object: nil,
        userInfo: ["target": UserGroupMentionTarget(groupId: groupId, spaceId: spaceId)]
      )
      return
    }
    if let target = text.attribute(.threadLink, at: index, effectiveRange: nil) as? ThreadLinkTarget {
      ThreadLinkNavigator.open(target: target)
      return
    }
    var range = NSRange(location: 0, length: 0)
    if text.attribute(.inlineCode, at: index, effectiveRange: &range) as? Bool == true {
      copy((text.string as NSString).substring(with: range), toast: "Copied code")
      return
    }
    if let command = text.attribute(.botCommand, at: index, effectiveRange: &range) as? String, range.length > 0 {
      sendBotCommand(command.isEmpty ? (text.string as NSString).substring(with: range) : command, message: message)
      return
    }
    if let email = text.attribute(.emailAddress, at: index, effectiveRange: nil) as? String {
      copy(email, toast: "Copied email")
      return
    }
    if let phone = text.attribute(.phoneNumber, at: index, effectiveRange: nil) as? String {
      copy(phone, toast: "Copied number")
      return
    }
    if let url = linkURL(in: text, at: index) {
      if let mention = inlineMentionTarget(from: url) {
        openUser(mention.userId, agentId: mention.agentId, peer: peer)
      } else {
        InAppBrowser.shared.open(url, from: presenter)
      }
    }
  }

  static func toggleReaction(_ emoji: String, on message: FullMessage) {
    let currentUserID = Auth.shared.getCurrentUserId() ?? 0
    let model = message.message
    if message.reactions.contains(where: { $0.reaction.emoji == emoji && $0.reaction.userId == currentUserID }) {
      Transactions.shared.mutate(transaction: .deleteReaction(.init(
        message: model,
        emoji: emoji,
        peerId: model.peerId,
        chatId: model.chatId
      )))
    } else {
      Transactions.shared.mutate(transaction: .addReaction(.init(
        message: model,
        emoji: emoji,
        userId: currentUserID,
        peerId: model.peerId
      )))
    }
  }

  /// Opens where a forwarded message came from: the original message, or the sender's chat
  /// when the original is private.
  static func openForwardSource(of fullMessage: FullMessage) {
    let message = fullMessage.message
    guard let forwardedMessageId = message.forwardFromMessageId else { return }

    var forwardPeer: Peer?
    if let peerUserId = message.forwardFromPeerUserId {
      let currentUserId = Auth.shared.getCurrentUserId()
      if let senderId = message.forwardFromUserId, senderId != currentUserId {
        forwardPeer = .user(id: senderId)
      } else {
        forwardPeer = .user(id: peerUserId)
      }
    } else if let threadId = message.forwardFromPeerThreadId {
      forwardPeer = .thread(id: threadId)
    }

    if fullMessage.forwardHeaderIsPrivate,
       let forwardPeer,
       let userId = forwardPeer.asUserId(),
       forwardPeer != message.peerId
    {
      NotificationCenter.default.post(
        name: Notification.Name("NavigateToForwardDestination"),
        object: nil,
        userInfo: ["peerUserId": userId]
      )
      return
    }

    if forwardPeer == nil || forwardPeer == message.peerId {
      NotificationCenter.default.post(
        name: Notification.Name("ScrollToRepliedMessage"),
        object: nil,
        userInfo: ["repliedToMessageId": forwardedMessageId, "chatId": message.chatId]
      )
      return
    }

    if let forwardPeer {
      var userInfo: [AnyHashable: Any] = ["messageId": forwardedMessageId]
      if let userId = forwardPeer.asUserId() {
        userInfo["peerUserId"] = userId
      }
      if let threadId = forwardPeer.asThreadId() {
        userInfo["peerThreadId"] = threadId
      }
      NotificationCenter.default.post(
        name: Notification.Name("NavigateToForwardedMessage"),
        object: nil,
        userInfo: userInfo
      )
    }
  }

  /// "Never show previews from this site", when the chat's space allows exclusions.
  static func neverShowPreviewAction(for attachment: FullAttachment, in message: Message) -> URLPreviewView.NeverShowPreviewAction? {
    guard let url = attachment.urlPreview?.openURL else { return nil }
    guard let context = SpaceUrlPreviewExclusionAccess.context(peer: message.peerId, url: url) else { return nil }
    let peerId = message.peerId
    let messageId = message.messageId
    return URLPreviewView.NeverShowPreviewAction(host: context.pattern.host) {
      Task {
        do {
          _ = try await Api.realtime.send(.addSpaceUrlPreviewExclusion(
            spaceId: context.spaceId,
            host: context.pattern.host,
            pathPrefix: nil,
            peerId: peerId,
            messageId: messageId
          ))
        } catch {
          Log.shared.error("Failed to exclude URL preview host", error: error)
          await MainActor.run {
            ToastManager.shared.showToast("Update failed", type: .error, systemImage: "exclamationmark.triangle")
          }
        }
      }
    }
  }

  /// Removes a link preview from your own message.
  static func removeURLPreview(_ attachment: FullAttachment, from message: Message) {
    guard let attachmentId = attachment.attachment.attachmentId else {
      Log.shared.error("Missing URL preview attachment id for deletion")
      return
    }
    let peerId = message.peerId
    let messageId = message.messageId
    Task {
      do {
        _ = try await Api.realtime.send(.deleteMessageAttachment(
          peerId: peerId,
          messageId: messageId,
          attachmentId: attachmentId
        ))
      } catch {
        Log.shared.error("Failed to remove URL preview attachment", error: error)
        await MainActor.run {
          ToastManager.shared.showToast("Remove failed", type: .error, systemImage: "exclamationmark.triangle")
        }
      }
    }
  }

  /// The thread summary's long-press menu. Deleting a subthread stays in the current view's
  /// menu for now.
  static func threadSummaryMenu(for message: Message) -> UIMenu {
    let isDisabled = message.status == .sending || message.status == .failed
    let attributes: UIMenuElement.Attributes = isDisabled ? [.disabled] : []
    return UIMenu(children: [
      UIAction(
        title: message.isSubthreadPlacement ? "Open Subthread" : "Open Thread",
        image: UIImage(systemName: "arrow.turn.down.right"),
        attributes: attributes
      ) { _ in ReplyThreadNavigator.open(message: message, source: .menu) },
      UIAction(title: "Copy Link", image: UIImage(systemName: "link"), attributes: attributes) { _ in
        ReplyThreadNavigator.copyLink(message: message)
      },
      UIAction(
        title: "Open",
        subtitle: "Add to Open Chats",
        image: UIImage(systemName: "tray.and.arrow.down"),
        attributes: attributes
      ) { _ in ReplyThreadNavigator.addToInbox(message: message) },
    ])
  }

  /// Scrolls to the message a reply quotes.
  static func openRepliedMessage(of message: Message) {
    guard let repliedId = message.repliedToMessageId else { return }
    NotificationCenter.default.post(
      name: Notification.Name("ScrollToRepliedMessage"),
      object: nil,
      userInfo: ["repliedToMessageId": repliedId, "chatId": message.chatId]
    )
  }

  /// Loads a quoted message that isn't in the local database yet.
  static func fetchRepliedMessageIfNeeded(for message: Message) {
    guard let repliedId = message.repliedToMessageId, repliedId > 0 else { return }
    let peer = message.peerId
    let chatId = message.chatId
    Task.detached(priority: .utility) {
      await TargetMessagesFetcher.shared.ensureCachedOnce(peer: peer, chatId: chatId, messageIds: [repliedId])
    }
  }

  static func toggleAcknowledgement(on message: FullMessage) {
    guard let action = message.acknowledgementAction(currentUserId: Auth.shared.getCurrentUserId()) else { return }
    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    let target = message
    Task {
      do {
        try await Api.realtime.send(.acknowledgeMessages(message: target, action: action))
      } catch {
        Log.scoped("Acknowledgement").error("Failed to update Ack", error: error)
        ToastManager.shared.showToast("Could not update Ack", type: .error, systemImage: "exclamationmark.triangle.fill")
      }
    }
  }

  static func perform(
    _ action: MessageGestureAction,
    on message: FullMessage,
    onReactionsMenu: ((FullMessage) -> Void)?
  ) {
    switch action {
    case .none:
      return
    case .toggleAck:
      toggleAcknowledgement(on: message)
    case .reply:
      guard message.canReply else { return }
      UIImpactFeedbackGenerator(style: .medium).impactOccurred()
      ChatState.shared.setReplyingMessageId(peer: message.message.peerId, id: message.message.messageId)
    case .reactionsMenu:
      onReactionsMenu?(message)
    case .toggleHeart, .toggleThumbsUp:
      guard let baseEmoji = action.reactionEmoji else { return }
      UIImpactFeedbackGenerator(style: .medium).impactOccurred()
      toggleReaction(EmojiSkinTonePreferenceStore.current().applying(to: baseEmoji), on: message)
    }
  }

  // MARK: - Helpers

  private static func openUser(_ userId: Int64, agentId: Int64?, peer: Peer) {
    guard let agentId else {
      NotificationCenter.default.post(name: Notification.Name("MentionTapped"), object: nil, userInfo: ["userId": userId])
      return
    }
    Task { @MainActor in
      guard !(await BotAgentMentionNavigator.open(agentId: agentId, botUserId: userId, peer: peer)) else { return }
      NotificationCenter.default.post(name: Notification.Name("MentionTapped"), object: nil, userInfo: ["userId": userId])
    }
  }

  private static func copy(_ string: String, toast: String) {
    UIPasteboard.general.string = string
    ToastManager.shared.showToast(toast, type: .success, systemImage: "doc.on.doc")
  }

  private static func sendBotCommand(_ command: String, message: FullMessage) {
    var entity = MessageEntity()
    entity.type = .botCommand
    entity.offset = 0
    entity.length = Int64((command as NSString).length)
    var entities = MessageEntities()
    entities.entities = [entity]
    Task {
      do {
        try await Api.realtime.send(.sendMessage(
          text: command,
          peerId: message.message.peerId,
          chatId: message.message.chatId,
          replyToMsgId: nil,
          isSticker: nil,
          entities: entities
        ))
      } catch {
        ToastManager.shared.showToast("Failed to send command", type: .error, systemImage: "exclamationmark.triangle.fill")
      }
    }
  }

  static func linkURL(in text: NSAttributedString, at index: Int) -> URL? {
    guard index >= 0, index < text.length,
          text.attribute(.mentionUserId, at: index, effectiveRange: nil) == nil
    else { return nil }
    let value = text.attribute(.link, at: index, effectiveRange: nil)
    if let url = value as? URL {
      return LinkDetector.isSupportedLinkURL(url) ? url : nil
    }
    guard let string = value as? String else { return nil }
    if let url = URL(string: string), LinkDetector.isSupportedLinkURL(url) {
      return url
    }
    guard !string.contains("://"),
          let url = URL(string: "https://\(string)"),
          let scheme = url.scheme?.lowercased(),
          ["http", "https"].contains(scheme)
    else { return nil }
    return url
  }

  private static func inlineMentionTarget(from url: URL) -> (userId: Int64, agentId: Int64?)? {
    guard url.scheme?.lowercased() == "inline", url.host?.lowercased() == "user" else { return nil }
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    let agentId = items.first { $0.name.lowercased() == "agent_id" }?.value.flatMap(Int64.init).flatMap { $0 > 0 ? $0 : nil }
    let queryId = items.first { ["id", "user_id"].contains($0.name.lowercased()) }?.value
    if let queryId, let userId = Int64(queryId), userId > 0 {
      return (userId, agentId)
    }
    guard let last = url.pathComponents.last, let userId = Int64(last), userId > 0 else { return nil }
    return (userId, agentId)
  }
}
