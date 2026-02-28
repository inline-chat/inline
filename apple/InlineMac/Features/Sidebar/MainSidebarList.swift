import AppKit
import Foundation
import Combine
import InlineKit
import InlineMacWindow
import Observation

class MainSidebarList: NSView {
  private let snapshotBuildQueue = DispatchQueue(
    label: "chat.inline.MainSidebarList.snapshot-build",
    qos: .userInitiated
  )

  private let dependencies: AppDependencies
  private let homeChatsViewModel: ChatsViewModel
  private var spaceChatsViewModels: [Int64: ChatsViewModel] = [:]

  private static let itemSpacing: CGFloat = MainSidebar.itemSpacing
  private static let contentInsetTop: CGFloat = MainSidebar.outerEdgeInsets
  private static let contentInsetBottom: CGFloat = 8
  private static let contentInsetLeading: CGFloat = MainSidebar.outerEdgeInsets
  private static let contentInsetTrailing: CGFloat = MainSidebar.outerEdgeInsets

  enum Section: Hashable {
    case chats
  }

  enum Mode: Hashable {
    case inbox
    case archive
    case search
  }

  enum DisplayMode: Equatable {
    case compact
    case messagePreview

    var rowSize: RowLayoutSize {
      switch self {
      case .compact:
        return .compact
      case .messagePreview:
        return .messagePreview
      }
    }

    var itemHeight: CGFloat {
      rowSize.itemHeight
    }

    var avatarSize: CGFloat {
      rowSize.avatarSize
    }

    var messageFontSize: CGFloat {
      rowSize.messageFontSize
    }

    var messageLineSpacing: CGFloat {
      rowSize.messageLineSpacing
    }

    var showsMessagePreview: Bool {
      rowSize.showsMessagePreview
    }
  }

  enum RowLayoutSize: Equatable {
    case compact
    case messagePreview

    var itemHeight: CGFloat {
      switch self {
      case .compact:
        return MainSidebar.itemHeight
      case .messagePreview:
        return 46
      }
    }

    var avatarSize: CGFloat {
      switch self {
      case .compact:
        return MainSidebar.iconSize
      case .messagePreview:
        return 34
      }
    }

    var messageFontSize: CGFloat {
      12
    }

    var messageLineSpacing: CGFloat {
      switch self {
      case .compact:
        return 0
      case .messagePreview:
        return 2
      }
    }

    var showsMessagePreview: Bool {
      self == .messagePreview
    }
  }

  enum Item: Hashable {
    case chat(ChatListItem.Identifier)
    case action(ActionItem)
  }

  enum ActionItem: Hashable {
    case newThread
  }

  enum ScrollEvent {
    case didLiveScroll
    case didEndLiveScroll
  }

  private enum ActiveSourceKey: Equatable {
    case home
    case space(Int64)
  }

  private enum ItemRenderSignature: Hashable {
    case chat(ChatRenderSignature)
    case action(ActionItem)
  }

  private struct ChatRenderSignature: Hashable {
    let kind: ChatListItem.Kind
    let spaceId: Int64?
    let title: String
    let messagePreview: String
    let hasUnread: Bool
    let isPinned: Bool
    let isArchived: Bool
    let peerSignature: PeerSignature
  }

  private enum PeerSignature: Hashable {
    case user(
      id: Int64,
      firstName: String?,
      lastName: String?,
      username: String?,
      email: String?,
      phoneNumber: String?,
      profileFileUniqueId: String?,
      profileCdnUrl: String?,
      profileLocalPath: String?,
      bot: Bool
    )
    case chat(
      id: Int64,
      type: ChatType,
      title: String?,
      emoji: String?,
      createdBy: Int64?
    )
    case deleted
  }

  private struct SnapshotContext: Equatable {
    let mode: Mode
    let searchQuery: String
    let source: ActiveSourceKey
  }

  private var dataSource: NSCollectionViewDiffableDataSource<Section, Item>!
  private var previousItemsByID: [Item: ItemRenderSignature] = [:]
  private var previousOrderedItems: [Item] = []
  private var currentSections: [Section] = []
  private var chatItemsByID: [ChatListItem.Identifier: ChatListItem] = [:]
  private var selectedItemID: Item?
  private var lastSnapshotContext: SnapshotContext?
  private var activeViewModelCancellables = Set<AnyCancellable>()
  private var settingsCancellable: AnyCancellable?
  private var scrollEventsSubject = PassthroughSubject<ScrollEvent, Never>()
  private var quickSearchVisibilityObserver: NSObjectProtocol?
  private var isQuickSearchVisible = false

  private var nav2: Nav2? { dependencies.nav2 }
  private var mode: Mode = .inbox
  private var searchQuery: String = ""
  private var displayMode: DisplayMode = .compact
  private var sortStrategy: ChatsViewModel.SortStrategy = .lastActivity
  private var hasAppliedInitialSnapshot = false
  private var snapshotGeneration: UInt64 = 0
  private var isLiveScrolling = false
  private var navSelectedPeer: Peer?

  private(set) var lastChatItemCount: Int = 0
  var onChatCountChanged: ((Mode, Int) -> Void)?
  var onArchiveCountChanged: ((Int) -> Void)?

  lazy var collectionView: NSCollectionView = {
    let collectionView = MainSidebarCollectionView()
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
    displayMode = AppSettings.shared.showSidebarMessagePreview ? .messagePreview : .compact
    navSelectedPeer = Self.selectedPeer(from: dependencies.nav2)

    setupViews()
    setupNotifications()
    setupDataSource()
    bindDisplayModeSettings()
    bindActiveChatsViewModel()
    observeNavTabs()
    observeNavRoute()
    applySnapshot(animatingDifferences: false)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    if let quickSearchVisibilityObserver {
      NotificationCenter.default.removeObserver(quickSearchVisibilityObserver)
    }
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
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleNextChat),
      name: .nextChat,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handlePrevChat),
      name: .prevChat,
      object: nil
    )

    quickSearchVisibilityObserver = NotificationCenter.default.addObserver(
      forName: .quickSearchVisibilityChanged,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard let self else { return }
      guard let isVisible = notification.userInfo?["isVisible"] as? Bool else { return }
      guard isQuickSearchVisible != isVisible else { return }
      isQuickSearchVisible = isVisible
      refreshVisibleSelectionState()
      applySnapshot(animatingDifferences: false)
    }
  }

  private func bindDisplayModeSettings() {
    settingsCancellable = AppSettings.shared.$showSidebarMessagePreview
      .removeDuplicates()
      .receive(on: DispatchQueue.main)
      .sink { [weak self] showPreview in
        let mode: DisplayMode = showPreview ? .messagePreview : .compact
        self?.setDisplayMode(mode)
      }
  }

  @objc private func didLiveScroll() {
    isLiveScrolling = true
    scrollEventsSubject.send(.didLiveScroll)
    updateScrollSeparators()
  }

  @objc private func didEndLiveScroll() {
    isLiveScrolling = false
    scrollEventsSubject.send(.didEndLiveScroll)
    updateScrollSeparators()
  }

  // MARK: - Chat Navigation

  @objc private func handleNextChat() {
    navigateChat(offset: 1)
  }

  @objc private func handlePrevChat() {
    navigateChat(offset: -1)
  }

  private func canNavigateChats() -> Bool {
    guard mode != .search else { return false }
    return !isQuickSearchVisible
  }

  private func navigateChat(offset: Int) {
    guard canNavigateChats() else { return }
    guard let nav2 else { return }

    let snapshot = dataSource.snapshot()
    let orderedChatIds: [ChatListItem.Identifier] = snapshot.sectionIdentifiers.flatMap { section in
      snapshot.itemIdentifiers(inSection: section).compactMap { item in
        if case let .chat(id) = item { return id }
        return nil
      }
    }

    guard orderedChatIds.isEmpty == false else { return }

    let currentPeer = Self.selectedPeer(from: nav2)

    let currentIndex: Int = {
      guard let currentPeer else { return -1 }
      return orderedChatIds.firstIndex(where: { chatItemsByID[$0]?.peerId == currentPeer }) ?? -1
    }()

    let targetIndex = currentIndex + offset
    guard targetIndex >= 0, targetIndex < orderedChatIds.count else { return }
    guard let targetPeer = chatItemsByID[orderedChatIds[targetIndex]]?.peerId else { return }
    nav2.requestOpenChat(peer: targetPeer, database: dependencies.database)
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
      let highlightNavSelection = mode != .search && !isQuickSearchVisible

      let cellItem = collectionView.makeItem(
        withIdentifier: NSUserInterfaceItemIdentifier("MainSidebarCell"),
        for: indexPath
      ) as? MainSidebarItemCollectionViewItem

      if let content = content(for: itemID) {
        cellItem?.configure(
          with: content,
          dependencies: dependencies,
          events: scrollEventsSubject,
          highlightNavSelection: highlightNavSelection,
          isRouteSelected: isItemRouteSelected(itemID),
          displayMode: displayMode
        )
      }

      return cellItem
    }

  }

  private func bindActiveChatsViewModel() {
    let viewModel = activeChatsViewModel()
    activeViewModelCancellables.removeAll()
    viewModel.setSortStrategy(sortStrategy)

    viewModel.$items
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        self?.applySnapshot()
      }
      .store(in: &activeViewModelCancellables)
  }

  private func applySnapshot(animatingDifferences: Bool? = nil) {
    assert(Thread.isMainThread)

    let context = SnapshotContext(
      mode: mode,
      searchQuery: searchQuery,
      source: activeSourceKey()
    )
    let contextChanged = context != lastSnapshotContext
    let shouldAnimateHint = animatingDifferences ?? !contextChanged
    lastSnapshotContext = context

    let input = currentSnapshotInput()
    if hasAppliedInitialSnapshot == false {
      // First paint should be immediate and deterministic.
      let data = Self.makeSnapshotData(from: input)
      applySnapshotData(
        data,
        contextChanged: contextChanged,
        shouldAnimateHint: false,
        visibleItems: visibleItemIDs()
      )
      hasAppliedInitialSnapshot = true
      return
    }

    snapshotGeneration &+= 1
    let generation = snapshotGeneration
    let visibleItems = visibleItemIDs()

    snapshotBuildQueue.async { [input] in
      let data = Self.makeSnapshotData(from: input)
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        guard self.snapshotGeneration == generation else { return }
        self.applySnapshotData(
          data,
          contextChanged: contextChanged,
          shouldAnimateHint: shouldAnimateHint,
          visibleItems: visibleItems
        )
      }
    }
  }

  private func currentSnapshotInput() -> SnapshotInput {
    let viewModel = activeChatsViewModel()
    return SnapshotInput(
      mode: mode,
      searchQuery: searchQuery,
      activeItems: viewModel.items.active,
      archivedItems: viewModel.items.archived
    )
  }

  private func applySnapshotData(
    _ data: SnapshotData,
    contextChanged: Bool,
    shouldAnimateHint: Bool,
    visibleItems: Set<Item>
  ) {
    let previousSections = currentSections
    currentSections = data.sections

    if contextChanged {
      previousItemsByID = [:]
      previousOrderedItems = []
    }

    let oldValuesByItem = previousItemsByID
    let oldOrderedItems = previousOrderedItems

    var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()

    for section in data.sections {
      snapshot.appendSections([section])
      let sectionItems = data.items[section] ?? []
      snapshot.appendItems(sectionItems, toSection: section)
    }

    let changedItems = changedItemIDs(
      oldValuesByItem: oldValuesByItem,
      oldOrderedItems: oldOrderedItems,
      newData: data
    )
    let hasStructuralChanges = oldOrderedItems != data.orderedItems || previousSections != data.sections
    let hasVisibleStructuralChanges = hasStructuralChanges && !changedItems.isDisjoint(with: visibleItems)
    let shouldAnimate = shouldAnimateHint && !contextChanged && !isLiveScrolling && hasVisibleStructuralChanges

    chatItemsByID = data.chatItemsByID
    lastChatItemCount = data.chatItemCount
    onChatCountChanged?(mode, data.chatItemCount)
    onArchiveCountChanged?(data.archivedCount)

    if hasStructuralChanges == false {
      reconfigureVisibleItems(changedItems)
      syncSelection(snapshot: dataSource.snapshot())
      refreshVisibleSelectionState()
      previousItemsByID = data.valuesByItem
      previousOrderedItems = data.orderedItems
      updateScrollSeparators()
      return
    }

    dataSource.apply(snapshot, animatingDifferences: shouldAnimate) { [weak self] in
      self?.reconfigureVisibleItems(changedItems)
      self?.syncSelection(snapshot: snapshot)
      self?.refreshVisibleSelectionState()
      self?.updateScrollSeparators()
    }

    previousItemsByID = data.valuesByItem
    previousOrderedItems = data.orderedItems
    updateScrollSeparators()
  }

  private func changedItemIDs(
    oldValuesByItem: [Item: ItemRenderSignature],
    oldOrderedItems: [Item],
    newData: SnapshotData
  ) -> Set<Item> {
    var changed = Set<Item>()

    for (item, newValue) in newData.valuesByItem {
      guard let oldValue = oldValuesByItem[item] else { continue }
      if oldValue != newValue {
        changed.insert(item)
      }
    }

    let oldItems = Set(oldValuesByItem.keys)
    let newItems = Set(newData.valuesByItem.keys)

    changed.formUnion(oldItems.subtracting(newItems))
    changed.formUnion(newItems.subtracting(oldItems))

    if !oldOrderedItems.isEmpty {
      var oldPositions: [Item: Int] = [:]
      oldPositions.reserveCapacity(oldOrderedItems.count)
      for (index, item) in oldOrderedItems.enumerated() {
        oldPositions[item] = index
      }
      for (index, item) in newData.orderedItems.enumerated() {
        if let oldIndex = oldPositions[item], oldIndex != index {
          changed.insert(item)
        }
      }
    }

    return changed
  }

  private func reconfigureVisibleItems(_ changedItems: Set<Item>) {
    guard changedItems.isEmpty == false else { return }
    let highlightNavSelection = mode != .search && !isQuickSearchVisible

    for indexPath in collectionView.indexPathsForVisibleItems() {
      guard let itemID = dataSource.itemIdentifier(for: indexPath) else { continue }
      guard changedItems.contains(itemID) else { continue }
      guard let item = collectionView.item(at: indexPath) as? MainSidebarItemCollectionViewItem else { continue }
      guard let content = content(for: itemID) else { continue }

      item.configure(
        with: content,
        dependencies: dependencies,
        events: scrollEventsSubject,
        highlightNavSelection: highlightNavSelection,
        isRouteSelected: isItemRouteSelected(itemID),
        displayMode: displayMode
      )
    }
  }

  private func visibleItemIDs() -> Set<Item> {
    guard dataSource != nil else { return [] }
    let visible = collectionView.indexPathsForVisibleItems()
    return Set(visible.compactMap { dataSource.itemIdentifier(for: $0) })
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
    let orderedItems: [Item]
    let items: [Section: [Item]]
    let chatItemsByID: [ChatListItem.Identifier: ChatListItem]
    let valuesByItem: [Item: ItemRenderSignature]
    let chatItemCount: Int
    let archivedCount: Int
  }

  private struct SnapshotInput {
    let mode: Mode
    let searchQuery: String
    let activeItems: [ChatListItem]
    let archivedItems: [ChatListItem]
  }

  private static func makeSnapshotData(from input: SnapshotInput) -> SnapshotData {
    let archivedCount = input.archivedItems.count

    var sections: [Section] = []
    var orderedItems: [Item] = []
    var items: [Section: [Item]] = [:]
    var valuesByItem: [Item: ItemRenderSignature] = [:]
    var chatMap: [ChatListItem.Identifier: ChatListItem] = [:]
    var chatItemCount: Int = 0

    if input.mode == .search {
      let trimmedQuery = input.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
      guard trimmedQuery.isEmpty == false else {
        return SnapshotData(
          sections: [],
          orderedItems: [],
          items: [:],
          chatItemsByID: [:],
          valuesByItem: [:],
          chatItemCount: 0,
          archivedCount: archivedCount
        )
      }
    }

    let filteredItems: [ChatListItem]
    switch input.mode {
      case .archive:
        filteredItems = input.archivedItems
      case .inbox:
        filteredItems = input.activeItems
      case .search:
        let trimmedQuery = input.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        filteredItems = (input.activeItems + input.archivedItems)
          .filter { Self.matchesSearch($0, query: trimmedQuery) }
    }

    let visibleItems = filteredItems.filter { $0.dialog != nil }
    chatMap = Dictionary(uniqueKeysWithValues: visibleItems.map { ($0.id, $0) })
    chatItemCount = visibleItems.count

    var sectionItems = visibleItems.map { Item.chat($0.id) }
    if input.mode == .inbox {
      sectionItems.append(.action(.newThread))
    }

    if sectionItems.isEmpty == false {
      sections = [.chats]
      orderedItems = sectionItems
      items[.chats] = sectionItems

      sectionItems.forEach { item in
        switch item {
          case let .chat(id):
            guard let chatItem = chatMap[id] else { return }
            valuesByItem[item] = .chat(renderSignature(for: chatItem))
          case let .action(action):
            valuesByItem[item] = .action(action)
        }
      }
    }

    return SnapshotData(
      sections: sections,
      orderedItems: orderedItems,
      items: items,
      chatItemsByID: chatMap,
      valuesByItem: valuesByItem,
      chatItemCount: chatItemCount,
      archivedCount: archivedCount
    )
  }

  private func layout(for _: Section) -> NSCollectionLayoutSection {
    let height = displayMode.itemHeight
    let itemSize = NSCollectionLayoutSize(
      widthDimension: .fractionalWidth(1.0),
      heightDimension: .absolute(height)
    )
    let item = NSCollectionLayoutItem(layoutSize: itemSize)

    let groupSize = NSCollectionLayoutSize(
      widthDimension: .fractionalWidth(1.0),
      heightDimension: .absolute(height)
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

  private var shouldHighlightNavSelection: Bool {
    mode != .search && !isQuickSearchVisible
  }

  private func observeNavTabs() {
    guard nav2 != nil else { return }

    withObservationTracking { [weak self] in
      guard let self else { return }
      _ = nav2?.activeTab
      _ = nav2?.tabs
    } onChange: { [weak self] in
      // Re-arm observation immediately to avoid missing rapid successive changes.
      self?.observeNavTabs()
      Task { @MainActor [weak self] in
        self?.bindActiveChatsViewModel()
        self?.applySnapshot()
      }
    }
  }

  private func observeNavRoute() {
    guard nav2 != nil else { return }

    withObservationTracking { [weak self] in
      _ = self?.nav2?.currentRoute
      _ = self?.nav2?.pendingChatPeer
    } onChange: { [weak self] in
      self?.observeNavRoute()
      Task { @MainActor [weak self] in
        self?.updateRouteSelectionState()
      }
    }
  }

  private func updateRouteSelectionState() {
    let previousPeer = navSelectedPeer
    let nextPeer = Self.selectedPeer(from: nav2)
    guard previousPeer != nextPeer else { return }
    navSelectedPeer = nextPeer
    refreshVisibleSelectionState(for: candidateSelectionItems(oldPeer: previousPeer, newPeer: nextPeer))
  }

  private func candidateSelectionItems(oldPeer: Peer?, newPeer: Peer?) -> Set<Item>? {
    guard shouldHighlightNavSelection else { return nil }

    var candidates = Set<Item>()
    if let oldPeer, let oldID = chatItemsByID.first(where: { $0.value.peerId == oldPeer })?.key {
      candidates.insert(.chat(oldID))
    }
    if let newPeer, let newID = chatItemsByID.first(where: { $0.value.peerId == newPeer })?.key {
      candidates.insert(.chat(newID))
    }

    return candidates.isEmpty ? nil : candidates
  }

  private func refreshVisibleSelectionState(for targets: Set<Item>? = nil) {
    guard dataSource != nil else { return }
    let highlight = shouldHighlightNavSelection

    for indexPath in collectionView.indexPathsForVisibleItems() {
      guard let itemID = dataSource.itemIdentifier(for: indexPath) else { continue }
      if let targets, !targets.contains(itemID) {
        continue
      }
      guard let item = collectionView.item(at: indexPath) as? MainSidebarItemCollectionViewItem else { continue }
      item.updateSelectionState(
        routeSelected: isItemRouteSelected(itemID),
        highlightNavSelection: highlight
      )
    }
  }

  private func isItemRouteSelected(_ itemID: Item) -> Bool {
    guard shouldHighlightNavSelection else { return false }
    guard let selectedPeer = navSelectedPeer else { return false }
    guard case let .chat(id) = itemID else { return false }
    return chatItemsByID[id]?.peerId == selectedPeer
  }

  private func content(for item: Item) -> MainSidebarItemCollectionViewItem.Content? {
    switch item {
      case let .chat(id):
        guard let chat = chatItemsByID[id] else { return nil }
        return .init(kind: .item(chat))
      case let .action(action):
        return .init(kind: .action(action))
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
        viewModel.setSortStrategy(sortStrategy)
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
    refreshVisibleSelectionState()
    applySnapshot()
  }

  var currentSortStrategy: ChatsViewModel.SortStrategy {
    sortStrategy
  }

  func setSortStrategy(_ strategy: ChatsViewModel.SortStrategy) {
    guard sortStrategy != strategy else { return }
    sortStrategy = strategy
    homeChatsViewModel.setSortStrategy(strategy)
    for viewModel in spaceChatsViewModels.values {
      viewModel.setSortStrategy(strategy)
    }
    applySnapshot()
  }

  var currentDisplayMode: DisplayMode {
    displayMode
  }

  func setDisplayMode(_ mode: DisplayMode) {
    guard displayMode != mode else { return }
    displayMode = mode
    let visibleItems = collectionView.indexPathsForVisibleItems().compactMap { indexPath in
      collectionView.item(at: indexPath) as? MainSidebarItemCollectionViewItem
    }
    visibleItems.forEach { item in
      item.setDisplayMode(mode)
    }
    collectionView.collectionViewLayout?.invalidateLayout()
    collectionView.layoutSubtreeIfNeeded()
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
        let scopedSpaceId: Int64? = if item.kind == .contact {
          item.spaceId ?? nav2.activeTab.spaceId
        } else {
          item.spaceId
        }

        if item.kind == .contact, let scopedSpaceId, case let .user(userId) = peer {
          try await DataManager.shared.updateSpaceMemberDialogArchiveState(
            spaceId: scopedSpaceId,
            peerUserId: userId,
            archived: false
          )
        } else {
          try await DataManager.shared.updateDialog(peerId: peer, archived: false, spaceId: scopedSpaceId)
        }
      }
    }
    nav2.requestOpenChat(peer: peer, database: dependencies.database)
    return true
  }

  private static func matchesSearch(_ item: ChatListItem, query: String) -> Bool {
    let combined = searchTokens(for: item).joined(separator: " ")
    return combined.localizedCaseInsensitiveContains(query)
  }

  private static func selectedPeer(from route: Nav2Route?) -> Peer? {
    guard let route else { return nil }
    switch route {
    case let .chat(peer), let .chatInfo(peer):
      return peer
    default:
      return nil
    }
  }

  private static func selectedPeer(from nav2: Nav2?) -> Peer? {
    if let pendingPeer = nav2?.pendingChatPeer {
      return pendingPeer
    }
    return selectedPeer(from: nav2?.currentRoute)
  }

  private static func searchTokens(for item: ChatListItem) -> [String] {
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

  private static func renderSignature(for item: ChatListItem) -> ChatRenderSignature {
    let title: String = if let user = item.user {
      userTitle(user.user)
    } else if let title = item.chat?.humanReadableTitle {
      title
    } else {
      "Chat"
    }

    let messagePreview: String = {
      guard let lastMessage = item.lastMessage else { return "" }
      let messageText = lastMessage.displayTextForLastMessage
        ?? lastMessage.message.stringRepresentationPlain
      guard item.kind == .thread, item.chat?.type == .thread else { return messageText }
      guard let sender = lastMessage.senderInfo?.user.shortDisplayName, sender.isEmpty == false else {
        return messageText
      }
      return "\(sender): \(messageText)"
    }()

    let peerSignature: PeerSignature = if let user = item.user?.user {
      .user(
        id: user.id,
        firstName: user.firstName,
        lastName: user.lastName,
        username: user.username,
        email: user.email,
        phoneNumber: user.phoneNumber,
        profileFileUniqueId: user.profileFileUniqueId,
        profileCdnUrl: user.profileCdnUrl,
        profileLocalPath: user.profileLocalPath,
        bot: user.bot
      )
    } else if let chat = item.chat {
      .chat(
        id: chat.id,
        type: chat.type,
        title: chat.title,
        emoji: chat.emoji,
        createdBy: chat.createdBy
      )
    } else {
      .deleted
    }

    return ChatRenderSignature(
      kind: item.kind,
      spaceId: item.spaceId,
      title: title,
      messagePreview: messagePreview,
      hasUnread: item.hasUnread,
      isPinned: item.dialog?.pinned == true,
      isArchived: item.dialog?.archived == true,
      peerSignature: peerSignature
    )
  }

  private static func userTitle(_ user: User) -> String {
    if let displayName = nonEmpty(user.displayName) {
      return displayName
    }
    if let username = nonEmpty(user.username) {
      return username
    }
    if let email = nonEmpty(user.email) {
      return email
    }
    if let phoneNumber = nonEmpty(user.phoneNumber) {
      return phoneNumber
    }
    return "User"
  }

  private static func nonEmpty(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
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
        if case .chat = item { return true }
        return false
      }
    }
  }
}

private final class MainSidebarCollectionView: NSCollectionView {
  override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    if indexPathForItem(at: point) == nil {
      deselectAll(nil)
      window?.beginWindowDrag(with: event)
      return
    }
    super.mouseDown(with: event)
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
