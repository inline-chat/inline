import InlineKit
import InlineUI
import Logger
import SwiftUI

struct SidebarThreadItem: View {
  // MARK: - Props

  var chat: Chat
  var dialog: Dialog?
  var lastMessage: Message?
  var lastMessageSender: UserInfo?
  var spaceName: String?

  // MARK: - State

  @EnvironmentObject var dataManager: DataManager
  @EnvironmentObject var nav: Nav
  @Environment(\.realtime) var realtime
  @Environment(\.realtimeV2) var realtimeV2

  @State private var alertPresented: Bool = false
  @State private var pendingAction: Action?
  @State private var isHovered: Bool = false

  // MARK: - Computed

  var isSelected: Bool {
    nav.currentRoute == .chat(peer: .thread(id: chat.id))
  }

  var peerId: Peer { .thread(id: chat.id) }

  // MARK: - Views

  var body: some View {
    let peerId: Peer = .thread(id: chat.id)
    let view = SidebarItem(
      type: .chat(chat, spaceName: spaceName),
      dialog: dialog,
      lastMessage: lastMessage,
      lastMessageSender: lastMessageSender,
      selected: isSelected,
      onPress: {
        nav.open(.chat(peer: peerId))
      },
    )

    // Alert for delete confirmation
    .alert("Are you sure?", isPresented: $alertPresented, presenting: pendingAction, actions: { action in
      Button(actionText(action), role: .destructive) {
        act(action)
      }
      Button("Cancel", role: .cancel) {
        pendingAction = nil
      }
    }, message: { action in
      Text("Confirm you want to \(actionText(action).lowercased()) this chat. This action cannot be undone.")
    })

    // Actions on space
    .contextMenu {
      // TODO: check if we are owner or admin in space
      // if let creator = space.creator, creator == true {

      Button("Delete Chat", role: .destructive) {
        act(.delete)
      }
    }
    .contentShape(.focusEffect, .rect)

    view
  }

  func actionText(_ action: Action) -> String {
    action == .delete ? "Delete" : "Leave"
  }

  enum Action {
    case delete

    // TODO:
    // case leave
  }

  // MARK: - Methods

  private func startPendingAct(_ action: Action) {
    pendingAction = action
    DispatchQueue.main.async {
      alertPresented = true
    }
  }

  private func act(_ action: Action) {
    Task {
      switch action {
        case .delete:
          if pendingAction == action {
            do {
              try await realtimeV2.send(.deleteChat(peerId: peerId))

              // Delete in local db
              if let dialog {
                try await dialog.deleteFromLocalDatabase()
              } else {
                try await chat.deleteFromLocalDatabase()
              }

              navigateOut()
            } catch {
              // Show alert
              Log.shared.error("Failed to delete chat", error: error)
              let alert = NSAlert()
              alert.alertStyle = .warning
              alert.messageText = "Failed to delete chat"
              alert.informativeText = "Error \(error.localizedDescription)"
              alert.addButton(withTitle: "OK")
              alert.runModal()
            }
          } else {
            startPendingAct(action)
          }
      }
    }
  }

  private func navigateOut() {
    if isSelected {
      nav.open(.empty) // TODO: replace route
    }
  }
}

#Preview {
  SidebarThreadItem(
    chat: .preview,
    dialog: .previewThread,
    lastMessage: .preview,
  )
  .frame(width: 200)
  .previewsEnvironment(.populated)
}
