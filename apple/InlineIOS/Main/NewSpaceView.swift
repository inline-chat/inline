import Auth
import InlineKit
import InlineUI
import Logger
import SwiftUI
import UIKit

struct NewSpaceView: View {
  let spaceId: Int64

  @Environment(\.appDatabase) private var database
  @Environment(\.realtime) private var realtime
  @EnvironmentObject private var nav: Navigation
  @EnvironmentObject private var data: DataManager
  @EnvironmentStateObject private var viewModel: FullSpaceViewModel

  @State private var selectedTab: Tab = .chats
  @State private var showAddMemberSheet = false

  private enum Tab: String, CaseIterable {
    case chats = "Chats"
    case members = "Members"
  }

  // MARK: - Computed Properties

  private var currentUserMember: Member? {
    viewModel.members.first { $0.userInfo.user.id == Auth.shared.getCurrentUserId() }?.member
  }

  private var isCreator: Bool {
    currentUserMember?.role == .owner || currentUserMember?.role == .admin
  }

  init(spaceId: Int64) {
    self.spaceId = spaceId
    _viewModel = EnvironmentStateObject { env in
      FullSpaceViewModel(db: env.appDatabase, spaceId: spaceId)
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      Picker("View", selection: $selectedTab) {
        ForEach(Tab.allCases, id: \.self) { tab in
          Text(tab.rawValue).tag(tab)
        }
      }
      .pickerStyle(.segmented)
      .padding()

      contentView
    }
    .navigationBarTitleDisplayMode(.inline)
    .toolbar { toolbarContent }
    .toolbarRole(.editor)
    .sheet(isPresented: $showAddMemberSheet) {
      AddMember(showSheet: $showAddMemberSheet, spaceId: spaceId)
        .presentationCornerRadius(28)
    }
    .task { await loadData() }
  }

  @ToolbarContentBuilder
  private var toolbarContent: some ToolbarContent {
    ToolbarItem(placement: .principal) {
      SpaceHeaderView(space: viewModel.space)
    }

    ToolbarItem(placement: .navigationBarTrailing) {
      Menu {
        Button(action: { nav.push(.createThread(spaceId: spaceId)) }) {
          Label("New Group Chat", systemImage: "plus.message.fill")
        }
        Button(action: { showAddMemberSheet = true }) {
          Label("Invite Member", systemImage: "person.badge.plus.fill")
        }
      } label: {
        Image(systemName: "plus")
          .tint(.secondary)
      }
    }

    ToolbarItem(placement: .navigationBarTrailing) {
      Menu {
        Button(role: .destructive) {
          showSpaceActionAlert()
        } label: {
          if isCreator {
            Label("Delete Space", systemImage: "trash.fill")
          } else {
            Label("Leave Space", systemImage: "rectangle.portrait.and.arrow.right.fill")
          }
        }
      } label: {
        Image(systemName: "ellipsis")
          .tint(.secondary)
      }
    }
  }

  @ViewBuilder
  private var contentView: some View {
    switch selectedTab {
      case .chats:
        List {
          ForEach(viewModel.filteredChats, id: \.id) { item in
            ChatItemRow(item: item)
              .listRowInsets(.init(top: 9, leading: 16, bottom: 2, trailing: 0))
          }
        }
        .listStyle(.plain)

      case .members:
        List {
          ForEach(viewModel.members, id: \.userInfo.user.id) { member in
            MemberItemRow(
              member: member,
              hasUnread: viewModel.filteredMemberChats.first(where: { $0.user?.id == member.userInfo.user.id })?.dialog
                .unreadCount ?? 0 > 0
            )
            .listRowInsets(.init(top: 9, leading: 12, bottom: 2, trailing: 0))
          }
        }
        .listStyle(.plain)
    }
  }

  private func showSpaceActionAlert() {
    let title = isCreator ? "Delete Space" : "Leave Space"
    let message = isCreator
      ? "Are you sure you want to delete this space? This action cannot be undone."
      : "Are you sure you want to leave this space?"

    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    alert.addAction(UIAlertAction(title: title, style: .destructive) { _ in
      Task {
        do {
          nav.pop()
          if isCreator {
            try await data.deleteSpace(spaceId: spaceId)
          } else {
            try await data.leaveSpace(spaceId: spaceId)
          }
        } catch {
          Log.shared.error("Failed to \(isCreator ? "delete" : "leave") space", error: error)
        }
      }
    })

    if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
       let rootVC = windowScene.windows.first?.rootViewController
    {
      rootVC.topmostPresentedViewController.present(alert, animated: true)
    }
  }

  private func loadData() async {
    do {
      try await data.getSpace(spaceId: spaceId)
      try await data.getDialogs(spaceId: spaceId)
      try await realtime.invokeWithHandler(
        .getSpaceMembers,
        input: .getSpaceMembers(.with { $0.spaceID = spaceId })
      )
    } catch {
      Log.shared.error("Failed to load space data", error: error)
    }
  }
}

// MARK: - Supporting Views

private struct SpaceHeaderView: View {
  let space: Space?

  var body: some View {
    HStack {
      if let space {
        SpaceAvatar(space: space, size: 28)
          .padding(.trailing, 4)
      } else {
        Image(systemName: "person.2.fill")
          .foregroundColor(.secondary)
          .font(.callout)
          .padding(.trailing, 4)
      }

      Text(space?.nameWithoutEmoji ?? space?.name ?? "Space")
        .font(.body)
        .fontWeight(.semibold)
    }
  }
}

private struct ChatItemRow: View {
  let item: SpaceChatItem
  @EnvironmentObject private var nav: Navigation
  @EnvironmentObject private var data: DataManager

  var body: some View {
    Button {
      nav.push(.chat(peer: item.peerId))
    } label: {
      ChatItemView(props: ChatItemProps(
        dialog: item.dialog,
        user: item.userInfo,
        chat: item.chat,
        message: item.message,
        from: item.from,
        space: nil
      ))
    }
    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
      Button(role: .destructive) {
        Task {
          try await data.updateDialog(
            peerId: item.peerId,
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
            peerId: item.peerId,
            pinned: !(item.dialog.pinned ?? false)
          )
        }
      } label: {
        Image(systemName: item.dialog.pinned ?? false ? "pin.slash.fill" : "pin.fill")
      }
      .tint(.indigo)
    }
    .contextMenu {
      Button {
        Task {
          try await data.updateDialog(
            peerId: item.peerId,
            pinned: !(item.dialog.pinned ?? false)
          )
        }
      } label: {
        Label(
          item.dialog.pinned ?? false ? "Unpin" : "Pin",
          systemImage: item.dialog.pinned ?? false ? "pin.slash.fill" : "pin.fill"
        )
      }
      Button {
        nav.push(.chat(peer: item.peerId))
      } label: {
        Label("Open Chat", systemImage: "bubble.left")
      }
    } preview: {
      ChatView(peer: item.peerId, preview: true)
        .frame(width: Theme.shared.chatPreviewSize.width, height: Theme.shared.chatPreviewSize.height)
        .environmentObject(nav)
        .environmentObject(data)
    }
    .listRowBackground(item.dialog.pinned ?? false ? Color(.systemGray6).opacity(0.5) : .clear)
  }
}

private struct MemberItemRow: View {
  let member: FullMemberItem
  let hasUnread: Bool
  @EnvironmentObject private var nav: Navigation

  var body: some View {
    Button {
      nav.push(.chat(peer: .user(id: member.userInfo.user.id)))
    } label: {
      HStack(spacing: 9) {
        HStack(alignment: .center, spacing: 5) {
          Circle()
            .fill(hasUnread ? ColorManager.shared.swiftUIColor : .clear)
            .frame(width: 6, height: 6)
            .animation(.easeInOut(duration: 0.3), value: hasUnread)
          UserAvatar(user: member.userInfo.user, size: 34)
        }
        Text(member.userInfo.user.displayName)
          .font(.body)
      }
    }
  }
}
