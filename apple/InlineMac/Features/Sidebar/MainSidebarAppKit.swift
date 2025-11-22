import AppKit
import Combine
import InlineKit

class MainSidebarAppKit: NSViewController {
  private let dependencies: AppDependencies
  private var homeViewModel: HomeViewModel
  private var cancellables = Set<AnyCancellable>()

  private static let itemHeight: CGFloat = 34
  private static let itemSpacing: CGFloat = 1
  private static let contentInsetTop: CGFloat = 0
  private static let contentInsetBottom: CGFloat = 8
  // private static let contentInsetLeading: CGFloat = 6
  private static let contentInsetLeading: CGFloat = 8
  // private static let contentInsetTrailing: CGFloat = 6
  private static let contentInsetTrailing: CGFloat = 8

  enum Section {
    case main
  }

  private var dataSource: NSCollectionViewDiffableDataSource<Section, HomeChatItem.ID>!
  private var previousItems: [HomeChatItem] = []

  init(dependencies: AppDependencies) {
    self.dependencies = dependencies
    homeViewModel = HomeViewModel(
      db: dependencies.database
    )

    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private var items: [HomeChatItem] {
    homeViewModel.myChats.filter { item in
      item.user != nil
    }
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

  override func loadView() {
    view = NSView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.wantsLayer = true
    setupViews()
    setupNotifications()
  }

  private func setupViews() {
    view.addSubview(scrollView)

    NSLayoutConstraint.activate([
      scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: view.topAnchor),
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

    return NSCollectionViewCompositionalLayout(section: section)
  }

  override func viewDidLoad() {
    super.viewDidLoad()

    setupDataSource()

    homeViewModel.$myChats
      .receive(on: DispatchQueue.main)
      .sink { [weak self] chats in
        self?.updateDataSource(with: chats.filter { $0.user != nil })
      }
      .store(in: &cancellables)
  }

  private func setupDataSource() {
    collectionView.register(
      MainSidebarItemCollectionViewItem.self,
      forItemWithIdentifier: NSUserInterfaceItemIdentifier("MainSidebarCell")
    )

    dataSource = NSCollectionViewDiffableDataSource<Section, HomeChatItem.ID>(
      collectionView: collectionView
    ) { [weak self] collectionView, indexPath, itemID in
      guard let self,
            let item = items.first(where: { $0.id == itemID })
      else {
        return nil
      }

      let cellItem = collectionView.makeItem(
        withIdentifier: NSUserInterfaceItemIdentifier("MainSidebarCell"),
        for: indexPath
      ) as? MainSidebarItemCollectionViewItem

      cellItem?.configure(
        with: item,
        dependencies: dependencies,
        events: scrollEventsSubject
      )

      return cellItem
    }

    updateDataSource(with: items, animated: false)
  }

  private func updateDataSource(with items: [HomeChatItem], animated: Bool = true) {
    var snapshot = NSDiffableDataSourceSnapshot<Section, HomeChatItem.ID>()
    snapshot.appendSections([.main])

    let itemsToReload = items.filter { newItem in
      if let oldItem = previousItems.first(where: { $0.id == newItem.id }) {
        return oldItem != newItem
      }
      return false
    }

    snapshot.appendItems(items.map(\.id), toSection: .main)

    dataSource.apply(snapshot, animatingDifferences: animated) { [weak self] in
      if !itemsToReload.isEmpty {
        let indexPaths = itemsToReload.compactMap { item in
          self?.items.firstIndex(where: { $0.id == item.id })
        }.map { IndexPath(item: $0, section: 0) }

        if !indexPaths.isEmpty {
          self?.collectionView.reloadItems(at: Set(indexPaths))
        }
      }
    }

    previousItems = items
  }
}
