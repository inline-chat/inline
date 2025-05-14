import Auth
import InlineKit
import InlineUI
import Logger
import SwiftUI
import UIKit

private enum Tabs {
  case archived
  case chats
  case members

  var title: String {
    switch self {
      case .archived: "Archived"
      case .chats: "Chats"
      case .members: "Members"
    }
  }

  var icon: String {
    switch self {
      case .archived: "archivebox.fill"
      case .chats: "bubble.left.and.bubble.right.fill"
      case .members: "person.2.fill"
    }
  }
}

struct SpaceView: View {
  var spaceId: Int64

  @Environment(\.appDatabase) var database
  @Environment(\.realtime) var realtime
  @EnvironmentObject var nav: Navigation
  @EnvironmentObject var data: DataManager

  @EnvironmentStateObject var fullSpaceViewModel: FullSpaceViewModel

  @State private var navBarHeight: CGFloat = 0
  @State private var selectedTab: Tabs = .chats

  init(spaceId: Int64) {
    self.spaceId = spaceId
    _fullSpaceViewModel = EnvironmentStateObject { env in
      FullSpaceViewModel(db: env.appDatabase, spaceId: spaceId)
    }
  }

  @State var openAddMemberSheet = false

  // MARK: - Computed Properties

  var currentUserMemberItem: FullMemberItem? {
    fullSpaceViewModel.members.first { fullMember in
      fullMember.userInfo.user.id == Auth.shared.getCurrentUserId()
    }
  }

  var currentUserMember: Member? {
    currentUserMemberItem?.member
  }

  var isCreator: Bool {
    if currentUserMember?.role == .owner || currentUserMember?.role == .admin {
      true
    } else {
      false
    }
  }

  private func playTabHaptic() {
    let generator = UIImpactFeedbackGenerator(style: .soft)
    generator.impactOccurred(intensity: 0.5)
  }

  var body: some View {
    VStack {
      if selectedTab == .archived {
        ArchivedChatsView(type: .space(spaceId: spaceId))
          .environmentObject(fullSpaceViewModel)
      } else {
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
    }
    .id(selectedTab)
    .frame(maxWidth: .infinity)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(id: "space", placement: .principal) {
        HStack {
          if let space = fullSpaceViewModel.space {
            SpaceAvatar(space: space, size: 28)
              .padding(.trailing, 4)

          } else {
            Image(systemName: "person.2.fill")
              .foregroundColor(.secondary)
              .font(.callout)
              .padding(.trailing, 4)
          }
          VStack(alignment: .leading) {
            Text(fullSpaceViewModel.space?.nameWithoutEmoji ?? fullSpaceViewModel.space?.name ?? "Space")
              .font(.body)
              .fontWeight(.semibold)
          }
        }
      }
    }
    .toolbarRole(.editor)
    .toolbar {
      Group {
        ToolbarItem(placement: .navigationBarTrailing) {
          Menu {
            Button(action: {
              nav.push(.createThread(spaceId: spaceId))
            }) {
              Label("New Group Chat", systemImage: "plus.message.fill")
            }
            Button(action: {
              openAddMemberSheet = true
            }) {
              Label("Invite Member", systemImage: "person.badge.plus.fill")
            }
          } label: {
            Image(systemName: "plus")
              .tint(Color.secondary)
              .contentShape(Rectangle())
          }
        }

        ToolbarItem(placement: .navigationBarTrailing) {
          Menu {
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
              .contentShape(Rectangle())
          }
        }

        ToolbarItem(placement: .bottomBar) {
          BottomTabBar(
            tabs: [Tabs.archived, .chats, .members],
            selected: selectedTab,
            onSelect: { tab in
              playTabHaptic()
              withAnimation(.snappy(duration: 0.1)) {
                selectedTab = tab
              }
            }
          )
        }
      }
    }
    .sheet(isPresented: $openAddMemberSheet) {
      AddMember(showSheet: $openAddMemberSheet, spaceId: spaceId)
        .presentationCornerRadius(28)
    }
    .task {
      do {
        try await data.getSpace(spaceId: spaceId)
      } catch {
        Log.shared.error("Failed to getSpace", error: error)
      }

      // order matters here
      // @mo: please do not change ⚠️⚠️⚠️
      do {
        try await data.getDialogs(spaceId: spaceId)
      } catch {
        Log.shared.error("Failed to getDialogs", error: error)
      }

      do {
        try await realtime
          .invokeWithHandler(.getSpaceMembers, input: .getSpaceMembers(.with {
            $0.spaceID = spaceId
          }))
      } catch {
        Log.shared.error("Failed to get space members", error: error)
      }
    }
    .onAppear {
      // order matters here
      // @mo: please do not change ⚠️⚠️⚠️
      Task.detached {
        do {
          try await data.getSpace(spaceId: spaceId)
        } catch {
          Log.shared.error("Failed to getSpace", error: error)
        }

//        Task.detached {
//          do {
//            try await realtime
//              .invokeWithHandler(.getSpaceMembers, input: .getSpaceMembers(.with {
//                $0.spaceID = spaceId
//              }))
//          } catch {
//            Log.shared.error("Failed to get space members", error: error)
//          }
//        }

//        Task.detached {
//          do {
//            try await data.getDialogs(spaceId: spaceId)
//          } catch {
//            Log.shared.error("Failed to getDialogs", error: error)
//          }
//        }

//      Task {
//        try await data.getSpace(spaceId: spaceId)
//      }
//
//      Task.detached {
//        do {
//          try await realtime
//            .invokeWithHandler(.getSpaceMembers, input: .getSpaceMembers(.with {
//              $0.spaceID = spaceId
//            }))
//        } catch {
//          Log.shared.error("Failed to get space members", error: error)
//        }
//
//        // TODO: reduce over fetching
//        do {
//          try await data.getDialogs(spaceId: spaceId)
//        } catch {
//          Log.shared.error("Failed to getDialogs", error: error)
//        }
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
            nav.pop()
            try await data.deleteSpace(spaceId: spaceId)
          } else {
            nav.pop()
            try await data.leaveSpace(spaceId: spaceId)
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
    let memberItems = fullSpaceViewModel.filteredMemberChats.map { SpaceCombinedItem.member($0) }
    let chatItems = fullSpaceViewModel.filteredChats.map { SpaceCombinedItem.chat($0) }

    let allItems = (memberItems + chatItems).sorted { item1, item2 in
      let pinned1 = item1.isPinned
      let pinned2 = item2.isPinned
      if pinned1 != pinned2 { return pinned1 }
      return item1.date > item2.date
    }

    switch selectedTab {
      case .archived:
        return allItems.filter { item in
          switch item {
            case let .member(memberChat):
              memberChat.dialog.archived == true
            case let .chat(chat):
              chat.dialog.archived == true
          }
        }
      case .chats:
        return allItems.filter { item in
          switch item {
            case let .member(memberChat):
              memberChat.dialog.archived != true
            case let .chat(chat):
              chat.dialog.archived != true
          }
        }
      case .members:
        return allItems.filter { item in
          switch item {
            case let .member(memberChat):
              memberChat.dialog.archived != true
            case .chat:
              false
          }
        }
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
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
          Button(role: .destructive) {
            Task {
              try await data.updateDialog(
                peerId: .user(id: memberChat.user?.id ?? 0),
                archived: true
              )
            }
          } label: {
            Image(systemName: "tray.and.arrow.down.fill")
          }
          .tint(Color(.systemGray2))

          Button {
            Task {
              try await data.updateDialog(
                peerId: .user(id: memberChat.user?.id ?? 0),
                pinned: !(memberChat.dialog.pinned ?? false)
              )
            }
          } label: {
            Image(systemName: memberChat.dialog.pinned ?? false ? "pin.slash.fill" : "pin.fill")
          }
          .tint(.indigo)
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
          Button(role: .destructive) {
            Task {
              try await data.updateDialog(
                peerId: chat.peerId,
                archived: true
              )
            }
          } label: {
            Image(systemName: "tray.and.arrow.down.fill")
          }
          .tint(Color(.systemGray2))

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
          .tint(.indigo)
        }
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

private struct BottomTabBar: View {
  let tabs: [Tabs]
  let selected: Tabs
  let onSelect: (Tabs) -> Void
  var body: some View {
    HStack(spacing: 0) {
      ForEach(tabs, id: \.self) { tab in
        VStack {
          Image(systemName: tab.icon)
            .font(.system(size: 20, weight: .semibold))
            .foregroundColor(selected == tab ? Color(ThemeManager.shared.selected.accent) : Color(.systemGray4))
            .frame(width: 100, height: 36)
            .animation(.bouncy(duration: 0.08), value: selected == tab)
            .contentShape(Rectangle())
        }
        .frame(maxWidth: .infinity)
        .onTapGesture {
          onSelect(tab)
        }
      }
    }
    .frame(maxWidth: .infinity)
  }
}

#Preview {
  SpaceView(spaceId: Int64.random(in: 1 ... 500))
}
