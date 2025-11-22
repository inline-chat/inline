import AppKit
import Combine

struct TabModel: Hashable {
  let id: UUID = .init()
  let icon: String
  let title: String
}

class MainTabBar: NSViewController {
  private let tabHeight: CGFloat = Theme.tabBarItemHeight
  private let tabMaxWidth: CGFloat = 110
  private let iconSize: CGFloat = 16

  private var topGap: CGFloat {
    Theme.tabBarHeight - tabHeight
  }

  private var collectionView: NSCollectionView!

  private var dependencies: AppDependencies
  private var nav2: Nav2 { dependencies.nav2! }

  init(dependencies: AppDependencies) {
    self.dependencies = dependencies
    super.init(nibName: nil, bundle: nil)
    setupObservers()
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func loadView() {
    let containerView = NSView()
    containerView.wantsLayer = true

    let layout = NSCollectionViewFlowLayout()
    layout.scrollDirection = .horizontal
    layout.minimumInteritemSpacing = Theme.tabBarItemInset // Matches the inset for hovered
    // layout.minimumLineSpacing = 4
    layout.sectionInset = NSEdgeInsets(top: topGap, left: 24, bottom: 0, right: 40)

    collectionView = NSCollectionView()
    collectionView.collectionViewLayout = layout
    collectionView.dataSource = self
    collectionView.delegate = self
    collectionView.isSelectable = true
    collectionView.allowsEmptySelection = true
    collectionView.backgroundColors = [.clear]
    collectionView.register(
      TabCollectionViewItem.self,
      forItemWithIdentifier: NSUserInterfaceItemIdentifier("TabItem")
    )
    collectionView.translatesAutoresizingMaskIntoConstraints = false

    containerView.addSubview(collectionView)

    NSLayoutConstraint.activate([
      collectionView.topAnchor.constraint(equalTo: containerView.topAnchor),
      collectionView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 0),
      collectionView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: 0),
      collectionView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
    ])

    view = containerView
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    collectionView.reloadData()
  }

  private func setupObservers() {
    withObservationTracking {
      _ = nav2.tabs
      _ = nav2.activeTabIndex
    } onChange: {
      Task { @MainActor [weak self] in
        self?.collectionView?.reloadData()
        self?.setupObservers()
      }
    }
  }

  private func tabModel(for tabId: TabId) -> TabModel {
    switch tabId {
      case .home:
        TabModel(icon: "house", title: "Home")
      case let .space(id, name):
        TabModel(icon: "number", title: name)
    }
  }

  private func isTabClosable(at index: Int) -> Bool {
    guard index < nav2.tabs.count else { return false }
    if nav2.tabs.count == 1, nav2.tabs[index] == .home {
      return false
    }
    return true
  }
}

extension MainTabBar: NSCollectionViewDataSource {
  func collectionView(_: NSCollectionView, numberOfItemsInSection _: Int) -> Int {
    nav2.tabs.count
  }

  func collectionView(
    _ collectionView: NSCollectionView,
    itemForRepresentedObjectAt indexPath: IndexPath
  ) -> NSCollectionViewItem {
    let item = collectionView.makeItem(
      withIdentifier: NSUserInterfaceItemIdentifier("TabItem"),
      for: indexPath
    ) as! TabCollectionViewItem

    let tabId = nav2.tabs[indexPath.item]
    let tab = tabModel(for: tabId)
    let selected = nav2.activeTabIndex == indexPath.item
    let closable = isTabClosable(at: indexPath.item)

    item.configure(with: tab, iconSize: iconSize, selected: selected, closable: closable)
    item.onClose = { [weak self] in
      self?.nav2.removeTab(at: indexPath.item)
    }

    return item
  }
}

extension MainTabBar: NSCollectionViewDelegate {
  func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
    guard let indexPath = indexPaths.first else { return }
    nav2.setActiveTab(index: indexPath.item)
  }
}

extension MainTabBar: NSCollectionViewDelegateFlowLayout {
  func collectionView(
    _: NSCollectionView,
    layout _: NSCollectionViewLayout,
    sizeForItemAt indexPath: IndexPath
  ) -> NSSize {
    NSSize(width: tabMaxWidth, height: tabHeight)
  }
}
