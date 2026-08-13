import InlineKit
import InlineUI
import Invite
import SwiftUI

struct CreateSpaceRouteView: View {
  @Environment(\.nav) private var nav

  var body: some View {
    CreateSpaceSwiftUI { spaceId in
      nav.selectSpace(spaceId)
      nav.replace(.empty)
    }
      .environmentObject(Nav.main)
  }
}

struct NewChatRouteView: View {
  let spaceId: Int64?

  @Environment(\.dependencies) private var dependencies
  @Environment(\.nav) private var nav

  var body: some View {
    if let spaceId {
      CreateChatView(spaceId: spaceId) { chatId in
        let peer: Peer = .thread(id: chatId)

        if let dependencies {
          Task {
            await dependencies.realtimeV2.sendQueued(.updateDialogOpen(peerId: peer, open: true))
          }
          dependencies.requestOpenChat(peer: peer)
        } else {
          nav.open(.chat(peer: peer))
        }
      }
    } else {
      RoutePlaceholderView(
        title: "Open a space to start a chat",
        systemImage: "square.and.pencil"
      )
    }
  }
}

struct InviteToSpaceRouteView: View {
  let spaceId: Int64?

  @Environment(\.nav) private var nav
  @Environment(\.dependencies) private var dependencies

  var body: some View {
    InviteView(
      destination: spaceId.map { .space(id: $0) } ?? .inline,
      onManageMembers: spaceId.map { _ in
        { destinationSpaceID in
          if let nav2 = dependencies?.nav2 {
            nav2.navigate(to: .members(spaceId: destinationSpaceID))
          } else {
            nav.open(.members(spaceId: destinationSpaceID))
          }
        }
      },
      onOpenChat: { peer in
        if let dependencies {
          dependencies.openChatRoute(peer: peer)
        } else {
          nav.open(.chat(peer: peer))
        }
      },
      onCreateSpace: {
        nav.open(.createSpace)
      }
    )
  }
}

struct MembersRouteView: View {
  let spaceId: Int64

  var body: some View {
    MemberManagementView(spaceId: spaceId)
      .environmentObject(Nav.main)
  }
}

struct SpaceSettingsRouteView: View {
  let spaceId: Int64

  @Environment(\.nav) private var nav

  var body: some View {
    SpaceSettingsView(
      spaceId: spaceId,
      onOpenIntegrations: {
        nav.open(.spaceIntegrations(spaceId: spaceId))
      },
      onOpenMembers: {
        nav.open(.members(spaceId: spaceId))
      },
      onExit: {
        nav.selectHome()
        nav.open(.empty)
      }
    )
    .environmentObject(Nav.main)
  }
}

struct SpaceIntegrationsRouteView: View {
  let spaceId: Int64

  var body: some View {
    SpaceIntegrationsView(spaceId: spaceId)
  }
}
