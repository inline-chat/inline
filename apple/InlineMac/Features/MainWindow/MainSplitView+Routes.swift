import AppKit
import InlineKit
import SwiftUI

extension MainSplitView {
  func viewController(for route: Nav2Route) -> NSViewController {
    switch route {
      case .empty:
        return PlaceholderContentViewController(message: "Select a chat to get started")

      case let .chat(peer):
        return ChatViewAppKit(peerId: peer, dependencies: dependencies)

      case let .chatInfo(peer):
        return NSHostingController(
          rootView: ChatInfo(peerId: peer)
            .environment(dependencies: dependencies)
        )

      case let .profile(userId):
        if let userInfo = ObjectCache.shared.getUser(id: userId) {
          return NSHostingController(
            rootView: UserProfile(userInfo: userInfo)
              .environment(dependencies: dependencies)
          )
        }
        return PlaceholderContentViewController(message: "Profile unavailable")

      case .createSpace:
        return CreateSpaceViewController(dependencies: dependencies)

      case .newChat:
        if let spaceId = dependencies.nav2?.activeSpaceId {
          return NewChatViewController(spaceId: spaceId, dependencies: dependencies)
        }
        return PlaceholderContentViewController(message: "Open a space to start a chat")

      case .inviteToSpace:
        if let spaceId = dependencies.nav2?.activeSpaceId {
          return InviteToSpaceViewController(spaceId: spaceId, dependencies: dependencies)
        }
        return PlaceholderContentViewController(message: "Open a space to invite members")
    }
  }

  func toolbar(for route: Nav2Route) -> MainToolbarItems {
    switch route {
      case let .chat(peer):
        MainToolbarItems(
          items: [
            .navigationBack,
            .navigationForward,
            .chatTitle(peer: peer),
            .spacer,
            .participants(peer: peer),
            .translationIcon(peer: peer),
          ],
        )

      default:
        // TODO: Show a basic toolbar with undo redo and a title
        MainToolbarItems.defaultItems()
    }
  }
}
