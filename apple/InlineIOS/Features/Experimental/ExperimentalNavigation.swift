import Combine
import GRDB
import InlineKit
import InlineUI
import Invite
import Logger
import SwiftUI

@MainActor
@Observable
final class ExperimentalNavigationModel {
  private static let activeSpaceDefaultsKey = "activeSpaceId"

  var activeSpaceId: Int64? {
    didSet {
      saveActiveSpaceId(activeSpaceId)
    }
  }

  init() {
    activeSpaceId = Self.loadActiveSpaceId()
  }

  private static func loadActiveSpaceId() -> Int64? {
    let defaults = UserDefaults.standard

    if let value = defaults.object(forKey: activeSpaceDefaultsKey) as? Int64 {
      return value
    }
    if let value = defaults.object(forKey: activeSpaceDefaultsKey) as? Int {
      return Int64(value)
    }
    if let value = defaults.object(forKey: activeSpaceDefaultsKey) as? NSNumber {
      return value.int64Value
    }
    return nil
  }

  private func saveActiveSpaceId(_ spaceId: Int64?) {
    let defaults = UserDefaults.standard
    if let spaceId {
      defaults.set(spaceId, forKey: Self.activeSpaceDefaultsKey)
    } else {
      defaults.removeObject(forKey: Self.activeSpaceDefaultsKey)
    }
  }
}

struct ExperimentalDestinationView: View {
  @Bindable var nav: ExperimentalNavigationModel
  let destination: Destination

  var body: some View {
    content
  }

  @ViewBuilder
  private var content: some View {
    switch destination {
    case .chats:
      ExperimentalHomeView(nav: nav, initialTab: .inbox)
    case .archived:
      ExperimentalHomeView(nav: nav, initialTab: .archived)
    case .spaces:
      SpacesView()
    case let .space(id):
      SpaceView(spaceId: id)
    case let .chat(peer):
      ChatView(peer: peer, autoCleanupUntitledEmptyThreadOnBack: true)
    case let .chatInfo(chatItem):
      ChatInfoView(chatItem: chatItem)
    case let .spaceSettings(spaceId):
      SpaceSettingsView(spaceId: spaceId)
    case let .spaceIntegrations(spaceId):
      SpaceIntegrationsView(spaceId: spaceId)
    case let .integrationOptions(spaceId, provider):
      IntegrationOptionsView(spaceId: spaceId, provider: provider)
    case .createSpaceChat:
      CreateChatView(spaceId: nil)
    case let .createThread(spaceId):
      CreateChatView(spaceId: spaceId)
    case .createSpace:
      CreateSpaceView()
    }
  }
}

struct ExperimentalSheetView: View {
  let sheet: Sheet

  var body: some View {
    switch sheet {
    case .settings:
      NavigationStack {
        SettingsView()
      }
    case .createSpace:
      CreateSpace()
    case .alphaSheet:
      AlphaSheet()
    case let .addMember(spaceId):
      InviteToSpaceView(spaceId: spaceId)
    case let .members(spaceId):
      ExperimentalMembersSheetView(spaceId: spaceId)
    }
  }
}

// MARK: - Home

private enum ExperimentalHomeTab: Hashable {
  case inbox
  case archived
}

private struct ExperimentalHomeView: View {
  @Bindable var nav: ExperimentalNavigationModel
  let initialTab: ExperimentalHomeTab

  @Environment(Router.self) private var router
  @EnvironmentObject private var compactSpaceList: CompactSpaceList
  @EnvironmentObject private var data: DataManager
  @EnvironmentObject private var home: HomeViewModel
  @EnvironmentStateObject private var chatsModel: ExperimentalSpaceChatsViewModel

  @AppStorage(ExperimentalHomePreferenceKeys.chatScope) private var homeChatScopeRaw: String = ExperimentalHomeChatScope.all.rawValue
  @AppStorage(ExperimentalHomePreferenceKeys.chatItemRenderMode) private var chatItemRenderModeRaw: String = ExperimentalHomeChatItemRenderMode.twoLineLastMessage.rawValue
  @State private var didInitialFetch = false
  @State private var fetchedSpaceIds = Set<Int64>()

  init(nav: ExperimentalNavigationModel, initialTab: ExperimentalHomeTab) {
    self.nav = nav
    self.initialTab = initialTab
    _chatsModel = EnvironmentStateObject { env in
      ExperimentalSpaceChatsViewModel(db: env.appDatabase)
    }
  }

  var body: some View {
    Group {
      switch initialTab {
      case .inbox:
        ExperimentalChatListView(
          items: inboxItems,
          emptyStyle: .inlineLogo,
          emptyTitle: "No chats",
          emptySubtitle: "Start a new chat with the plus button.",
          sectionHeader: nil,
          showsSpaceNameInRows: nav.activeSpaceId == nil,
          chatItemRenderMode: chatItemRenderMode,
          onTapItem: openChat
        )
      case .archived:
        ExperimentalChatListView(
          items: archivedItems,
          emptyStyle: .text,
          emptyTitle: "No archived chats",
          emptySubtitle: "Archived chats will show up here.",
          sectionHeader: "Archived Chats",
          showsSpaceNameInRows: nav.activeSpaceId == nil,
          chatItemRenderMode: chatItemRenderMode,
          onTapItem: openChat
        )
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(.systemBackground))
    .navigationBarTitleDisplayMode(.inline)
    .navigationTitle("")
    .task {
      guard !didInitialFetch else { return }
      didInitialFetch = true
      await initialFetch()
    }
    .onChange(of: compactSpaceList.spaces) { _, _ in
      ensureActiveSpaceExists()
      chatsModel.setSpaceId(nav.activeSpaceId)
      Task { await refreshDialogsForCurrentSelection() }
    }
    .onChange(of: nav.activeSpaceId) { _, newValue in
      chatsModel.setSpaceId(newValue)
      Task { await refreshDialogsForCurrentSelection() }
    }
  }

  private var homeChatScope: ExperimentalHomeChatScope {
    ExperimentalHomeChatScope(rawValue: homeChatScopeRaw) ?? .all
  }

  private var chatItemRenderMode: ExperimentalHomeChatItemRenderMode {
    ExperimentalHomeChatItemRenderMode(rawValue: chatItemRenderModeRaw) ?? .twoLineLastMessage
  }

  private var visibleChats: [HomeChatItem] { chatsModel.items }

  private var currentChats: [HomeChatItem] {
    if nav.activeSpaceId == nil {
      let sorted = HomeViewModel.sortChats(home.chats)
      return sorted.filter { item in
        switch homeChatScope {
        case .all:
          true
        case .home:
          item.space == nil
        case .spaces:
          item.space != nil
        }
      }
    } else {
      return visibleChats
    }
  }

  private var inboxItems: [HomeChatItem] {
    currentChats.filter { $0.dialog.archived != true }
  }

  private var archivedItems: [HomeChatItem] {
    currentChats.filter { $0.dialog.archived == true }
  }

  private func ensureActiveSpaceExists() {
    guard let activeSpaceId = nav.activeSpaceId else { return }
    if !compactSpaceList.spaces.contains(where: { $0.id == activeSpaceId }) {
      nav.activeSpaceId = nil
    }
  }

  private func openChat(_ item: HomeChatItem) {
    router.push(.chat(peer: item.peerId))
  }

  private func initialFetch() async {
    do {
      _ = try await data.getSpaces()
    } catch {
      Log.shared.error("Failed to getSpaces", error: error)
    }
    chatsModel.setSpaceId(nav.activeSpaceId)
    await refreshDialogsForCurrentSelection()
  }

  private func refreshDialogsForCurrentSelection() async {
    if let spaceId = nav.activeSpaceId {
      await fetchDialogsIfNeeded(spaceId: spaceId)
    } else {
      // Home: show chats from all spaces, so ensure each space has at least one dialogs fetch.
      for space in compactSpaceList.spaces {
        await fetchDialogsIfNeeded(spaceId: space.id)
      }
    }
  }

  private func fetchDialogsIfNeeded(spaceId: Int64) async {
    guard fetchedSpaceIds.insert(spaceId).inserted else { return }
    do {
      try await data.getDialogs(spaceId: spaceId)
    } catch {
      Log.shared.error("Failed to get dialogs", error: error)
    }
  }
}

@MainActor
private final class ExperimentalSpaceChatsViewModel: ObservableObject {
  @Published private(set) var items: [HomeChatItem] = []

  private let db: AppDatabase
  private let log = Log.scoped("ExperimentalSpaceChatsViewModel")
  private var cancellable: AnyCancellable?
  private var activeSpaceId: Int64?

  init(db: AppDatabase) {
    self.db = db
  }

  func setSpaceId(_ spaceId: Int64?) {
    guard activeSpaceId != spaceId else { return }
    activeSpaceId = spaceId
    bind()
  }

  private func bind() {
    cancellable?.cancel()

    guard let spaceId = activeSpaceId else {
      items = []
      return
    }

    let spaceIdValue = spaceId

    cancellable = ValueObservation
      .tracking { db in
        let space = try Space.fetchOne(db, id: spaceIdValue)

        let threads = try Dialog
          .spaceChatItemQuery()
          .filter(Column("spaceId") == spaceIdValue)
          .fetchAll(db)

        let contacts = try Dialog
          .spaceChatItemQueryForUser()
          .filter(
            sql: "dialog.peerUserId IN (SELECT userId FROM member WHERE spaceId = ?)",
            arguments: StatementArguments([spaceIdValue])
          )
          .fetchAll(db)

        return ExperimentalSpaceChatsSnapshot(
          space: space,
          threadItems: threads,
          contactItems: contacts
        )
      }
      .publisher(in: db.dbWriter, scheduling: .immediate)
      .sink(
        receiveCompletion: { [weak self] completion in
          guard let self else { return }
          if case let .failure(error) = completion {
            log.error("Failed to fetch experimental space chats for spaceId=\(spaceIdValue): \(error)")
          }
        },
        receiveValue: { [weak self] snapshot in
          guard let self else { return }

          let mapped = Self.mergeUnique(
            (snapshot.threadItems + snapshot.contactItems).map { item in
              HomeChatItem(
                dialog: item.dialog,
                user: item.userInfo,
                chat: item.chat,
                lastMessage: Self.embeddedMessage(for: item),
                space: snapshot.space
              )
            }
          )
          .filter { $0.chat != nil || $0.user != nil }

          items = HomeViewModel.sortChats(mapped)
        }
      )
  }

  private static func embeddedMessage(for item: SpaceChatItem) -> EmbeddedMessage? {
    guard let message = item.message else { return nil }
    return EmbeddedMessage(
      message: message,
      senderInfo: item.from,
      translations: item.translations,
      photoInfo: item.photoInfo,
      videoInfo: nil
    )
  }

  private static func mergeUnique(_ items: [HomeChatItem]) -> [HomeChatItem] {
    var seen = Set<Int64>()
    return items.filter { item in
      seen.insert(item.id).inserted
    }
  }

  private struct ExperimentalSpaceChatsSnapshot: Sendable {
    let space: Space?
    let threadItems: [SpaceChatItem]
    let contactItems: [SpaceChatItem]
  }
}

private struct ExperimentalChatListView: View {
  enum EmptyStyle {
    case text
    case inlineLogo
  }

  let items: [HomeChatItem]
  let emptyStyle: EmptyStyle
  let emptyTitle: String
  let emptySubtitle: String
  let sectionHeader: String?
  let showsSpaceNameInRows: Bool
  let chatItemRenderMode: ExperimentalHomeChatItemRenderMode
  let onTapItem: (HomeChatItem) -> Void

  @EnvironmentObject private var data: DataManager

  var body: some View {
    if items.isEmpty {
      switch emptyStyle {
      case .text:
        ExperimentalEmptyStateView(title: emptyTitle, subtitle: emptySubtitle)
      case .inlineLogo:
        ExperimentalInlineLogoEmptyStateView()
      }
    } else {
      List {
        if let sectionHeader {
          Section {
            rows
          } header: {
            Text(sectionHeader)
              .textCase(nil)
          }
        } else {
          rows
        }
      }
      .listStyle(.plain)
      .animation(.snappy(duration: 0.25, extraBounce: 0), value: itemIDs)
    }
  }

  private var itemIDs: [Int64] {
    items.map(\.id)
  }

  private var rows: some View {
    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
      Button {
        onTapItem(item)
      } label: {
        rowContent(for: item)
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .swipeActions(edge: .trailing, allowsFullSwipe: true) {
        archiveButton(for: item)
      }
      .listRowSeparator(index == 0 ? .hidden : .visible, edges: .top)
      .listRowInsets(EdgeInsets(
        top: 8,
        leading: 16,
        bottom: 8,
        trailing: 16
      ))
      .transition(
        .asymmetric(
          insertion: .opacity.combined(with: .move(edge: .top)),
          removal: .opacity.combined(with: .move(edge: .top))
        )
      )
    }
  }

  @ViewBuilder
  private func archiveButton(for item: HomeChatItem) -> some View {
    let isArchived = item.dialog.archived == true

    Button(role: isArchived ? nil : .destructive) {
      Task {
        try await data.updateDialog(
          peerId: item.peerId,
          archived: !isArchived
        )
      }
    } label: {
      Label(
        isArchived ? "Unarchive" : "Archive",
        systemImage: isArchived ? "tray.and.arrow.up.fill" : "tray.and.arrow.down.fill"
      )
    }
    .tint(Color(.systemPurple))
  }

  @ViewBuilder
  private func rowContent(for item: HomeChatItem) -> some View {
    if let user = item.user {
      ChatListItem(
        type: .user(user, chat: item.chat),
        dialog: item.dialog,
        lastMessage: item.lastMessage?.message,
        lastMessageSender: item.lastMessage?.senderInfo,
        embeddedLastMessage: item.lastMessage,
        displayMode: chatItemRenderMode.chatListItemDisplayMode
      )
    } else if let chat = item.chat {
      ChatListItem(
        type: .chat(chat, spaceName: showsSpaceNameInRows ? item.space?.nameWithoutEmoji : nil),
        dialog: item.dialog,
        lastMessage: item.lastMessage?.message,
        lastMessageSender: item.lastMessage?.senderInfo,
        embeddedLastMessage: item.lastMessage,
        displayMode: chatItemRenderMode.chatListItemDisplayMode
      )
    } else {
      EmptyView()
    }
  }
}

private extension ExperimentalHomeChatItemRenderMode {
  var chatListItemDisplayMode: ChatListItem.DisplayMode {
    switch self {
    case .twoLineLastMessage:
      .twoLineLastMessage
    case .oneLineLastMessage:
      .oneLineLastMessage
    case .noLastMessage:
      .minimal
    }
  }
}

private struct ExperimentalEmptyStateView: View {
  let title: String
  let subtitle: String

  var body: some View {
    VStack(spacing: 10) {
      Text(title)
        .font(.title3)
        .fontWeight(.semibold)

      Text(subtitle)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(.systemBackground))
  }
}

private struct ExperimentalInlineLogoEmptyStateView: View {
  @Environment(\.colorScheme) private var colorScheme

  private var imageOpacity: Double {
    colorScheme == .dark ? 0.2 : 1.0
  }

  var body: some View {
    Image("inline-logo-bg")
      .resizable()
      .scaledToFit()
      .frame(maxWidth: 320, maxHeight: 320)
      .opacity(imageOpacity)
      .accessibilityHidden(true)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color(.systemBackground))
  }
}

// MARK: - Members Sheet

struct ExperimentalMembersSheetView: View {
  let spaceId: Int64

  @Environment(Router.self) private var router
  @EnvironmentStateObject private var viewModel: SpaceFullMembersViewModel

  init(spaceId: Int64) {
    self.spaceId = spaceId
    _viewModel = EnvironmentStateObject { env in
      SpaceFullMembersViewModel(db: env.appDatabase, spaceId: spaceId)
    }
  }

  var body: some View {
    NavigationStack {
      List {
        ForEach(viewModel.filteredMembers) { member in
          ExperimentalMemberRow(
            member: member,
            onMessage: {
              router.dismissSheet()
              router.push(.chat(peer: .user(id: member.userInfo.user.id)))
            }
          )
          .listRowSeparator(.hidden)
          .listRowBackground(Color.clear)
        }
      }
      .listStyle(.plain)
      .navigationTitle("Members")
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button {
            Task {
              await viewModel.refetchMembers()
            }
          } label: {
            if viewModel.isLoading {
              ProgressView()
            } else {
              Image(systemName: "arrow.clockwise")
            }
          }
          .accessibilityLabel("Refresh")
        }
      }
    }
  }
}

private struct ExperimentalMemberRow: View {
  let member: FullMemberItem
  let onMessage: () -> Void

  @Environment(\.colorScheme) private var colorScheme

  private var buttonFill: Color {
    colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.045)
  }

  private var borderColor: Color {
    colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.07)
  }

  var body: some View {
    HStack(spacing: 12) {
      UserAvatar(userInfo: member.userInfo, size: 34)

      Text(member.userInfo.user.displayName)
        .font(.system(size: 16, weight: .medium))
        .foregroundStyle(.primary)
        .lineLimit(1)

      Spacer(minLength: 0)

      Button(action: onMessage) {
        Image(systemName: "bubble.left.and.bubble.right.fill")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(.primary)
          .frame(width: 34, height: 34)
          .background(buttonFill, in: Circle())
          .overlay(
            Circle().stroke(borderColor, lineWidth: 0.5)
          )
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Message")
    }
    .padding(.vertical, 6)
  }
}

// MARK: - Avatars (synced with macOS experimental UI)

private struct ExperimentalSidebarChatIcon: View, Equatable {
  enum PeerType: Equatable {
    case chat(Chat)
    case user(UserInfo)

    static func == (lhs: PeerType, rhs: PeerType) -> Bool {
      switch (lhs, rhs) {
      case let (.chat(lhsChat), .chat(rhsChat)):
        return lhsChat.id == rhsChat.id
          && lhsChat.title == rhsChat.title
          && lhsChat.emoji == rhsChat.emoji

      case let (.user(lhsUserInfo), .user(rhsUserInfo)):
        return userNameSignature(lhsUserInfo.user) == userNameSignature(rhsUserInfo.user)
          && profilePhotoId(lhsUserInfo) == profilePhotoId(rhsUserInfo)

      default:
        return false
      }
    }

    private static func userNameSignature(_ user: User) -> UserNameSignature {
      UserNameSignature(
        firstName: user.firstName,
        lastName: user.lastName,
        username: user.username,
        phoneNumber: user.phoneNumber,
        email: user.email
      )
    }

    private static func profilePhotoId(_ userInfo: UserInfo) -> String? {
      userInfo.profilePhoto?.first?.id ?? userInfo.user.profileFileId
    }

    private struct UserNameSignature: Hashable {
      let firstName: String?
      let lastName: String?
      let username: String?
      let phoneNumber: String?
      let email: String?
    }
  }

  var peer: PeerType
  var size: CGFloat = 34

  static func == (lhs: ExperimentalSidebarChatIcon, rhs: ExperimentalSidebarChatIcon) -> Bool {
    lhs.peer == rhs.peer && lhs.size == rhs.size
  }

  var body: some View {
    switch peer {
    case let .chat(chat):
      ExperimentalThreadIcon(emoji: normalizedEmoji(chat.emoji), size: size)
    case let .user(userInfo):
      UserAvatar(userInfo: userInfo, size: size)
    }
  }

  private func normalizedEmoji(_ emoji: String?) -> String? {
    guard let emoji else { return nil }
    let trimmed = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

private struct ExperimentalThreadIcon: View {
  let emoji: String?
  let size: CGFloat

  @Environment(\.colorScheme) private var colorScheme

  private static let lightTop = Color(.sRGB, red: 241 / 255, green: 239 / 255, blue: 239 / 255, opacity: 0.5)
  private static let lightBottom = Color(.sRGB, red: 229 / 255, green: 229 / 255, blue: 229 / 255, opacity: 0.5)
  private static let darkTop = Color(.sRGB, red: 58 / 255, green: 58 / 255, blue: 58 / 255, opacity: 0.5)
  private static let darkBottom = Color(.sRGB, red: 44 / 255, green: 44 / 255, blue: 44 / 255, opacity: 0.5)
  private static let symbolForeground = Color(.sRGB, red: 0.35, green: 0.35, blue: 0.35, opacity: 1)

  private var backgroundGradient: LinearGradient {
    let colors = colorScheme == .dark
      ? [Self.darkTop, Self.darkBottom]
      : [Self.lightTop, Self.lightBottom]

    return LinearGradient(
      colors: colors,
      startPoint: .top,
      endPoint: .bottom
    )
  }

  private var borderColor: Color {
    colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.06)
  }

  private var emojiPointSize: CGFloat { size * 0.5 }
  private var symbolPointSize: CGFloat { size * 0.5 }

  var body: some View {
    Circle()
      .fill(backgroundGradient)
      .overlay(
        Circle()
          .stroke(borderColor, lineWidth: 0.5)
      )
      .overlay {
        if let emoji {
          Text(emoji)
            .font(.system(size: emojiPointSize, weight: .regular))
        } else {
          Image(systemName: "number")
            .font(.system(size: symbolPointSize, weight: .medium))
            .foregroundColor(Self.symbolForeground)
        }
      }
      .frame(width: size, height: size)
      .fixedSize()
  }
}
