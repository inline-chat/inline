import Auth
import InlineKit
import InlineUI
import Logger
import SwiftUI

struct SpaceView: View {
  var spaceId: Int64

  @Environment(\.appDatabase) var database
  @Environment(\.realtime) var realtime
  @EnvironmentObject var nav: Navigation
  @EnvironmentObject var data: DataManager

  @EnvironmentStateObject var fullSpaceViewModel: FullSpaceViewModel

  init(spaceId: Int64) {
    self.spaceId = spaceId
    _fullSpaceViewModel = EnvironmentStateObject { env in
      FullSpaceViewModel(db: env.appDatabase, spaceId: spaceId)
    }
  }

  @State var openCreateThreadSheet = false
  @State var openAddMemberSheet = false

  var currentUserMember: Member? {
    fullSpaceViewModel.members.first(where: { $0.userId == Auth.shared.getCurrentUserId() })
  }

  var isCreator: Bool {
    if currentUserMember?.role == .owner || currentUserMember?.role == .admin {
      true
    } else {
      false
    }
  }

  var body: some View {
    VStack {
      List {
        Section {
          ForEach(getCombinedItems(), id: \.id) { item in
            combinedItemRow(for: item)
              .listRowInsets(.init(
                top: 9,
                leading: 16,
                bottom: 2,
                trailing: 0
              ))
          }
        }
      }
      .listStyle(.plain)
      .animation(.default, value: fullSpaceViewModel.chats)
      .animation(.default, value: fullSpaceViewModel.memberChats)
    }
    .frame(maxWidth: .infinity)
    .navigationBarTitleDisplayMode(.large)
    .navigationTitle(fullSpaceViewModel.space?.name ?? "")
    .toolbarRole(.editor)
    .toolbar {
      Group {
        ToolbarItem(placement: .navigationBarTrailing) {
          Menu {
            Button(action: {
              openCreateThreadSheet = true
            }) {
              Label("New Chat", systemImage: "plus.message.fill")
            }
            Button(action: {
              openAddMemberSheet = true
            }) {
              Label("Invite Member", systemImage: "person.badge.plus.fill")
            }
            Divider()
            Button(role: .destructive, action: {
              setupAndPresentAlert(spaceId: spaceId, isCreator: isCreator)
            }) {
              if isCreator {
                Label("Delete Space", systemImage: "trash.fill")

              } else {
                Label("Leave Space", systemImage: "rectangle.portrait.and.arrow.right.fill")
              }
            }
          } label: {
            Image(systemName: "ellipsis")
              .tint(Color.secondary)
          }
        }
      }
    }
    .sheet(isPresented: $openCreateThreadSheet) {
      CreateThread(spaceId: spaceId)
        .presentationBackground(.thinMaterial)
        .presentationCornerRadius(28)
    }
    .sheet(isPresented: $openAddMemberSheet) {
      AddMember(showSheet: $openAddMemberSheet, spaceId: spaceId)
        .presentationCornerRadius(28)
    }
    .task {
      do {
        try await data.getDialogs(spaceId: spaceId)

      } catch {
        Log.shared.error("Failed to getPrivateChats", error: error)
      }
    }
    .onAppear {
      Task {
        try await data.getSpace(spaceId: spaceId)
      }
    }
  }

  // MARK: - Helper Methods

  func setupAndPresentAlert(spaceId: Int64, isCreator: Bool) {
    let title = isCreator ? "Delete Space" : "Leave Space"
    let message = isCreator
      ? "Are you sure you want to delete this space? This action cannot be undone."
      : "Are you sure you want to leave this space?"

    let alert = UIAlertController(
      title: title,
      message: message,
      preferredStyle: .alert
    )

    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    alert.addAction(UIAlertAction(title: title, style: .destructive) { _ in
      Task {
        do {
          if isCreator {
            try await data.deleteSpace(spaceId: spaceId)
            nav.pop()
          } else {
            try await data.leaveSpace(spaceId: spaceId)
            nav.pop()
          }
        } catch {
          print("Error: \(error)")
        }
      }
    })

    if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
       let rootVC = windowScene.windows.first?.rootViewController
    {
      rootVC.topmostPresentedViewController.present(alert, animated: true)
    }
  }

  private func getCombinedItems() -> [SpaceCombinedItem] {
    let memberItems = fullSpaceViewModel.memberChats.map { SpaceCombinedItem.member($0) }
    let chatItems = fullSpaceViewModel.chats.map { SpaceCombinedItem.chat($0) }

    return (memberItems + chatItems).sorted { item1, item2 in

      let pinned1 = item1.isPinned
      let pinned2 = item2.isPinned
      if pinned1 != pinned2 { return pinned1 }

      return item1.date > item2.date
    }
  }

  @ViewBuilder
  private func combinedItemRow(for item: SpaceCombinedItem) -> some View {
    switch item {
      case let .member(memberChat):
        Button {
          nav.push(.chat(peer: .user(id: memberChat.user?.id ?? 0)))
        } label: {
          DirectChatItem(props: Props(
            dialog: memberChat.dialog,
            user: memberChat.userInfo,
            chat: memberChat.chat,
            message: memberChat.message,
            from: memberChat.from?.user
          ))
        }
        .contextMenu {
          Button {
            nav.push(.chat(peer: .user(id: memberChat.user?.id ?? 0)))
          } label: {
            Label("Open Chat", systemImage: "bubble.left")
          }
        } preview: {
          ChatView(peer: .user(id: memberChat.user?.id ?? 0), preview: true)
            .frame(width: Theme.shared.chatPreviewSize.width, height: Theme.shared.chatPreviewSize.height)
            .environmentObject(nav)
            .environmentObject(data)
            .environment(\.realtime, realtime)
            .environment(\.appDatabase, database)
        }

      case let .chat(chat):
        Button {
          nav.push(.chat(peer: chat.peerId))
        } label: {
          ChatItemView(props: ChatItemProps(
            dialog: chat.dialog,
            user: chat.userInfo,
            chat: chat.chat,
            message: chat.message,
            from: chat.from
          ))
        }

        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
          Button {
            Task {
              try await data.updateDialog(
                peerId: chat.peerId,
                pinned: !(chat.dialog.pinned ?? false)
              )
            }
          } label: {
            Image(systemName: chat.dialog.pinned ?? false ? "pin.slash.fill" : "pin.fill")
          }
        }
        .tint(.indigo)
        .contextMenu {
          Button {
            Task {
              try await data.updateDialog(
                peerId: chat.peerId,
                pinned: !(chat.dialog.pinned ?? false)
              )
            }
          } label: {
            Label(
              chat.dialog.pinned ?? false ? "Unpin" : "Pin",
              systemImage: chat.dialog.pinned ?? false ? "pin.slash.fill" : "pin.fill"
            )
          }
          Button {
            nav.push(.chat(peer: chat.peerId))
          } label: {
            Label("Open Chat", systemImage: "bubble.left")
          }

        } preview: {
          ChatView(peer: chat.peerId, preview: true)
            .frame(width: Theme.shared.chatPreviewSize.width, height: Theme.shared.chatPreviewSize.height)
            .environmentObject(nav)
            .environmentObject(data)
            .environment(\.realtime, realtime)
            .environment(\.appDatabase, database)
        }
        .listRowBackground(chat.dialog.pinned ?? false ? Color(.systemGray6).opacity(0.5) : .clear)
    }
  }
}

// MARK: - CombinedItem Enum

private enum SpaceCombinedItem: Identifiable {
  case member(SpaceChatItem)
  case chat(SpaceChatItem)

  var id: Int64 {
    switch self {
      case let .member(item): item.user?.id ?? 0
      case let .chat(item): item.id
    }
  }

  var date: Date {
    switch self {
      case let .member(item): item.message?.date ?? item.chat?.date ?? Date()
      case let .chat(item): item.message?.date ?? item.chat?.date ?? Date()
    }
  }

  var isPinned: Bool {
    switch self {
      case let .member(item): item.dialog.pinned ?? false
      case let .chat(item): item.dialog.pinned ?? false
    }
  }
}

#Preview {
  SpaceView(spaceId: Int64.random(in: 1 ... 500))
}
