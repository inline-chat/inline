import AppKit
import Foundation
import Combine
import InlineKit
import Observation

class MainSidebarList: NSView {
  private let dependencies: AppDependencies
  private let homeChatsViewModel: ChatsViewModel
  private var spaceChatsViewModels: [Int64: ChatsViewModel] = [:]

  private static let itemHeight: CGFloat = MainSidebar.itemHeight
  private static let itemSpacing: CGFloat = MainSidebar.itemSpacing
  private static let contentInsetTop: CGFloat = MainSidebar.outerEdgeInsets
  private static let contentInsetBottom: CGFloat = 8
  private static let contentInsetLeading: CGFloat = MainSidebar.outerEdgeInsets
  private static let contentInsetTrailing: CGFloat = MainSidebar.outerEdgeInsets

  enum Section: Hashable {
    case threads
    case dms
    case archiveChats
    case searchResults
  }

  enum Mode: Hashable {
    case inbox
    case archive
    case search
  }

  enum Item: Hashable {
    case header(Section)
    case chat(ChatListItem.Identifier)
  }

  enum ScrollEvent {
    case didLiveScroll
    case didEndLiveScroll
  }

  private enum ActiveSourceKey: Equatable {
    case home
    case space(Int64)
  }

  private struct SnapshotContext: Equatable {
    let mode: Mode
    let searchQuery: String
    let source: ActiveSourceKey
  }

  private var dataSource: NSCollectionViewDiffableDataSource<Section, Item>!
  private var previousItemsByID: [Item: AnyHashable] = [:]
  private var currentSections: [Section] = []
  private var chatItemsByID: [ChatListItem.Identifier: ChatListItem] = [:]
  private var selectedItemID: Item?
  private var lastSnapshotContext: SnapshotContext?
  private var activeViewModelCancellables = Set<AnyCancellable>()
  private var scrollEventsSubject = PassthroughSubject<ScrollEvent, Never>()

  private var nav2: Nav2? { dependencies.nav2 }
  private var mode: Mode = .inbox
  private var searchQuery: String = ""
  // TODO: Persist collapsed sections across sessions.
  private var collapsedSections = Set<Section>()

  private(set) var lastChatItemCount: Int = 0
  var onChatCountChanged: ((Mode, Int) -> Void)?
  var onArchiveCountChanged: ((Int) -> Void)?

  lazy var collectionView: NSCollectionView = {
    let collectionView = NSCollectionView()
    collectionView.collectionViewLayout = createLayout()
    collectionView.backgroundColors = [.clear]
    collectionView.translatesAutoresizingMaskIntoConstraints = false
    collectionView.isSelectable = true
    collectionView.allowsEmptySelection = true
    collectionView.allowsMultipleSelection = false
    return collectionView
  }()

  lazy var scrollView: NSScrollView = {
    let scrollView = NSScrollView()
    scrollView.drawsBackground = false
    scrollView.documentView = collectionView
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.contentView.wantsLayer = true
    scrollView.postsBoundsChangedNotifications = true
    scrollView.hasVerticalScroller = true
    scrollView.scrollerStyle = .overlay
    scrollView.verticalScroller?.controlSize = .mini
    return scrollView
  }()

  private lazy var topSeparator: NSView = {
    let view = NSView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.wantsLayer = true
    view.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.05).cgColor
    view.isHidden = true
    return view
  }()

  private lazy var bottomSeparator: NSView = {
    let view = NSView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.wantsLayer = true
    view.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.05).cgColor
    view.isHidden = true
    return view
  }()

  init(dependencies: AppDependencies) {
    self.dependencies = dependencies
    homeChatsViewModel = ChatsViewModel(
      source: .home,
      db: dependencies.database
    )

    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false

    setupViews()
    setupNotifications()
    setupDataSource()
    bindActiveChatsViewModel()
    observeNav()
    applySnapshot(animatingDifferences: false)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  private func setupViews() {
    addSubview(scrollView)
    addSubview(topSeparator)
    addSubview(bottomSeparator)
    collectionView.delegate = self

    NSLayoutConstraint.activate([
      scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: topAnchor),
      scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

      topSeparator.leadingAnchor.constraint(equalTo: leadingAnchor),
      topSeparator.trailingAnchor.constraint(equalTo: trailingAnchor),
      topSeparator.topAnchor.constraint(equalTo: topAnchor),
      topSeparator.heightAnchor.constraint(equalToConstant: 1),

      bottomSeparator.leadingAnchor.constraint(equalTo: leadingAnchor),
      bottomSeparator.trailingAnchor.constraint(equalTo: trailingAnchor),
      bottomSeparator.bottomAnchor.constraint(equalTo: bottomAnchor),
      bottomSeparator.heightAnchor.constraint(equalToConstant: 1),
    ])
    updateScrollSeparators()
  }

  private func setupNotifications() {
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(didLiveScroll),
      name: NSScrollView.didLiveScrollNotification,
      object: scrollView
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(didEndLiveScroll),
      name: NSScrollView.didEndLiveScrollNotification,
      object: scrollView
    )
  }

  @objc private func didLiveScroll() {
    scrollEventsSubject.send(.didLiveScroll)
    updateScrollSeparators()
  }

  @objc private func didEndLiveScroll() {
    scrollEventsSubject.send(.didEndLiveScroll)
    updateScrollSeparators()
  }

  private func createLayout() -> NSCollectionViewLayout {
    let sectionProvider: NSCollectionViewCompositionalLayoutSectionProvider = { [weak self] sectionIndex, _ in
      guard
        let self,
        sectionIndex < currentSections.count
      else { return nil }

      let sectionKind = currentSections[sectionIndex]
      return layout(for: sectionKind)
    }

    return NSCollectionViewCompositionalLayout(sectionProvider: sectionProvider)
  }

  private func setupDataSource() {
    collectionView.register(
      MainSidebarItemCollectionViewItem.self,
      forItemWithIdentifier: NSUserInterfaceItemIdentifier("MainSidebarCell")
    )

    dataSource = NSCollectionViewDiffableDataSource<Section, Item>(
      collectionView: collectionView
    ) { [weak self] collectionView, indexPath, itemID in
      guard let self else { return nil }

      let cellItem = collectionView.makeItem(
        withIdentifier: NSUserInterfaceItemIdentifier("MainSidebarCell"),
        for: indexPath
      ) as? MainSidebarItemCollectionViewItem

      if let content = content(for: itemID) {
        cellItem?.configure(
          with: content,
          dependencies: dependencies,
          events: scrollEventsSubject,
          highlightNavSelection: mode != .search,
          onHeaderTap: { [weak self] section in
            self?.toggleSection(section)
          }
        )
      }

      return cellItem
    }

    applySnapshot(animatingDifferences: false)
  }

  private func bindActiveChatsViewModel() {
    let viewModel = activeChatsViewModel()
    activeViewModelCancellables.removeAll()

    Publishers.CombineLatest4(
      viewModel.$threads,
      viewModel.$contacts,
      viewModel.$archivedChats,
      viewModel.$archivedContacts
    )
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _, _, _, _ in
        self?.applySnapshot()
      }
      .store(in: &activeViewModelCancellables)
  }

  private func applySnapshot(animatingDifferences: Bool? = nil) {
    let context = SnapshotContext(
      mode: mode,
      searchQuery: searchQuery,
      source: activeSourceKey()
    )
    let contextChanged = context != lastSnapshotContext
    let shouldAnimate = animatingDifferences ?? !contextChanged
    lastSnapshotContext = context

    let data = makeSnapshotData()
    currentSections = data.sections

    if contextChanged {
      previousItemsByID = [:]
    }

    var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
    var itemsToReload: [Item] = []

    for section in data.sections {
      snapshot.appendSections([section])
      let sectionItems = data.items[section] ?? []
      snapshot.appendItems(sectionItems, toSection: section)

      let reloadCandidates = sectionItems.filter { item in
        guard let newValue = data.valuesByItem[item] else { return false }
        if let old = previousItemsByID[item] {
          return old != newValue
        }
        return true
      }
      itemsToReload.append(contentsOf: reloadCandidates)
    }

    if !itemsToReload.isEmpty {
      snapshot.reloadItems(itemsToReload)
    }

    chatItemsByID = data.chatItemsByID
    lastChatItemCount = data.chatItemCount
    onChatCountChanged?(mode, data.chatItemCount)
    onArchiveCountChanged?(data.archivedCount)

    dataSource.apply(snapshot, animatingDifferences: shouldAnimate) { [weak self] in
      self?.syncSelection(snapshot: snapshot)
      self?.updateScrollSeparators()
    }

    previousItemsByID = data.valuesByItem
    if let layout = collectionView.collectionViewLayout {
      layout.invalidateLayout()
    }
    updateScrollSeparators()
  }

  private func updateScrollSeparators() {
    let contentHeight = scrollView.documentView?.bounds.height ?? 0
    let viewportHeight = scrollView.contentView.bounds.height
    let maxOffset = max(0, contentHeight - viewportHeight)
    if maxOffset <= 1 {
      topSeparator.isHidden = true
      bottomSeparator.isHidden = true
      return
    }

    let yOffset = scrollView.contentView.bounds.origin.y
    topSeparator.isHidden = yOffset <= 1
    bottomSeparator.isHidden = yOffset >= maxOffset - 1
  }

  private func activeSourceKey() -> ActiveSourceKey {
    guard let activeTab = nav2?.activeTab else {
      return .home
    }

    switch activeTab {
      case .home:
        return .home
      case let .space(id, _):
        return .space(id)
    }
  }

  private func indexPath(
    of itemID: Item,
    in snapshot: NSDiffableDataSourceSnapshot<Section, Item>
  ) -> (Int, Int)? {
    for (sectionIndex, section) in snapshot.sectionIdentifiers.enumerated() {
      let items = snapshot.itemIdentifiers(inSection: section)
      if let itemIndex = items.firstIndex(of: itemID) {
        return (sectionIndex, itemIndex)
      }
    }
    return nil
  }

  private struct SnapshotData {
    let sections: [Section]
    let items: [Section: [Item]]
    let chatItemsByID: [ChatListItem.Identifier: ChatListItem]
    let valuesByItem: [Item: AnyHashable]
    let chatItemCount: Int
    let archivedCount: Int
  }

  private func makeSnapshotData() -> SnapshotData {
    let viewModel = activeChatsViewModel()

    let threads = viewModel.threads
    let contacts = viewModel.contacts
    let archivedChats = viewModel.archivedChats
    let archivedContacts = viewModel.archivedContacts
    let archivedCount = archivedChats.count + archivedContacts.count

    var sections: [Section] = []
    var items: [Section: [Item]] = [:]
    var valuesByItem: [Item: AnyHashable] = [:]
    var chatMap: [ChatListItem.Identifier: ChatListItem] = [:]
    var chatItemCount: Int = 0

    func appendSection(_ section: Section, chatItems: [ChatListItem]) {
      guard chatItems.isEmpty == false else { return }
      let isCollapsed = isCollapsibleSection(section) && collapsedSections.contains(section)
      let sectionItems: [Item] = isCollapsed ? [.header(section)] : [.header(section)] + chatItems.map { .chat($0.id) }
      sections.append(section)
      items[section] = sectionItems
      sectionItems.forEach { item in
        switch item {
          case let .chat(id): valuesByItem[item] = chatMap[id]
          case let .header(section): valuesByItem[item] = "header-\(section)-\(isCollapsed)" as AnyHashable
        }
      }
    }

    switch mode {
      case .archive:
        let combinedArchived = mergeUniqueItems(archivedChats + archivedContacts)
        let filteredArchived = combinedArchived.filter { $0.dialog != nil }
        let sortedArchived = viewModel.isSpaceSource ? sortSpaceItems(filteredArchived) : filteredArchived
        chatMap = Dictionary(uniqueKeysWithValues: sortedArchived.map { ($0.id, $0) })
        chatItemCount = sortedArchived.count
        appendSection(.archiveChats, chatItems: sortedArchived)

      case .inbox:
        if viewModel.isSpaceSource {
          let filteredThreads = threads.filter { $0.dialog != nil }
          let filteredContacts = contacts.filter { $0.dialog != nil }
          let sortedThreads = sortSpaceItems(filteredThreads)
          let sortedContacts = sortSpaceItems(filteredContacts)
          let combined = mergeUniqueItems(sortedThreads + sortedContacts)
          chatMap = Dictionary(uniqueKeysWithValues: combined.map { ($0.id, $0) })
          chatItemCount = combined.count
          appendSection(.threads, chatItems: sortedThreads)
          appendSection(.dms, chatItems: sortedContacts)
        } else {
          let filteredThreads = threads.filter { $0.dialog != nil }
          let splitItems = splitHomeItems(filteredThreads)
          let combined = mergeUniqueItems(splitItems.threads + splitItems.dms)
          chatMap = Dictionary(uniqueKeysWithValues: combined.map { ($0.id, $0) })
          chatItemCount = combined.count
          appendSection(.threads, chatItems: splitItems.threads)
          appendSection(.dms, chatItems: splitItems.dms)
        }

      case .search:
        let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedQuery.isEmpty == false else {
          return SnapshotData(
            sections: [],
            items: [:],
            chatItemsByID: [:],
            valuesByItem: [:],
            chatItemCount: 0,
            archivedCount: archivedCount
          )
        }

        let allThreads = mergeUniqueItems(threads + archivedChats)
        let allContacts = mergeUniqueItems(contacts + archivedContacts)
        let filteredThreads = allThreads.filter { matchesSearch($0, query: trimmedQuery) }
        let filteredContacts = allContacts.filter { matchesSearch($0, query: trimmedQuery) }

        let combined = filteredThreads + filteredContacts
        let filteredCombined = combined.filter { $0.dialog != nil }
        let sortedCombined = viewModel.isSpaceSource ? sortSpaceItems(filteredCombined) : filteredCombined
        let searchMap = Dictionary(uniqueKeysWithValues: sortedCombined.map { ($0.id, $0) })

        if viewModel.isSpaceSource {
          if sortedCombined.isEmpty == false {
            let chatItems: [Item] = [.header(.searchResults)] + sortedCombined.map { .chat($0.id) }
            sections = [.searchResults]
            items[.searchResults] = chatItems
            chatItems.forEach { item in
              switch item {
                case let .chat(id): valuesByItem[item] = searchMap[id]
                case let .header(section): valuesByItem[item] = "header-\(section)" as AnyHashable
              }
            }
          }
        } else {
          if filteredThreads.isEmpty == false {
            let chatItems: [Item] = [.header(.searchResults)] + filteredThreads.map { .chat($0.id) }
            sections = [.searchResults]
            items[.searchResults] = chatItems
            chatItems.forEach { item in
              switch item {
                case let .chat(id): valuesByItem[item] = searchMap[id]
                case let .header(section): valuesByItem[item] = "header-\(section)" as AnyHashable
              }
            }
          }
        }

        chatMap = searchMap
        chatItemCount = sortedCombined.count
    }

    return SnapshotData(
      sections: sections,
      items: items,
      chatItemsByID: chatMap,
      valuesByItem: valuesByItem,
      chatItemCount: chatItemCount,
      archivedCount: archivedCount
    )
  }

  private func layout(for _: Section) -> NSCollectionLayoutSection {
    let itemSize = NSCollectionLayoutSize(
      widthDimension: .fractionalWidth(1.0),
      heightDimension: .estimated(Self.itemHeight)
    )
    let item = NSCollectionLayoutItem(layoutSize: itemSize)

    let groupSize = NSCollectionLayoutSize(
      widthDimension: .fractionalWidth(1.0),
      heightDimension: .estimated(Self.itemHeight)
    )
    let group = NSCollectionLayoutGroup.horizontal(
      layoutSize: groupSize,
      subitems: [item]
    )

    let section = NSCollectionLayoutSection(group: group)
    section.interGroupSpacing = Self.itemSpacing
    section.contentInsets = NSDirectionalEdgeInsets(
      top: Self.contentInsetTop,
      leading: Self.contentInsetLeading,
      bottom: Self.contentInsetBottom,
      trailing: Self.contentInsetTrailing
    )

    return section
  }

  private func observeNav() {
    guard nav2 != nil else { return }

    withObservationTracking { [weak self] in
      guard let self else { return }
      _ = nav2?.activeTab
      _ = nav2?.tabs
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        self?.bindActiveChatsViewModel()
        self?.applySnapshot()
        self?.observeNav()
      }
    }
  }

  private func content(for item: Item) -> MainSidebarItemCollectionViewItem.Content? {
    switch item {
      case let .chat(id):
        guard let chat = chatItemsByID[id] else { return nil }
        return .init(kind: .item(chat))
      case let .header(section):
        let title: String
        let symbol: String
        let showsDisclosure: Bool
        let isCollapsed = isCollapsibleSection(section) && collapsedSections.contains(section)
        switch section {
          case .threads:
            title = "Threads"
            symbol = "bubble.left.and.bubble.right.fill"
            showsDisclosure = true
          case .dms:
            title = "DMs"
            symbol = "person.fill"
            showsDisclosure = true
          case .archiveChats:
            title = "Archived"
            symbol = "archivebox.fill"
            showsDisclosure = false
          case .searchResults:
            title = "Results"
            symbol = "magnifyingglass"
            showsDisclosure = false
        }
        return .init(
          kind: .header(
            section: section,
            title: title,
            symbol: symbol,
            showsDisclosure: showsDisclosure,
            isCollapsed: isCollapsed
          )
        )
    }
  }

  private func activeChatsViewModel() -> ChatsViewModel {
    guard let activeTab = nav2?.activeTab else {
      return homeChatsViewModel
    }

    switch activeTab {
      case .home:
        return homeChatsViewModel
      case let .space(id, _):
        if let existing = spaceChatsViewModels[id] {
          return existing
        }
        let viewModel = ChatsViewModel(source: .space(id: id), db: dependencies.database)
        spaceChatsViewModels[id] = viewModel
        return viewModel
    }
  }

  func setMode(_ mode: Mode) {
    guard self.mode != mode else { return }
    self.mode = mode
    if mode != .search {
      selectedItemID = nil
      collectionView.deselectAll(nil)
    }
    applySnapshot()
  }

  func setSearchQuery(_ query: String) {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard searchQuery != trimmed else { return }
    searchQuery = trimmed
    selectedItemID = nil
    if mode == .search {
      applySnapshot()
    }
  }

  func clearSelection() {
    selectedItemID = nil
    collectionView.deselectAll(nil)
  }

  func selectNextResult() {
    guard mode == .search else { return }
    moveSelection(isForward: true)
  }

  func selectPreviousResult() {
    guard mode == .search else { return }
    moveSelection(isForward: false)
  }

  @discardableResult
  func activateSelection() -> Bool {
    guard mode == .search else { return false }
    guard let nav2, let selectedItemID, case let .chat(id) = selectedItemID else { return false }
    guard let item = chatItemsByID[id], let peer = item.peerId else { return false }
    if item.dialog?.archived == true {
      Task(priority: .userInitiated) {
        try await DataManager.shared.updateDialog(peerId: peer, archived: false, spaceId: item.spaceId)
      }
    }
    nav2.navigate(to: .chat(peer: peer))
    return true
  }

  private func mergeUniqueItems(_ items: [ChatListItem]) -> [ChatListItem] {
    var seen = Set<ChatListItem.Identifier>()
    return items.filter { item in
      seen.insert(item.id).inserted
    }
  }

  private func matchesSearch(_ item: ChatListItem, query: String) -> Bool {
    let combined = searchTokens(for: item).joined(separator: " ")
    return combined.localizedCaseInsensitiveContains(query)
  }

  private func sortSpaceItems(_ items: [ChatListItem]) -> [ChatListItem] {
    items.sorted { lhs, rhs in
      let pinned1 = lhs.dialog?.pinned ?? false
      let pinned2 = rhs.dialog?.pinned ?? false
      if pinned1 != pinned2 { return pinned1 }
      let date1 = lhs.lastMessage?.message.date ?? lhs.chat?.date ?? Date.distantPast
      let date2 = rhs.lastMessage?.message.date ?? rhs.chat?.date ?? Date.distantPast
      return date1 > date2
    }
  }

  private func isCollapsibleSection(_ section: Section) -> Bool {
    switch section {
      case .threads, .dms:
        return true
      case .archiveChats, .searchResults:
        return false
    }
  }

  private func toggleSection(_ section: Section) {
    guard isCollapsibleSection(section) else { return }
    if collapsedSections.contains(section) {
      collapsedSections.remove(section)
    } else {
      collapsedSections.insert(section)
    }
    applySnapshot()
  }

  private func splitHomeItems(_ items: [ChatListItem]) -> (threads: [ChatListItem], dms: [ChatListItem]) {
    var threads: [ChatListItem] = []
    var dms: [ChatListItem] = []
    for item in items {
      if item.peerId?.isPrivate == true {
        dms.append(item)
      } else {
        threads.append(item)
      }
    }
    return (threads, dms)
  }

  private func searchTokens(for item: ChatListItem) -> [String] {
    var tokens: [String] = []

    if let user = item.user?.user {
      if let firstName = user.firstName { tokens.append(firstName) }
      if let lastName = user.lastName { tokens.append(lastName) }
      if let username = user.username { tokens.append(username) }
      if let email = user.email { tokens.append(email) }
      tokens.append(user.displayName)
    }

    if let chat = item.chat?.title {
      tokens.append(chat)
    }

    tokens.append(item.displayTitle)
    return tokens
  }

  private func syncSelection(snapshot: NSDiffableDataSourceSnapshot<Section, Item>) {
    guard mode == .search else { return }
    let selectable = selectableItems(in: snapshot)
    guard selectable.isEmpty == false else {
      selectedItemID = nil
      collectionView.deselectAll(nil)
      return
    }

    if let selectedItemID, selectable.contains(selectedItemID) == false {
      self.selectedItemID = nil
    }

    if selectedItemID == nil {
      selectedItemID = selectable.first
    }

    guard let selectedItemID,
          let (sectionIndex, itemIndex) = indexPath(of: selectedItemID, in: snapshot)
    else { return }

    let indexPath = IndexPath(item: itemIndex, section: sectionIndex)
    collectionView.deselectAll(nil)
    collectionView.selectItems(at: [indexPath], scrollPosition: .centeredVertically)
  }

  private func moveSelection(isForward: Bool) {
    let snapshot = dataSource.snapshot()
    let selectable = selectableItems(in: snapshot)
    guard selectable.isEmpty == false else { return }

    let currentIndex: Int
    if let selectedItemID, let index = selectable.firstIndex(of: selectedItemID) {
      currentIndex = index
    } else {
      currentIndex = 0
    }

    let nextIndex: Int
    if isForward {
      nextIndex = min(currentIndex + 1, selectable.count - 1)
    } else {
      nextIndex = max(currentIndex - 1, 0)
    }

    collectionView.deselectAll(nil)
    selectedItemID = selectable[nextIndex]
    if let selectedItemID,
       let (sectionIndex, itemIndex) = indexPath(of: selectedItemID, in: snapshot)
    {
      let indexPath = IndexPath(item: itemIndex, section: sectionIndex)
      collectionView.selectItems(at: [indexPath], scrollPosition: .centeredVertically)
    }
  }

  private func selectableItems(in snapshot: NSDiffableDataSourceSnapshot<Section, Item>) -> [Item] {
    snapshot.sectionIdentifiers.flatMap { section in
      snapshot.itemIdentifiers(inSection: section).filter { item in
        if case .chat = item {
          return true
        }
        return false
      }
    }
  }
}

extension MainSidebarList: NSCollectionViewDelegate {
  func collectionView(
    _: NSCollectionView,
    shouldSelectItemsAt indexPaths: Set<IndexPath>
  ) -> Set<IndexPath> {
    guard mode == .search else { return [] }
    guard let dataSource else { return [] }
    let allowed = indexPaths.filter { indexPath in
      guard let itemID = dataSource.itemIdentifier(for: indexPath) else { return false }
      if case .chat = itemID {
        return true
      }
      return false
    }
    return Set(allowed)
  }

  func collectionView(
    _: NSCollectionView,
    didSelectItemsAt indexPaths: Set<IndexPath>
  ) {
    guard mode == .search else { return }
    guard let indexPath = indexPaths.first,
          let itemID = dataSource.itemIdentifier(for: indexPath)
    else { return }
    selectedItemID = itemID
  }
}
