import Auth
import InlineKit
import InlineUI
import Logger
import SwiftUI
import UIKit

// MARK: - SpaceView

struct SpaceView: View {
  let spaceId: Int64

  @Environment(\.appDatabase) private var database
  @Environment(\.realtimeV2) private var realtimeV2
  @EnvironmentObject private var data: DataManager
  @Environment(Router.self) private var router
  @EnvironmentStateObject private var viewModel: FullSpaceViewModel
  @EnvironmentObject private var tabsManager: TabsManager

  @State private var showAddMemberSheet = false
  @State private var selectedSegment = 0

  var space: Space? {
    viewModel.space
  }

  enum Segment: Int, CaseIterable {
    case chats
    case members

    var title: String {
      switch self {
        case .chats: "Chats"
        case .members: "Members"
      }
    }
  }

  init(spaceId: Int64) {
    self.spaceId = spaceId
    _viewModel = EnvironmentStateObject { env in
      FullSpaceViewModel(db: env.appDatabase, spaceId: spaceId)
    }
  }

  // MARK: - Computed Properties

  private var currentUserMember: Member? {
    viewModel.members.first { $0.userInfo.user.id == Auth.shared.getCurrentUserId() }?.member
  }

  private var chatItems: [HomeChatItem] {
    HomeViewModel.sortChats(viewModel.filteredChats.map(homeItem(from:)))
  }

  private var memberChatItems: [HomeChatItem] {
    sortMembers(viewModel.filteredMemberChats.map(homeItem(from:)))
  }

  private var isCreator: Bool {
    currentUserMember?.role == .owner || currentUserMember?.role == .admin
  }

  // MARK: - Body

  var body: some View {
    VStack(spacing: 0) {
      Picker("View", selection: $selectedSegment) {
        ForEach(Segment.allCases, id: \.rawValue) { segment in
          Text(segment.title).tag(segment.rawValue)
        }
      }
      .pickerStyle(.segmented)
      .padding()

      contentView
    }
    .navigationBarTitleDisplayMode(.inline)
    .navigationTitle(space?.displayName ?? "Space")
    .toolbar { toolbarContent }
    .task { await loadData() }
  }

  // MARK: - Subviews

  private var contentView: some View {
    Group {
      switch Segment(rawValue: selectedSegment) {
        case .chats:
          ChatListView(
            items: chatItems,
            isArchived: false,
            onItemTap: handleItemTap,
            onArchive: handleArchive,
            onPin: handlePin,
            onRead: handleRead,
            onUnread: handleUnread
          )
        case .members:
          ChatListView(
            items: memberChatItems,
            isArchived: false,
            showPinnedStyling: false,
            showPinAction: false,
            onItemTap: handleItemTap,
            onArchive: handleArchive,
            onPin: handlePin,
            onRead: handleRead,
            onUnread: handleUnread
          )
        case .none:
          EmptyView()
      }
    }
    .id(selectedSegment)
  }

  @ToolbarContentBuilder
  private var toolbarContent: some ToolbarContent {
    ToolbarItem(placement: .principal) {
      SpaceHeaderView(space: space)
    }

    ToolbarItem(placement: .topBarTrailing) {
      Menu {
        Button(action: { router.push(.createThread(spaceId: spaceId)) }) {
          Label("New Group Chat", systemImage: "plus.message")
        }
        Button(action: {
          router.presentSheet(.addMember(spaceId: spaceId))
        }) {
          Label("Invite Member", systemImage: "person.badge.plus")
        }

        Button {
          router.push(.spaceSettings(spaceId: spaceId))
        } label: {
          Label("Settings", systemImage: "gearshape")
        }
      } label: {
        Image(systemName: "line.3.horizontal.decrease")
          .foregroundStyle(.primary)
      }
    }
  }

  // MARK: - Actions

  private func handleItemTap(_ item: HomeChatItem) {
    if let user = item.user {
      router.push(.chat(peer: .user(id: user.user.id)))
    } else if let chat = item.chat {
      router.push(.chat(peer: .thread(id: chat.id)))
    }
  }

  private func handleArchive(_ item: HomeChatItem) {
    Task {
      if let user = item.user {
        try await data.updateSpaceMemberDialogArchiveState(
          spaceId: spaceId,
          peerUserId: user.user.id,
          archived: true
        )
      } else if let chat = item.chat {
        try await data.updateDialog(peerId: .thread(id: chat.id), archived: true)
      }
    }
  }

  private func handlePin(_ item: HomeChatItem) {
    Task {
      let isPinned = item.dialog.pinned ?? false
      if let user = item.user {
        try await data.updateDialog(peerId: .user(id: user.user.id), pinned: !isPinned)
      } else if let chat = item.chat {
        try await data.updateDialog(peerId: .thread(id: chat.id), pinned: !isPinned)
      }
    }
  }

  private func handleRead(_ item: HomeChatItem) {
    Task {
      UnreadManager.shared.readAll(item.dialog.peerId, chatId: item.chat?.id ?? 0)
    }
  }

  private func handleUnread(_ item: HomeChatItem) {
    Task {
      do {
        try await realtimeV2.send(.markAsUnread(peerId: item.dialog.peerId))
      } catch {
        Log.shared.error("Failed to mark as unread", error: error)
      }
    }
  }

  private func homeItem(from item: SpaceChatItem) -> HomeChatItem {
    HomeChatItem(
      dialog: item.dialog,
      user: item.userInfo,
      chat: item.chat,
      lastMessage: embeddedMessage(for: item),
      space: viewModel.space
    )
  }

  private func embeddedMessage(for item: SpaceChatItem) -> EmbeddedMessage? {
    guard let message = item.message else { return nil }
    return EmbeddedMessage(
      message: message,
      senderInfo: item.from,
      translations: item.translations,
      photoInfo: item.photoInfo
    )
  }

  private func sortMembers(_ items: [HomeChatItem]) -> [HomeChatItem] {
    items.sorted { lhs, rhs in
      let date1 = lhs.lastMessage?.message.date ?? lhs.chat?.date ?? Date.distantPast
      let date2 = rhs.lastMessage?.message.date ?? rhs.chat?.date ?? Date.distantPast
      return date1 > date2
    }
  }

  private func loadData() async {
    do {
      try await data.getSpace(spaceId: spaceId)
      try await data.getDialogs(spaceId: spaceId)
      try await realtimeV2.send(.getSpaceMembers(spaceId: spaceId))
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
        .font(.title3)
        .fontWeight(.semibold)
    }
  }
}

// MARK: - Preview

#Preview {
  SpaceView(spaceId: Int64.random(in: 1 ... 500))
}
