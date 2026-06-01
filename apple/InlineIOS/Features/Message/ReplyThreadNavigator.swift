import InlineKit
import Logger
import UIKit

extension Notification.Name {
  static let navigateToReplyThread = Notification.Name("NavigateToReplyThread")
}

@MainActor
enum ReplyThreadNavigator {
  enum Source {
    case menu
    case summary
  }

  private enum OpenError: Error {
    case invalidResponse
  }

  private struct MessageKey: Hashable {
    let chatId: Int64
    let messageId: Int64
  }

  private static let log = Log.scoped("ReplyThreadNavigator")
  private static var openingMessages = Set<MessageKey>()

  static func open(
    message: Message,
    source: Source,
    setLoading: ((Bool) -> Void)? = nil
  ) {
    guard message.status != .sending, message.status != .failed else { return }

    if let peer = message.replyThreadPeer {
      navigate(to: peer)
      return
    }

    let key = MessageKey(chatId: message.chatId, messageId: message.messageId)
    guard !openingMessages.contains(key) else { return }
    openingMessages.insert(key)

    let showsToast = source == .menu || setLoading == nil
    if showsToast {
      ToastManager.shared.hideToast()
      ToastManager.shared.showToast(
        "Creating thread...",
        type: .loading,
        systemImage: "bubble.left.and.bubble.right"
      )
    }
    setLoading?(true)

    Task { @MainActor in
      defer {
        openingMessages.remove(key)
        setLoading?(false)
      }

      do {
        let result = try await Api.realtime.send(
          .createSubthread(
            parentChatId: message.chatId,
            parentMessageId: message.messageId
          )
        )

        guard case let .createSubthread(response) = result, response.hasChat else {
          throw OpenError.invalidResponse
        }

        if showsToast {
          ToastManager.shared.hideToast()
        }
        navigate(to: .thread(id: response.chat.id))
      } catch {
        if showsToast {
          ToastManager.shared.hideToast()
        }
        ToastManager.shared.showToast(
          "Failed to open thread",
          type: .error,
          systemImage: "exclamationmark.triangle"
        )
        log.error("Failed to open reply thread", error: error)
      }
    }
  }

  private static func navigate(to peer: Peer) {
    var userInfo: [AnyHashable: Any] = [:]
    if let userId = peer.asUserId() {
      userInfo["peerUserId"] = userId
    }
    if let threadId = peer.asThreadId() {
      userInfo["peerThreadId"] = threadId
    }

    NotificationCenter.default.post(
      name: .navigateToReplyThread,
      object: nil,
      userInfo: userInfo
    )
  }
}
