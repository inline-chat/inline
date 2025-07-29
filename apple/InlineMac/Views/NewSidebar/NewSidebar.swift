import AppKit
import Combine
import InlineKit
import Logger

class NewSidebar: NSViewController {
  private let dependencies: AppDependencies
  private var tab: HomeSidebar.Tab
  private var homeViewModel: HomeViewModel
  private var cancellables = Set<AnyCancellable>()

  private var rowHeight: CGFloat = SidebarItemRow.height

  // Add section enum for diffable data source
  enum Section {
    case main
  }

  // Add diffable data source
  private var dataSource: NSTableViewDiffableDataSource<Section, HomeChatItem.ID>!

  // Keep track of previous items to detect changes
  private var previousItems: [HomeChatItem] = []

  init(dependencies: AppDependencies, tab: HomeSidebar.Tab) {
    self.dependencies = dependencies
    self.tab = tab
    homeViewModel = HomeViewModel(
      db: dependencies.database,
    )

    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private var items: [HomeChatItem] {
    switch tab {
      case .archive:
        homeViewModel.archivedChats

      case .inbox:
        homeViewModel.myChats

      // ... unsupported
      default:
        homeViewModel.myChats
    }
  }

  public func update(tab: HomeSidebar.Tab) {
    self.tab = tab
    updateDataSource(with: items, animated: false)
  }

  lazy var tableView: NSTableView = {
    let tableView = NSTableView()
    tableView.delegate = self
    tableView.rowHeight = rowHeight
    tableView.style = .plain
    tableView.backgroundColor = .clear
    tableView.headerView = nil
    tableView.rowSizeStyle = .custom
    tableView.selectionHighlightStyle = .none
    tableView.allowsMultipleSelection = false

    tableView.intercellSpacing = NSSize(width: 0, height: 0)
    tableView.usesAutomaticRowHeights = false
    tableView.rowHeight = rowHeight

    let column = NSTableColumn(identifier: .init("messageColumn"))
    column.isEditable = false
    column.title = ""
    column.resizingMask = [.autoresizingMask]

    tableView.addTableColumn(column)
    tableView.translatesAutoresizingMaskIntoConstraints = false
    tableView.wantsLayer = true
    tableView.layerContentsRedrawPolicy = .onSetNeedsDisplay
    tableView.layer?.drawsAsynchronously = true

    return tableView
  }()

  lazy var scrollView: NSScrollView = {
    let scrollView = NSScrollView()
    scrollView.drawsBackground = false
    scrollView.documentView = tableView
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.contentView.wantsLayer = true
    scrollView.postsBoundsChangedNotifications = true

    scrollView.hasVerticalScroller = true
    scrollView.scrollerStyle = .overlay
    scrollView.verticalScroller?.controlSize = .mini

    return scrollView
  }()

  override func loadView() {
    view = NSView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.wantsLayer = true
    setupViews()
    setupNotifications()
  }

  private func setupViews() {
    view.addSubview(scrollView)

    // Ensure the view has a minimum size
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
      selector: #selector(handleBoundsChanged),
      name: NSView.boundsDidChangeNotification,
      object: scrollView.contentView
    )
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
  }

  enum SidebarEvents {
    case didLiveScroll
    case didEndLiveScroll
  }

  private var sidebarEventsSubject = PassthroughSubject<SidebarEvents, Never>()

  @objc private func didLiveScroll() {
    sidebarEventsSubject.send(.didLiveScroll)
  }

  @objc private func didEndLiveScroll() {
    sidebarEventsSubject.send(.didEndLiveScroll)
  }

  @objc private func handleBoundsChanged() {
    // TODO:
  }

  override func viewDidLayout() {
    super.viewDidLayout()
  }

  override func viewDidLoad() {
    super.viewDidLoad()

    // Setup diffable data source
    setupDataSource()

    // Observe chat changes
    homeViewModel.$myChats
      .receive(on: DispatchQueue.main)
      .sink { [weak self] chats in
        if self?.tab == .inbox {
          self?.updateDataSource(with: chats)
        }
      }
      .store(in: &cancellables)

    homeViewModel.$archivedChats
      .receive(on: DispatchQueue.main)
      .sink { [weak self] chats in
        if self?.tab == .archive {
          self?.updateDataSource(with: chats)
        }
      }
      .store(in: &cancellables)
  }

  private func setupDataSource() {
    // Create diffable data source
    dataSource = NSTableViewDiffableDataSource<Section, HomeChatItem.ID>(
      tableView: tableView
    ) { [weak self] tableView, _, _, itemID in
      guard let self,
            let item = items.first(where: { $0.id == itemID })
      else {
        return NSView() // Return empty view instead of nil
      }

      let identifier = NSUserInterfaceItemIdentifier("ItemRow")
      let row = tableView.makeView(withIdentifier: identifier, owner: nil) as? SidebarItemRow
        ?? SidebarItemRow(dependencies: dependencies, events: sidebarEventsSubject)
      row.identifier = identifier
      row.configure(with: item)
      return row
    }

    // Set initial data
    updateDataSource(with: items, animated: false)
  }

  /// Check which messages need to be translated
  private func processForTranslation(items: [HomeChatItem]) {
    let currentRoute = dependencies.nav.currentRoute
    Task.detached {
      for item in items {
        // if active route, don't translate, it's already translating
        guard currentRoute != .chat(peer: item.peerId) else { continue }
        guard let lastMessage = item.lastMessage else { continue }
        TranslationViewModel.translateMessages(for: item.peerId, messages: [FullMessage(from: lastMessage)])
      }
    }
  }

  private func updateDataSource(with items: [HomeChatItem], animated: Bool = true) {
    var snapshot = NSDiffableDataSourceSnapshot<Section, HomeChatItem.ID>()
    snapshot.appendSections([.main])

    // Find items that need to be reloaded (exist in both old and new data but have changed)
    let itemsToReload = items.filter { newItem in
      if let oldItem = previousItems.first(where: { $0.id == newItem.id }) {
        return oldItem != newItem
      }
      return false
    }

    processForTranslation(items: itemsToReload)

    // Add all items to the new snapshot
    snapshot.appendItems(items.map(\.id), toSection: .main)

    // // Apply the snapshot with animation
    dataSource.apply(snapshot, animatingDifferences: animated) { [weak self] in
      // After applying the snapshot, reload the cells that need updating
      if !itemsToReload.isEmpty {
        let indexes = itemsToReload.compactMap { item in
          self?.items.firstIndex(where: { $0.id == item.id })
        }
        if !indexes.isEmpty {
          self?.tableView.reloadData(forRowIndexes: IndexSet(indexes), columnIndexes: IndexSet([0]))
        }
      }
    }

    // Update previous items
    previousItems = items
  }

  // MARK: - Chat Navigation

  @objc private func handleNextChat() {
    navigateChat(offset: 1)
  }

  @objc private func handlePrevChat() {
    navigateChat(offset: -1)
  }

  private func navigateChat(offset: Int) {
    guard !items.isEmpty else { return }

    let nav = dependencies.nav

    // Determine current peer in route
    let currentPeer: Peer? = switch nav.currentRoute {
      case let .chat(peer):
        peer
      default:
        nil
    }

    // Find current index
    let currentIndex: Int = {
      if let currentPeer, let idx = items.firstIndex(where: { $0.peerId == currentPeer }) {
        return idx
      }
      return -1
    }()

    let targetIndex = currentIndex + offset
    guard targetIndex >= 0, targetIndex < items.count else { return }

    let targetPeer = items[targetIndex].peerId
    nav.open(.chat(peer: targetPeer))
  }
}

// MARK: - NSTableViewDelegate

extension NewSidebar: NSTableViewDelegate {
  func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
    rowHeight
  }

  func tableView(
    _ tableView: NSTableView,
    rowActionsForRow row: Int,
    edge: NSTableView.RowActionEdge
  ) -> [NSTableViewRowAction] {
    let item = items[row]
    switch edge {
      case .trailing:
        return [createArchiveAction(item: item)]
      case .leading:
        return [createReadUnreadAction(item: item), createPinAction(item: item)]
      default:
        return []
    }
  }

  private func createPinAction(item: HomeChatItem) -> NSTableViewRowAction {
    let isPinned = item.dialog.pinned == true

    // Pin action
    let pinAction = NSTableViewRowAction(
      style: .regular,
      title: isPinned ? "Unpin" : "Pin"
    ) { [weak self] _, row in
      guard let self else { return }
      let item = items[row]

      // Dismiss the swipe action on the main thread
      tableView.rowActionsVisible = false

      Task.detached {
        // Wait for the swipe action to be dismissed otherwise it will glitch
        try await Task.sleep(for: .milliseconds(340))

        try await DataManager.shared.updateDialog(peerId: item.peerId, pinned: !isPinned)
      }
    }
    pinAction.backgroundColor = .systemOrange
    pinAction.image = NSImage(systemSymbolName: isPinned ? "pin.slash" : "pin", accessibilityDescription: nil)
    return pinAction
  }

  private func createArchiveAction(item: HomeChatItem) -> NSTableViewRowAction {
    let isArchived = item.dialog.archived == true

    // Archive action
    let archiveAction = NSTableViewRowAction(
      style: .destructive,
      title: isArchived ? "Unarchive" : "Archive",
    ) { [weak self] _, row in
      guard let self else { return }
      let item = items[row]
      Task(priority: .userInitiated) {
        try await DataManager.shared.updateDialog(peerId: item.peerId, archived: !isArchived)
      }
    }
    archiveAction.backgroundColor = .systemPurple
    archiveAction.image = NSImage(systemSymbolName: isArchived ? "pin.slash" : "pin", accessibilityDescription: nil)
    return archiveAction
  }
  
  private func createReadUnreadAction(item: HomeChatItem) -> NSTableViewRowAction {
    let hasUnread = (item.dialog.unreadCount ?? 0) > 0 || (item.dialog.unreadMark == true)
    
    let readUnreadAction = NSTableViewRowAction(
      style: .regular,
      title: hasUnread ? "Mark Read" : "Mark Unread"
    ) { [weak self] _, row in
      guard let self else { return }
      let item = items[row]
      
      // Dismiss the swipe action on the main thread
      tableView.rowActionsVisible = false
      
      Task.detached {
        // Wait for the swipe action to be dismissed otherwise it will glitch
        try await Task.sleep(for: .milliseconds(340))
        
        do {
          if hasUnread {
            // Mark as read using UnreadManager
            UnreadManager.shared.readAll(item.peerId, chatId: item.chat?.id ?? 0)
          } else {
            // Mark as unread using realtime API
            try await self.dependencies.realtime
              .invokeWithHandler(.markAsUnread, input: .markAsUnread(.with {
              $0.peerID = item.peerId.toInputPeer()
            }))
          }
        } catch {
          Log.shared.error("Failed to update read/unread status", error: error)
        }
      }
    }
    
    readUnreadAction.backgroundColor = hasUnread ? .systemBlue : .systemGray
    readUnreadAction.image = NSImage(
      systemSymbolName: hasUnread ? "checkmark.message.fill" : "message.badge.filled.fill",
      accessibilityDescription: nil
    )
    
    return readUnreadAction
  }
}

// MARK: - NSTableViewDataSource

extension NewSidebar: NSTableViewDataSource {
  func numberOfRows(in tableView: NSTableView) -> Int {
    let count = items.count
    print("Number of rows: \(count)")
    return count
  }
}
