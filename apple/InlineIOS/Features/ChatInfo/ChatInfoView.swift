import Auth
import Combine
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
  @EnvironmentStateObject var linksViewModel: ChatLinksViewModel
  @EnvironmentStateObject var mediaViewModel: ChatMediaViewModel
  @EnvironmentStateObject var spaceMembersViewModel: SpaceMembersViewModel
  @StateObject var spaceFullMembersViewModel: SpaceFullMembersViewModel
  @State  var space: Space?
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
  @State  var showMakePublicAlert = false
  @State  var showMakePrivateSheet = false
  @State  var selectedVisibilityParticipants: Set<Int64> = []
  @State  var chat: Chat?
  @State  var chatSubscription: AnyCancellable?
  @State  var isEditingInfo = false
  @State  var draftTitle = ""
  @State  var draftEmoji = ""
  @State  var isEmojiPickerPresented = false
  @State  var isSavingInfo = false
  @FocusState  var isTitleFocused: Bool

  @Environment(\.appDatabase) var database
  @Environment(\.colorScheme) var colorScheme

  enum ChatInfoTab: String, CaseIterable {
    case info = "Info"
    case media = "Media"
    case files = "Files"
    case links = "Links"
  }

  var availableTabs: [ChatInfoTab] {
    isDM ? [.media, .files, .links] : [.info, .media, .files, .links]
  }

  var currentChat: Chat? {
    chat ?? chatItem.chat
  }

  var currentChatId: Int64 {
    currentChat?.id ?? chatItem.chat?.id ?? 0
  }

  var isPrivate: Bool {
    currentChat?.isPublic == false
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

  var isCurrentUserParticipant: Bool {
    guard let currentUserId = Auth.shared.getCurrentUserId() else { return false }
    return participantsWithMembersViewModel.participants.contains(where: { $0.user.id == currentUserId })
  }

  var canEditChatInfo: Bool {
    guard !isDM else { return false }
    return isCurrentUserParticipant
  }

  var chatTitle: String {
    currentChat?.title ?? chatItem.chat?.title ?? "Chat"
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
        chatId: chatItem.chat?.id ?? 0,
        peer: chatItem.peerId
      )
    }

    _linksViewModel = EnvironmentStateObject { env in
      ChatLinksViewModel(
        db: env.appDatabase,
        chatId: chatItem.chat?.id ?? 0,
        peer: chatItem.peerId
      )
    }

    _mediaViewModel = EnvironmentStateObject { env in
      ChatMediaViewModel(
        db: env.appDatabase,
        chatId: chatItem.chat?.id ?? 0,
        peer: chatItem.peerId,
        excludeStickerMedia: true
      )
    }

    _spaceMembersViewModel = EnvironmentStateObject { env in
      SpaceMembersViewModel(db: env.appDatabase, spaceId: chatItem.chat?.spaceId ?? 0)
    }

    _spaceFullMembersViewModel = StateObject(wrappedValue: SpaceFullMembersViewModel(
      db: AppDatabase.shared,
      spaceId: chatItem.chat?.spaceId ?? 0
    ))

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
                    chatId: currentChatId,
                    chatItem: chatItem,
                    spaceMembersViewModel: spaceMembersViewModel,
                    space: space,
                    removeParticipant: { userInfo in
                      guard currentChatId != 0 else {
                        Log.shared.error("No chat ID found when trying to remove participant")
                        return
                      }
                      Task {
                        do {
                          try await Api.realtime.send(.removeChatParticipant(
                            chatID: currentChatId,
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
                    },
                    requestMakePublic: {
                      showMakePublicAlert = true
                    },
                    requestMakePrivate: {
                      guard !isDM else { return }
                      if let currentUserId = Auth.shared.getCurrentUserId() {
                        selectedVisibilityParticipants = [currentUserId]
                      } else {
                        selectedVisibilityParticipants = []
                      }
                      showMakePrivateSheet = true
                    }
                  ))
              }
            case .media:
              MediaTabView(
                mediaViewModel: mediaViewModel,
                onShowInChat: showMessageInChat
              )
            case .files:
              DocumentsTabView(
                documentsViewModel: documentsViewModel,
                peerUserId: chatItem.dialog.peerUserId,
                peerThreadId: chatItem.dialog.peerThreadId
              )
            case .links:
              LinksTabView(
                linksViewModel: linksViewModel
              )
          }
        }
        .animation(.easeInOut(duration: 0.3), value: selectedTab)
      }
      .coordinateSpace(name: "mainScroll")
    }
    .onAppear {
      subscribeToChatUpdates()
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
        if !availableTabs.contains(selectedTab) {
          selectedTab = availableTabs.first ?? .files
        }
      }
    }
    .onReceive(
      NotificationCenter.default
        .publisher(for: Notification.Name("chatDeletedNotification"))
    ) { notification in
      if let chatId = notification.userInfo?["chatId"] as? Int64,
         chatId == currentChatId
      {
        nav.pop()
      }
    }
    .sheet(isPresented: $isSearching) {
      searchSheet
    }
    .sheet(isPresented: $showMakePrivateSheet) {
      ChatVisibilityParticipantsSheet(
        spaceViewModel: spaceFullMembersViewModel,
        selectedParticipants: $selectedVisibilityParticipants,
        currentUserId: Auth.shared.getCurrentUserId(),
        onConfirm: {
          guard currentChatId != 0 else { return }
          var participantIds = selectedVisibilityParticipants
          if let currentUserId = Auth.shared.getCurrentUserId() {
            participantIds.insert(currentUserId)
          }
          Task {
            do {
              _ = try await Api.realtime.send(.updateChatVisibility(
                chatID: currentChatId,
                isPublic: false,
                participantIDs: participantIds.map(\.self)
              ))
              await participantsWithMembersViewModel.refetchParticipants()
              showMakePrivateSheet = false
            } catch {
              Log.shared.error("Failed to make chat ", error: error)
            }
          }
        },
        onCancel: {
          showMakePrivateSheet = false
        }
      )
    }
    .alert("Make Chat Public", isPresented: $showMakePublicAlert) {
      Button("Cancel", role: .cancel) {}
      Button("Make Public", role: .destructive) {
        guard currentChatId != 0 else { return }
        Task {
          do {
            _ = try await Api.realtime.send(.updateChatVisibility(
              chatID: currentChatId,
              isPublic: true,
              participantIDs: []
            ))
            await participantsWithMembersViewModel.refetchParticipants()
          } catch {
            Log.shared.error("Failed to make chat public", error: error)
          }
        }
      }
    } message: {
      Text("People without access to public chats will lose access to this thread.")
    }
    .toolbar {
      if canEditChatInfo {
        if isEditingInfo {
          ToolbarItem(placement: .topBarLeading) {
            Button("Cancel") {
              cancelEditingChatInfo()
            }
            .buttonStyle(.borderless)
          }
          ToolbarItem(placement: .topBarTrailing) {
            Button(isSavingInfo ? "Saving..." : "Save") {
              saveChatInfo()
            }
            .buttonStyle(.borderless)
            .disabled(!canSaveChatInfo || isSavingInfo)
            .opacity((!canSaveChatInfo || isSavingInfo) ? 0.5 : 1)
          }
        } else {
          ToolbarItem(placement: .topBarTrailing) {
            Button("Edit") {
              startEditingChatInfo()
            }
            .buttonStyle(.borderless)
          }
        }
      }
    }
  }

  @MainActor
   func subscribeToChatUpdates() {
    guard chatSubscription == nil else { return }
    guard case let .thread(chatId) = chatItem.peerId else { return }

    chatSubscription = ObjectCache.shared.getChatPublisher(id: chatId)
      .sink { updatedChat in
        DispatchQueue.main.async {
          self.chat = updatedChat
        }
      }
  }
}

struct InfoTabView: View {
  @EnvironmentObject  var chatInfoView: ChatInfoViewEnvironment
  @State  var participantToRemove: UserInfo?
  @State  var showRemoveAlert = false

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

        if chatInfoView.isOwnerOrAdmin, !chatInfoView.isDM {
          Divider()
            .padding(.horizontal, 16)

          Button(action: {
            if chatInfoView.isPrivate {
              chatInfoView.requestMakePublic()
            } else {
              chatInfoView.requestMakePrivate()
            }
          }) {
            HStack {
              Image(systemName: chatInfoView.isPrivate ? "person.2.fill" : "lock.fill")
              Text(chatInfoView.isPrivate ? "Make Public" : "Make Private")
                .font(.callout)
              Spacer()
            }
            .foregroundColor(Color(ThemeManager.shared.selected.accent))
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
          }
          .buttonStyle(.plain)
        }
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
          ParticipantAvatarView(userInfo: userInfo, size: 68)
            .frame(width: 68, height: 68)

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

struct ParticipantAvatarView: UIViewRepresentable {
  let userInfo: UserInfo
  let size: CGFloat

  func makeUIView(context: Context) -> UserAvatarView {
    let view = UserAvatarView()
    view.isUserInteractionEnabled = true
    let tapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap))
    tapGesture.delegate = context.coordinator
    view.addGestureRecognizer(tapGesture)
    return view
  }

  func updateUIView(_ uiView: UserAvatarView, context: Context) {
    uiView.configure(with: userInfo, size: size)
    context.coordinator.userInfo = userInfo
    context.coordinator.avatarView = uiView
  }

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  class Coordinator: NSObject, UIGestureRecognizerDelegate {
    var userInfo: UserInfo?
    weak var avatarView: UserAvatarView?

    @objc func handleTap() {
      guard let userInfo, let avatarView else { return }

      let sourceImage = avatarView.currentImage() ?? snapshotImage(from: avatarView)
      guard let resolved = resolveAvatarURL(for: userInfo, fallbackImage: sourceImage) else { return }

      let sourceCornerRadius = max(
        avatarView.layer.cornerRadius,
        min(avatarView.bounds.width, avatarView.bounds.height) / 2
      )
      let imageViewer = ImageViewerController(
        imageURL: resolved.url,
        sourceView: avatarView,
        sourceImage: sourceImage,
        sourceCornerRadius: sourceCornerRadius
      )
      if resolved.isTemporary {
        let temporaryUrl = resolved.url
        imageViewer.onDismiss = {
          try? FileManager.default.removeItem(at: temporaryUrl)
        }
      }

      findViewController(from: avatarView)?.present(imageViewer, animated: false)
    }

    func gestureRecognizer(
      _ gestureRecognizer: UIGestureRecognizer,
      shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
      true
    }

     func resolveAvatarURL(
      for userInfo: UserInfo,
      fallbackImage: UIImage?
    ) -> (url: URL, isTemporary: Bool)? {
      if let localUrl = userInfo.user.getLocalURL(),
         FileManager.default.fileExists(atPath: localUrl.path)
      {
        return (localUrl, false)
      }

      if let localFileUrl = userInfo.profilePhoto?.first?.getLocalURL(),
         FileManager.default.fileExists(atPath: localFileUrl.path)
      {
        return (localFileUrl, false)
      }

      if let remoteUrl = userInfo.user.getRemoteURL() {
        return (remoteUrl, false)
      }

      if let remoteFileUrl = userInfo.profilePhoto?.first?.getRemoteURL() {
        return (remoteFileUrl, false)
      }

      guard let fallbackImage, let temporaryUrl = cacheTemporaryImage(fallbackImage) else { return nil }
      return (temporaryUrl, true)
    }

     func cacheTemporaryImage(_ image: UIImage) -> URL? {
      guard let data = image.jpegData(compressionQuality: 0.95) else { return nil }
      let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("avatar-\(UUID().uuidString).jpg")
      do {
        try data.write(to: url, options: [.atomic])
        return url
      } catch {
        Log.shared.error("Failed to cache avatar snapshot", error: error)
        return nil
      }
    }

     func snapshotImage(from view: UIView) -> UIImage? {
      guard view.bounds.width > 0, view.bounds.height > 0 else { return nil }
      let renderer = UIGraphicsImageRenderer(bounds: view.bounds)
      return renderer.image { context in
        view.layer.render(in: context.cgContext)
      }
    }

     func findViewController(from view: UIView) -> UIViewController? {
      var responder: UIResponder? = view
      while let nextResponder = responder?.next {
        if let viewController = nextResponder as? UIViewController {
          return viewController
        }
        responder = nextResponder
      }
      return nil
    }
  }
}
