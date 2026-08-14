import Foundation
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

struct InviteRouteView: View {
  let sessionID: UUID
  let spaceId: Int64?
  let stage: InviteFlowStage

  @Environment(\.nav) private var nav
  @Environment(\.dependencies) private var dependencies

  @ViewBuilder
  var body: some View {
    if let session = nav.inviteSession(id: sessionID) {
      InviteView(
        session: session,
        stage: stage,
        onContinue: {
          nav.open(
            .inviteReview(sessionID: sessionID, spaceId: spaceId),
            tracksChatNavigation: false
          )
        },
        onShowOutcome: {
          nav.replace(.inviteOutcome(sessionID: sessionID, spaceId: spaceId))
        },
        onInviteMore: {
          if nav.canGoBack {
            nav.goBack()
          } else {
            nav.replace(.invite(sessionID: sessionID, spaceId: spaceId))
          }
        },
        onManageMembers: { destinationSpaceID in
          if let nav2 = dependencies?.nav2 {
            nav2.navigate(to: .members(spaceId: destinationSpaceID))
          } else {
            nav.open(.members(spaceId: destinationSpaceID))
          }
        },
        onOpenChat: { peer in
          if let dependencies {
            dependencies.openChatRoute(peer: peer)
          } else {
            nav.open(.chat(peer: peer))
          }
        }
      )
    } else {
      RoutePlaceholderView(
        title: "Start a new invitation",
        systemImage: "person.badge.plus"
      )
      .task {
        nav.beginInvite(spaceId: spaceId)
      }
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
