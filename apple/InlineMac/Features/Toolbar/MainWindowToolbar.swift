import AppKit
import InlineKit
import SwiftUI

@MainActor
struct MainWindowToolbar: ToolbarContent {
  let nav: Nav3

  var body: some ToolbarContent {
    ToolbarItem(placement: .navigation) {
      BackForwardToolbarButtons(nav: nav)
        .toolbarVisibilityPriority(.low, label: "Back/Forward")
    }
  }
}

@MainActor
private struct BackForwardToolbarButtons: View {
  let nav: Nav3

  var body: some View {
    ControlGroup {
      BackNavigationHistoryButton(nav: nav)
      ForwardNavigationHistoryButton(nav: nav)
    }
    .controlGroupStyle(.navigation)
  }
}

@MainActor
private struct BackNavigationHistoryButton: View {
  let nav: Nav3

  var body: some View {
    NavigationHistoryButton(nav: nav, direction: .back)
  }
}

@MainActor
private struct ForwardNavigationHistoryButton: View {
  let nav: Nav3

  var body: some View {
    NavigationHistoryButton(nav: nav, direction: .forward)
  }
}

@MainActor
private struct NavigationHistoryButton: View {
  let nav: Nav3
  let direction: NavigationHistoryDirection

  var body: some View {
    Menu {
      NavigationHistoryMenuItems(nav: nav, direction: direction)
    } label: {
      Label(direction.title, systemImage: direction.systemImage)
        .labelStyle(.iconOnly)
    } primaryAction: {
      direction.go(nav)
    }
    .menuIndicator(.hidden)
    .disabled(direction.isEnabled(nav) == false)
  }
}

@MainActor
private struct NavigationHistoryMenuItems: View {
  let nav: Nav3
  let direction: NavigationHistoryDirection

  var body: some View {
    ForEach(direction.items(nav)) { item in
      NavigationHistoryMenuItemButton(nav: nav, item: item)
    }
    .labelStyle(.titleAndIcon)
  }
}

@MainActor
private struct NavigationHistoryMenuItemButton: View {
  let nav: Nav3
  let item: Nav3HistoryMenuItem

  var body: some View {
    Button {
      nav.go(to: item)
    } label: {
      let label = NavHistoryMenuLabel.label(for: item.state)
      Label {
        Text(label.title)
      } icon: {
        if let image = label.image {
          Image(nsImage: image)
            .renderingMode(.original)
        } else {
          Image(systemName: label.systemImage)
        }
      }
    }
  }
}

@MainActor
private enum NavigationHistoryDirection {
  case back
  case forward

  var title: String {
    switch self {
    case .back:
      "Go Back"
    case .forward:
      "Go Forward"
    }
  }

  var systemImage: String {
    switch self {
    case .back:
      "chevron.left"
    case .forward:
      "chevron.right"
    }
  }

  func isEnabled(_ nav: Nav3) -> Bool {
    switch self {
    case .back:
      nav.canGoBack
    case .forward:
      nav.canGoForward
    }
  }

  func go(_ nav: Nav3) {
    switch self {
    case .back:
      nav.goBack()
    case .forward:
      nav.goForward()
    }
  }

  func items(_ nav: Nav3) -> [Nav3HistoryMenuItem] {
    switch self {
    case .back:
      nav.backHistoryMenuItems
    case .forward:
      nav.forwardHistoryMenuItems
    }
  }
}

@MainActor
private enum NavHistoryMenuLabel {
  private static let maxThreadTitleLength = 24
  private static let truncationSuffix = "..."

  static func label(for state: Nav3RouteState) -> (title: String, systemImage: String, image: NSImage?) {
    let systemImage = systemImage(for: state.route)
    return (
      title: title(for: state),
      systemImage: systemImage,
      image: image(for: state.route)
    )
  }

  static func title(for state: Nav3RouteState) -> String {
    title(for: state.route, selectedSpaceId: state.selectedSpaceId)
  }

  private static func title(for route: Nav3Route, selectedSpaceId: Int64?) -> String {
    let spaceName = selectedSpaceId.flatMap { ObjectCache.shared.getCachedSpace(id: $0)?.displayName }

    switch route {
    case .empty:
      return spaceName ?? "Home"

    case .allChats:
      return spaceName.map { "\($0) Chats" } ?? "Chats"

    case .archivedChats:
      return spaceName.map { "Archived \($0) Chats" } ?? "Archived Chats"

    case let .chat(peer):
      return threadMenuTitle(peerTitle(peer), for: peer)

    case let .chatInfo(peer, query):
      return threadMenuTitle("\(peerTitle(peer)) \(chatInfoTitle(query))", for: peer)

    case let .profile(userId):
      return ObjectCache.shared.getCachedUser(id: userId)?.user.displayName ?? "Profile"

    case .createSpace:
      return "Create Space"

    case .newChat:
      return "New Chat"

    case .inviteToSpace:
      return "Invite to Space"

    case let .members(spaceId):
      return spaceRouteTitle(spaceId: spaceId, suffix: "Members", fallback: "Members")

    case let .spaceSettings(spaceId):
      return spaceRouteTitle(spaceId: spaceId, suffix: "Settings", fallback: "Space Settings")

    case let .spaceIntegrations(spaceId):
      return spaceRouteTitle(spaceId: spaceId, suffix: "Integrations", fallback: "Space Integrations")
    }
  }

  private static func systemImage(for route: Nav3Route) -> String {
    switch route {
    case .empty:
      return "house"

    case .allChats:
      return "text.bubble"

    case .archivedChats:
      return "archivebox"

    case let .chat(peer):
      return peerSystemImage(peer)

    case let .chatInfo(_, query):
      return chatInfoSystemImage(query)

    case let .profile(userId):
      guard let userInfo = ObjectCache.shared.getCachedUser(id: userId) else {
        return "person.crop.circle"
      }
      return userInfo.user.isCurrentUser() ? "bookmark.fill" : "person.crop.circle"

    case .createSpace:
      return "plus.square.on.square"

    case .newChat:
      return "square.and.pencil"

    case .inviteToSpace:
      return "person.badge.plus"

    case .members:
      return "person.2"

    case .spaceSettings:
      return "gearshape"

    case .spaceIntegrations:
      return "puzzlepiece"
    }
  }

  private static func peerTitle(_ peer: Peer) -> String {
    switch peer {
    case let .user(id):
      guard let userInfo = ObjectCache.shared.getCachedUser(id: id) else {
        return "Direct Message"
      }
      return userInfo.user.isCurrentUser() ? "Saved Messages" : userInfo.user.displayName

    case let .thread(id):
      guard let chat = ObjectCache.shared.getCachedChat(id: id) else {
        return "Chat"
      }
      return ReplyThreadTitleFallback.title(for: chat, anchorText: nil)
    }
  }

  private static func threadMenuTitle(_ title: String, for peer: Peer) -> String {
    guard case .thread = peer else { return title }
    return truncatedThreadTitle(title)
  }

  private static func truncatedThreadTitle(_ title: String) -> String {
    guard title.count > maxThreadTitleLength else { return title }
    return String(title.prefix(maxThreadTitleLength - truncationSuffix.count)) + truncationSuffix
  }

  private static func peerSystemImage(_ peer: Peer) -> String {
    switch peer {
    case let .user(id):
      guard let userInfo = ObjectCache.shared.getCachedUser(id: id) else {
        return "person.crop.circle"
      }
      return userInfo.user.isCurrentUser() ? "bookmark.fill" : "person.crop.circle"

    case let .thread(id):
      guard let chat = ObjectCache.shared.getCachedChat(id: id) else {
        return "bubble.left.fill"
      }
      return ThreadIconSymbol.name(isReplyThread: chat.isReplyThread)
    }
  }

  private static func chatInfoTitle(_ query: Nav3Route.ChatInfoQuery?) -> String {
    switch query {
    case .files:
      "Files"
    case .media:
      "Media"
    case .links:
      "Links"
    case .participants:
      "Participants"
    case nil:
      "Info"
    }
  }

  private static func chatInfoSystemImage(_ query: Nav3Route.ChatInfoQuery?) -> String {
    switch query {
    case .files:
      "folder"
    case .media:
      "photo.on.rectangle"
    case .links:
      "link"
    case .participants:
      "person.2"
    case nil:
      "info.circle"
    }
  }

  private static func spaceRouteTitle(spaceId: Int64, suffix: String, fallback: String) -> String {
    guard let space = ObjectCache.shared.getCachedSpace(id: spaceId) else {
      return fallback
    }
    return "\(space.displayName) \(suffix)"
  }

  private static func image(for route: Nav3Route) -> NSImage? {
    guard let peer = peerType(for: route) else { return nil }
    return MenuIcon.image(for: peer)
  }

  private static func peerType(for route: Nav3Route) -> ChatIcon.PeerType? {
    switch route {
    case let .chat(peer), let .chatInfo(peer, _):
      return peerType(for: peer)

    case let .profile(userId):
      guard let userInfo = ObjectCache.shared.getCachedUser(id: userId) else {
        return nil
      }
      return .user(userInfo)

    default:
      return nil
    }
  }

  private static func peerType(for peer: Peer) -> ChatIcon.PeerType? {
    switch peer {
    case let .user(id):
      guard let userInfo = ObjectCache.shared.getCachedUser(id: id) else {
        return nil
      }
      return userInfo.user.isCurrentUser() ? .savedMessage(userInfo.user) : .user(userInfo)

    case let .thread(id):
      guard let chat = ObjectCache.shared.getCachedChat(id: id) else {
        return nil
      }
      return .chat(chat)
    }
  }
}
