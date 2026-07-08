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
    case alreadyOpening
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

    Task { @MainActor in
      do {
        let peer = try await resolveThreadPeer(message: message, source: source, setLoading: setLoading)
        navigate(to: peer)
      } catch OpenError.alreadyOpening {
        return
      } catch {
        ToastManager.shared.showToast(
          "Failed to open thread",
          type: .error,
          systemImage: "exclamationmark.triangle"
        )
        log.error("Failed to open reply thread", error: error)
      }
    }
  }

  static func copyLink(message: Message) {
    guard message.status != .sending, message.status != .failed else { return }

    Task { @MainActor in
      do {
        let peer = try await resolveThreadPeer(message: message, source: .menu)
        guard let url = deepLinkURL(for: peer) else {
          throw OpenError.invalidResponse
        }

        UIPasteboard.general.string = url.absoluteString
        ToastManager.shared.showToast(
          "Copied link",
          type: .success,
          systemImage: "doc.on.doc"
        )
      } catch OpenError.alreadyOpening {
        return
      } catch {
        ToastManager.shared.showToast(
          "Failed to copy link",
          type: .error,
          systemImage: "exclamationmark.triangle"
        )
        log.error("Failed to copy reply thread link", error: error)
      }
    }
  }

  static func addToInbox(message: Message) {
    guard message.status != .sending, message.status != .failed else { return }

    Task { @MainActor in
      do {
        let peer = try await resolveThreadPeer(message: message, source: .menu)
        ToastManager.shared.hideToast()
        ToastManager.shared.showToast(
          "Adding to inbox...",
          type: .loading,
          systemImage: "tray.and.arrow.down"
        )

        _ = try await Api.realtime.send(.updateDialogFollowMode(peerId: peer, selection: .following))
        _ = try await Api.realtime.send(.showInChatList(peerId: peer))
        _ = try await Api.realtime.send(.updateDialogOpen(peerId: peer, open: true))

        ToastManager.shared.hideToast()
        ToastManager.shared.showToast(
          "Added to inbox",
          type: .success,
          systemImage: "tray.and.arrow.down.fill"
        )
      } catch OpenError.alreadyOpening {
        return
      } catch {
        ToastManager.shared.hideToast()
        ToastManager.shared.showToast(
          "Failed to add to inbox",
          type: .error,
          systemImage: "exclamationmark.triangle"
        )
        log.error("Failed to add reply thread to inbox", error: error)
      }
    }
  }

  private static func resolveThreadPeer(
    message: Message,
    source: Source,
    setLoading: ((Bool) -> Void)? = nil
  ) async throws -> Peer {
    guard message.status != .sending, message.status != .failed else {
      throw OpenError.invalidResponse
    }

    if let peer = message.replyThreadPeer {
      return peer
    }

    let key = MessageKey(chatId: message.chatId, messageId: message.messageId)
    guard !openingMessages.contains(key) else { throw OpenError.alreadyOpening }
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

    defer {
      openingMessages.remove(key)
      setLoading?(false)
      if showsToast {
        ToastManager.shared.hideToast()
      }
    }

    let result = try await Api.realtime.send(
      .createSubthread(
        parentChatId: message.chatId,
        parentMessageId: message.messageId
      )
    )

    guard case let .createSubthread(response) = result, response.hasChat else {
      throw OpenError.invalidResponse
    }

    return .thread(id: response.chat.id)
  }

  private static func deepLinkURL(for peer: Peer) -> URL? {
    switch peer {
    case let .user(id):
      InlineDeepLink.user(id: id).url
    case let .thread(id):
      InlineDeepLink.chat(id: id).url
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
