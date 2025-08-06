import Auth
import Foundation
import GRDB
import InlineKit
import InlineUI
import Logger
import SwiftUI

class ChatInfoViewEnvironment: ObservableObject {
  @Binding var isSearching: Bool
  let isPrivate: Bool
  let isDM: Bool
  let isOwnerOrAdmin: Bool
  let participants: [UserInfo]
  let chatId: Int64
  let removeParticipant: (UserInfo) -> Void
  let openParticipantChat: (UserInfo) -> Void

  init(
    isSearching: Binding<Bool>,
    isPrivate: Bool,
    isDM: Bool,
    isOwnerOrAdmin: Bool,
    participants: [UserInfo],
    chatId: Int64,
    removeParticipant: @escaping (UserInfo) -> Void,
    openParticipantChat: @escaping (UserInfo) -> Void
  ) {
    _isSearching = isSearching
    self.isPrivate = isPrivate
    self.isDM = isDM
    self.isOwnerOrAdmin = isOwnerOrAdmin
    self.participants = participants
    self.chatId = chatId
    self.removeParticipant = removeParticipant
    self.openParticipantChat = openParticipantChat
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
    ZStack(alignment: .top) {
      ScrollView(.vertical) {
        LazyVStack(spacing: 18) {
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
              InfoTabView()
                .environmentObject(ChatInfoViewEnvironment(
                  isSearching: $isSearching,
                  isPrivate: isPrivate,
                  isDM: isDM,
                  isOwnerOrAdmin: isOwnerOrAdmin,
                  participants: participantsViewModel.participants,
                  chatId: chatItem.chat?.id ?? 0,
                  removeParticipant: { userInfo in
                    Task {
                      do {
                        try await Realtime.shared.invokeWithHandler(
                          .removeChatParticipant,
                          input: .removeChatParticipant(.with { input in
                            input.chatID = chatItem.chat?.id ?? 0
                            input.userID = userInfo.user.id
                          })
                        )
                      } catch {
                        Log.shared.error("Failed to remove participant", error: error)
                      }
                    }
                  },
                  openParticipantChat: { userInfo in
                    let impactFeedback = UIImpactFeedbackGenerator(style: .light)
                    impactFeedback.impactOccurred()
                    nav.push(.chat(peer: Peer.user(id: userInfo.user.id)))
                  }
                ))
            case .documents:
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
  @EnvironmentObject private var chatInfoView: ChatInfoViewEnvironment
  @State private var participantToRemove: UserInfo?
  @State private var showRemoveAlert = false

  var body: some View {
    VStack(spacing: 16) {
      VStack {
        HStack {
          Image(systemName: chatInfoView.isPrivate ? "lock.fill" : "person.2.fill")
            .foregroundStyle(Color(ThemeManager.shared.selected.accent))
            .font(.title3)

          Text("Type")

          Spacer()

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

      if chatInfoView.isPrivate, !chatInfoView.isDM {
        participantsGrid
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
      // Plus button as first item
      if chatInfoView.isOwnerOrAdmin {
        Button(action: {
          chatInfoView.isSearching = true
        }) {
          VStack(spacing: 4) {
            Circle()
              .fill(Color(.systemGray6))
              .frame(width: 75, height: 75)
              .overlay {
                Image(systemName: "plus")
                  .font(.title)
                  .foregroundColor(.secondary)
              }

            VStack(spacing: 2) {
              Text("Add")
                .font(.callout)
                .lineLimit(1)

              Text(" ")
                .font(.caption)
                .foregroundColor(.clear)
            }
          }
        }
        .buttonStyle(.plain)
      }

      // Existing participants
      ForEach(chatInfoView.participants) { userInfo in
        VStack(spacing: 4) {
          UserAvatar(userInfo: userInfo, size: 75)

          VStack(spacing: -2) {
            Text(userInfo.user.firstName ?? "User")
              .font(.callout)
              .foregroundColor(.primary)
              .lineLimit(1)

            if let username = userInfo.user.username {
              Text("@\(username)")
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
            } else {
              Text(" ")
                .font(.caption)
                .foregroundColor(.clear)
            }
          }
        }
        // .onTapGesture {
        //   chatInfoView.openParticipantChat(userInfo)
        // }
        .onLongPressGesture {
          if chatInfoView.isOwnerOrAdmin {
            let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
            impactFeedback.impactOccurred()
            participantToRemove = userInfo
            showRemoveAlert = true
          }
        }
        .transition(.asymmetric(
          insertion: .scale(scale: 0.8).combined(with: .opacity).combined(with: .move(edge: .bottom)),
          removal: .scale(scale: 0.8).combined(with: .opacity).combined(with: .move(edge: .top))
        ))
      }
    }
    .padding(.top, 8)
    .animation(.easeInOut(duration: 0.4), value: chatInfoView.participants.count)
  }
}

struct DocumentsTabView: View {
  @ObservedObject var documentsViewModel: ChatDocumentsViewModel
  let peerUserId: Int64?
  let peerThreadId: Int64?

  var body: some View {
    VStack(spacing: 16) {
      if documentsViewModel.documents.isEmpty {
        VStack(spacing: 8) {
          Text("No documents shared in this chat yet.")
            .font(.headline)
            .themedPrimaryText()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
      } else {
        // Documents content without scroll
        LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
          ForEach(documentsViewModel.groupedDocuments, id: \.date) { group in
            Section {
              // Documents for this date
              ForEach(group.documents, id: \.id) { document in
                DocumentRow(
                  documentInfo: document,
                  chatId: peerThreadId
                )
                .padding(.bottom, 8)
              }
            } header: {
              HStack {
                Text(formatDate(group.date))
                  .font(.subheadline)
                  .fontWeight(.medium)
                  .foregroundColor(.secondary)
                  .padding(.horizontal, 12)
                  .padding(.vertical, 6)
                  .background(
                    Capsule()
                      .fill(Color(.systemBackground).opacity(0.95))
                  )
                  .padding(.leading, 16)
                Spacer()
              }
              .padding(.vertical, 8)
            }
          }
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  // Format date for display
  private func formatDate(_ date: Date) -> String {
    let calendar = Calendar.current
    let now = Date()

    if calendar.isDateInToday(date) {
      return "Today"
    } else if calendar.isDateInYesterday(date) {
      return "Yesterday"
    } else if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) {
      let formatter = DateFormatter()
      formatter.dateFormat = "EEEE"
      return formatter.string(from: date)
    } else {
      let formatter = DateFormatter()
      formatter.dateFormat = "MMMM d, yyyy"
      return formatter.string(from: date)
    }
  }
}

// Preference key for scroll offset
struct ScrollOffsetPreferenceKey: PreferenceKey {
  static var defaultValue: CGFloat = 0

  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = nextValue()
  }
}
