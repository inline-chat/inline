import Auth
import Combine
import InlineCompatUI
import InlineIOSFoundation
import InlineKit
import InlineUI
import Logger
import RealtimeV2
import UIKit

/// All Chats, Open Chats and Archived Chats. Replaces `ExperimentalHomeView`/`ExperimentalChatListView`.
@MainActor
final class HomeListViewController: UIViewController, UICollectionViewDelegate {
  enum Surface { case inbox, allChats, archived }

  private struct Section: Hashable {
    enum Kind: Hashable { case pinned, open, timeline(ChatListTimelinePeriod), day(Date) }
    let kind: Kind
  }

  private unowned let shell: MainShellController
  let surface: Surface
  private var collectionView: UICollectionView!
  private var dataSource: UICollectionViewDiffableDataSource<Section, Peer>!
  private var items: [Peer: ChatListItemSnapshot] = [:]
  private var sections: [Section] = []
  private var cancellables: Set<AnyCancellable> = []
  private let emptyView = EmptyStateView(title: "")
  private let spinner = UIActivityIndicatorView(style: .medium)
  private var pinnedExpanded: Bool {
    didSet {
      UserDefaults.standard.set(pinnedExpanded, forKey: pinnedKey)
      applyState(animated: true)
    }
  }

  private var pinnedKey: String {
    ExperimentalHomePreferenceKeys.pinnedExpanded(
      surface: surface == .allChats ? .allChats : .inbox,
      userID: Auth.shared.getCurrentUserId()
    )
  }

  private var routerTab: AppTab {
    switch surface {
    case .inbox: .inbox
    case .allChats, .archived: .allChats
    }
  }

  init(shell: MainShellController, surface: Surface) {
    self.shell = shell
    self.surface = surface
    let key = ExperimentalHomePreferenceKeys.pinnedExpanded(
      surface: surface == .allChats ? .allChats : .inbox,
      userID: Auth.shared.getCurrentUserId()
    )
    pinnedExpanded = UserDefaults.standard.object(forKey: key) as? Bool ?? true
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  // MARK: Lifecycle

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = ThemeManager.shared.selected.backgroundColor
    navigationItem.backButtonDisplayMode = .minimal
    if surface == .archived {
      title = String(localized: "Archived Chats")
    }
    makeCollectionView()
    makeOverlays()

    // First render is synchronous from the store's local snapshot.
    applyState(animated: false)
    shell.homeList.$state
      .dropFirst()
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        guard let self else { return }
        applyState(animated: shell.homeList.lastUpdateAnimates)
      }
      .store(in: &cancellables)

    // Row highlight follows the router (opening or open chat) and the layout preferences.
    observe { [weak self] in
      guard let self else { return }
      _ = shell.router[routerTab]
      _ = shell.router.pendingPreparedDestination
      refreshLitRows()
    }
    observe { [weak self] in
      guard let self else { return }
      _ = shell.home.renderMode
      _ = shell.home.unreadBadgeStyle
      reconfigureAll()
    }
    if surface != .archived { updateToolbar() }
    installVoicePill()
  }

  // MARK: Voice playback pill

  private var voicePill: VoicePlaybackPillView?
  private var voicePillVisible = false
  private var voicePillTop: NSLayoutConstraint?

  /// The playback capsule sits under the navigation bar on home roots, as before.
  private func installVoicePill() {
    let pill = VoicePlaybackPillView()
    pill.onOpen = { [weak self] target in
      guard let self else { return }
      VoicePlaybackNavigation.open(target, router: shell.router)
    }
    pill.translatesAutoresizingMaskIntoConstraints = false
    pill.alpha = 0
    pill.isHidden = true
    view.addSubview(pill)
    let top = pill.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8)
    voicePillTop = top
    NSLayoutConstraint.activate([
      top,
      pill.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 8),
      pill.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8),
    ])
    voicePill = pill
    let player = SharedAudioPlayer.shared
    player.$state.combineLatest(player.$loadingVoice)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _, _ in self?.updateVoicePill() }
      .store(in: &cancellables)
    player.$playbackError
      .receive(on: DispatchQueue.main)
      .sink { [weak self] error in self?.presentPlaybackError(error) }
      .store(in: &cancellables)
    updateVoicePill()
  }

  private func updateVoicePill() {
    guard let pill = voicePill else { return }
    let visible = SharedAudioPlayer.shared.isVoiceSelected
    guard visible != voicePillVisible else { return }
    voicePillVisible = visible
    if visible { pill.isHidden = false }
    let animate = view.window != nil && !UIAccessibility.isReduceMotionEnabled
    UIView.animate(withDuration: animate ? 0.26 : 0, delay: 0, options: [.beginFromCurrentState]) {
      let inset: CGFloat = visible ? VoicePlaybackPillView.height + 16 : 0
      // The list makes room below the bar; the pill stays put in that room.
      self.additionalSafeAreaInsets.top = inset
      self.voicePillTop?.constant = 8 - inset
      pill.alpha = visible ? 1 : 0
      pill.transform = visible ? .identity : CGAffineTransform(scaleX: 0.92, y: 0.92)
      self.view.layoutIfNeeded()
    } completion: { _ in
      if !self.voicePillVisible { pill.isHidden = true }
    }
  }

  private func presentPlaybackError(_ error: String?) {
    guard let error, view.window != nil, shell.router.presentedSheet == nil,
          shell.router.selectedTabPath.isEmpty, presentedViewController == nil
    else { return }
    let alert = UIAlertController(title: "Voice playback failed", message: error, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "OK", style: .cancel) { _ in SharedAudioPlayer.shared.clearPlaybackError() })
    present(alert, animated: true)
  }

  // MARK: Collection view

  private var layoutMode: ChatListLayoutMode {
    switch shell.home.renderMode {
    case .large: .large
    case .noLastMessage: .compact
    case .oneLineLastMessage, .twoLineLastMessage: .standard
    }
  }

  private var verticalInset: CGFloat {
    switch shell.home.renderMode {
    case .noLastMessage: 0
    case .oneLineLastMessage, .twoLineLastMessage: 5
    case .large: 2
    }
  }

  private func makeCollectionView() {
    var config = UICollectionLayoutListConfiguration(appearance: .plain)
    config.backgroundColor = .clear
    config.headerMode = .supplementary
    config.headerTopPadding = 0
    config.showsSeparators = true
    config.itemSeparatorHandler = { [weak self] indexPath, separator in
      var separator = separator
      guard let self else { return separator }
      let inset = Theme.Layout.screenEdgeOpticalInset
      separator.bottomSeparatorInsets = NSDirectionalEdgeInsets(top: 0, leading: inset, bottom: 0, trailing: inset)
      separator.topSeparatorVisibility = .hidden
      let lastInSection = indexPath.item == (self.collectionView.numberOfItems(inSection: indexPath.section) - 1)
      if self.layoutMode == .compact || lastInSection {
        separator.bottomSeparatorVisibility = .hidden
      }
      separator.color = UIColor.separator.withAlphaComponent(0.55)
      return separator
    }
    config.leadingSwipeActionsConfigurationProvider = { [weak self] indexPath in
      self?.leadingSwipe(at: indexPath)
    }
    config.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
      self?.trailingSwipe(at: indexPath)
    }
    let layout = UICollectionViewCompositionalLayout { [weak self] _, environment in
      let section = NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
      section.interGroupSpacing = 0
      let spacing: CGFloat = switch self?.shell.home.renderMode ?? .twoLineLastMessage {
      case .noLastMessage: 7
      case .oneLineLastMessage, .twoLineLastMessage: 10
      case .large: 12
      }
      section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: spacing, trailing: 0)
      return section
    }

    collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
    collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    collectionView.backgroundColor = .clear
    collectionView.delegate = self
    collectionView.alwaysBounceVertical = true
    collectionView.contentInset.bottom = 32
    collectionView.compatSetTopEdgeEffect(.soft)
    view.addSubview(collectionView)

    let cellRegistration = UICollectionView.CellRegistration<ChatListCell, Peer> { [weak self] cell, _, peer in
      guard let self, let item = items[peer] else { return }
      cell.configure(item, layout: layoutMode, badgeStyle: shell.home.unreadBadgeStyle, verticalInset: verticalInset)
      cell.isLit = isLit(peer)
    }
    dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, peer in
      collectionView.dequeueConfiguredReusableCell(using: cellRegistration, for: indexPath, item: peer)
    }

    let headerRegistration = UICollectionView.SupplementaryRegistration<SectionHeaderView>(
      elementKind: UICollectionView.elementKindSectionHeader
    ) { [weak self] header, _, indexPath in
      guard let self, sections.indices.contains(indexPath.section) else { return }
      let section = sections[indexPath.section]
      let isPinned = section.kind == .pinned
      header.configure(
        title: title(for: section),
        compact: layoutMode == .compact,
        showsChevron: isPinned && !pinnedExpanded,
        onTap: isPinned ? { [weak self] in self?.pinnedExpanded.toggle() } : nil
      )
    }
    dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
      collectionView.dequeueConfiguredReusableSupplementary(using: headerRegistration, for: indexPath)
    }
  }

  private func makeOverlays() {
    emptyView.translatesAutoresizingMaskIntoConstraints = false
    emptyView.isHidden = true
    view.addSubview(emptyView)
    spinner.translatesAutoresizingMaskIntoConstraints = false
    spinner.hidesWhenStopped = true
    view.addSubview(spinner)
    NSLayoutConstraint.activate([
      emptyView.topAnchor.constraint(equalTo: view.topAnchor),
      emptyView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      emptyView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      emptyView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
    ])
  }

  // MARK: State

  private func applyState(animated: Bool) {
    let state = shell.homeList.state
    let presentation = state.presentation
    var newSections: [(Section, [ChatListItemSnapshot])] = []
    switch surface {
    case .inbox:
      if !presentation.inboxPinned.isEmpty {
        newSections.append((Section(kind: .pinned), pinnedExpanded ? presentation.inboxPinned : []))
      }
      if !presentation.inboxUnpinned.isEmpty {
        newSections.append((Section(kind: .open), presentation.inboxUnpinned))
      }
    case .allChats:
      if !presentation.allChatsPinned.isEmpty {
        newSections.append((Section(kind: .pinned), pinnedExpanded ? presentation.allChatsPinned : []))
      }
      for section in presentation.allChatSections {
        newSections.append((Section(kind: .timeline(section.id)), section.items))
      }
    case .archived:
      for section in presentation.archivedSections {
        newSections.append((Section(kind: .day(section.id)), section.items))
      }
    }

    // Peers are unique across the list; first placement wins.
    var seen = Set<Peer>()
    var snapshot = NSDiffableDataSourceSnapshot<Section, Peer>()
    var newItems: [Peer: ChatListItemSnapshot] = [:]
    for (section, rows) in newSections {
      snapshot.appendSections([section])
      let unique = rows.filter { seen.insert($0.peer).inserted }
      snapshot.appendItems(unique.map(\.peer), toSection: section)
      for row in unique { newItems[row.peer] = row }
    }
    let changed = newItems.compactMap { peer, item -> Peer? in
      guard let old = items[peer], old != item else { return nil }
      return peer
    }
    if !changed.isEmpty {
      snapshot.reconfigureItems(changed)
    }
    let headerChanged = sections != snapshot.sectionIdentifiers
    items = newItems
    sections = snapshot.sectionIdentifiers
    let animate = animated && view.window != nil && !UIAccessibility.isReduceMotionEnabled
    dataSource.apply(snapshot, animatingDifferences: animate)
    if headerChanged || !animate {
      refreshHeaders()
    }
    updateOverlay(isLoading: state.isLoading, error: state.errorDescription, isEmpty: newItems.isEmpty && sections.isEmpty)
  }

  private func refreshHeaders() {
    for indexPath in collectionView.indexPathsForVisibleSupplementaryElements(ofKind: UICollectionView.elementKindSectionHeader) {
      guard let header = collectionView.supplementaryView(
        forElementKind: UICollectionView.elementKindSectionHeader, at: indexPath
      ) as? SectionHeaderView, sections.indices.contains(indexPath.section) else { continue }
      let section = sections[indexPath.section]
      let isPinned = section.kind == .pinned
      header.configure(
        title: title(for: section),
        compact: layoutMode == .compact,
        showsChevron: isPinned && !pinnedExpanded,
        onTap: isPinned ? { [weak self] in self?.pinnedExpanded.toggle() } : nil
      )
    }
  }

  private func reconfigureAll() {
    guard dataSource != nil else { return }
    var snapshot = dataSource.snapshot()
    snapshot.reconfigureItems(snapshot.itemIdentifiers)
    dataSource.apply(snapshot, animatingDifferences: false)
    collectionView.collectionViewLayout.invalidateLayout()
    refreshHeaders()
  }

  private func updateOverlay(isLoading: Bool, error: String?, isEmpty: Bool) {
    if isLoading && isEmpty {
      spinner.startAnimating()
      emptyView.isHidden = true
      return
    }
    spinner.stopAnimating()
    guard isEmpty else {
      emptyView.isHidden = true
      return
    }
    emptyView.isHidden = false
    if error != nil {
      emptyView.update(
        systemImage: "exclamationmark.triangle",
        title: String(localized: "Chats stored on this device could not be read.")
      )
      return
    }
    switch surface {
    case .inbox:
      emptyView.update(
        systemImage: "tray",
        title: String(localized: "No open chats"),
        message: String(localized: "Open a chat from All Chats to keep it here.")
      )
    case .allChats:
      if shell.home.allChatsFilter == .unread {
        emptyView.update(
          systemImage: "checkmark.message",
          title: String(localized: "No unread chats"),
          message: String(localized: "You’re caught up.")
        )
      } else {
        emptyView.update(
          systemImage: "bubble.left.and.bubble.right",
          title: String(localized: "No chats"),
          message: String(localized: "Start a new thread with the compose button.")
        )
      }
    case .archived:
      emptyView.update(
        title: String(localized: "No archived chats"),
        message: String(localized: "Archived chats will show up here.")
      )
    }
  }

  private func title(for section: Section) -> String {
    switch section.kind {
    case .pinned: return String(localized: "Pinned")
    case .open: return String(localized: "Open Chats")
    case let .timeline(period): return Self.title(for: period)
    case let .day(day): return Self.title(forDay: day)
    }
  }

  private static let weekdayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("EEEEMMMd")
    return formatter
  }()

  private static let monthFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("MMMM")
    return formatter
  }()

  private static let yearFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("y")
    return formatter
  }()

  static func title(forDay day: Date) -> String {
    let calendar = Calendar.autoupdatingCurrent
    if calendar.isDateInToday(day) { return String(localized: "Today") }
    if calendar.isDateInYesterday(day) { return String(localized: "Yesterday") }
    return weekdayFormatter.string(from: day)
  }

  static func title(for period: ChatListTimelinePeriod) -> String {
    let calendar = Calendar.autoupdatingCurrent
    switch period {
    case let .day(day):
      return title(forDay: day)
    case let .month(year, month):
      guard let date = calendar.date(from: DateComponents(year: year, month: month, day: 1)) else { return "\(month)" }
      return monthFormatter.string(from: date)
    case let .year(year):
      guard let date = calendar.date(from: DateComponents(year: year, month: 1, day: 1)) else { return "\(year)" }
      return yearFormatter.string(from: date)
    }
  }

  // MARK: Highlight and selection

  private func isLit(_ peer: Peer) -> Bool {
    let destination = Destination.chat(peer: peer)
    return shell.router.pendingPreparedDestination == destination || shell.router[routerTab].contains(destination)
  }

  private func refreshLitRows() {
    guard collectionView != nil else { return }
    for cell in collectionView.visibleCells {
      guard let cell = cell as? ChatListCell, let peer = cell.item?.peer else { continue }
      cell.isLit = isLit(peer)
    }
  }

  func collectionView(_ collectionView: UICollectionView, didHighlightItemAt indexPath: IndexPath) {
    guard let peer = dataSource.itemIdentifier(for: indexPath) else { return }
    // The chat's first window is read while the finger is down, so the push rarely waits.
    ChatOpenPreparation.shared.prefetch(peer: peer)
  }

  func collectionView(_ collectionView: UICollectionView, didUnhighlightItemAt indexPath: IndexPath) {
    guard let peer = dataSource.itemIdentifier(for: indexPath) else { return }
    let destination = Destination.chat(peer: peer)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
      guard let self, shell.router.pendingPreparedDestination != destination,
            !shell.router[routerTab].contains(destination)
      else { return }
      ChatOpenPreparation.shared.discard(peer: peer)
    }
  }

  func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
    collectionView.deselectItem(at: indexPath, animated: false)
    guard let peer = dataSource.itemIdentifier(for: indexPath) else { return }
    ExperimentalHomeNavigationPerformance.beginChatOpen(peer: peer, source: "home")
    shell.router.push(.chat(peer: peer), for: routerTab)
  }

  // MARK: Context menu

  func collectionView(
    _ collectionView: UICollectionView,
    contextMenuConfigurationForItemAt indexPath: IndexPath,
    point: CGPoint
  ) -> UIContextMenuConfiguration? {
    guard let peer = dataSource.itemIdentifier(for: indexPath), let item = items[peer] else { return nil }
    return UIContextMenuConfiguration(identifier: peer.contextMenuIdentifier, previewProvider: nil) { [weak self] _ in
      self?.contextMenu(for: item)
    }
  }

  private func contextMenu(for item: ChatListItemSnapshot) -> UIMenu {
    let readUnread = UIAction(
      title: item.needsAttention ? String(localized: "Mark as Read") : String(localized: "Mark as Unread"),
      image: UIImage(systemName: item.needsAttention ? "checkmark.message" : "envelope.badge")
    ) { [weak self] _ in self?.setRead(item.peer, isUnread: item.needsAttention) }
    let pin = UIAction(
      title: item.isPinned ? String(localized: "Unpin") : String(localized: "Pin"),
      image: UIImage(systemName: item.isPinned ? "pin.slash" : "pin")
    ) { [weak self] _ in self?.setPinned(item.peer, pinned: !item.isPinned) }
    let archive = UIAction(
      title: String(localized: "Archive"), image: UIImage(systemName: "archivebox"), attributes: .destructive
    ) { [weak self] _ in self?.requestArchive(item) }

    switch surface {
    case .inbox:
      let close = UIAction(title: String(localized: "Close"), image: UIImage(systemName: "xmark")) { [weak self] _ in
        self?.close(item.peer)
      }
      return UIMenu(children: [
        readUnread, pin,
        UIMenu(options: .displayInline, children: [close, archive]),
      ])
    case .allChats:
      let open = UIAction(
        title: String(localized: "Open"),
        subtitle: String(localized: "Add to Open Chats"),
        image: UIImage(systemName: "tray.and.arrow.down")
      ) { [weak self] _ in self?.addToOpen(item) }
      return UIMenu(children: [
        open, readUnread, pin,
        UIMenu(options: .displayInline, children: [archive]),
      ])
    case .archived:
      let unarchive = UIAction(
        title: String(localized: "Unarchive"), image: UIImage(systemName: "arrow.uturn.backward.circle")
      ) { [weak self] _ in self?.unarchive(item) }
      return UIMenu(children: [unarchive, readUnread])
    }
  }

  // MARK: Swipe actions

  private func leadingSwipe(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
    guard let peer = dataSource.itemIdentifier(for: indexPath), let item = items[peer] else { return nil }
    let read = UIContextualAction(
      style: .normal,
      title: item.needsAttention ? String(localized: "Read") : String(localized: "Unread")
    ) { [weak self] _, _, done in
      self?.setRead(peer, isUnread: item.needsAttention)
      done(true)
    }
    read.image = UIImage(systemName: item.needsAttention ? "checkmark.message.fill" : "envelope.badge.fill")
    read.backgroundColor = .systemBlue
    var actions = [read]
    if peer.asUserId() == nil {
      let follow = UIContextualAction(
        style: .normal,
        title: item.isFollowed ? String(localized: "Unfollow") : String(localized: "Follow")
      ) { [weak self] _, _, done in
        self?.setFollow(peer, isFollowed: item.isFollowed)
        done(true)
      }
      follow.image = UIImage(systemName: item.isFollowed ? "eye.slash.fill" : "eye.fill")
      follow.backgroundColor = .systemPurple
      actions.append(follow)
    }
    let configuration = UISwipeActionsConfiguration(actions: actions)
    configuration.performsFirstActionWithFullSwipe = surface == .allChats
    return configuration
  }

  private func trailingSwipe(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
    guard let peer = dataSource.itemIdentifier(for: indexPath), let item = items[peer] else { return nil }
    var actions: [UIContextualAction] = []
    switch surface {
    case .inbox:
      let close = UIContextualAction(style: .normal, title: String(localized: "Close")) { [weak self] _, _, done in
        self?.close(peer)
        done(true)
      }
      close.image = UIImage(systemName: "xmark")
      close.backgroundColor = .systemGray
      actions.append(close)
    case .allChats:
      let open = UIContextualAction(style: .normal, title: String(localized: "Open")) { [weak self] _, _, done in
        self?.addToOpen(item)
        done(true)
      }
      open.image = UIImage(systemName: "tray.and.arrow.down.fill")
      open.backgroundColor = .systemGreen
      let archive = UIContextualAction(style: .normal, title: String(localized: "Archive")) { [weak self] _, _, done in
        self?.requestArchive(item)
        done(true)
      }
      archive.image = UIImage(systemName: "archivebox.fill")
      archive.backgroundColor = .systemRed
      actions += [open, archive]
    case .archived:
      let unarchive = UIContextualAction(style: .normal, title: String(localized: "Unarchive")) { [weak self] _, _, done in
        self?.unarchive(item)
        done(true)
      }
      unarchive.image = UIImage(systemName: "arrow.uturn.backward.circle.fill")
      unarchive.backgroundColor = .systemBlue
      actions.append(unarchive)
    }
    if surface != .archived {
      let pin = UIContextualAction(
        style: .normal,
        title: item.isPinned ? String(localized: "Unpin") : String(localized: "Pin")
      ) { [weak self] _, _, done in
        done(true)
        // Let the swipe close before the row moves between sections.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
          self?.setPinned(peer, pinned: !item.isPinned)
        }
      }
      pin.image = UIImage(systemName: item.isPinned ? "pin.slash.fill" : "pin.fill")
      pin.backgroundColor = .systemIndigo
      actions.append(pin)
    }
    return UISwipeActionsConfiguration(actions: actions)
  }

  // MARK: Actions

  private func setRead(_ peer: Peer, isUnread: Bool) {
    Task {
      do {
        _ = try await shell.homeActions.perform(peer: peer) {
          if isUnread {
            _ = try await Api.realtime.send(.readMessages(peerId: peer, readActivity: true))
          } else {
            _ = try await Api.realtime.send(.markAsUnread(peerId: peer))
          }
        }
      } catch {
        Log.shared.error("Failed to update read state", error: error)
        ToastManager.shared.showToast("Could not update unread state", type: .error, systemImage: "exclamationmark.triangle.fill")
      }
    }
  }

  private func setPinned(_ peer: Peer, pinned: Bool) {
    Task {
      do {
        _ = try await shell.homeActions.perform(peer: peer) {
          _ = try await Api.realtime.send(.updateDialogOrder(peerId: peer, pinned: pinned))
        }
      } catch {
        Log.shared.error("Failed to update pin state", error: error)
        ToastManager.shared.showToast("Could not update pin", type: .error, systemImage: "exclamationmark.triangle.fill")
      }
    }
  }

  private func setFollow(_ peer: Peer, isFollowed: Bool) {
    Task {
      do {
        _ = try await Api.realtime.send(.updateDialogFollowMode(
          peerId: peer, selection: isFollowed ? .unfollowed : .following
        ))
        ToastManager.shared.showToast(
          isFollowed ? "Unfollowed" : "Following",
          description: isFollowed
            ? "Only mentions and replies can bring this chat back."
            : "New messages will appear in Open Chats.",
          type: .success,
          systemImage: isFollowed ? "eye.slash.fill" : "eye.fill"
        )
      } catch {
        Log.shared.error("Failed to update follow state", error: error)
        ToastManager.shared.showToast("Could not update follow state", type: .error, systemImage: "exclamationmark.triangle.fill")
      }
    }
  }

  private func close(_ peer: Peer) {
    Task {
      do {
        _ = try await InboxMembershipService.shared.close(peer: peer)
      } catch {
        Log.shared.error("Failed to update Inbox state", error: error)
        ToastManager.shared.showToast("Could not close chat", type: .error, systemImage: "exclamationmark.triangle.fill")
      }
    }
  }

  private func addToOpen(_ item: ChatListItemSnapshot) {
    Task {
      do {
        if item.isOpen {
          ToastManager.shared.showToast(
            "Already open", description: "This chat is already in Open Chats.", type: .info, systemImage: "bubble.left.fill"
          )
          return
        }
        guard try await InboxMembershipService.shared.open(peer: item.peer) else { return }
        ToastManager.shared.showToast("Now in Open Chats", type: .success, systemImage: "bubble.left.fill")
      } catch {
        Log.shared.error("Failed to update Inbox state", error: error)
        ToastManager.shared.showToast("Could not open chat", type: .error, systemImage: "exclamationmark.triangle.fill")
      }
    }
  }

  private func requestArchive(_ item: ChatListItemSnapshot) {
    Task { [weak self] in
      guard let self else { return }
      let confirmed = await confirm(
        title: String(localized: "Archive Chat?"),
        message: String(localized: "This chat will move to Archived Chats. You can find it from the ••• menu."),
        confirmTitle: String(localized: "Archive"),
        destructive: true
      )
      guard confirmed else { return }
      archive(item)
    }
  }

  private func archive(_ item: ChatListItemSnapshot) {
    Task {
      do {
        let didPerform = try await shell.homeActions.perform(peer: item.peer) {
          try await shell.data.updateDialog(
            peerId: item.peer, archived: true, spaceId: item.spaceID, deleteEmptyThreadIfArchiving: false
          )
        }
        guard didPerform else { return }
        ToastManager.shared.showToast(
          "Archived",
          type: .success,
          systemImage: "archivebox.fill",
          action: { [weak self] in self?.unarchive(item, showsSuccessToast: false) },
          actionTitle: "Undo"
        )
      } catch {
        Log.shared.error("Failed to archive chat", error: error)
        ToastManager.shared.showToast("Could not archive chat", type: .error, systemImage: "exclamationmark.triangle.fill")
      }
    }
  }

  private func unarchive(_ item: ChatListItemSnapshot, showsSuccessToast: Bool = true) {
    Task {
      do {
        let didPerform = try await shell.homeActions.perform(peer: item.peer) {
          try await shell.data.updateDialog(
            peerId: item.peer, archived: false, spaceId: item.spaceID, deleteEmptyThreadIfArchiving: false
          )
        }
        guard didPerform, showsSuccessToast else { return }
        ToastManager.shared.showToast("Restored to All Chats", type: .success, systemImage: "arrow.uturn.backward.circle.fill")
      } catch {
        Log.shared.error("Failed to unarchive chat", error: error)
        ToastManager.shared.showToast("Could not restore chat", type: .error, systemImage: "exclamationmark.triangle.fill")
      }
    }
  }

  // MARK: Toolbar

  func updateToolbar() {
    guard surface != .archived, isViewLoaded else { return }
    HomeToolbar.apply(to: navigationItem, surface: surface, shell: shell)
  }
}

// MARK: - Section header

private final class SectionHeaderView: UICollectionViewListCell {
  private let label = UILabel()
  private let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
  private var onTap: (() -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    label.adjustsFontForContentSizeCategory = true
    label.textColor = .secondaryLabel
    chevron.preferredSymbolConfiguration = .init(textStyle: .caption1, scale: .default)
    chevron.tintColor = .secondaryLabel
    let stack = UIStackView(arrangedSubviews: [label, chevron])
    stack.spacing = 6
    stack.alignment = .center
    stack.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(stack)
    let inset = Theme.Layout.screenEdgeOpticalInset
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: inset),
      stack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -inset),
      stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 1),
      stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
    ])
    addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
    accessibilityTraits = .header
    backgroundConfiguration = .clear()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func configure(title: String, compact: Bool, showsChevron: Bool, onTap: (() -> Void)?) {
    let size: CGFloat = compact ? 15 : 16
    label.font = UIFontMetrics(forTextStyle: compact ? .subheadline : .headline)
      .scaledFont(for: .systemFont(ofSize: size, weight: .semibold))
    label.text = title
    chevron.isHidden = !showsChevron
    self.onTap = onTap
    accessibilityLabel = title
    accessibilityTraits = onTap == nil ? .header : [.header, .button]
  }

  @objc private func tapped() { onTap?() }
}

private extension Peer {
  var contextMenuIdentifier: NSString {
    switch self {
    case let .user(id): "user-\(id)" as NSString
    case let .thread(id): "thread-\(id)" as NSString
    }
  }
}
