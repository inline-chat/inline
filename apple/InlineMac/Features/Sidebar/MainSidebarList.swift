import AppKit
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
    case homeChats
    case spaceThreads
    case spaceMembers
  }

  enum Item: Hashable {
    case header(Section)
    case chat(ChatListItem.Identifier)
  }

  enum ScrollEvent {
    case didLiveScroll
    case didEndLiveScroll
  }

  private var dataSource: NSCollectionViewDiffableDataSource<Section, Item>!
  private var previousItemsByID: [Item: AnyHashable] = [:]
  private var currentSections: [Section] = []
  private var chatItemsByID: [ChatListItem.Identifier: ChatListItem] = [:]
  private var activeViewModelCancellables = Set<AnyCancellable>()
  private var scrollEventsSubject = PassthroughSubject<ScrollEvent, Never>()

  private var nav2: Nav2? { dependencies.nav2 }

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
    applySnapshot(animated: false)
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

    NSLayoutConstraint.activate([
      scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: topAnchor),
      scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
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
  }

  @objc private func didEndLiveScroll() {
    scrollEventsSubject.send(.didEndLiveScroll)
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
          events: scrollEventsSubject
        )
      }

      return cellItem
    }

    applySnapshot(animated: false)
  }

  private func bindActiveChatsViewModel() {
    let viewModel = activeChatsViewModel()
    activeViewModelCancellables.removeAll()

    viewModel.$threads
      .combineLatest(viewModel.$contacts)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        self?.applySnapshot()
      }
      .store(in: &activeViewModelCancellables)
  }

  private func applySnapshot(animated: Bool = false) {
    let data = makeSnapshotData()
    currentSections = data.sections

    var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
    var itemsToReload: [Item] = []
 
    for section in data.sections {
      snapshot.appendSections([section])
      let sectionItems = data.items[section] ?? []
      snapshot.appendItems(sectionItems, toSection: section)

      let reloadCandidates = sectionItems.filter { item in
        guard let newValue = value(for: item) else { return false }
        if let old = previousItemsByID[item] {
          return old != newValue
        }
        return true
      }
      itemsToReload.append(contentsOf: reloadCandidates)
    }

    chatItemsByID = data.chatItemsByID

    dataSource.apply(snapshot, animatingDifferences: animated) { [weak self] in
      if !itemsToReload.isEmpty {
        let indexPaths: [IndexPath] = itemsToReload.compactMap { item in
          guard let self else { return nil }
          guard let (sectionIndex, itemIndex) = self.indexPath(of: item, in: snapshot) else { return nil }
          return IndexPath(item: itemIndex, section: sectionIndex)
        }

        if !indexPaths.isEmpty {
          self?.collectionView.reloadItems(at: Set(indexPaths))
        }
      }
    }

    previousItemsByID = data.valuesByItem
    if let layout = collectionView.collectionViewLayout {
      layout.invalidateLayout()
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
  }

  private func makeSnapshotData() -> SnapshotData {
    let viewModel = activeChatsViewModel()

    let threads = viewModel.threads
    let contacts = viewModel.contacts
    let allItems = threads + contacts
    let chatMap = Dictionary(uniqueKeysWithValues: allItems.map { ($0.id, $0) })

    let sections: [Section]
    var items: [Section: [Item]] = [:]
    var valuesByItem: [Item: AnyHashable] = [:]

    if viewModel.isSpaceSource {
      let threadItems: [Item] = [.header(.spaceThreads)] + threads.map { .chat($0.id) }
      let contactItems: [Item] = [.header(.spaceMembers)] + contacts.map { .chat($0.id) }

      sections = [.spaceThreads, .spaceMembers]
      items[.spaceThreads] = threadItems
      items[.spaceMembers] = contactItems

      threadItems.forEach { item in
        switch item {
          case let .chat(id): valuesByItem[item] = chatMap[id]
          case let .header(section): valuesByItem[item] = "header-\(section)" as AnyHashable
        }
      }

      contactItems.forEach { item in
        switch item {
          case let .chat(id): valuesByItem[item] = chatMap[id]
          case let .header(section): valuesByItem[item] = "header-\(section)" as AnyHashable
        }
      }
    } else {
      let chatItems: [Item] = threads.map { .chat($0.id) }
      sections = [.homeChats]
      items[.homeChats] = chatItems
      chatItems.forEach { item in
        if case let .chat(id) = item {
          valuesByItem[item] = chatMap[id]
        }
      }
    }

    return SnapshotData(
      sections: sections,
      items: items,
      chatItemsByID: chatMap,
      valuesByItem: valuesByItem
    )
  }

  private func layout(for _: Section) -> NSCollectionLayoutSection {
    let itemSize = NSCollectionLayoutSize(
      widthDimension: .fractionalWidth(1.0),
      heightDimension: .absolute(Self.itemHeight)
    )
    let item = NSCollectionLayoutItem(layoutSize: itemSize)

    let groupSize = NSCollectionLayoutSize(
      widthDimension: .fractionalWidth(1.0),
      heightDimension: .absolute(Self.itemHeight)
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

  private func value(for item: Item) -> AnyHashable? {
    switch item {
      case let .chat(id):
        chatItemsByID[id]
      case let .header(section):
        "header-\(section)" as AnyHashable
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
        switch section {
          case .spaceThreads:
            title = "Threads"
            symbol = "text.bubble.fill"
          case .spaceMembers:
            title = "Members"
            symbol = "person.2.fill"
          case .homeChats:
            title = "Chats"
            symbol = "bubble.left.and.bubble.right.fill"
        }
        return .init(kind: .header(title: title, symbol: symbol))
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
}
