import AppKit
import Auth
import Combine
import GRDB
import InlineKit
import InlineMacUI
import InlineUI
import Logger
import SwiftUI
import Translation

struct AllChatsRouteView: View {
  @Environment(\.dependencies) private var dependencies
  @Environment(\.nav) private var nav
  @EnvironmentStateObject private var viewModel: AllChatsViewModel
  @ObservedObject private var settings = AppSettings.shared
  @State private var rowLayout: AllChatsRowLayout = .twoLine
  @State private var listFilter: AllChatsListFilter = .all
  @AppStorage private var pinnedExpanded: Bool

  private let filter: AllChatsFilter

  init(archived: Bool = false) {
    filter = archived ? .archived : .chats
    _pinnedExpanded = AppStorage(
      wrappedValue: true,
      "macos.allChats.pinnedExpanded.\(Auth.shared.getCurrentUserId().map(String.init) ?? "signed-out")"
    )
    _viewModel = EnvironmentStateObject { env in
      AllChatsViewModel(db: env.appDatabase)
    }
  }

  var body: some View {
    let title = pageTitle
    let presentation = viewModel.presentation(
      for: filter,
      listFilter: listFilter,
      spaceId: nav.selectedSpaceId
    )

    ZStack {
      if viewModel.isLoading {
        ProgressView()
          .controlSize(.small)
      } else if viewModel.errorText != nil || showsEmptyFilterState(presentation: presentation) {
        RoutePlaceholderView(
          title: viewModel.errorText ?? emptyTitle,
          systemImage: viewModel.errorText == nil ? emptySystemImage : "exclamationmark.triangle"
        )
      } else {
        chatList(presentation: presentation)
      }
    }
    .navigationTitle(title)
    .toolbar(removing: .title)
    .toolbar {
      let titleItem =
        MacToolbarItem(placement: .navigation, priority: .high, label: "") {
          RouteToolbarTitleItem(title: title)
        }

      if #available(macOS 26.0, *) {
        titleItem.sharedBackgroundVisibility(.hidden)
      } else {
        titleItem
      }

      if #available(macOS 26.0, *) {
        ToolbarSpacer(.flexible)
      }

      if filter == .chats {
        ToolbarItem {
          listFilterMenu
        }
      }

      // Keep the alternate row layout available in source, but do not expose
      // it in production while the toolbar is dedicated to chat filtering.
      // ToolbarItem { rowLayoutMenu }

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

  private func chatList(presentation: AllChatsPresentation) -> some View {
    List {
      if filter == .chats {
        NewThreadListRow(action: createNewThread)
          .listRowInsets(EdgeInsets(top: 0, leading: 5, bottom: 0, trailing: 5))
          .listRowSeparator(.hidden)
          .listRowBackground(Color.clear)
      }

      if !presentation.pinnedItems.isEmpty {
        AllChatsPinnedSection(isExpanded: $pinnedExpanded) {
          chatRows(presentation.pinnedItems)
        }
      }

      ForEach(presentation.sections) { section in
        Section {
          chatRows(section.items)
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

  private func chatRows(_ items: [AllChatsItem]) -> some View {
    ForEach(items) { item in
      ChatListRow(
        item: item,
        selected: nav.currentRoute.selectedPeer == item.peerId,
        showsSpaceName: nav.selectedSpaceId == nil,
        layout: rowLayout,
        unreadBadgeStyle: settings.unreadBadgeStyle,
        switchToSpace: openSpace,
        action: {
          open(item)
        }
      )
      .listRowInsets(EdgeInsets(top: 0, leading: 5, bottom: 0, trailing: 5))
      .listRowSeparator(.hidden)
      .listRowBackground(Color.clear)
    }
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

  private var listFilterMenu: some View {
    Menu {
      listFilterButton(.all, title: "All Chats")
      listFilterButton(.unread, title: "Unread")
    } label: {
      Label("Filter", systemImage: "line.3.horizontal.decrease")
    }
    .help("Filter Chats")
  }

  private func listFilterButton(
    _ value: AllChatsListFilter,
    title: LocalizedStringKey
  ) -> some View {
    Button {
      listFilter = value
    } label: {
      if listFilter == value {
        Label(title, systemImage: "checkmark")
      } else {
        Text(title)
      }
    }
  }

  private func showsEmptyFilterState(presentation: AllChatsPresentation) -> Bool {
    presentation.isEmpty && (filter == .archived || listFilter == .unread)
  }

  private var emptyTitle: String {
    listFilter == .unread ? "No unread chats" : filter.emptyTitle
  }

  private var emptySystemImage: String {
    listFilter == .unread ? "checkmark.message" : filter.emptySystemImage
  }

  private func toggleArchiveFilter() {
    if filter == .archived {
      closeArchiveFilter()
    } else {
      openArchiveFilter()
    }
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
    return nav.history[index].route
  }
}

private struct AllChatsPinnedSection<Rows: View>: View {
  @Binding var isExpanded: Bool
  let rows: Rows

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  init(isExpanded: Binding<Bool>, @ViewBuilder rows: () -> Rows) {
    _isExpanded = isExpanded
    self.rows = rows()
  }

  var body: some View {
    Section {
      if isExpanded {
        rows
      }
    } header: {
      AllChatsPinnedSectionHeader(isExpanded: isExpanded, action: toggle)
    }
    .listSectionSeparator(.hidden)
  }

  private func toggle() {
    withAnimation(reduceMotion ? nil : .smooth(duration: 0.18)) {
      isExpanded.toggle()
    }
  }
}

private struct AllChatsPinnedSectionHeader: View {
  let isExpanded: Bool
  let action: () -> Void

  var body: some View {
    HStack(spacing: 6) {
      Text("Pinned")
        .frame(maxWidth: .infinity, alignment: .leading)
      Button(action: action) {
        Image(systemName: "chevron.down")
          .font(.caption.weight(.semibold))
          .rotationEffect(.degrees(isExpanded ? 0 : -90))
          .frame(width: 20, height: 20)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Pinned")
      .accessibilityValue(accessibilityValue)
      .accessibilityHint(accessibilityHint)
    }
    .font(.system(size: 12, weight: .semibold))
    .foregroundStyle(.secondary)
    .lineLimit(1)
    .padding(.horizontal, 13)
    .padding(.top, 2)
  }

  private var accessibilityValue: LocalizedStringKey {
    isExpanded ? "Expanded" : "Collapsed"
  }

  private var accessibilityHint: LocalizedStringKey {
    isExpanded ? "Collapses pinned chats" : "Expands pinned chats"
  }
}

private enum AllChatsRowLayout: Equatable {
  case twoLine
  case titlePreviewLine
}

private enum AllChatsListFilter: Equatable {
  case all
  case unread

  func includes(_ item: AllChatsItem) -> Bool {
    switch self {
    case .all:
      true
    case .unread:
      item.unread
    }
  }
}

private enum AllChatsFilter: Equatable {
  case chats
  case archived

  var title: String {
    switch self {
    case .chats:
      "All Chats"
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
      return "\(spaceName) / All Chats"
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
  private var translationCancellable: AnyCancellable?
  private var translationLanguageCancellable: AnyCancellable?
  private var chatsRetryTask: Task<Void, Never>?
  private var chatsRetryAttempt = 0
  private var snapshots: [ChatListItemSnapshot] = []

  init(db: AppDatabase) {
    self.db = db
    translationCancellable = TranslationState.shared.subject.sink { [weak self] event in
      guard let self else { return }
      let (peer, _) = event
      guard snapshots.contains(where: { $0.peer == peer }) else { return }
      apply(Self.makeItems(snapshots))
      observeChats()
    }
    translationLanguageCancellable = NotificationCenter.default
      .publisher(for: .translationLanguageChanged)
      .sink { [weak self] _ in
        self?.observeChats()
      }
    observeChats()
    observeSpaces()
  }

  private func observeChats() {
    chatsCancellable?.cancel()
    chatsCancellable = nil
    chatsRetryTask?.cancel()
    chatsRetryTask = nil

    #if DEBUG
    db.warnIfInMemoryDatabaseForObservation("AllChatsViewModel.chats")
    #endif

    chatsCancellable = ValueObservation
      .tracking { db in
        try ChatListDatabaseQuery.fetchSnapshots(
          db,
          spaceID: nil,
          includeSpaceChatsInHome: true,
          translationLanguage: UserLocale.getCurrentLanguage(),
          includePreviewSenderIdentity: true
        )
      }
      .publisher(in: db.dbWriter, scheduling: .immediate)
      .sink(
        receiveCompletion: { [weak self] completion in
          guard let self else { return }

          if case let .failure(error) = completion {
            isLoading = false
            errorText = items.isEmpty ? "Couldn’t load chats. Retrying…" : nil
            log.error("All chats observation failed: \(Self.safeErrorName(error))")
            scheduleChatsObservationRetry()
          }
        },
        receiveValue: { [weak self] snapshots in
          guard let self else { return }
          self.snapshots = snapshots
          apply(Self.makeItems(snapshots))
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
          return Dialog.getDialogId(peerId: lhs.peerId)
            > Dialog.getDialogId(peerId: rhs.peerId)
        }
        return lhs.lastActivityDate > rhs.lastActivityDate
      }

    chatsRetryAttempt = 0
    chatsRetryTask?.cancel()
    chatsRetryTask = nil
    errorText = nil
    isLoading = false
  }

  private func scheduleChatsObservationRetry() {
    guard chatsRetryTask == nil else { return }
    chatsRetryAttempt &+= 1
    let delay = min(pow(2, Double(min(chatsRetryAttempt - 1, 5))) * 0.25, 8)
    chatsRetryTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(delay))
      guard Task.isCancelled == false, let self else { return }
      chatsRetryTask = nil
      observeChats()
    }
  }

  private nonisolated static func safeErrorName(_ error: Error) -> String {
    if error is RowDecodingError {
      return "RowDecodingError"
    }
    if let error = error as? DatabaseError {
      return "DatabaseError(\(error.resultCode.rawValue))"
    }
    return String(reflecting: type(of: error))
  }

  private nonisolated static func makeItems(
    _ snapshots: [ChatListItemSnapshot]
  ) -> [AllChatsItem] {
    snapshots.map(AllChatsItem.init)
  }

  fileprivate func presentation(
    for filter: AllChatsFilter,
    listFilter: AllChatsListFilter,
    spaceId: Int64?
  ) -> AllChatsPresentation {
    let filteredItems = items.filter { item in
      item.chatListHidden == false
        && filter.includes(item)
        && listFilter.includes(item)
        && (spaceId == nil || item.spaceId == spaceId)
    }
    let pinnedItems = filter == .chats
      ? filteredItems.filter(\.pinned).sorted(by: Self.pinnedOrdered)
      : []
    let timelineItems = filter == .chats
      ? filteredItems.filter { !$0.pinned }
      : filteredItems
    return AllChatsPresentation(
      pinnedItems: pinnedItems,
      sections: Self.makeSections(items: timelineItems)
    )
  }

  fileprivate func spaceName(id: Int64?) -> String? {
    guard let id else { return nil }
    return spacesById[id]?.displayName
  }

  private static func makeSections(items: [AllChatsItem]) -> [AllChatsSection] {
    let calendar = Calendar.current
    var sections: [AllChatsSection] = []

    for item in items {
      let period = ChatListTimelinePeriod.classify(
        item.lastActivityDate,
        calendar: calendar
      )
      if sections.last?.id == period {
        sections[sections.count - 1].items.append(item)
      } else {
        sections.append(AllChatsSection(
          id: period,
          title: ChatListTimelinePeriodTitle.string(for: period, calendar: calendar),
          items: [item]
        ))
      }
    }

    return sections
  }

  private static func pinnedOrdered(_ lhs: AllChatsItem, _ rhs: AllChatsItem) -> Bool {
    switch (lhs.pinnedOrder, rhs.pinnedOrder) {
    case let (lhsOrder?, rhsOrder?) where lhsOrder != rhsOrder:
      return lhsOrder < rhsOrder
    case (_?, nil):
      return true
    case (nil, _?):
      return false
    default:
      if lhs.lastActivityDate != rhs.lastActivityDate {
        return lhs.lastActivityDate > rhs.lastActivityDate
      }
      return lhs.chatId > rhs.chatId
    }
  }
}

struct AllChatsPresentation: Equatable {
  let pinnedItems: [AllChatsItem]
  let sections: [AllChatsSection]

  var isEmpty: Bool {
    pinnedItems.isEmpty && sections.isEmpty
  }
}

struct AllChatsSection: Identifiable, Equatable {
  let id: ChatListTimelinePeriod
  let title: String
  var items: [AllChatsItem]
}

struct AllChatsItem: Identifiable, Equatable {
  let id: Peer
  let peerId: Peer
  let chatId: Int64
  let title: String
  let subtitle: String
  let lastActivityDate: Date
  let unread: Bool
  let unreadCount: Int
  let unreadMark: Bool
  let prominentUnreadIndicator: Bool
  let isOpen: Bool
  let pinned: Bool
  let pinnedOrder: String?
  let folderID: Int64?
  let archived: Bool
  let chatListHidden: Bool
  let identity: ChatListIdentityDescriptor?
  let previewSender: AllChatsPreviewSender?
  let spaceId: Int64?
  let spaceName: String?
  let chatType: ChatType?
  let chatCreatedBy: Int64?
  let chatIsPublic: Bool?

  init(snapshot: ChatListItemSnapshot) {
    id = snapshot.peer
    peerId = snapshot.peer
    chatId = snapshot.chatID
    title = snapshot.title
    let showsTranslation = TranslationState.shared.isTranslationEnabled(for: snapshot.peer)
    subtitle = (showsTranslation ? snapshot.translatedPreviewText : nil)
      ?? snapshot.previewText
      ?? "No messages"
    lastActivityDate = snapshot.lastUpdatedAt ?? Date.distantPast
    unreadCount = snapshot.unreadCount
    unreadMark = snapshot.unreadMark
    unread = snapshot.isUnread
    prominentUnreadIndicator = snapshot.isProminent
    isOpen = snapshot.isOpen
    pinned = snapshot.isPinned
    pinnedOrder = snapshot.pinnedOrder
    folderID = snapshot.folderID
    archived = snapshot.isArchived
    chatListHidden = snapshot.isChatListHidden
    identity = snapshot.identity
    if let name = snapshot.previewSenderName, name.isEmpty == false {
      previewSender = AllChatsPreviewSender(
        name: name,
        identity: snapshot.previewSenderIdentity
      )
    } else {
      previewSender = nil
    }
    spaceId = snapshot.spaceID
    spaceName = snapshot.spaceName
    chatType = snapshot.chatType
    chatCreatedBy = snapshot.chatCreatedBy
    chatIsPublic = snapshot.chatIsPublic
  }
}

struct AllChatsPreviewSender: Equatable {
  let name: String
  let identity: ChatListUserAvatarDescriptor?
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
    .inlineTooltip(
      "New thread",
      shortcut: .command("N")
    )
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

private enum AllChatsRowConfirmation {
  case archive
  case destructive(ChatDestructiveAction)

  var title: String {
    switch self {
    case .archive:
      "Archive Chat?"
    case let .destructive(action):
      action.title
    }
  }

  var actionTitle: String {
    switch self {
    case .archive:
      "Archive"
    case let .destructive(action):
      action.shortTitle
    }
  }

  func message(chatTitle: String) -> String {
    switch self {
    case .archive:
      "\(chatTitle) will move to Archived Chats. You can find it from the Archive button in the toolbar."
    case let .destructive(action):
      action.confirmationMessage(chatTitle: chatTitle)
    }
  }
}

private struct ChatListRow: View {
  let item: AllChatsItem
  let selected: Bool
  let showsSpaceName: Bool
  let layout: AllChatsRowLayout
  let unreadBadgeStyle: UnreadBadgeStyle
  let switchToSpace: (Int64) -> Void
  let action: () -> Void

  @Environment(\.dependencies) private var dependencies
  @Environment(\.nav) private var nav
  @Environment(\.colorScheme) private var colorScheme
  @State private var isHovered = false
  @State private var pendingConfirmation: AllChatsRowConfirmation?

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

  private var destructiveAction: ChatDestructiveAction? {
    ChatDestructiveActionResolver.action(
      peer: peerId,
      chatType: item.chatType,
      chatCreatedBy: item.chatCreatedBy,
      chatSpaceId: item.spaceId,
      chatIsPublic: item.chatIsPublic,
      currentUserId: dependencies?.auth.getCurrentUserId()
    )
  }

  private var destructiveConfirmationPresented: Binding<Bool> {
    Binding {
      pendingConfirmation != nil
    } set: { isPresented in
      if isPresented == false {
        pendingConfirmation = nil
      }
    }
  }

  var body: some View {
    ZStack(alignment: .leading) {
      if unreadBadgeStyle == .dot {
        unreadIndicator
          .padding(.leading, Theme.sidebarItemUnreadDotLeadingSpacing)
      }

      HStack(spacing: rowIconSpacing) {
        icon
          .frame(width: rowIconSize, height: rowIconSize)

        rowContent
      }
      .padding(.leading, Theme.sidebarItemInnerSpacing)
      .padding(.trailing, Self.horizontalPadding)
    }
    .frame(height: rowHeight)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, Self.verticalPadding)
    .animation(.smoothSnappy, value: item.unread)
    .animation(.smoothSnappy, value: item.unreadCount)
    .animation(.smoothSnappy, value: item.unreadMark)
    .animation(.smoothSnappy, value: item.prominentUnreadIndicator)
    .animation(.smoothSnappy, value: unreadBadgeStyle)
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

      if item.pinned || item.folderID == nil {
        Button {
          togglePin()
        } label: {
          Label(item.pinned ? "Unpin" : "Pin", systemImage: item.pinned ? "pin.slash.fill" : "pin.fill")
        }
      }

      Button {
        toggleReadUnread()
      } label: {
        Label(
          item.unread ? "Mark Read" : "Mark Unread",
          systemImage: item.unread ? "checkmark.message.fill" : "envelope.badge.fill"
        )
      }

      if item.archived {
        Button {
          toggleArchive()
        } label: {
          Label("Unarchive", systemImage: "archivebox")
        }
      } else {
        Button(role: .destructive) {
          pendingConfirmation = .archive
        } label: {
          Label("Archive", systemImage: "archivebox")
        }
      }

      if let destructiveAction {
        Divider()

        Button(role: .destructive) {
          pendingConfirmation = .destructive(destructiveAction)
        } label: {
          Label(destructiveAction.title, systemImage: destructiveAction.systemImage)
        }
      }
    }
    .alert(
      pendingConfirmation?.title ?? "Confirm",
      isPresented: destructiveConfirmationPresented,
      presenting: pendingConfirmation
    ) { confirmation in
      Button("Cancel", role: .cancel) {
        pendingConfirmation = nil
      }

      Button(confirmation.actionTitle, role: .destructive) {
        perform(confirmation)
      }
    } message: { confirmation in
      Text(confirmation.message(chatTitle: item.title))
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

        if unreadBadgeStyle == .numbered {
          unreadIndicator
        }
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

      if unreadBadgeStyle == .numbered {
        unreadIndicator
          .fixedSize(horizontal: true, vertical: false)
          .layoutPriority(2)
      }
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

  private var unreadIndicator: some View {
    UnreadBadge(
      unreadCount: item.unread ? item.unreadCount : 0,
      hasUnreadMark: item.unread && item.unreadMark,
      prominent: item.prominentUnreadIndicator,
      style: unreadBadgeStyle,
      dotSize: Theme.sidebarItemUnreadDotSize
    )
    .layoutPriority(1)
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
    switch item.identity {
    case let .thread(descriptor):
      SidebarThreadIcon(
        emoji: descriptor.emoji,
        isReplyThread: descriptor.isReplyThread,
        size: Self.iconSize,
        shape: .circle
      )
    case let .user(descriptor):
      avatar(descriptor, size: Self.iconSize)
    case nil:
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
    switch item.identity {
    case let .thread(descriptor):
      SidebarThreadIcon(
        emoji: descriptor.emoji,
        isReplyThread: descriptor.isReplyThread,
        size: Self.compactIconSize,
        shape: .roundedSquare
      )
    case let .user(descriptor):
      avatar(descriptor, size: Self.compactIconSize)
    case nil:
      SidebarThreadIcon(
        emoji: nil,
        size: Self.compactIconSize,
        shape: .roundedSquare
      )
    }
  }

  private func avatar(
    _ descriptor: ChatListUserAvatarDescriptor,
    size: CGFloat
  ) -> some View {
    UserAvatar(
      userID: descriptor.userID,
      firstName: descriptor.firstName,
      lastName: descriptor.lastName,
      email: descriptor.email,
      username: descriptor.username,
      stableAvatarIdentity: descriptor.stableAvatarIdentity,
      remoteURL: descriptor.remoteURL,
      localURL: descriptor.localURL,
      size: size
    )
    .equatable()
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
        guard item.isOpen == false else {
          ToastCenter.shared.showInfo("Already open")
          return
        }
        if peerId.isThread, item.chatListHidden {
          _ = try await dependencies.realtimeV2.send(.showInChatList(peerId: peerId))
        }
        _ = try await dependencies.realtimeV2.send(.updateDialogOpen(peerId: peerId, open: true))
        ToastCenter.shared.showSuccess("Opened in sidebar")
      } catch {
        ToastCenter.shared.showError("Couldn’t open in sidebar")
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
        if item.archived {
          try await DataManager.shared.updateDialog(
            peerId: peerId,
            archived: false,
            spaceId: item.spaceId
          )
        } else if let dependencies {
          try await dependencies.appUndo.archiveChat(peer: peerId, spaceID: item.spaceId)
        } else {
          try await DataManager.shared.updateDialog(
            peerId: peerId,
            archived: true,
            spaceId: item.spaceId,
            deleteEmptyThreadIfArchiving: false
          )
        }

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

  private func perform(_ confirmation: AllChatsRowConfirmation) {
    pendingConfirmation = nil

    switch confirmation {
    case .archive:
      toggleArchive()
    case let .destructive(action):
      performDestructiveAction(action)
    }
  }

  @MainActor
  private func performDestructiveAction(_ action: ChatDestructiveAction) {
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
          if let identity = sender.identity {
            UserAvatar(
              userID: identity.userID,
              firstName: identity.firstName,
              lastName: identity.lastName,
              email: identity.email,
              username: identity.username,
              stableAvatarIdentity: identity.stableAvatarIdentity,
              remoteURL: identity.remoteURL,
              localURL: identity.localURL,
              size: Self.iconSize
            )
            .equatable()
            .frame(width: Self.iconSize, height: Self.iconSize)
          }
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

private struct AllChatsTrailingInfo: View {
  let item: AllChatsItem
  let showsSpaceName: Bool
  let switchToSpace: (Int64) -> Void
  let maxWidth: CGFloat

  var body: some View {
    HStack(spacing: 3) {
      if showsSpaceName,
         let spaceId = item.spaceId,
         let spaceName = cleanSpaceName {
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

  private static let otherYearFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("MMM d, y")
    return formatter
  }()

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

#Preview {
  AllChatsRouteView()
    .appDatabase(.populated())
    .environment(dependencies: AppDependencies())
}
