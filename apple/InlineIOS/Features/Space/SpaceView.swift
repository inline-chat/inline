import Auth
import InlineKit
import InlineUI
import Logger
import SwiftUI
import UIKit

// MARK: - SpaceView

struct SpaceView: View {
  private enum SpaceTab: Hashable {
    case openChats
    case allChats
    case members

    var title: String {
      switch self {
        case .openChats:
          "Open Chats"
        case .allChats:
          "All Chats"
        case .members:
          "Members"
      }
    }

    var systemImage: String {
      switch self {
        case .openChats:
          "bubble.left.and.bubble.right.fill"
        case .allChats:
          "text.bubble.fill"
        case .members:
          "person.2.fill"
      }
    }
  }

  let spaceId: Int64

  @Environment(\.appDatabase) private var database
  @Environment(\.realtimeV2) private var realtimeV2
  @EnvironmentObject private var data: DataManager
  @Environment(Router.self) private var router
  @EnvironmentStateObject private var viewModel: FullSpaceViewModel
  @EnvironmentObject private var tabsManager: TabsManager

  @State private var showAddMemberSheet = false
  @State private var selectedTab: SpaceTab = .openChats

  var space: Space? {
    viewModel.space
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
    TabView(selection: $selectedTab) {
      chatList(for: viewModel.filteredChats, emptyMessage: "No chats in this space yet")
        .tag(SpaceTab.allChats)
        .tabItem { tabLabel(for: .allChats) }

      chatList(for: viewModel.filteredMemberChats, emptyMessage: "No open chats yet")
        .tag(SpaceTab.openChats)
        .tabItem { tabLabel(for: .openChats) }

      membersList
        .tag(SpaceTab.members)
        .tabItem { tabLabel(for: .members) }
    }
    .task { await loadData() }
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

  @ViewBuilder
  private func chatList(for items: [SpaceChatItem], emptyMessage: String) -> some View {
    if items.isEmpty {
      emptyState(message: emptyMessage, systemImage: "bubble.left.and.exclamationmark")
    } else {
      List(items, id: \.id) { item in
        ChatItemRow(item: item)
      }
      .listStyle(.plain)
      .scrollContentBackground(.hidden)
      .background(Color(.systemBackground))
    }
  }

  @ViewBuilder
  private var membersList: some View {
    if viewModel.members.isEmpty {
      emptyState(message: "No members yet", systemImage: "person.fill.questionmark")
    } else {
      List(viewModel.members, id: \.id) { member in
        MemberItemRow(member: member, hasUnread: false)
      }
      .listStyle(.plain)
      .scrollContentBackground(.hidden)
      .background(Color(.systemBackground))
    }
  }

  private func tabLabel(for tab: SpaceTab) -> some View {
    Label(tab.title, systemImage: tab.systemImage)
  }

  private func emptyState(message: String, systemImage: String) -> some View {
    VStack(spacing: 12) {
      Image(systemName: systemImage)
        .font(.largeTitle)
        .foregroundColor(.secondary)
      Text(message)
        .font(.body)
        .foregroundColor(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(.systemBackground))
  }
}
