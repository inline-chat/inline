import AppKit
import Combine
import GRDB
import InlineKit
import Logger
import SwiftUI
import Translation

struct AllChatsRouteView: View {
  @Environment(\.dependencies) private var dependencies
  @Environment(\.nav) private var nav
  @EnvironmentStateObject private var viewModel: AllChatsViewModel
  @State private var rowLayout: AllChatsRowLayout = .twoLine

  private let filter: AllChatsFilter

  init(archived: Bool = false) {
    filter = archived ? .archived : .chats
    _viewModel = EnvironmentStateObject { env in
      AllChatsViewModel(db: env.appDatabase)
    }
  }

  var body: some View {
    let title = pageTitle
    let sections = viewModel.sections(for: filter, spaceId: nav.selectedSpaceId)

    ZStack {
      if viewModel.isLoading {
        ProgressView()
          .controlSize(.small)
      } else if viewModel.errorText != nil || (sections.isEmpty && filter == .archived) {
        RoutePlaceholderView(
          title: viewModel.errorText ?? filter.emptyTitle,
          systemImage: viewModel.errorText == nil ? filter.emptySystemImage : "exclamationmark.triangle"
        )
      } else {
        chatList(sections: sections)
      }
    }
    .navigationTitle(title)
    .toolbar(removing: .title)
    .toolbar {
      let titleItem =
        ToolbarItem(placement: .navigation) {
          RouteToolbarTitleItem(title: title)
            .toolbarVisibilityPriority(.high, label: "")
        }

      if #available(macOS 26.0, *) {
        titleItem.sharedBackgroundVisibility(.hidden)
      } else {
        titleItem
      }

      if #available(macOS 26.0, *) {
        ToolbarSpacer(.flexible)
      }

      ToolbarItem {
        rowLayoutMenu
      }

      ToolbarItem {
        Button(action: toggleArchiveFilter) {
          Label(filter.archiveButtonTitle, systemImage: filter.archiveButtonSystemImage)
        }
        .help(filter.archiveButtonTitle)
      }
    }
    .onEscapeKey("all_chats_archive_escape", enabled: filter == .archived) {
      closeArchiveFilter()
    }
    .onExitCommand {
      guard filter == .archived else { return }
      closeArchiveFilter()
    }
  }

  private func chatList(sections: [AllChatsSection]) -> some View {
    List {
      if filter == .chats {
        NewThreadListRow(action: createNewThread)
          .listRowInsets(EdgeInsets(top: 0, leading: 5, bottom: 0, trailing: 5))
          .listRowSeparator(.hidden)
          .listRowBackground(Color.clear)
      }

      ForEach(sections) { section in
        Section {
          ForEach(section.items) { item in
            ChatListRow(
              item: item,
              selected: nav.currentRoute.selectedPeer == item.peerId,
              showsSpaceName: nav.selectedSpaceId == nil,
              layout: rowLayout,
              switchToSpace: openSpace,
              action: {
                open(item)
              }
            )
            .listRowInsets(EdgeInsets(top: 0, leading: 5, bottom: 0, trailing: 5))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
          }
        } header: {
          AllChatsSectionHeader(title: section.title)
        }
        .listSectionSeparator(.hidden)
      }
    }
    .listStyle(.inset)
    .scrollContentBackground(.hidden)
    .allChatsScrollEdgeEffect()
  }

  private var pageTitle: String {
    filter.title(spaceName: activeSpaceName)
  }

  private var activeSpaceName: String? {
    viewModel.spaceName(id: nav.selectedSpaceId)
  }

  private func open(_ item: AllChatsItem) {
    if let dependencies {
      if nav.selectedSpaceId == nil {
        dependencies.requestOpenChatInHome(peer: item.peerId)
      } else {
        dependencies.requestOpenChat(peer: item.peerId)
      }
      return
    }

    if nav.selectedSpaceId == nil {
      nav.selectHome()
    }
    nav.open(.chat(peer: item.peerId))
  }

  private func openSpace(_ spaceId: Int64) {
    nav.selectSpace(spaceId)
  }

  private func createNewThread() {
    guard let dependencies else {
      nav.open(.newChat(spaceId: nav.selectedSpaceId))
      return
    }

    NewThreadAction.start(dependencies: dependencies, spaceId: nav.selectedSpaceId)
  }

  private var rowLayoutMenu: some View {
    Menu {
      Button {
        rowLayout = rowLayout == .twoLine ? .titlePreviewLine : .twoLine
      } label: {
        if rowLayout == .titlePreviewLine {
          Label("Title and Preview on One Line", systemImage: "checkmark")
        } else {
          Text("Title and Preview on One Line")
        }
      }
    } label: {
      Label("View Options", systemImage: "line.3.horizontal.decrease")
    }
    .help("View Options")
  }

  private func toggleArchiveFilter() {
    filter == .archived ? closeArchiveFilter() : openArchiveFilter()
  }

  private func openArchiveFilter() {
    guard filter != .archived else { return }
    nav.open(.archivedChats)
  }

  private func closeArchiveFilter() {
    guard filter == .archived else { return }

    if previousRoute == .allChats {
      nav.goBack()
    } else {
      nav.replace(.allChats)
    }
  }

  private var previousRoute: Nav3Route? {
    let index = nav.historyIndex - 1
    guard nav.history.indices.contains(index) else { return nil }
    return nav.history[index]
  }
}

private enum AllChatsRowLayout: Equatable {
  case twoLine
  case titlePreviewLine
}

private enum AllChatsFilter: Equatable {
  case chats
  case archived

  var title: String {
    switch self {
    case .chats:
      "Chats"
    case .archived:
      "Archived Chats"
    }
  }

  func title(spaceName: String?) -> String {
    guard let spaceName, spaceName.isEmpty == false else {
      return title
    }

    switch self {
    case .chats:
      return "\(spaceName) Chats"
    case .archived:
      return "Archived \(spaceName) Chats"
    }
  }

  var emptyTitle: String {
    switch self {
    case .chats:
      "No chats"
    case .archived:
      "No archived chats"
    }
  }

  var emptySystemImage: String {
    switch self {
    case .chats:
      "bubble.left"
    case .archived:
      "archivebox"
    }
  }

  var archiveButtonTitle: String {
    switch self {
    case .chats:
      "Archive"
    case .archived:
      "Show Chats"
    }
  }

  var archiveButtonSystemImage: String {
    switch self {
    case .chats:
      "archivebox"
    case .archived:
      "archivebox.fill"
    }
  }

  func includes(_ item: AllChatsItem) -> Bool {
    switch self {
    case .chats:
      item.archived == false
    case .archived:
      item.archived
    }
  }
}

private extension View {
  @ViewBuilder
  func allChatsScrollEdgeEffect() -> some View {
    if #available(macOS 26.0, *) {
      scrollEdgeEffectStyle(.hard, for: .top)
    } else {
      self
    }
  }
}

private struct AllChatsSectionHeader: View {
  let title: String

  var body: some View {
    Text(title)
      .font(.system(size: 12, weight: .semibold))
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 13)
      .padding(.top, 2)
      .padding(.bottom, 0)
  }
}

@MainActor
final class AllChatsViewModel: ObservableObject {
  @Published private(set) var items: [AllChatsItem] = []
  @Published private(set) var spacesById: [Int64: Space] = [:]
  @Published private(set) var isLoading = true
  @Published private(set) var errorText: String?

  private let db: AppDatabase
  private let log = Log.scoped("AllChatsViewModel")
  private var chatsCancellable: AnyCancellable?
  private var spacesCancellable: AnyCancellable?

  init(db: AppDatabase) {
    self.db = db
    observeChats()
    observeSpaces()
  }

  private func observeChats() {
    #if DEBUG
    db.warnIfInMemoryDatabaseForObservation("AllChatsViewModel.chats")
    #endif

    chatsCancellable = ValueObservation
      .tracking { db in
        let chats = try HomeChatItem.all().fetchAll(db)
        return try Self.makeItems(chats, db: db)
      }
      .publisher(in: db.dbWriter, scheduling: .immediate)
      .sink(
        receiveCompletion: { [weak self] completion in
          guard let self else { return }

          if case let .failure(error) = completion {
            isLoading = false
            errorText = error.localizedDescription
            log.error("All chats observation failed: \(error.localizedDescription)")
          }
        },
        receiveValue: { [weak self] items in
          guard let self else { return }
          apply(items)
        }
      )
  }

  private func observeSpaces() {
    spacesCancellable = ValueObservation
      .tracking { db in
        try Space.fetchAll(db)
      }
      .publisher(in: db.dbWriter, scheduling: .immediate)
      .sink(
        receiveCompletion: { [weak self] completion in
          guard case let .failure(error) = completion else { return }
          self?.log.error("All chats spaces observation failed: \(error.localizedDescription)")
        },
        receiveValue: { [weak self] spaces in
          self?.spacesById = Dictionary(uniqueKeysWithValues: spaces.map { ($0.id, $0) })
        }
      )
  }

  private func apply(_ items: [AllChatsItem]) {
    self.items = items
      .sorted { lhs, rhs in
        if lhs.lastActivityDate == rhs.lastActivityDate {
          return lhs.id > rhs.id
        }
        return lhs.lastActivityDate > rhs.lastActivityDate
      }

    errorText = nil
    isLoading = false
  }

  private nonisolated static func makeItems(_ chats: [HomeChatItem], db: Database) throws -> [AllChatsItem] {
    let titles = try ReplyThreadTitleFallback.titlesByChatId(for: chats, db: db)
    return HomeViewModel
      .filterEmptyChats(chats)
      .compactMap { chat in
        AllChatsItem(chat: chat, titleOverride: chat.chat.flatMap { titles[$0.id] })
      }
  }

  fileprivate func sections(for filter: AllChatsFilter, spaceId: Int64?) -> [AllChatsSection] {
    Self.makeSections(items: items.filter { item in
      item.chatListHidden == false
        && filter.includes(item)
        && (spaceId == nil || item.spaceId == spaceId)
    })
  }

  fileprivate func spaceName(id: Int64?) -> String? {
    guard let id else { return nil }
    return spacesById[id]?.displayName
  }

  private static func makeSections(items: [AllChatsItem]) -> [AllChatsSection] {
    let calendar = Calendar.current
    var sections: [AllChatsSection] = []

    for item in items {
      let day = calendar.startOfDay(for: item.lastActivityDate)
      if sections.last?.id == day {
        sections[sections.count - 1].items.append(item)
      } else {
        sections.append(AllChatsSection(
          id: day,
          title: AllChatsDateFormatter.title(for: day, calendar: calendar),
          items: [item]
        ))
      }
    }

    return sections
  }
}

struct AllChatsSection: Identifiable, Equatable {
  let id: Date
  let title: String
  var items: [AllChatsItem]
}

struct AllChatsItem: Identifiable, Equatable {
  let id: Int64
  let peerId: Peer
  let chatId: Int64
  let title: String
  let subtitle: String
  let lastActivityDate: Date
  let unread: Bool
  let unreadCount: Int
  let unreadMark: Bool
  let pinned: Bool
  let archived: Bool
  let chatListHidden: Bool
  let peer: ChatIcon.PeerType?
  let previewSender: AllChatsPreviewSender?
  let spaceId: Int64?
  let spaceName: String?

  init?(chat: HomeChatItem, titleOverride: String? = nil) {
    guard chat.chat != nil || chat.user != nil else { return nil }

    let preview = Self.preview(for: chat)
    id = chat.id
    peerId = chat.peerId
    chatId = chat.chat?.id ?? 0
    title = titleOverride ?? Self.title(for: chat)
    subtitle = preview.text
    lastActivityDate = chat.lastMessage?.message.date
      ?? chat.chat?.date
      ?? Date.distantPast
    unreadCount = max(chat.dialog.unreadCount ?? 0, 0)
    unreadMark = chat.dialog.unreadMark == true
    unread = unreadCount > 0 || unreadMark
    pinned = chat.dialog.pinned == true
    archived = chat.dialog.archived == true
    chatListHidden = chat.dialog.chatListHidden == true
    previewSender = preview.sender
    spaceId = chat.dialog.spaceId ?? chat.chat?.spaceId ?? chat.space?.id
    spaceName = chat.space?.displayName

    if let user = chat.user {
      peer = user.user.isCurrentUser() ? .savedMessage(user.user) : .user(user)
    } else if let chat = chat.chat {
      peer = .chat(chat)
    } else {
      peer = nil
    }
  }

  private static func title(for item: HomeChatItem) -> String {
    if let user = item.user?.user {
      return user.isCurrentUser() ? "Saved Messages" : user.displayName
    }

    return item.chat?.humanReadableTitle ?? "Chat"
  }

  private static func preview(for item: HomeChatItem) -> Preview {
    if let draft = draftText(for: item.dialog) {
      return Preview(text: draft, sender: nil)
    }

    guard let lastMessage = item.lastMessage else {
      return Preview(text: "No messages", sender: nil)
    }

    let text = normalizedPreviewText(
      lastMessage.displayTextForLastMessage
        ?? lastMessage.documentPreviewTextForAllChats
        ?? lastMessage.message.stringRepresentationPlain
    )

    return Preview(text: text, sender: previewSender(for: item, message: lastMessage))
  }

  private static func previewSender(
    for item: HomeChatItem,
    message: EmbeddedMessage
  ) -> AllChatsPreviewSender? {
    guard item.chat?.type == .thread,
          let senderInfo = message.senderInfo
    else {
      return nil
    }

    let name = senderInfo.user.shortDisplayName
    guard name.isEmpty == false else { return nil }

    return AllChatsPreviewSender(name: name, peer: .user(senderInfo))
  }

  private static func draftText(for dialog: Dialog) -> String? {
    guard let draftText = dialog.draftMessage?.text else { return nil }
    let text = normalizedPreviewText(draftText)
    guard text.isEmpty == false else { return nil }
    return "Draft: \(text)"
  }

  private static func normalizedPreviewText(_ text: String) -> String {
    text
      .components(separatedBy: .newlines)
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private struct Preview {
    let text: String
    let sender: AllChatsPreviewSender?
  }
}

struct AllChatsPreviewSender: Equatable {
  let name: String
  let peer: ChatIcon.PeerType
}

private struct NewThreadListRow: View {
  let action: () -> Void

  @Environment(\.colorScheme) private var colorScheme
  @State private var isHovered = false

  private static let iconSize: CGFloat = 30
  private static let rowHeight: CGFloat = 40
  private static let horizontalPadding: CGFloat = 8
  private static let cornerRadius: CGFloat = 6

  var body: some View {
    Button(action: action) {
      HStack(spacing: 9) {
        Circle()
          .fill(.quinary)
          .frame(width: Self.iconSize, height: Self.iconSize)
          .overlay {
            Image(systemName: "square.and.pencil")
              .font(.system(size: Self.iconSize * 0.42, weight: .regular))
              .foregroundStyle(.secondary)
          }

        Text("New thread")
          .font(.system(size: 13, weight: .regular))
          .foregroundStyle(.secondary)
          .lineLimit(1)

        Spacer(minLength: 0)
      }
      .frame(maxWidth: .infinity, minHeight: Self.rowHeight, alignment: .leading)
      .padding(.horizontal, Self.horizontalPadding)
      .contentShape(.rect(cornerRadius: Self.cornerRadius))
      .background(background)
    }
    .buttonStyle(.plain)
    .help("New Thread")
    .accessibilityLabel("New Thread")
    .accessibilityAddTraits(.isButton)
    .onHover { isHovered = $0 }
  }

  private var background: some View {
    RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
      .fill(backgroundColor)
  }

  private var backgroundColor: Color {
    if isHovered {
      return colorScheme == .dark ? .white.opacity(0.06) : .black.opacity(0.04)
    }

    return .clear
  }
}

private struct ChatListRow: View {
  let item: AllChatsItem
  let selected: Bool
  let showsSpaceName: Bool
  let layout: AllChatsRowLayout
  let switchToSpace: (Int64) -> Void
  let action: () -> Void

  @Environment(\.dependencies) private var dependencies
  @Environment(\.nav) private var nav
  @Environment(\.colorScheme) private var colorScheme
  @State private var isHovered = false
  @State private var pendingDestructiveAction: ChatDestructiveAction?

  private static let iconSize: CGFloat = 30
  private static let compactIconSize: CGFloat = 22
  private static let twoLineRowHeight: CGFloat = 50
  private static let oneLineRowHeight: CGFloat = 40
  private static let oneLineTitleWidth: CGFloat = 164
  private static let oneLineTrailingWidth: CGFloat = 80
  private static let horizontalPadding: CGFloat = 8
  private static let verticalPadding: CGFloat = 0
  private static let cornerRadius: CGFloat = 6
  private static let titleFont: Font = .system(size: 13, weight: .medium)

  private var rowHeight: CGFloat {
    layout == .titlePreviewLine ? Self.oneLineRowHeight : Self.twoLineRowHeight
  }

  private var rowIconSize: CGFloat {
    layout == .titlePreviewLine ? Self.compactIconSize : Self.iconSize
  }

  private var rowIconSpacing: CGFloat {
    layout == .titlePreviewLine ? 7 : 9
  }

  private var peerId: Peer {
    item.peerId
  }

  private var threadChat: Chat? {
    guard case let .chat(chat) = item.peer else { return nil }
    return chat
  }

  private var destructiveAction: ChatDestructiveAction? {
    ChatDestructiveActionResolver.action(
      peer: peerId,
      chat: threadChat,
      currentUserId: dependencies?.auth.getCurrentUserId()
    )
  }

  private var destructiveConfirmationPresented: Binding<Bool> {
    Binding {
      pendingDestructiveAction != nil
    } set: { isPresented in
      if isPresented == false {
        pendingDestructiveAction = nil
      }
    }
  }

  var body: some View {
    HStack(spacing: rowIconSpacing) {
      icon
        .frame(width: rowIconSize, height: rowIconSize)

      rowContent
    }
    .frame(height: rowHeight)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, Self.horizontalPadding)
    .padding(.vertical, Self.verticalPadding)
    .contentShape(.rect(cornerRadius: Self.cornerRadius))
    .background(background)
    .onTapGesture(perform: openFromClick)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(item.title)
    .accessibilityAddTraits(.isButton)
    .accessibilityAddTraits(selected ? .isSelected : [])
    .onHover { isHovered = $0 }
    .contextMenu {
      Button {
        openInNewTab()
      } label: {
        Label("Open in New Tab", systemImage: "plus.rectangle.on.rectangle")
      }

      Button {
        MainWindowOpenCoordinator.shared.openNewWindow(.chat(peer: peerId))
      } label: {
        Label("Open in New Window", systemImage: "macwindow")
      }

      Button {
        openInSidebar()
      } label: {
        Label("Open in Sidebar", systemImage: "sidebar.left")
      }

      Divider()

      Button {
        togglePin()
      } label: {
        Label(item.pinned ? "Unpin" : "Pin", systemImage: item.pinned ? "pin.slash.fill" : "pin.fill")
      }

      Button {
        toggleReadUnread()
      } label: {
        Label(
          item.unread ? "Mark Read" : "Mark Unread",
          systemImage: item.unread ? "checkmark.message.fill" : "envelope.badge.fill"
        )
      }

      Button {
        toggleArchive()
      } label: {
        Label(item.archived ? "Unarchive" : "Archive", systemImage: "archivebox")
      }

      if let destructiveAction {
        Divider()

        Button(role: .destructive) {
          pendingDestructiveAction = destructiveAction
        } label: {
          Label(destructiveAction.title, systemImage: destructiveAction.systemImage)
        }
      }
    }
    .alert(
      pendingDestructiveAction?.title ?? "Confirm",
      isPresented: destructiveConfirmationPresented,
      presenting: pendingDestructiveAction
    ) { action in
      Button("Cancel", role: .cancel) {
        pendingDestructiveAction = nil
      }

      Button(action.shortTitle, role: .destructive) {
        performDestructiveAction(action)
      }
    } message: { action in
      Text(action.confirmationMessage(chatTitle: item.title))
    }
  }

  @ViewBuilder
  private var rowContent: some View {
    switch layout {
    case .twoLine:
      twoLineContent
    case .titlePreviewLine:
      titlePreviewLineContent
    }
  }

  private var twoLineContent: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        titleText
          .frame(maxWidth: .infinity, alignment: .leading)

        trailingInfo()
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      HStack(alignment: .center, spacing: 8) {
        AllChatsPreviewLine(
          text: item.subtitle,
          sender: item.previewSender,
          showsProfilePhotos: true
        )

        unreadIndicator
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var titlePreviewLineContent: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      titleText
        .frame(width: Self.oneLineTitleWidth, alignment: .leading)

      AllChatsPreviewLine(
        text: item.subtitle,
        sender: item.previewSender,
        showsProfilePhotos: false
      )
      .layoutPriority(1)

      trailingInfo(maxWidth: Self.oneLineTrailingWidth)
        .frame(width: Self.oneLineTrailingWidth, alignment: .trailing)
        .layoutPriority(1)

      unreadIndicator
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(2)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var titleText: some View {
    Text(item.title)
      .font(Self.titleFont)
      .foregroundStyle(.primary)
      .lineLimit(1)
  }

  private func trailingInfo(maxWidth: CGFloat = 190) -> some View {
    AllChatsTrailingInfo(
      item: item,
      showsSpaceName: showsSpaceName,
      switchToSpace: switchToSpace,
      maxWidth: maxWidth
    )
  }

  @ViewBuilder
  private var unreadIndicator: some View {
    if item.unread {
      AllChatsUnreadIndicator(
        unreadCount: item.unreadCount,
        hasUnreadMark: item.unreadMark
      )
      .layoutPriority(1)
    }
  }

  @ViewBuilder
  private var icon: some View {
    if layout == .titlePreviewLine {
      compactIcon
    } else {
      fullIcon
    }
  }

  @ViewBuilder
  private var fullIcon: some View {
    if case let .chat(chat) = item.peer {
      SidebarThreadIcon(
        chat: chat,
        size: Self.iconSize,
        shape: .circle
      )
    } else if let peer = item.peer {
      ChatIcon(peer: peer, size: Self.iconSize)
    } else {
      Circle()
        .fill(Color.primary.opacity(0.08))
        .overlay {
          Image(systemName: "bubble.left")
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(.secondary)
        }
    }
  }

  @ViewBuilder
  private var compactIcon: some View {
    if case let .chat(chat) = item.peer {
      SidebarThreadIcon(
        chat: chat,
        size: Self.compactIconSize,
        shape: .roundedSquare
      )
    } else if let peer = item.peer {
      SidebarChatIcon(peer: peer, size: Self.compactIconSize)
    } else {
      SidebarThreadIcon(
        emoji: nil,
        size: Self.compactIconSize,
        shape: .roundedSquare
      )
    }
  }

  private var background: some View {
    RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
      .fill(backgroundColor)
  }

  private var backgroundColor: Color {
    if selected {
      return colorScheme == .dark ? .white.opacity(0.1) : .black.opacity(0.07)
    }

    if isHovered {
      return colorScheme == .dark ? .white.opacity(0.06) : .black.opacity(0.04)
    }

    return .clear
  }

  private func openFromClick() {
    let flags = NSApp.currentEvent?.modifierFlags

    if flags?.contains(.option) == true {
      openInSidebar()
      return
    }

    if flags?.contains(.command) == true {
      openInNewTab()
      return
    }

    action()
  }

  private func openInNewTab() {
    MainWindowOpenCoordinator.shared.openTab(.chat(peer: peerId))
  }

  private func openInSidebar() {
    Task(priority: .userInitiated) {
      do {
        guard let dependencies else { return }
        if peerId.isThread, item.chatListHidden {
          _ = try await dependencies.realtimeV2.send(.showInChatList(peerId: peerId))
        }
        _ = try await dependencies.realtimeV2.send(.updateDialogOpen(peerId: peerId, open: true))
      } catch {
        Log.shared.error("Failed to open chat in sidebar", error: error)
      }
    }
  }

  private func togglePin() {
    Task(priority: .userInitiated) {
      do {
        try await DataManager.shared.updateDialog(peerId: peerId, pinned: !item.pinned)
      } catch {
        Log.shared.error("Failed to update pin status", error: error)
      }
    }
  }

  private func toggleReadUnread() {
    Task(priority: .userInitiated) {
      do {
        if item.unread {
          UnreadManager.shared.readAll(peerId, chatId: item.chatId)
          return
        }

        guard let dependencies else { return }
        try await dependencies.realtimeV2.send(.markAsUnread(peerId: peerId))
      } catch {
        Log.shared.error("Failed to update read/unread status", error: error)
      }
    }
  }

  private func toggleArchive() {
    Task(priority: .userInitiated) {
      do {
        try await DataManager.shared.updateDialog(
          peerId: peerId,
          archived: !item.archived,
          spaceId: item.spaceId
        )

        if item.archived == false, isSelectedInCurrentNavigation {
          await MainActor.run {
            nav.open(.empty)
            dependencies?.nav2?.navigate(to: .empty)
            dependencies?.nav3?.open(.empty)
          }
        }
      } catch {
        Log.shared.error("Failed to update archive state", error: error)
      }
    }
  }

  @MainActor
  private func performDestructiveAction(_ action: ChatDestructiveAction) {
    pendingDestructiveAction = nil
    ChatDestructiveActionRunner.perform(action, peer: peerId, dependencies: dependencies) {
      if isSelectedInCurrentNavigation {
        dependencies?.nav2?.navigate(to: .empty)
        dependencies?.nav3?.open(.empty)
        nav.open(.empty)
      }
    }
  }

  private var isSelectedInCurrentNavigation: Bool {
    if nav.currentRoute.selectedPeer == peerId {
      return true
    }

    if dependencies?.nav3?.currentRoute.selectedPeer == peerId {
      return true
    }

    if case let .chat(peer)? = dependencies?.nav2?.currentRoute, peer == peerId {
      return true
    }

    return false
  }
}

private struct AllChatsPreviewLine: View {
  let text: String
  let sender: AllChatsPreviewSender?
  let showsProfilePhotos: Bool

  private static let iconSize: CGFloat = 14
  private static let textFont: Font = .system(size: 13, weight: .regular)

  var body: some View {
    HStack(alignment: .center, spacing: 4) {
      if let sender {
        if showsProfilePhotos {
          SidebarChatIcon(peer: sender.peer, size: Self.iconSize)
            .frame(width: Self.iconSize, height: Self.iconSize)
        }

        (Text(sender.name)
          .font(Self.textFont)
          + Text(": \(text)")
          .font(Self.textFont))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.tail)
          .layoutPriority(1)
      } else {
        Text(text)
          .font(Self.textFont)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.tail)
          .layoutPriority(1)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct AllChatsUnreadIndicator: View {
  let unreadCount: Int
  let hasUnreadMark: Bool

  var body: some View {
    if unreadCount > 0 {
      AllChatsUnreadBadge(count: unreadCount)
    } else if hasUnreadMark {
      AllChatsUnreadMark()
    }
  }
}

private struct AllChatsUnreadBadge: View {
  let count: Int

  private static let height: CGFloat = 16

  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    Text(String(count))
      .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
      .foregroundStyle(Color.primary.opacity(0.76))
      .lineLimit(1)
      .padding(.horizontal, 5)
      .frame(minWidth: Self.height)
      .frame(height: Self.height)
      .fixedSize(horizontal: true, vertical: false)
      .background(Capsule().fill(backgroundColor))
  }

  private var backgroundColor: Color {
    colorScheme == .dark ? .white.opacity(0.16) : .black.opacity(0.09)
  }
}

private struct AllChatsUnreadMark: View {
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    Circle()
      .fill(colorScheme == .dark ? .white.opacity(0.36) : .black.opacity(0.28))
      .frame(width: 7, height: 7)
  }
}

private struct AllChatsTrailingInfo: View {
  let item: AllChatsItem
  let showsSpaceName: Bool
  let switchToSpace: (Int64) -> Void
  let maxWidth: CGFloat

  var body: some View {
    HStack(spacing: 3) {
      if showsSpaceName,
         let spaceId = item.spaceId,
         let spaceName = cleanSpaceName
      {
        AllChatsSpacePill(name: spaceName) {
          switchToSpace(spaceId)
        }

        if showsTime {
          Text("•")
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
        }
      }

      AllChatsTimeLabel(date: item.lastActivityDate)
        .equatable()
        .layoutPriority(1)
    }
    .frame(maxWidth: maxWidth, alignment: .trailing)
  }

  private var cleanSpaceName: String? {
    guard let spaceName = item.spaceName?.trimmingCharacters(in: .whitespacesAndNewlines),
          spaceName.isEmpty == false
    else {
      return nil
    }

    return spaceName
  }

  private var showsTime: Bool {
    AllChatsDateFormatter.rowTitle(for: item.lastActivityDate, calendar: .current) != nil
  }
}

private struct AllChatsSpacePill: View {
  let name: String
  let action: () -> Void

  @Environment(\.colorScheme) private var colorScheme
  @State private var isHovered = false

  var body: some View {
    Button(action: action) {
      Text(name)
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
        .lineLimit(1)
        .truncationMode(.tail)
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(background)
    }
    .buttonStyle(.plain)
    .help("Show \(name) Chats")
    .onHover { isHovered = $0 }
  }

  private var background: some View {
    RoundedRectangle(cornerRadius: 4, style: .continuous)
      .fill(isHovered ? hoverColor : .clear)
  }

  private var hoverColor: Color {
    colorScheme == .dark ? .white.opacity(0.08) : .black.opacity(0.05)
  }
}

private struct AllChatsTimeLabel: View, Equatable {
  let date: Date

  var body: some View {
    if let time = AllChatsDateFormatter.rowTitle(for: date, calendar: .current) {
      Text(time)
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
        .lineLimit(1)
    }
  }
}

private enum AllChatsDateFormatter {
  private static let rowTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("jm")
    return formatter
  }()

  private static let weekdayTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("EEEjm")
    return formatter
  }()

  private static let currentYearFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("MMM d")
    return formatter
  }()

  private static let otherYearFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("MMM d, y")
    return formatter
  }()

  static func title(for date: Date, calendar: Calendar) -> String {
    if calendar.isDateInToday(date) {
      return "Today"
    }

    if calendar.isDateInYesterday(date) {
      return "Yesterday"
    }

    if calendar.component(.year, from: date) == calendar.component(.year, from: Date()) {
      return currentYearFormatter.string(from: date)
    }

    return otherYearFormatter.string(from: date)
  }

  static func rowTitle(for date: Date, calendar: Calendar) -> String? {
    guard date != Date.distantPast else { return nil }

    let now = Date()
    if now.timeIntervalSince(date) < 60 {
      return "just now"
    }

    if calendar.isDateInToday(date) {
      return rowTimeFormatter.string(from: date)
    }

    let day = calendar.startOfDay(for: date)
    let today = calendar.startOfDay(for: now)
    let days = calendar.dateComponents([.day], from: day, to: today).day

    if let days, days > 0, days < 7 {
      return weekdayTimeFormatter.string(from: date)
    }

    return nil
  }
}

private extension EmbeddedMessage {
  var documentPreviewTextForAllChats: String? {
    guard message.documentId != nil else { return nil }
    guard let fileName = document?.fileName?.trimmingCharacters(in: .whitespacesAndNewlines),
          fileName.isEmpty == false
    else {
      return nil
    }
    return fileName.replacingOccurrences(of: "\n", with: " ")
  }
}

#Preview {
  AllChatsRouteView()
    .appDatabase(.populated())
    .environment(dependencies: AppDependencies())
}
