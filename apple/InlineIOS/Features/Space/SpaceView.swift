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
    ToolbarItem(placement: .principal) {
      SpaceHeaderView(space: space)
    }

    ToolbarItem(placement: .topBarTrailing) {
      Menu {
        Button(action: { router.presentSheet(.createThread(spaceId: spaceId)) }) {
          Label("New Group Chat", systemImage: "plus.message")
        }
        Button(action: { showAddMemberSheet = true }) {
          Label("Invite Member", systemImage: "person.badge.plus")
        }

        Button {
          router.push(.spaceSettings(spaceId: spaceId))
        } label: {
          Label("Settings", systemImage: "gearshape")
        }
      } label: {
        Image(systemName: "ellipsis")
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
        .font(.title3)
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

// MARK: - Preview

#Preview {
  SpaceView(spaceId: Int64.random(in: 1 ... 500))
}
