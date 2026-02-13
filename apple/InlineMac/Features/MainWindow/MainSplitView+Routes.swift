import AppKit
import InlineKit
import SwiftUI

extension MainSplitView {
  func viewController(for route: Nav2Route) -> NSViewController {
    switch route {
      case .empty:
        return PlaceholderContentViewController(message: nil)

      case .spaces:
        return PlaceholderContentViewController(message: nil)

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

      case let .members(spaceId):
        return MemberManagementViewController(spaceId: spaceId, dependencies: dependencies)

      case let .spaceIntegrations(spaceId):
        return SpaceIntegrationsViewController(spaceId: spaceId, dependencies: dependencies)
    }
  }

  func toolbar(for route: Nav2Route) -> MainToolbarItems {
    switch route {
      case let .chat(peer):
        var items: [MainToolbarItemIdentifier] = [
          .navigationButtons,
          .chatTitle(peer: peer),
          .spacer,
          .notifications(peer: peer),
          .participants(peer: peer),
        ]

        if case .user = peer {
          items.append(.nudge(peer: peer))
        }

        if AppSettings.shared.translationUIEnabled {
          items.append(.translationIcon(peer: peer))
        }
        items.append(.menu(peer: peer))

        return MainToolbarItems(items: items)

      default:
        // TODO: Show a basic toolbar with undo redo and a title
        return MainToolbarItems.defaultItems()
    }
  }
}
