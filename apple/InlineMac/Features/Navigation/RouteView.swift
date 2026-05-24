import InlineKit
import SwiftUI

struct RouteView: View {
  @Environment(\.nav) private var nav
  @ObservedObject private var settings = AppSettings.shared

  let route: Nav3Route

  var body: some View {
    switch route {
    case .empty:
      EmptyRouteView()

    case .allChats:
      if settings.sidebarAsInbox {
        AllChatsRouteView()
      } else {
        disabledExperimentalRoute
      }

    case .archivedChats:
      if settings.sidebarAsInbox {
        AllChatsRouteView(archived: true)
      } else {
        disabledExperimentalRoute
      }

    case let .chat(peer):
      ChatRouteView(peer: peer)
        .id(peer.toString())

    case let .chatInfo(peer, query):
      ChatInfoRouteView(peer: peer, query: query)

    case let .profile(userId):
      ProfileRouteView(userId: userId)

    case .createSpace:
      CreateSpaceRouteView()

    case let .newChat(spaceId):
      NewChatRouteView(spaceId: spaceId)

    case let .inviteToSpace(spaceId):
      InviteToSpaceRouteView(spaceId: spaceId)

    case let .members(spaceId):
      MembersRouteView(spaceId: spaceId)

    case let .spaceSettings(spaceId):
      SpaceSettingsRouteView(spaceId: spaceId)

    case let .spaceIntegrations(spaceId):
      SpaceIntegrationsRouteView(spaceId: spaceId)
    }
  }

  private var disabledExperimentalRoute: some View {
    Color.clear
      .task { @MainActor in
        guard settings.sidebarAsInbox == false else { return }
        nav.replace(.empty)
      }
  }
}
