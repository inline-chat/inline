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
  @Environment(\.realtime) private var realtime
  @EnvironmentObject private var nav: Navigation
  @EnvironmentObject private var data: DataManager
  @EnvironmentStateObject private var viewModel: FullSpaceViewModel
  @EnvironmentObject private var tabsManager: TabsManager

  @State private var showAddMemberSheet = false
  @State private var selectedSegment = 0

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
    .toolbar { toolbarContent }
    .toolbarRole(.editor)
    .sheet(isPresented: $showAddMemberSheet) {
      AddMember(showSheet: $showAddMemberSheet, spaceId: spaceId)
        .presentationCornerRadius(28)
    }
    .task { await loadData() }
  }

  // MARK: - Subviews

  private var contentView: some View {
    Group {
      switch Segment(rawValue: selectedSegment) {
        case .chats:
          ChatListContent(items: viewModel.filteredChats)
            .environmentObject(viewModel)
        case .members:
          MemberListView(members: viewModel.members)
            .environmentObject(viewModel)
        case .none:
          EmptyView()
      }
    }
    .id(selectedSegment)
  }

  @ToolbarContentBuilder
  private var toolbarContent: some ToolbarContent {
    ToolbarItem(placement: .topBarLeading) {
      Button(action: {
        tabsManager.setActiveSpaceId(nil)
      }, label: {
        Image(systemName: "chevron.left")
          .fontWeight(.medium)
      })
    }
    ToolbarItem(placement: .principal) {
      SpaceHeaderView(space: viewModel.space)
    }

    ToolbarItemGroup(placement: .navigationBarTrailing) {
      Button {
        nav.push(.spaceSettings(spaceId: spaceId))
      } label: {
        Image(systemName: "gearshape.fill")
          .tint(.secondary)
      }

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
  }

  // MARK: - Actions

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

private struct MemberListView: View {
  let members: [FullMemberItem]
  @EnvironmentObject private var viewModel: FullSpaceViewModel

  var body: some View {
    List {
      ForEach(members, id: \.userInfo.user.id) { member in
        MemberItemRow(
          member: member,
          hasUnread: viewModel.filteredMemberChats.first(where: { $0.user?.id == member.userInfo.user.id })?.dialog
            .unreadCount ?? 0 > 0
        )
        .listRowInsets(.init(top: 4, leading: 12, bottom: 4, trailing: 0))
      }
    }
    .listStyle(.plain)
  }
}

private struct ChatListContent: View {
  let items: [SpaceChatItem]
  @EnvironmentObject private var viewModel: FullSpaceViewModel

  var body: some View {
    List {
      ForEach(items, id: \.id) { item in
        ChatItemRow(item: item)
          .listRowInsets(.init(top: 9, leading: 16, bottom: 2, trailing: 0))
      }
    }
    .listStyle(.plain)
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
      HStack(alignment: .center, spacing: 9) {
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

// MARK: - Preview

#Preview {
  SpaceView(spaceId: Int64.random(in: 1 ... 500))
}
