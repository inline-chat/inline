import Auth
import InlineKit
import Logger
import UIKit

extension Notification.Name {
  static let navigateToThreadLink = Notification.Name("NavigateToThreadLink")
}

@MainActor
enum ThreadLinkNavigator {
  private static let log = Log.scoped("ThreadLinkNavigator")

  static func open(target: ThreadLinkTarget) {
    if let peer = target.directPeer {
      navigate(to: peer)
      return
    }

    Task { @MainActor in
      do {
        guard let peer = try await ThreadLinkResolver.resolveOrCreate(
          target,
          currentUserId: Auth.shared.getCurrentUserId()
        ) else {
          ToastManager.shared.showToast(
            "Thread not found",
            type: .error,
            systemImage: "exclamationmark.triangle"
          )
          return
        }

        navigate(to: peer)
      } catch ThreadLinkResolver.Error.missingCurrentUser {
        ToastManager.shared.showToast(
          "You're signed out. Please log in again.",
          type: .error,
          systemImage: "exclamationmark.triangle"
        )
      } catch {
        ToastManager.shared.showToast(
          "Failed to open thread",
          type: .error,
          systemImage: "exclamationmark.triangle"
        )
        log.error("Failed to resolve thread link", error: error)
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
      name: .navigateToThreadLink,
      object: nil,
      userInfo: userInfo
    )
  }
}
