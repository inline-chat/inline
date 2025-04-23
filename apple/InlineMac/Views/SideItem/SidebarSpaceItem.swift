import InlineKit
import InlineUI
import SwiftUI

struct SidebarSpaceItem: View {
  // MARK: - Props

  var space: Space

  // MARK: - State

  @EnvironmentObject var dataManager: DataManager
  @EnvironmentObject var nav: Nav

  @State private var alertPresented: Bool = false
  @State private var pendingAction: Action?
  @State private var isHovered: Bool = false

  // MARK: - Views

  var body: some View {
    let view = SidebarItem(
      type: .space(space),
      dialog: nil,
      lastMessage: nil,
      selected: false,
      onPress: {
        nav.openSpace(space.id)
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
      Text("Confirm you want to \(actionText(action).lowercased()) this space")
    })

    // Actions on space
    .contextMenu {
      // Only creators can delete space for now
      if let creator = space.creator, creator == true {
        Button("Delete Space", role: .destructive) {
          act(.delete)
        }
      } else {
        Button("Leave Space", role: .destructive) {
          act(.leave)
        }
      }
    }
    .contentShape(.focusEffect, .rect)

    if #available(macOS 14, *) {
      view
    } else {
      view
    }
  }

  func actionText(_ action: Action) -> String {
    action == .delete ? "Delete" : "Leave"
  }

  enum Action {
    case delete
    case leave
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
            navigateOutOfSpace()
            try await dataManager.deleteSpace(spaceId: space.id)
          } else {
            startPendingAct(action)
          }
        case .leave:
          if pendingAction == action {
            navigateOutOfSpace()
            try await dataManager.leaveSpace(spaceId: space.id)
          } else {
            startPendingAct(action)
          }
      }
    }
  }

  private func navigateOutOfSpace() {
    if nav.currentSpaceId == space.id {
      nav.openHome()
    }
  }
}

#Preview {
  SidebarSpaceItem(space: Space(name: "Space Name", date: Date()))
    .frame(width: 200)
    .previewsEnvironment(.populated)
}
