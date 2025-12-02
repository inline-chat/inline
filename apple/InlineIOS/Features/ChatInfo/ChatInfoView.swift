import Auth
import Foundation
import GRDB
import InlineKit
import InlineUI
import Logger
import SwiftUI

struct ChatInfoView: View {
  let chatItem: SpaceChatItem
  @StateObject var participantsWithMembersViewModel: ChatParticipantsWithMembersViewModel
  @EnvironmentStateObject var documentsViewModel: ChatDocumentsViewModel
  @EnvironmentStateObject var photosViewModel: ChatPhotosViewModel
  @EnvironmentStateObject var spaceMembersViewModel: SpaceMembersViewModel
  @State private var space: Space?
  @State var isSearching = false
  @State var searchText = ""
  @State var searchResults: [UserInfo] = []
  @State var isSearchingState = false
  @StateObject var searchDebouncer = Debouncer(delay: 0.3)
  @EnvironmentObject var nav: Navigation
  @EnvironmentObject var api: ApiClient
  @Environment(Router.self) var router
  @State var selectedTab: ChatInfoTab
  @Namespace var tabSelection

  @Environment(\.appDatabase) var database
  @Environment(\.colorScheme) var colorScheme

  enum ChatInfoTab: String, CaseIterable {
    case info = "Info"
    // case photos = "Photos"
    case files = "Files"
  }

  var availableTabs: [ChatInfoTab] {
    isDM ? [.files] : [.info, .files]
  }

  var isPrivate: Bool {
    chatItem.chat?.isPublic == false
  }

  var isDM: Bool {
    chatItem.peerId.isPrivate
  }

  var theme = ThemeManager.shared.selected

  var currentMemberRole: MemberRole? {
    spaceMembersViewModel.members
      .first(
        where: { $0.userId == Auth.shared.getCurrentUserId()
        }
      )?.role
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
    _participantsWithMembersViewModel = StateObject(wrappedValue: ChatParticipantsWithMembersViewModel(
      db: AppDatabase.shared,
      chatId: chatItem.chat?.id ?? 0
    ))

    _documentsViewModel = EnvironmentStateObject { env in
      ChatDocumentsViewModel(
        db: env.appDatabase,
        chatId: chatItem.chat?.id ?? 0
      )
    }

    _photosViewModel = EnvironmentStateObject { env in
      ChatPhotosViewModel(
        db: env.appDatabase,
        chatId: chatItem.chat?.id ?? 0
      )
    }

    _spaceMembersViewModel = EnvironmentStateObject { env in
      SpaceMembersViewModel(db: env.appDatabase, spaceId: chatItem.chat?.spaceId ?? 0)
    }

    // Default tab based on chat type
    // DMs have no info tab
    if chatItem.chat?.type == .thread {
      selectedTab = .info
    } else {
      selectedTab = .files
    }
  }

  var body: some View {
    ZStack(alignment: .top) {
      ScrollView(.vertical) {
        LazyVStack(spacing: 18) {
          chatInfoHeader

          // Tab Bar
          HStack(spacing: 2) {
            Spacer()

            ForEach(availableTabs, id: \.self) { tab in
              Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation(.smoothSnappy) {
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
            .padding(.bottom, 12)

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
              if !isDM {
                InfoTabView()
                  .environmentObject(ChatInfoViewEnvironment(
                    isSearching: $isSearching,
                    isPrivate: isPrivate,
                    isDM: isDM,
                    isOwnerOrAdmin: isOwnerOrAdmin,
                    participants: participantsWithMembersViewModel.participants,
                    chatId: chatItem.chat?.id ?? 0,
                    chatItem: chatItem,
                    spaceMembersViewModel: spaceMembersViewModel,
                    space: space,
                    removeParticipant: { userInfo in
                      guard let chatId = chatItem.chat?.id else {
                        Log.shared.error("No chat ID found when trying to remove participant")
                        return
                      }
                      Task {
                        do {
                          try await Api.realtime.send(.removeChatParticipant(
                            chatID: chatId,
                            userID: userInfo.user.id
                          ))
                        } catch {
                          Log.shared.error("Failed to remove participant", error: error)
                        }
                      }
                    },
                    openParticipantChat: { userInfo in
                      UIImpactFeedbackGenerator(style: .light).impactOccurred()
                      nav.push(.chat(peer: Peer.user(id: userInfo.user.id)))
                    }
                  ))
              }
            case .files:
              DocumentsTabView(
                documentsViewModel: documentsViewModel,
                peerUserId: chatItem.dialog.peerUserId,
                peerThreadId: chatItem.dialog.peerThreadId
              )
          }
        }
        .animation(.easeInOut(duration: 0.3), value: selectedTab)
      }
      .coordinateSpace(name: "mainScroll")
    }
    .onAppear {
      Task {
        if let spaceId = chatItem.chat?.spaceId {
          await spaceMembersViewModel.refetchMembers()
          // Fetch space information
          do {
            space = try await database.reader.read { db in
              try Space.fetchOne(db, id: spaceId)
            }
          } catch {
            Log.shared.error("Failed to fetch space: \(error)")
          }
        }
        await participantsWithMembersViewModel.refetchParticipants()

        // Set default tab based on chat type
        if isDM, selectedTab == .info {
          //  selectedTab = .photos
        }
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
  @EnvironmentObject private var chatInfoView: ChatInfoViewEnvironment
  @State private var participantToRemove: UserInfo?
  @State private var showRemoveAlert = false

  var body: some View {
    VStack(spacing: 16) {
      VStack {
        HStack {
          Text("Type")

          Spacer()
          Image(systemName: chatInfoView.isPrivate ? "lock.fill" : "person.2.fill")
            .foregroundStyle(Color(ThemeManager.shared.selected.accent))

          Text(chatInfoView.isPrivate ? "Private" : "Public")
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
      }
      .background(Color(UIColor { traitCollection in
        if traitCollection.userInterfaceStyle == .dark {
          UIColor(hex: "#141414") ?? UIColor.systemGray6
        } else {
          UIColor(hex: "#F8F8F8") ?? UIColor.systemGray6
        }
      }))
      .clipShape(RoundedRectangle(cornerRadius: 10))
      .padding(.bottom, 14)

      if !chatInfoView.isDM, chatInfoView.isPrivate {
        participantsGrid
      } else {
        Text(
          "\(chatInfoView.spaceMembersViewModel.members.count) \(chatInfoView.spaceMembersViewModel.members.count == 1 ? "member" : "members") of \(chatInfoView.space?.displayName ?? "this space") are participants of this chat. New members will have access by default."
        )
        .foregroundColor(.secondary)
        .font(.callout)
      }
    }
    .padding(.horizontal, 16)
    .alert("Remove Participant", isPresented: $showRemoveAlert) {
      Button("Cancel", role: .cancel) {}
      Button("Remove", role: .destructive) {
        if let participant = participantToRemove {
          chatInfoView.removeParticipant(participant)
        }
      }
    } message: {
      if let participant = participantToRemove {
        Text("Are you sure you want to remove \(participant.user.firstName ?? "this user") from the chat?")
      }
    }
  }

  @ViewBuilder
  var participantsGrid: some View {
    LazyVGrid(columns: [
      GridItem(.flexible()),
      GridItem(.flexible()),
      GridItem(.flexible()),
      GridItem(.flexible()),
    ], spacing: 16) {
      if chatInfoView.isOwnerOrAdmin, chatInfoView.isPrivate {
        Button(action: {
          chatInfoView.isSearching = true
        }) {
          VStack(spacing: 4) {
            Circle()
              .fill(Color(.systemGray6))
              .frame(width: 68, height: 68)
              .overlay {
                Image(systemName: "plus")
                  .font(.title)
                  .foregroundColor(.secondary)
              }

            Text("Add")
              .font(.callout)
              .lineLimit(1)
          }
        }
        .buttonStyle(.plain)
      }

      // Existing participants

      ForEach(chatInfoView.participants) { userInfo in
        VStack(spacing: 4) {
          UserAvatar(userInfo: userInfo, size: 68)

          Text(userInfo.user.shortDisplayName)
            .font(.callout)
            .foregroundColor(.primary)
            .lineLimit(1)
        }
        .contextMenu {
          if chatInfoView.isOwnerOrAdmin, chatInfoView.isPrivate {
            Button(role: .destructive, action: {
              let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
              impactFeedback.impactOccurred()
              participantToRemove = userInfo
              showRemoveAlert = true
            }) {
              Label("Remove Participant", systemImage: "minus.circle")
            }
          }
        }

        .transition(.asymmetric(
          insertion: .scale(scale: 0.8).combined(with: .opacity),
          removal: .scale(scale: 0.8).combined(with: .opacity)
        ))
      }
    }
    .padding(.top, 8)
    .animation(.easeInOut(duration: 0.2), value: chatInfoView.participants.count)
  }
}
