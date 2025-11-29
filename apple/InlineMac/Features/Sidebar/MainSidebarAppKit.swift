import AppKit
import Combine
import InlineKit
import Observation

class MainSidebarAppKit: NSViewController {
  private let dependencies: AppDependencies
  private var homeViewModel: HomeViewModel
  private var nav2: Nav2?
  private var cancellables = Set<AnyCancellable>()

  private static let itemHeight: CGFloat = 34
  private static let itemSpacing: CGFloat = 1
  private static let contentInsetTop: CGFloat = 0
  private static let contentInsetBottom: CGFloat = 8
  // private static let contentInsetLeading: CGFloat = 6
  private static let contentInsetLeading: CGFloat = 8
  // private static let contentInsetTrailing: CGFloat = 6
  private static let contentInsetTrailing: CGFloat = 8

  enum Section: Hashable {
    case homeChats
    case spaceThreads
    case spaceMembers
  }

  enum Item: Hashable {
    case header(Section)
    case chat(HomeChatItem.ID)
    case member(Member.ID)
  }

  private var dataSource: NSCollectionViewDiffableDataSource<Section, Item>!
  private var previousItemsByID: [Item: AnyHashable] = [:]
  private var currentSections: [Section] = []
  private var chatByID: [HomeChatItem.ID: HomeChatItem] = [:]
  private var memberByID: [Member.ID: Member] = [:]
  private var memberUserCancellables = Set<AnyCancellable>()

  init(dependencies: AppDependencies) {
    self.dependencies = dependencies
    nav2 = dependencies.nav2
    homeViewModel = HomeViewModel(
      db: dependencies.database
    )

    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

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

  enum ScrollEvent {
    case didLiveScroll
    case didEndLiveScroll
  }

  private var scrollEventsSubject = PassthroughSubject<ScrollEvent, Never>()

  // Header
  private lazy var headerStack: NSStackView = {
    let stack = NSStackView()
    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.distribution = .fill
    stack.spacing = 6
    stack.translatesAutoresizingMaskIntoConstraints = false
    return stack
  }()

  private lazy var titleLabel: NSTextField = {
    let label = NSTextField(labelWithString: "")
    label.font = .systemFont(ofSize: 13, weight: .semibold)
    label.textColor = .secondaryLabelColor
    label.lineBreakMode = .byTruncatingTail
    label.translatesAutoresizingMaskIntoConstraints = false
    return label
  }()

  private var headerTopConstraint: NSLayoutConstraint?

  override func loadView() {
    view = NSView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.wantsLayer = true
    setupViews()
    setupNotifications()
  }

  private func setupViews() {
    headerStack.addArrangedSubview(titleLabel)

    view.addSubview(headerStack)
    view.addSubview(scrollView)

    headerTopConstraint = headerStack.topAnchor.constraint(equalTo: view.topAnchor, constant: headerTopInset())

    NSLayoutConstraint.activate([
      headerStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
      headerStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
      headerTopConstraint!,

      scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 6),
      scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
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
        sectionIndex < self.currentSections.count
      else { return nil }

      let sectionKind = self.currentSections[sectionIndex]
      return self.layout(for: sectionKind)
    }

    return NSCollectionViewCompositionalLayout(sectionProvider: sectionProvider)
  }

  override func viewDidLoad() {
    super.viewDidLoad()

    setupDataSource()

    homeViewModel.$myChats
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        self?.applySnapshot()
      }
      .store(in: &cancellables)

    observeNav()
    updateTitle()
    applySnapshot(animated: false)
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

      if let content = self.content(for: itemID) {
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

  private func applySnapshot(animated: Bool = true) {
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

    chatByID = data.chatByID
    memberByID = data.memberByID

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
    let chatByID: [HomeChatItem.ID: HomeChatItem]
    let memberByID: [Member.ID: Member]
    let valuesByItem: [Item: AnyHashable]
  }

  private func makeSnapshotData() -> SnapshotData {
    let defaultChats = homeViewModel.myChats
    let defaultItems: [Item] = defaultChats.map { .chat($0.id) }
    let defaultChatMap = Dictionary(uniqueKeysWithValues: defaultChats.map { ($0.id, $0) })

    guard let activeTab = nav2?.activeTab else {
      return SnapshotData(
        sections: [.homeChats],
        items: [.homeChats: defaultItems],
        chatByID: defaultChatMap,
        memberByID: [:],
        valuesByItem: Dictionary(uniqueKeysWithValues: defaultItems.compactMap { item in
          switch item {
            case let .chat(id): return (item, defaultChatMap[id] as AnyHashable? ?? "" as AnyHashable)
            default: return nil
          }
        })
      )
    }

    switch activeTab {
      case .home:
        let chats = homeViewModel.myChats.filter { $0.space == nil }
        let items: [Item] = chats.map { .chat($0.id) }
        let chatMap = Dictionary(uniqueKeysWithValues: chats.map { ($0.id, $0) })
        return SnapshotData(
          sections: [.homeChats],
          items: [.homeChats: items],
          chatByID: chatMap,
          memberByID: [:],
          valuesByItem: Dictionary(uniqueKeysWithValues: items.compactMap { item in
            switch item {
              case let .chat(id): return (item, chatMap[id] as AnyHashable? ?? "" as AnyHashable)
              default: return nil
            }
          })
        )
      case let .space(id, _):
        let threads = homeViewModel.myChats.filter { $0.space?.id == id }
        let spaceMembers = homeViewModel.spaces.first(where: { $0.space.id == id })?.members ?? []
        updateMemberSubscriptions(members: spaceMembers)

        let threadItems: [Item] = [.header(.spaceThreads)] + threads.map { .chat($0.id) }
        let memberItems: [Item] = [.header(.spaceMembers)] + spaceMembers.map { .member($0.id) }

        let chatMap = Dictionary(uniqueKeysWithValues: threads.map { ($0.id, $0) })
        let memberMap = Dictionary(uniqueKeysWithValues: spaceMembers.map { ($0.id, $0) })

        var values: [Item: AnyHashable] = [:]
        threadItems.forEach { item in
          switch item {
            case let .chat(cid): values[item] = chatMap[cid]
            case let .header(section): values[item] = "header-\(section)" as AnyHashable
            default: break
          }
        }
        memberItems.forEach { item in
          switch item {
            case let .member(mid): values[item] = memberMap[mid]
            case let .header(section): values[item] = "header-\(section)" as AnyHashable
            default: break
          }
        }

        return SnapshotData(
          sections: [.spaceThreads, .spaceMembers],
          items: [.spaceThreads: threadItems, .spaceMembers: memberItems],
          chatByID: chatMap,
          memberByID: memberMap,
          valuesByItem: values
        )
    }
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
      _ = self.nav2?.activeTab
      _ = self.nav2?.tabs
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        self?.updateTitle()
        self?.applySnapshot()
        self?.observeNav()
      }
    }
  }

  private func updateTitle() {
    let title = nav2?.activeTab.tabTitle ?? "Home"
    titleLabel.stringValue = title
  }

  private func value(for item: Item) -> AnyHashable? {
    switch item {
      case let .chat(id):
        return chatByID[id]
      case let .member(id):
        return memberByID[id]
      case let .header(section):
        return "header-\(section)" as AnyHashable
    }
  }

  private func content(for item: Item) -> MainSidebarItemCollectionViewItem.Content? {
    switch item {
      case let .chat(id):
        guard let chat = chatByID[id] else { return nil }
        return .init(kind: .chat(chat))
      case let .member(id):
        guard let member = memberByID[id] else { return nil }
        let userInfo = ObjectCache.shared.getUser(id: member.userId)
        return .init(kind: .member(member, userInfo))
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

  private func updateMemberSubscriptions(members: [Member]) {
    memberUserCancellables.removeAll()
    for member in members {
      let publisher = ObjectCache.shared.getUserPublisher(id: member.userId)
      publisher
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
          self?.applySnapshot()
        }
        .store(in: &memberUserCancellables)
    }
  }

  private func headerTopInset() -> CGFloat {
    if let window = view.window, window.styleMask.contains(.fullSizeContentView) {
      // Leave room for traffic lights when content is full-height.
      return 40
    }
    return 8
  }

  override func viewDidLayout() {
    super.viewDidLayout()
    headerTopConstraint?.constant = headerTopInset()
  }
}
