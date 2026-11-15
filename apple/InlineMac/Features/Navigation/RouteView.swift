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
      // With the stable route, one chat route view (and its toolbar items) survives chat switches and
      // swaps the chat inside it; otherwise every chat rebuilds the route from scratch.
      ChatRouteView(peer: peer)
        .id(settings.stableChatRouteEnabled ? "chat-route" : peer.toString())

    case let .chatInfo(peer, query):
      ChatInfoRouteView(peer: peer, query: query)

    case let .profile(userId):
      ProfileRouteView(userId: userId)

    case .createSpace:
      CreateSpaceRouteView()

    case let .newChat(spaceId):
      NewChatRouteView(spaceId: spaceId)

    case let .invite(sessionID, spaceId):
      InviteRouteView(sessionID: sessionID, spaceId: spaceId, stage: .selection)

    case let .inviteReview(sessionID, spaceId):
      InviteRouteView(sessionID: sessionID, spaceId: spaceId, stage: .review)

    case let .inviteOutcome(sessionID, spaceId):
      InviteRouteView(sessionID: sessionID, spaceId: spaceId, stage: .outcome)

    case let .members(spaceId):
      MembersRouteView(spaceId: spaceId)

    case let .spaceSettings(spaceId):
      SpaceSettingsRouteView(spaceId: spaceId)

    case let .spaceIntegrations(spaceId):
      SpaceIntegrationsRouteView(spaceId: spaceId)

    case let .grid(spaceId):
      GridView(spaceID: spaceId)
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
