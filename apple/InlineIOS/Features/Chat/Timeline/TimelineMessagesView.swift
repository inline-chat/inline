import Auth
import Combine
import InlineIOSUI
import InlineKit
import InlineMessageLayout
import InlineUI
import Logger
import UIKit

/// The message list on `InlineTimeline`, hosted by `ChatContainerView` behind the
/// `experimental.iosTimeline` switch.
///
/// Rows come from the view model's row feed and are shown by the production `MessageView`, planned
/// exactly as the collection view's cell plans it. The container owns the keyboard and the composer
/// and reports one compose area; this view turns it into the list's bottom inset in the same call.
@MainActor
final class TimelineMessagesView: UIView, ChatMessageListHosting, SendMessageAnimationListGate {
  let viewModel: MessagesProgressiveViewModel
  let list: TimelineListView<ChatRowID>

  var onContextMenuWillDisplay: (() -> Void)?
  var onContextMenuDidEnd: (() -> Void)?
  var onScrollAffordanceChanged: ((MessagesCollectionView.ScrollAffordanceState) -> Void)? {
    didSet { onScrollAffordanceChanged?(affordance) }
  }

  var onVisibleMessagesChanged: (([Int64]?) -> Void)?

  private let peer: Peer
  private let chatId: Int64?
  private let spaceId: Int64?
  private let openAnchor: ChatOpenAnchor
  private var theme: IOSThemeSnapshot
  private var snapshot: ChatRowSnapshot?
  private var hasOpened = false
  private var cancellables = Set<AnyCancellable>()
  private let log = Log.scoped("TimelineMessagesView")

  // Planning
  private let textLayoutCache = TextLayoutCache()
  private var plans: [ChatRowID: Plan] = [:]
  private var legacyHeights: [ChatRowID: (revision: UInt64, width: CGFloat, height: CGFloat)] = [:]
  /// Every row's height at the width it was measured at. The list asks for the height of each placed
  /// row on every frame of a fling, so this answers before the row itself is looked at. A row leaves
  /// it when its content changes (the row diff), when it is planned again, and on an environment change.
  private var heights: [ChatRowID: (width: CGFloat, height: CGFloat)] = [:]
  private var environmentRevision: UInt64 = 0
  private var rowPool: [TimelineRowView] = []

  // Send flight
  weak var sendAnimationCoordinator: SendMessageAnimationCoordinator?
  /// Rows of sent messages whose bubble is still flying in from the composer.
  private var flightTargets: Set<ChatRowID> = []

  // Floating date
  private let datePill = TimelineDatePill(floating: true)
  /// Where each day starts in the rows, oldest first.
  private var dayRows: [(index: Int, day: Date)] = []
  private var datePillDay: Date?
  private var datePillHide: DispatchWorkItem?

  // Message menu
  private let menuActions: MessageMenuActions
  private var menu: TimelineMessageMenu!

  // Insets
  private var composeBottomInset: CGFloat = 0
  /// A send shrinks the composer before its row arrives. The shrink waits for the row, so the list
  /// moves once, not down and back up.
  private var heldComposeInset: CGFloat?
  private var holdsComposeInsetForSend = false
  private var composeInsetHoldTask: Task<Void, Never>?
  private var pinnedHeaderHeight: CGFloat = 0
  private var lastNavigationInset: CGFloat = 0
  private static let bottomPadding: CGFloat = 12

  // History, jumps, read state
  private var loadingEdges: Set<TimelineEdge> = []
  private var historyTasks: [TimelineEdge: Task<Void, Never>] = [:]
  private var jumpTask: Task<Void, Never>?
  private var returnToLatestTask: Task<Void, Never>?
  private var pendingFocusMessageId: Int64?
  private var lastReadCandidate: Int64 = 0
  private var readFrontier: Int64 = 0
  private var unreadState: ChatActivityNavigator.State = .empty
  private var affordance = MessagesCollectionView.ScrollAffordanceState()
  private var lastReadPass: CFTimeInterval = 0

  private struct Plan {
    var revision: UInt64
    var environment: UInt64
    var width: CGFloat
    var streamLength: Int?
    var content: MessageViewContent
    var layout: MessageLayout
  }

  #if DEBUG
  /// The harness's signed-out stand-in for the current user.
  static var debugCurrentUserId: Int64?
  private var probe: TimelineProbe?
  #endif

  /// Rows changing in place move like `MessageMotion.standard` (a critically damped 0.27 s spring).
  private static let rowTiming = TimelineTiming.spring(mass: 1, stiffness: 541.5, damping: 46.54, duration: 0.4)

  init(
    peer: Peer, chatId: Int64?, spaceId: Int64?, initialState: MessagesProgressiveViewModel.InitialState?,
    collapsedMaxId: Int64?, theme: IOSThemeSnapshot
  ) {
    self.peer = peer
    self.chatId = chatId
    self.spaceId = spaceId
    self.theme = theme
    openAnchor = initialState?.openAnchor ?? .latest
    var currentUserId = Auth.shared.getCurrentUserId()
    #if DEBUG
    currentUserId = Self.debugCurrentUserId ?? currentUserId
    #endif
    viewModel = MessagesProgressiveViewModel(
      peer: peer, chatId: chatId, initialState: initialState, collapsedMaxId: collapsedMaxId,
      currentUserId: currentUserId
    )
    list = TimelineListView(rows: TimelineRows(height: { _, _ in 0 }, make: { _, _ in UIView() }))
    menuActions = MessageMenuActions(peerId: peer, spaceId: spaceId, theme: theme)
    super.init(frame: .zero)
    setUpMenu()
    backgroundColor = .clear
    list.rows = TimelineRows(
      height: { [unowned self] id, width in height(of: id, width: width) },
      make: { [unowned self] id, width in makeRow(id, width: width) },
      update: { [unowned self] id, view, width, timing in
        (view as? TimelineRowView).map { configure($0, id: id, width: width, timing: timing) }
      },
      recycle: { [unowned self] _, view in
        guard let row = view as? TimelineRowView, rowPool.count < 24 else { return }
        row.prepareForReuse()
        rowPool.append(row)
      }
    )
    list.onDemand = { [weak self] edges in edges.forEach { self?.loadHistory($0) } }
    list.onLayout = { [weak self] _ in self?.layoutChanged() }
    list.onScrollEnded = { [weak self] in self?.scrollEnded() }
    addSubview(list)
    datePill.alpha = 0
    datePill.onTap = { [weak self] in self?.jumpToDatePillDay() }
    addSubview(datePill)

    viewModel.rowFeed.isPublishing = true
    viewModel.rowFeed.updates.sink { [weak self] update in self?.apply(update) }.store(in: &cancellables)
    NotificationCenter.default.addObserver(
      self, selector: #selector(scrollToRepliedMessage(_:)), name: Notification.Name("ScrollToRepliedMessage"),
      object: nil
    )
    NotificationCenter.default.addObserver(
      self, selector: #selector(applicationDidBecomeActive), name: UIApplication.didBecomeActiveNotification,
      object: nil
    )
    viewModel.ensureThreadAnchorCached()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  private func setUpMenu() {
    menu = TimelineMessageMenu(list: list, actions: menuActions) { [weak self] id in self?.row(id) }
    menu.onWillDisplay = { [weak self] in self?.onContextMenuWillDisplay?() }
    menu.onDidEnd = { [weak self] in self?.onContextMenuDidEnd?() }
    menuActions.presenter = { [weak self] in self?.findViewController() }
    menuActions.containerWidth = { [weak self] in
      self?.window?.bounds.width ?? self?.bounds.width ?? UIScreen.main.bounds.width
    }
    menuActions.currentMessage = { [weak self] stableId, messageId, chatId, randomId in
      self?.snapshot?.rows.lazy.compactMap(\.content.message).first { message in
        message.id == stableId
          || (message.message.messageId == messageId && message.message.chatId == chatId)
          || (randomId != nil && message.message.randomId == randomId && message.message.chatId == chatId)
      }
    }
    menuActions.react = { [weak self] _, toggle in
      guard let self else { return toggle() }
      menu.react(toggle)
    }
    // Over the open menu's own window, so the sheet shows above it.
    menuActions.emojiSheetOverWindow = { [weak self] in self?.menu.controller?.moveToOwnWindow() }
    menuActions.onEmojiSheetDismissed = { [weak self] in
      guard let self, !menu.isActive else { return }
      onContextMenuDidEnd?()
    }
    menuActions.loadIntegrations()
  }

  isolated deinit {
    for task in historyTasks.values { task.cancel() }
    jumpTask?.cancel()
    returnToLatestTask?.cancel()
    viewModel.dispose()
  }

  // MARK: - Layout and insets

  override func layoutSubviews() {
    super.layoutSubviews()
    list.frame = bounds
    applyInsets(.none)
    openIfNeeded()
    updateDatePill()
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window == nil {
      for task in historyTasks.values { task.cancel() }
      jumpTask?.cancel()
      returnToLatestTask?.cancel()
      // The menu's overlay belongs to the window and would outlive the chat.
      menu.dismissImmediately()
      saveReadingPlace()
      onVisibleMessagesChanged?(nil)
      #if DEBUG
      probe?.stop()
      probe = nil
      #endif
    } else {
      setNeedsLayout()
      #if DEBUG
      if TimelineProbe.isRequested, probe == nil { probe = TimelineProbe(list: list, host: self) }
      #endif
    }
  }

  override func traitCollectionDidChange(_ previous: UITraitCollection?) {
    super.traitCollectionDidChange(previous)
    guard previous?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory
      || previous?.displayScale != traitCollection.displayScale
      || previous?.layoutDirection != traitCollection.layoutDirection else { return }
    environmentChanged()
  }

  /// The top inset is the navigation bar and the pinned header; the bottom one is the compose area.
  private func applyInsets(_ timing: TimelineTiming) {
    guard let window else { return }
    let barHeight = findViewController()?.navigationController?.navigationBar.frame.height ?? 0
    if barHeight > 0 { lastNavigationInset = window.safeAreaInsets.top + barHeight }
    let navigationInset = lastNavigationInset > 0 ? lastNavigationInset : window.safeAreaInsets.top
    // The chat header sizes its blur from this, as it does for the collection view.
    NotificationCenter.default.post(
      name: Notification.Name("NavigationBarHeight"), object: nil, userInfo: ["navBarHeight": navigationInset]
    )
    list.setInsets(
      top: max(0, navigationInset + pinnedHeaderHeight - 10),
      bottom: composeBottomInset + Self.bottomPadding,
      timing: timing
    )
  }

  func composeAreaDidChange(bottomInset: CGFloat, timing: TimelineTiming, isInteractive _: Bool) {
    // The composer shrinks right after a send (the text, a reply or edit bar going away) while the
    // sent row is still on its way.
    if !holdsComposeInsetForSend, bottomInset < composeBottomInset,
       sendAnimationCoordinator?.hasPreparedSource == true
    {
      deferComposeInsetForPendingSendAnimation(composeHeight: 0)
    }
    if holdsComposeInsetForSend, bottomInset < composeBottomInset {
      heldComposeInset = bottomInset
      return
    }
    heldComposeInset = nil
    guard abs(bottomInset - composeBottomInset) > 0.01 else { return }
    composeBottomInset = bottomInset
    applyInsets(timing)
  }

  /// The composer is about to shrink for a send whose row is on its way.
  func deferComposeInsetForPendingSendAnimation(composeHeight _: CGFloat) {
    holdsComposeInsetForSend = true
    composeInsetHoldTask?.cancel()
    composeInsetHoldTask = Task { @MainActor [weak self] in
      // The row normally arrives within a frame or two; without it the shrink still lands.
      try? await Task.sleep(for: .milliseconds(450))
      guard !Task.isCancelled else { return }
      self?.releaseComposeInsetHold(applying: true)
    }
  }

  /// Ends a send's hold. The held inset is applied now, or returned for the caller's transaction.
  @discardableResult
  private func releaseComposeInsetHold(applying: Bool) -> CGFloat? {
    guard holdsComposeInsetForSend else { return nil }
    holdsComposeInsetForSend = false
    composeInsetHoldTask?.cancel()
    composeInsetHoldTask = nil
    guard let held = heldComposeInset else { return nil }
    heldComposeInset = nil
    composeBottomInset = held
    if applying { applyInsets(Self.rowTiming) }
    return held
  }

  func updatePinnedHeaderHeight(_ height: CGFloat) {
    guard height != pinnedHeaderHeight else { return }
    pinnedHeaderHeight = height
    applyInsets(UIView.inheritedAnimationDuration > 0 ? Self.rowTiming : .none)
  }

  // The container reports the whole compose area; these older, partial reports are not needed.
  func setInitialComposeHeight(_: CGFloat) {}
  func updateComposeInset(composeHeight _: CGFloat, animation _: ComposeHeightChangeAnimation) {}
  func setComposeBottomOffset(_: CGFloat) {}

  // MARK: - Rows

  private func row(_ id: ChatRowID) -> ChatRow? { snapshot?.row(for: id) }

  private func height(of id: ChatRowID, width: CGFloat) -> CGFloat {
    if let cached = heights[id], abs(cached.width - width) < 0.5 { return cached.height }
    let height = measure(id, width: width)
    heights[id] = (width, height)
    return height
  }

  private func measure(_ id: ChatRowID, width: CGFloat) -> CGFloat {
    guard let row = row(id) else { return 0 }
    switch row.content {
      case let .message(message, grouping):
        return messageHeight(row, message, grouping, isThreadAnchor: false, width: width)
      case let .threadParent(message):
        return messageHeight(row, message, ChatRowGrouping(), isThreadAnchor: true, width: width)
      case .daySeparator: return 44
      case .unreadLine: return 34
      case .statusNotice: return 30
      case .collapsedHistory: return 44
      case .threadRepliesHeader: return 34
    }
  }

  private func messageHeight(
    _ row: ChatRow, _ message: FullMessage, _ grouping: ChatRowGrouping, isThreadAnchor: Bool, width: CGFloat
  ) -> CGFloat {
    if let plan = plan(row, message, grouping, isThreadAnchor: isThreadAnchor, width: width) {
      return plan.layout.size.height
    }
    if let cached = legacyHeights[row.id], cached.revision == row.revision, abs(cached.width - width) < 0.5 {
      return cached.height
    }
    let view = TimelineRowView()
    view.showLegacy(
      message, grouping: grouping, isThreadAnchor: isThreadAnchor, width: width, theme: theme, spaceId: spaceId
    )
    let height = view.legacyHeight(width: width)
    legacyHeights[row.id] = (row.revision, width, height)
    return height
  }

  /// The plan for a message the next message view supports; nil for the kinds it does not.
  private func plan(
    _ row: ChatRow, _ message: FullMessage, _ grouping: ChatRowGrouping, isThreadAnchor: Bool, width: CGFloat
  ) -> Plan? {
    let pacer = MessageStreamPacer.shared
    let streamLength = pacer.revealedLength(for: message.id)
    // A cached plan means the kind is supported; checking that walks the message, so it comes after.
    if let plan = plans[row.id], plan.revision == row.revision, plan.environment == environmentRevision,
       abs(plan.width - width) < 0.5, plan.streamLength == streamLength
    {
      return plan
    }
    guard width > 0, MessageViewContent.supports(message, displayMode: isThreadAnchor ? .threadAnchor : .normal)
    else { return nil }
    let avatar: MessageLayoutInput.Avatar = grouping.showsAvatar
      ? (grouping.isLastInGroup || isThreadAnchor ? .visible : .reserved)
      : .none
    var context = MessageRowContext(
      rowWidth: width,
      isFirstInGroup: grouping.isFirstInGroup,
      isLastInGroup: grouping.isLastInGroup,
      showsName: grouping.showsSenderName,
      avatar: avatar,
      theme: theme,
      traits: traitCollection
    )
    context.isThreadAnchor = isThreadAnchor
    guard let content = MessageViewContent.make(
      message, context: context, footer: pacer.isStreaming(message.id) ? .reserved : .visible,
      revealedLength: streamLength
    ) else { return nil }
    let plan = Plan(
      revision: row.revision, environment: environmentRevision, width: width, streamLength: streamLength,
      content: content, layout: MessageLayoutPlanner.layout(content.input, cache: textLayoutCache)
    )
    plans[row.id] = plan
    return plan
  }

  private func makeRow(_ id: ChatRowID, width: CGFloat) -> UIView {
    let view = rowPool.popLast() ?? TimelineRowView()
    configure(view, id: id, width: width, timing: .none)
    return view
  }

  private func configure(_ view: TimelineRowView, id: ChatRowID, width: CGFloat, timing: TimelineTiming) {
    guard let row = row(id) else { return }
    defer {
      view.isMenuSourceHidden = menu.isSource(id)
      view.isSendTargetHidden = flightTargets.contains(id)
      // A swipe replies to a message that can take a reply; never to the thread's parent.
      if case let .message(message, _) = row.content, message.canReply {
        view.replyMessage = message
      } else {
        view.replyMessage = nil
      }
    }
    switch row.content {
      case let .message(message, grouping):
        configureMessage(view, row, message, grouping, isThreadAnchor: false, width: width, timing: timing)
      case let .threadParent(message):
        configureMessage(view, row, message, ChatRowGrouping(), isThreadAnchor: true, width: width, timing: timing)
      case let .daySeparator(dayStart):
        view.showLabel(Self.dayTitle(dayStart), style: .pill, theme: theme)
      case .unreadLine:
        view.showLabel("Unread messages", style: .line, theme: theme)
      case let .statusNotice(text):
        view.showLabel(text, style: .plain, theme: theme)
      case .collapsedHistory:
        view.showLabel("Earlier messages are hidden", style: .plain, theme: theme)
      case .threadRepliesHeader:
        view.showLabel("Replies", style: .plain, theme: theme)
    }
  }

  private func configureMessage(
    _ view: TimelineRowView, _ row: ChatRow, _ message: FullMessage, _ grouping: ChatRowGrouping,
    isThreadAnchor: Bool, width: CGFloat, timing: TimelineTiming
  ) {
    guard let plan = plan(row, message, grouping, isThreadAnchor: isThreadAnchor, width: width) else {
      view.showLegacy(
        message, grouping: grouping, isThreadAnchor: isThreadAnchor, width: width, theme: theme, spaceId: spaceId
      )
      return
    }
    let messageView = view.showMessage()
    messageView.spaceId = spaceId
    let id = row.id
    messageView.onAvatarTap = { [weak self] in
      guard let from = self?.row(id)?.content.message?.from else { return }
      NotificationCenter.default.post(
        name: Notification.Name("NavigateToUser"), object: nil, userInfo: ["userId": from.id]
      )
    }
    messageView.onPhotoTap = { [weak self] message, _, image, url in self?.presentPhoto(message, image: image, url: url) }
    messageView.onReactionsMenu = { [weak self] message in self?.menuActions.showReactionEmojiPicker(for: message) }
    // A disclosure opened or closed, or a streamed line was revealed: the row is planned again
    // and the list moves with it.
    messageView.onContentStateChange = { [weak self] _ in self?.replan(id, timing: Self.rowTiming) }
    messageView.onRevealLineChange = { [weak self] _ in self?.replan(id, timing: .streamingLine) }
    messageView.apply(plan.content, layout: plan.layout, motion: Self.motion(for: timing))
  }

  private func replan(_ id: ChatRowID, timing: TimelineTiming) {
    plans[id] = nil
    heights[id] = nil
    list.apply(TimelineTransaction(changed: [id], timing: timing))
  }

  private static func motion(for timing: TimelineTiming) -> MessageMotion {
    switch timing {
      case .none: .immediate
      case let .curve(duration, _, _, _, _): .easeInOut(duration: Double(duration))
      case .spring: .standard
    }
  }

  private static func dayTitle(_ day: Date) -> String {
    let calendar = Calendar.autoupdatingCurrent
    if calendar.isDateInToday(day) { return "Today" }
    if calendar.isDateInYesterday(day) { return "Yesterday" }
    let sameYear = calendar.isDate(day, equalTo: Date(), toGranularity: .year)
    return day.formatted(sameYear ? .dateTime.month(.wide).day() : .dateTime.month(.wide).day().year())
  }

  /// Theme, text size or direction changed: every row is planned again where it stands.
  private func environmentChanged() {
    environmentRevision &+= 1
    plans.removeAll()
    legacyHeights.removeAll()
    heights.removeAll()
    guard let snapshot else { return }
    list.apply(TimelineTransaction(changed: Set(snapshot.ids)))
  }

  func applyTheme(_ theme: IOSThemeSnapshot) {
    guard theme != self.theme else { return }
    self.theme = theme
    menuActions.theme = theme
    environmentChanged()
  }

  // MARK: - Updates

  /// The first frame: the rows at the place the chat opens at.
  private func openIfNeeded() {
    guard !hasOpened, bounds.width > 0, bounds.height > 0, window != nil,
          let snapshot = viewModel.rowFeed.snapshot else { return }
    hasOpened = true
    self.snapshot = snapshot
    rebuildDayRows()
    var scroll = TimelineScroll<ChatRowID>.latest
    switch openAnchor {
      case .latest:
        break
      case .unread:
        // Below where the date pill sits, as the collection view places it.
        if snapshot.index(of: .unreadLine) != nil { scroll = .to(.unreadLine, .top(DateSeparatorView.height)) }
      case let .saved(place):
        if let row = snapshot.rows.first(where: { $0.content.message?.message.messageId == place.messageId }) {
          scroll = .to(row.id, .top(place.offset))
        }
    }
    list.apply(TimelineTransaction(rows: snapshot.ids, coverage: coverage(snapshot), scroll: scroll))
    readPass(force: true)
  }

  private func coverage(_ snapshot: ChatRowSnapshot) -> TimelineCoverage {
    TimelineCoverage(reachesOldest: snapshot.coverage.reachesOldest, reachesNewest: snapshot.coverage.reachesNewest)
  }

  private func apply(_ update: ChatRowUpdate) {
    guard hasOpened else { return }
    let snapshot = update.snapshot
    self.snapshot = snapshot
    rebuildDayRows()
    let diff = update.diff
    for change in diff.removals {
      plans[change.id] = nil
      legacyHeights[change.id] = nil
      heights[change.id] = nil
    }
    let changed = Set(diff.updates.map(\.id))
    for id in changed { heights[id] = nil }

    var timing = TimelineTiming.none
    var scroll = TimelineScroll<ChatRowID>.preserve
    switch snapshot.reason {
      case .liveAdd, .liveUpdate, .delete, .sendAck:
        timing = Self.rowTiming
      case .localSend:
        timing = Self.rowTiming
        scroll = .latest
        ChatReadingPlaceStore.shared.clear(for: peer)
      case let .jump(target):
        scroll = jumpScroll(for: target, in: snapshot)
      case .initialOpen, .olderPage, .newerPage, .refresh, .presentation:
        break
    }
    // The sent row and the composer's shrink move as one.
    let releasedInset = snapshot.reason == .localSend ? releaseComposeInsetHold(applying: false) : nil
    list.apply(TimelineTransaction(
      rows: snapshot.ids, coverage: coverage(snapshot), scroll: scroll,
      bottomInset: releasedInset.map { $0 + Self.bottomPadding }, changed: changed, timing: timing
    ))
    if !diff.insertions.isEmpty { beginSendFlights(diff.insertions.map(\.id)) }
    if case .jump = snapshot.reason { highlightPendingFocus() }
    viewModel.ensureThreadAnchorCached()
    readPass(force: true)
  }

  private func jumpScroll(for target: ChatRowJumpTarget, in snapshot: ChatRowSnapshot) -> TimelineScroll<ChatRowID> {
    if let messageId = pendingFocusMessageId,
       let row = snapshot.rows.first(where: { $0.content.message?.message.messageId == messageId })
    {
      return .to(row.id, .center)
    }
    switch target {
      case .latest:
        return .latest
      case .unreadLine:
        return snapshot.index(of: .unreadLine) != nil ? .to(.unreadLine, .top(DateSeparatorView.height)) : .latest
      case let .message(messageId):
        guard let row = snapshot.rows.first(where: { $0.content.message?.message.messageId == messageId })
        else { return .latest }
        return .to(row.id, .center)
    }
  }

  // MARK: - History

  private func loadHistory(_ edge: TimelineEdge) {
    guard !loadingEdges.contains(edge), window != nil else { return }
    loadingEdges.insert(edge)
    historyTasks[edge] = Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        loadingEdges.remove(edge)
        historyTasks[edge] = nil
      }
      let direction: MessagesProgressiveViewModel.MessagesLoadDirection = edge == .older ? .older : .newer
      let local = edge == .older ? viewModel.canLoadOlderFromLocal : viewModel.canLoadNewerFromLocal
      if !local {
        guard let boundary = edge == .older ? viewModel.oldestLoadedMessageId : viewModel.newestLoadedMessageId
        else { return }
        do {
          let outcome = edge == .older
            ? try await MessageHistoryRepairCoordinator.shared.loadOlder(peer: peer, beforeID: boundary)
            : try await MessageHistoryRepairCoordinator.shared.loadNewer(peer: peer, afterID: boundary)
          if outcome == .empty { return }
        } catch {
          return
        }
      }
      _ = await viewModel.loadBatchAsync(at: direction, allowUnavailableLocal: !local)
    }
  }

  // MARK: - Scrolling to places

  private var distanceFromBottom: CGFloat { list.layout.distanceToNewest ?? .greatestFiniteMagnitude }

  /// The composer prepares a flight only when the new message will land on screen: the list is at
  /// the live end, within a screen of the newest message.
  var acceptsSendAnimation: Bool {
    hasOpened && viewModel.historyCoverage.isAtCertifiedLiveEnd && distanceFromBottom < bounds.height
  }

  /// A new row the composer prepared a flight for: its bubble lands where the row settles, and the
  /// row shows once it has.
  private func beginSendFlights(_ inserted: [ChatRowID]) {
    guard let coordinator = sendAnimationCoordinator, let window else { return }
    for id in inserted {
      guard case let .message(message, _)? = row(id)?.content,
            let identity = coordinator.pendingIdentity(for: message),
            !coordinator.isAnimating(identity: identity)
      else { continue }
      guard let rowView = list.view(for: id) as? TimelineRowView, let messageView = rowView.shownMessageView,
            let frames = messageView.sendAnimationTargetFrames(),
            let snapshot = messageView.sendAnimationBubbleSnapshot()
      else {
        coordinator.cancel(identity: identity)
        continue
      }
      // The row and the list are at their settled places in the model; the motion is additive tracks.
      let bubbleFrame = messageView.convert(frames.bubble, to: window)
      let textFrame = messageView.convert(frames.text, to: window)
      let baseline = messageView.convert(CGPoint(x: 0, y: frames.firstBaseline), to: window).y
      guard bubbleFrame.isFiniteAndVisible, textFrame.isFiniteAndVisible, baseline.isFinite else {
        coordinator.cancel(identity: identity)
        continue
      }
      let target = SendMessageAnimationTarget(
        identity: identity,
        messageStableId: message.id,
        bubbleFrameInWindow: bubbleFrame,
        textFrameInWindow: textFrame,
        bubbleSnapshotView: snapshot,
        textFrameInBubble: frames.text.offsetBy(dx: -frames.bubble.minX, dy: -frames.bubble.minY),
        textFirstBaselineYInWindow: baseline,
        textFirstBaselineYInBubble: frames.firstBaseline - frames.bubble.minY,
        bubbleTailSide: message.message.out == true ? .trailing : .leading
      )
      flightTargets.insert(id)
      rowView.isSendTargetHidden = true
      let began = SendMessageAnimationActions.performWithAnimationsEnabled(reason: "timeline-begin-flight") {
        coordinator.beginIfPossible(target: target) { [weak self] _ in self?.endFlight(id) }
      }
      if !began {
        endFlight(id)
        coordinator.cancel(identity: identity)
      }
    }
  }

  private func endFlight(_ id: ChatRowID) {
    flightTargets.remove(id)
    (list.view(for: id) as? TimelineRowView)?.isSendTargetHidden = false
  }

  func scrollToBottom() {
    ChatReadingPlaceStore.shared.clear(for: peer)
    jumpTask?.cancel()
    pendingFocusMessageId = nil
    if viewModel.historyCoverage.isAtCertifiedLiveEnd {
      // Near enough to travel there; a far jump lands at once until the carousel exists.
      let near = distanceFromBottom < bounds.height * 3
      list.apply(TimelineTransaction(scroll: .latest, timing: near ? Self.rowTiming : .none))
      return
    }
    guard returnToLatestTask == nil else { return }
    let account = try? Auth.shared.handle.beginAccountMutation()
    returnToLatestTask = Task { @MainActor [weak self] in
      defer { self?.returnToLatestTask = nil }
      guard let self else { return }
      do {
        _ = try await viewModel.loadLatestWindowAsync()
        var transaction = GetChatHistoryTransaction(peer: peer, mode: .historyModeLatest)
        transaction.type = .ephemeral()
        _ = try await Api.realtime.send(transaction, expectedAccount: account)
        _ = try await viewModel.loadLatestWindowAsync()
      } catch is CancellationError {
        return
      } catch {
        ToastManager.shared.showToast("Could not load latest history", type: .error)
      }
    }
  }

  func cancelPendingMessageFocus() {
    jumpTask?.cancel()
    pendingFocusMessageId = nil
  }

  func scrollToMessageWhenAvailable(_ messageID: Int64, requiresExactMessage _: Bool) {
    jumpTask?.cancel()
    returnToLatestTask?.cancel()
    pendingFocusMessageId = messageID
    if let row = snapshot?.rows.first(where: { $0.content.message?.message.messageId == messageID }) {
      let near = list.layout.placement(for: row.id) != nil
      list.apply(TimelineTransaction(scroll: .to(row.id, .center), timing: near ? Self.rowTiming : .none))
      highlightPendingFocus()
      return
    }
    jumpTask = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        if !viewModel.historyCoverage.isCertifiedMessage(messageID) {
          _ = try await MessageHistoryRepairCoordinator.shared.loadAround(
            peer: peer, anchorID: messageID, limit: MessagesProgressiveViewModel.defaultInitialLimit()
          )
        }
        guard !Task.isCancelled else { return }
        if !viewModel.loadLocalWindowAroundMessage(messageId: messageID) {
          pendingFocusMessageId = nil
          ToastManager.shared.showToast("Message unavailable", type: .info)
        }
      } catch is CancellationError {
        return
      } catch {
        pendingFocusMessageId = nil
        ToastManager.shared.showToast("Could not load that message", type: .error)
      }
    }
  }

  private func highlightPendingFocus() {
    guard let messageId = pendingFocusMessageId,
          let row = snapshot?.rows.first(where: { $0.content.message?.message.messageId == messageId }),
          let view = list.view(for: row.id) as? TimelineRowView else { return }
    pendingFocusMessageId = nil
    view.flash(theme: theme)
  }

  @objc private func scrollToRepliedMessage(_ note: Notification) {
    guard let messageId = note.userInfo?["repliedToMessageId"] as? Int64,
          let noteChatId = note.userInfo?["chatId"] as? Int64, noteChatId == chatId, window != nil else { return }
    scrollToMessageWhenAvailable(messageId, requiresExactMessage: false)
  }

  // MARK: - Read state, reading place, scroll button

  func setUnreadState(_ state: ChatActivityNavigator.State) {
    unreadState = state
    updateAffordance(force: true)
  }

  private func layoutChanged() {
    updateAffordance(force: false)
    updateDatePill()
    // While the list moves, read marking runs a few times a second at most.
    readPass(force: false)
  }

  private func scrollEnded() {
    scheduleDatePillHide()
    saveReadingPlace()
    readPass(force: true)
  }

  @objc private func applicationDidBecomeActive() {
    readPass(force: true)
  }

  private func visibleMessages() -> [FullMessage] {
    guard let snapshot else { return [] }
    return list.layout.visible.compactMap { snapshot.row(for: $0.id)?.content.message }
      .filter { $0.message.messageId > 0 }
  }

  /// Marks what the reader has seen. Only for a list that is on screen in an active app.
  private func readPass(force: Bool) {
    let now = CACurrentMediaTime()
    guard force || now - lastReadPass > 0.3 else { return }
    lastReadPass = now
    guard hasOpened, window != nil, UIApplication.shared.applicationState == .active, !list.isTracking,
          let chatId
    else {
      if window == nil || UIApplication.shared.applicationState != .active { onVisibleMessagesChanged?(nil) }
      return
    }
    let visible = visibleMessages()
    if distanceFromBottom <= 12, viewModel.historyCoverage.isAtCertifiedLiveEnd {
      UnreadManager.shared.readAll(peer, chatId: chatId)
    } else if let candidate = visible.filter({ $0.message.out != true && !$0.message.isServiceMessage })
      .map(\.message.messageId).max(), candidate > lastReadCandidate
    {
      lastReadCandidate = candidate
      UnreadManager.shared.readVisible(peerId: peer, chatId: chatId, highestVisibleIncomingID: candidate)
      if candidate > readFrontier {
        readFrontier = candidate
        updateAffordance(force: true)
      }
    }
    onVisibleMessagesChanged?(visible.map(\.message.messageId))
  }

  /// Saves where the reader is when the newest message is off screen, and clears it otherwise.
  private func saveReadingPlace() {
    guard hasOpened, let snapshot else { return }
    if !viewModel.canLoadNewerFromLocal, distanceFromBottom <= 12 {
      ChatReadingPlaceStore.shared.clear(for: peer)
      return
    }
    let top = list.layout.viewport.usableTop
    for placement in list.layout.visible {
      guard let messageId = snapshot.row(for: placement.id)?.content.message?.message.messageId, messageId > 0,
            placement.y >= top - 0.5 || placement.id == list.layout.visible.last?.id else { continue }
      ChatReadingPlaceStore.shared.save(ChatReadingPlace(messageId: messageId, offset: placement.y - top), for: peer)
      return
    }
  }

  /// The scroll button shows beyond 44 pt from the bottom and hides again within 12 pt.
  private func updateAffordance(force: Bool) {
    let distance = distanceFromBottom
    let visible = affordance.isVisible ? distance > 12 : distance > 44
    var count = affordance.unreadCount
    if force {
      count = ChatUnreadBadgeCount.resolve(
        unreadCount: unreadState.unreadCount, readInboxMaxId: unreadState.readInboxMaxId,
        readFrontier: readFrontier, coverage: viewModel.historyCoverage, loadedMessages: viewModel.messages
      )
    }
    let next = MessagesCollectionView.ScrollAffordanceState(isVisible: visible, unreadCount: count)
    guard next != affordance else { return }
    affordance = next
    onScrollAffordanceChanged?(next)
  }

  // MARK: - Floating date

  private func rebuildDayRows() {
    dayRows = snapshot?.rows.enumerated().compactMap { index, row in
      if case let .daySeparator(day) = row.content { (index, day) } else { nil }
    } ?? []
  }

  /// The day of the topmost row floats at the top edge while the reader scrolls. The next day's row
  /// pushes it up; when the day's own row is on screen, that row shows the date instead.
  private func updateDatePill() {
    let layout = list.layout
    let top = layout.viewport.usableTop
    datePill.frame = CGRect(x: 0, y: datePill.frame.minY, width: bounds.width, height: TimelineDatePill.height)
    guard hasOpened, !dayRows.isEmpty,
          let topRow = layout.placements.first(where: { $0.maxY > top + 1 }),
          let current = dayRows.last(where: { $0.index <= topRow.index })
    else {
      datePill.setVisible(false, animated: false)
      return
    }
    if let own = layout.placements.first(where: { $0.index == current.index }), own.y >= top - 0.5 {
      datePill.setVisible(false, animated: false)
      return
    }
    var y = top
    if let next = dayRows.first(where: { $0.index > topRow.index }),
       let row = layout.placements.first(where: { $0.index == next.index })
    {
      y = min(top, row.y - TimelineDatePill.height)
    }
    datePill.frame.origin.y = y
    datePillDay = current.day
    datePill.configure(title: Self.dayTitle(current.day))
    if list.isTracking || list.isDecelerating {
      datePillHide?.cancel()
      datePill.setVisible(true, animated: datePill.alpha == 0)
    }
  }

  private func scheduleDatePillHide() {
    datePillHide?.cancel()
    let hide = DispatchWorkItem { [weak self] in self?.datePill.setVisible(false, animated: true) }
    datePillHide = hide
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: hide)
  }

  /// The day's first message at the top, as the collection view's badge does.
  private func jumpToDatePillDay() {
    guard let day = datePillDay else { return }
    let id = ChatRowID.daySeparator(day)
    let near = list.layout.placement(for: id) != nil
    list.apply(TimelineTransaction(scroll: .to(id, .top(0)), timing: near ? Self.rowTiming : .none))
    scheduleDatePillHide()
  }

  // MARK: - The rest of the container's contract

  var highestPositiveMessageId: Int64? {
    viewModel.messages.map(\.message.messageId).filter { $0 > 0 }.max()
  }

  var isContextMenuInteractionActive: Bool { menu.isActive }
  var isReactionPickerPresented: Bool { menuActions.isReactionPickerPresented }
  func cancelContextMenuKeyboardRestoration() {}
  func preserveContextMenuViewportForKeyboardRestoration() {}

  func setCollapsedMaxId(_ collapsedMaxId: Int64?) {
    viewModel.rowFeed.setCollapsedMaxId(collapsedMaxId)
  }

  func collapseHistory(maxID: Int64?) async throws {
    let effectiveMaxID = try await Api.realtime.collapseHistory(peer: peer.toInputPeer(), maxID: maxID)
    setCollapsedMaxId(effectiveMaxID)
  }

  private func presentPhoto(_ message: FullMessage, image: UIImage?, url: URL) {
    guard let viewController = findViewController(), viewController.presentedViewController == nil,
          let chatId else { return }
    let anchor = MediaGalleryItem(message: message.message, photo: message.photoInfo, video: message.videoInfo)
      ?? MediaGalleryItem.photo(url: url, id: message.message.messageId)
    var actions = MediaGalleryViewController.Actions()
    actions.showInChat = { [weak self] item in self?.scrollToMessageWhenAvailable(item.id) }
    let viewer = MediaGalleryViewController(
      source: ChatMediaGallerySource(chatId: chatId, peer: peer, anchor: anchor),
      initialItemID: anchor.id, sourceImage: image, actions: actions,
      sourceViewProvider: { [weak self] item in
        item.messageStableId.flatMap { self?.list.view(for: .message($0)) }
      }
    )
    viewController.present(viewer, animated: false)
  }

  private func findViewController() -> UIViewController? {
    var responder: UIResponder? = self
    while let next = responder?.next {
      if let controller = next as? UIViewController { return controller }
      responder = next
    }
    return nil
  }
}
