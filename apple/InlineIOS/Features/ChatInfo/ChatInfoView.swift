import Auth
import Foundation
import GRDB
import InlineKit
import InlineUI
import Logger
import SwiftUI

struct SearchUserRow: View {
  let userInfo: UserInfo
  let onTap: () -> Void

  var body: some View {
    Button(action: onTap) {
      HStack(spacing: 9) {
        UserAvatar(userInfo: userInfo, size: 32)
        Text((userInfo.user.firstName ?? "") + " " + (userInfo.user.lastName ?? ""))
          .fontWeight(.medium)
          .themedPrimaryText()
      }
    }
  }
}

struct EmptySearchView: View {
  let isSearching: Bool

  var body: some View {
    if isSearching {
      ProgressView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      VStack(spacing: 4) {
        Text("🔍")
          .font(.largeTitle)
          .themedPrimaryText()
          .padding(.bottom, 14)
        Text("Search for people")
          .font(.headline)
          .themedPrimaryText()
        Text("Type a username to find someone to add. eg. dena, mo")
          .themedSecondaryText()
          .multilineTextAlignment(.center)
      }
      .padding(.horizontal, 45)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

struct ChatInfoView: View {
  let chatItem: SpaceChatItem
  @StateObject var participantsViewModel: ChatParticipantsViewModel
  @EnvironmentStateObject var documentsViewModel: ChatDocumentsViewModel
  @EnvironmentStateObject var spaceMembersViewModel: SpaceMembersViewModel
  @State var isSearching = false
  @State var searchText = ""
  @State var searchResults: [UserInfo] = []
  @State var isSearchingState = false
  @StateObject var searchDebouncer = Debouncer(delay: 0.3)
  @EnvironmentObject var nav: Navigation
  @EnvironmentObject var api: ApiClient
  @State private var selectedTab: ChatInfoTab = .info
  @Namespace private var tabSelection

  @Environment(\.appDatabase) var database
  @Environment(\.colorScheme) var colorScheme

  enum ChatInfoTab: String, CaseIterable {
    case info = "Info"
    case documents = "Documents"
  }

  var isPrivate: Bool {
    chatItem.chat?.isPublic == false
  }

  var isDM: Bool {
    chatItem.peerId.isPrivate
  }

  var theme = ThemeManager.shared.selected

  var currentMemberRole: MemberRole? {
    spaceMembersViewModel.members.first(where: { $0.userId == Auth.shared.getCurrentUserId() })?.role
  }

  var isOwnerOrAdmin: Bool {
    currentMemberRole == .owner || currentMemberRole == .admin
  }

  var chatTitle: String {
    chatItem.chat?.title ?? "Chat"
  }

  var chatProfileColors: [Color] {
    let _ = colorScheme
    return [
      Color(.systemGray3).adjustLuminosity(by: 0.2),
      Color(.systemGray5).adjustLuminosity(by: 0),
    ]
  }

  init(chatItem: SpaceChatItem) {
    self.chatItem = chatItem
    _participantsViewModel = StateObject(wrappedValue: ChatParticipantsViewModel(
      db: AppDatabase.shared,
      chatId: chatItem.chat?.id ?? 0
    ))

    _documentsViewModel = EnvironmentStateObject { env in
      ChatDocumentsViewModel(
        db: env.appDatabase,
        chatId: chatItem.chat?.id ?? 0
      )
    }

    _spaceMembersViewModel = EnvironmentStateObject { env in
      SpaceMembersViewModel(db: env.appDatabase, spaceId: chatItem.chat?.spaceId ?? 0)
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      // ScrollView(.vertical) {
      VStack(spacing: 18) {
        chatInfoHeader

        // Tab Bar
        HStack(spacing: 2) {
          ForEach(ChatInfoTab.allCases, id: \.self) { tab in
            Button {
              withAnimation(.easeInOut(duration: 0.3)) {
                selectedTab = tab
              }
            } label: {
              Text(tab.rawValue)
                .font(.callout)
                .foregroundColor(selectedTab == tab ? .primary : .secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background {
                  if selectedTab == tab {
                    Capsule()
                      .fill(.thinMaterial)
                      .matchedGeometryEffect(id: "tab_background", in: tabSelection)
                  }
                }
            }
            .buttonStyle(.plain)
          }

          Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
      }
      // }
      // Tab Content
      VStack {
        switch selectedTab {
          case .info:
            InfoTabView()
          case .documents:
            DocumentsTabView(documentsViewModel: documentsViewModel)
        }
      }
      .animation(.easeInOut(duration: 0.3), value: selectedTab)
    }
    .onAppear {
      Task {
        if let spaceId = chatItem.chat?.spaceId {
          await spaceMembersViewModel.refetchMembers()
        }
        await participantsViewModel.refetchParticipants()
      }
    }
    .onReceive(
      NotificationCenter.default
        .publisher(for: Notification.Name("chatDeletedNotification"))
    ) { notification in
      if let chatId = notification.userInfo?["chatId"] as? Int64,
         chatId == chatItem.chat?.id
      {
        nav.pop()
      }
    }
    .sheet(isPresented: $isSearching) {
      searchSheet
    }
  }
}

struct InfoTabView: View {
  var body: some View {
    VStack(spacing: 8) {
      Spacer()

      Text("Chat Information")
        .font(.headline)
        .foregroundColor(.primary)

      Text("This is the info tab content. Here you can view chat details, participants, and settings.")
        .font(.body)
        .foregroundColor(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 40)
      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
  }
}

struct DocumentsTabView: View {
  @ObservedObject var documentsViewModel: ChatDocumentsViewModel

  var body: some View {
    VStack(spacing: 16) {
      if documentsViewModel.documents.isEmpty {
        VStack(spacing: 8) {
          Spacer()

          Text("📄")
            .font(.largeTitle)
            .themedPrimaryText()
            .padding(.bottom, 8)

          Text("No documents shared in this chat yet.")
            .font(.headline)
            .themedPrimaryText()

          Text("Documents shared in this chat will appear here")
            .font(.subheadline)
            .themedSecondaryText()
            .multilineTextAlignment(.center)
            .padding(.horizontal, 40)

          Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
      } else {
        ScrollView(.vertical) {
          LazyVStack(spacing: 8) {
            ForEach(documentsViewModel.documents, id: \.id) { document in
              DocumentRow(
                documentInfo: document
              )
            }
          }
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
