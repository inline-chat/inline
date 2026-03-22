import InlineKit
import InlineProtocol
import Logger
import SwiftUI

enum Route {
  case createNewChat
  case visibility
  case selectParticipants
}

enum ChatType {
  case `public`
  case `private`
}

struct CreateChatView: View {
  @State private var selectedRoute: Route = .createNewChat
  @State private var text = ""
  @State private var emoji = ""
  @State private var selectedChatType: ChatType = .public
  @State private var selectedSpaceId: Int64?
  @State private var selectedParticipants: Set<Int64> = []
  @State private var selectedSpaceName: String?
  @FormState var formState

  @Environment(\.auth) var auth
  @Environment(\.realtimeV2) var realtimeV2
  @EnvironmentStateObject private var spaceViewModel: FullSpaceViewModel

  @Environment(Router.self) private var router

  var spaceId: Int64?

  init(spaceId: Int64? = nil) {
    self.spaceId = spaceId
    _spaceViewModel = EnvironmentStateObject { env in
      FullSpaceViewModel(db: env.appDatabase, spaceId: spaceId ?? 0)
    }
  }

  var navigationTitle: String {
    switch selectedRoute {
      case .createNewChat:
        "Create New Chat"
      case .visibility:
        "Visibility"
      case .selectParticipants:
        selectedParticipants
          .count > 0 ?
          "\(selectedParticipants.count) \(selectedParticipants.count == 1 ? "participant" : "participants")" :
          "Select Participants"
      default:
        "Create Chat"
    }
  }

  var body: some View {
    Group {
      Form {
        switch selectedRoute {
          case .createNewChat:
            CreateNewChatView(
              text: $text,
              emoji: $emoji,
              selectedRoute: $selectedRoute,
              spaceId: spaceId,
              selectedSpaceId: $selectedSpaceId,
              selectedSpaceName: $selectedSpaceName
            )
          case .visibility:
            VisibilityView(
              selectedChatType: $selectedChatType,
              selectedRoute: $selectedRoute,
              selectedSpaceName: $selectedSpaceName,
              formState: formState,
              createChat: createChat
            )
          case .selectParticipants:
            SelectParticipantsView(
              selectedParticipants: $selectedParticipants,
              spaceId: selectedSpaceId ?? spaceId ?? 0,
              selectedRoute: $selectedRoute,
              formState: formState,
              createChat: createChat
            )
        }
      }
    }
    .navigationTitle(navigationTitle)
    .hideTabBarIfNeeded()
  }

  private func createChat() {
    Task {
      do {
        guard let currentUserId = auth.currentUserId else {
          formState.failed(error: "You're signed out. Please log in again.")
          return
        }

        formState.startLoading()
        // For public threads the server requires an empty participants list
        var participants: [Int64] = selectedChatType == .public ? [] : selectedParticipants.map(\.self)
        if selectedChatType == .private, participants.isEmpty {
          participants = [currentUserId]
        }

        let chatId = try await realtimeV2.createThreadLocally(
          title: text,
          emoji: emoji.isEmpty ? nil : emoji,
          isPublic: selectedChatType == .public,
          spaceId: selectedSpaceId ?? spaceId ?? 0,
          participants: participants
        )

        formState.succeeded()
        router.popToRoot()
        router.push(.chat(peer: .thread(id: chatId)))
      } catch {
        formState.failed(error: error.localizedDescription)
        Log.shared.error("Failed to create chat", error: error)
      }
    }
  }
}

#Preview {
  CreateChatView(spaceId: nil)
}
