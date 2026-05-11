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
        if let dependencies {
          dependencies.requestOpenChat(peer: .thread(id: chatId))
        } else {
          nav.open(.chat(peer: .thread(id: chatId)))
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
    if let spaceId {
      InviteToSpaceView(
        spaceId: spaceId,
        onManageMembers: {
          if let nav2 = dependencies?.nav2 {
            nav2.navigate(to: .members(spaceId: spaceId))
          } else {
            nav.open(.members(spaceId: spaceId))
          }
        }
      )
    } else {
      RoutePlaceholderView(
        title: "Open a space to invite members",
        systemImage: "person.badge.plus"
      )
    }
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
