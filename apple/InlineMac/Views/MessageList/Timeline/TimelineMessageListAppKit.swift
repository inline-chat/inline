import AppKit
import Auth
import Combine
import InlineKit
import InlineMacUI
import InlineMessageLayout
import InlineUI
import Logger
import Observation
import TextProcessing
import TimelineAppKit
import TimelineCore
import Translation

/// The new macOS message list (Settings > Experimental > New Message List).
///
/// Rows come from the same Mac row model as the table list (`ChatRowListViewModel`) and draw with the same
/// production cells (`MessageTableCell`, the separator cells), measured by `MessageSizeCalculator`. What is new is
/// underneath: `TimelineListView` from TimelineAppKit places only the rows around the reading row, has no content
/// height to estimate, keeps the reading row through every change, and moves rows, insets and scroll in one
/// transaction. Trackpad flings follow AppKit's own momentum curve on the render server.
///
/// Opens at the newest message, a message asked for, the saved place or the unread line (fetching history around a
/// line the cache cannot show, hidden until it lands); pages history both ways (local, then remote) and trims the far
/// side of a long window; follows the composer; keeps the reading row through history, arrivals, edits, resizes;
/// scrolls to the newest message on send (fetching it when the cache stops short); jumps to a message (fetching
/// history around it when it is not cached) and flashes it once it lands.
///
/// Reads as the table list does: at the live end, everything once per newest message; in history, through the newest
/// incoming message on screen.
///
/// Selects text across messages and whole messages (to forward or delete) as the table list does.
@MainActor
final class TimelineMessageListAppKit: NSViewController, ChatMessageListController {
  typealias RowID = ChatRowListViewModel.Row

  private let log = Log.scoped("TimelineMessageList")
  private let dependencies: AppDependencies
  private let peerId: Peer
  private let chat: Chat
  private let chatRows: ChatRowListViewModel
  private let sizeCalculator = MessageSizeCalculator.shared
  private let renderStyle: MessageRenderStyle
  private let surfaceStyle: ChatViewAppearance.SurfaceStyle
  private let additionalTopContentInset: CGFloat
  private let showUnreadAfter: Int64?
  private var list: TimelineListView<RowID>!
  private let toolbarBackground: ToolbarBackgroundView
  private var toolbarHeight: CGFloat = 0
  private var topOverlayHeight: CGFloat = 0
  private var composeInset: CGFloat = Theme.composeMinHeight
  /// While the composer animates its height: the height it shows now, which the list's inset follows frame by frame
  /// (`composerHeightDidChange`); nil otherwise.
  private var composeInsetShown: CGFloat?
  private var composerFollowEnd: DispatchWorkItem?
  private var maximumContentWidth: CGFloat?
  private var isDisposed = false
  private var hasPlacedInitialRows = false

  // Layout plans (and so heights): exact, cached per row for its width, grouping and content revision. A row's cell is
  // configured with the plan its height came from, and plans are prepared ahead of the list in idle slices
  // (`prefetchPlans`), so a fling binds rows instead of measuring their text (Telegram measures before the list asks).
  private struct HeightKey: Equatable {
    var width: CGFloat
    var props: Int
    var revision: Int
  }

  private var heights: [RowID: (key: HeightKey, plan: MessageSizeCalculator.LayoutPlans)] = [:] {
    didSet { if heights.isEmpty { previousPlans.removeAll(keepingCapacity: true) } }
  }
  /// Messages this long keep their plan while the width changes (`messagePlan`), and re-plan when it settles.
  private static let deferredReplanLength = 20_000
  /// The long messages that kept an older plan through the resize going on.
  private var liveResizePlans: [RowID: CFTimeInterval] = [:]

  /// A resize is going on: the width changed in the last 300 ms (a window's live resize, a split pane's drag). Read
  /// from the width itself: `inLiveResize` was false through a window edge drag here.
  private var isResizing: Bool { CACurrentMediaTime() - lastWidthChange < 0.3 }
  private var lastWidthChange: CFTimeInterval = 0
  private var lastLaidOutWidth: CGFloat = 0
  private var resizeSettle: DispatchWorkItem?

  private func noteWidthChange() {
    let width = view.bounds.width
    guard abs(width - lastLaidOutWidth) > 0.5 else { return }
    let first = lastLaidOutWidth == 0
    lastLaidOutWidth = width
    guard !first else { return }
    lastWidthChange = CACurrentMediaTime()
    resizeSettle?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.replanAfterLiveResize() }
    resizeSettle = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.32, execute: work)
  }

  /// The resize ended: rows that kept an older plan through it are planned at the final width.
  private func replanAfterLiveResize() {
    guard !liveResizePlans.isEmpty, !isDisposed else { return }
    liveResizePlans.removeAll()
    let column = cellWidth(list.bounds.width)
    let stale = Set(list.placedViews.map(\.0).filter { id in heights[id].map { $0.key.width != column } ?? false })
    guard !stale.isEmpty else { return }
    list.apply(TimelineTransaction(changed: stale))
  }

  /// Each row's plan at the width before the last change (`messagePlan`).
  private var previousPlans: [RowID: (key: HeightKey, plan: MessageSizeCalculator.LayoutPlans)] = [:]
  /// Per-row derived values, for the messages and rows as they are: the list asks for heights (and the floating date
  /// for sections) on every frame of a scroll, and building a row's inputs (grouping with its neighbours, its text's
  /// direction) each time cost more than the rows' drawing.
  private var propsCache: [RowID: MessageViewInputProps] = [:]
  private var sectionCache: [RowID: RowID?] = [:]
  private var derivedRevision = (messages: -1, rows: -1)

  private func validateDerivedCaches() {
    let revision = (chatRows.messagesRevision, chatRows.rows.count)
    guard revision != derivedRevision else { return }
    derivedRevision = revision
    propsCache.removeAll(keepingCapacity: true)
    sectionCache.removeAll(keepingCapacity: true)
  }

  private func cachedInputProps(for id: RowID) -> MessageViewInputProps? {
    validateDerivedCaches()
    if let props = propsCache[id] { return props }
    guard let props = inputProps(for: id) else { return nil }
    propsCache[id] = props
    return props
  }
  private var revisions: [Int64: Int] = [:]
  /// Message cells a placed row gave up when its message changed kind, by pool key.
  private var cellPools: [String: [MessageTableCell]] = [:]

  // Paging, as the iOS timeline pages: one load per edge at a time; an edge whose page failed or brought nothing is
  // blocked for this window (a new window, a reload or the reader scrolling again unblocks it).
  private var loadingEdges: Set<TimelineEdge> = []
  private var blockedEdges: Set<TimelineEdge> = []
  private var historyTasks: [TimelineEdge: Task<Void, Never>] = [:]
  private var windowGeneration = 0
  private var lastCoverage: TimelineCoverage?
  /// A page landed while the list moved: the window's far side is trimmed once it rests (`trimWindow`).
  private var pendingTrimEdge: TimelineEdge?
  private var trimTask: Task<Void, Never>?

  // Opening
  private let openAnchor: ChatOpenAnchor
  private let initialTargetMessageId: Int64?
  /// Set while history around an unread line the cache could not show is fetched; the list is hidden until it lands
  /// (`beginUnreadFetchIfNeeded`).
  private var unreadFetchBoundary: Int64?
  private var unreadFetchTask: Task<Void, Never>?
  private var unreadFetchConnection: AnyCancellable?
  private var unreadFetchSpinner: NSProgressIndicator?
  /// The reading place last told to the view model, so reloads stay in that part of history.
  private var reportedPlace: (atBottom: Bool, messageId: Int64?)?

  // selection: text selection across messages and message selection (forward, delete), as the table list's, through
  // the timeline's rows (`TimelineRowGeometry`).
  private var messageSelection = MessageSelectionState()
  /// The checkbox column shows: messages are measured that much narrower.
  private var showsForwardSelection = false
  /// Rows configured while selection mode opens or closes animate their checkboxes and messages.
  private var animatesSelectionMode = false
  private lazy var textSelection = MessageListTextSelection(host: self)
  private lazy var selectionRows: TimelineRowGeometry = {
    let rows = TimelineRowGeometry(
      list: list,
      rows: { [weak self] in self?.chatRows.rows ?? [] },
      index: { [weak self] in self?.selectionRowIndex($0) },
      insets: { [weak self] in (self?.topInset ?? 0, self?.bottomInset ?? 0) }
    )
    rows.onCopy = { [weak self] in self?.textSelection.copySelection() ?? false }
    rows.canCopy = { [weak self] in self?.textSelection.hasSelection ?? false }
    return rows
  }()
  let messageColumnGuide = NSLayoutGuide()
  private var columnWidth: NSLayoutConstraint?

  init(
    dependencies: AppDependencies,
    peerId: Peer,
    chat: Chat,
    showUnreadAfter: Int64? = nil,
    initialState: MessagesProgressiveViewModel.InitialState? = nil,
    initialTargetMessageId: Int64? = nil,
    unreadFetchBoundary: Int64? = nil,
    collapsedMaxId: Int64? = nil,
    initialPinnedMessage: PreparedPinnedMessage? = nil,
    surfaceStyle: ChatViewAppearance.SurfaceStyle = .content,
    additionalTopContentInset: CGFloat = 0
  ) {
    openAnchor = initialState?.openAnchor ?? .latest
    self.initialPinnedMessage = initialPinnedMessage
    // The prepared pin's height is in the first frame's top inset, so the rows don't move when it shows.
    pinnedHeaderHeight = initialPinnedMessage == nil ? 0 : PinnedMessageHeaderView.preferredHeight
    self.initialTargetMessageId = initialTargetMessageId
    // A message asked for wins over the unread line.
    self.unreadFetchBoundary = initialTargetMessageId == nil
      ? unreadFetchBoundary ?? initialState?.uncachedUnreadBoundary : nil
    self.dependencies = dependencies
    self.peerId = peerId
    self.chat = chat
    self.showUnreadAfter = showUnreadAfter
    self.surfaceStyle = surfaceStyle
    self.additionalTopContentInset = additionalTopContentInset
    renderStyle = AppSettings.shared.messageRenderStyle
    chatRows = ChatRowListViewModel(peer: peerId, chatId: chat.id, initialState: initialState, collapsedMaxId: collapsedMaxId)
    toolbarBackground = ToolbarBackgroundView(surfaceStyle: surfaceStyle)
    super.init(nibName: nil, bundle: nil)
    sizeCalculator.prepareForUse()
    NotificationCenter.default.addObserver(
      self, selector: #selector(richBlockLayoutStateDidChange), name: .richBlockLayoutStateDidChange, object: nil
    )
    NotificationCenter.default.addObserver(
      self, selector: #selector(chatTypographyDidChange), name: ChatTypography.didChangeNotification, object: nil
    )
    // The DM peer's silenced-notifications notice, from memory, so the first rows include it.
    if let userId = statusNoticeUserId {
      _ = chatRows.setStatusNotice(ObjectCache.shared.getCachedUser(id: userId)?.notificationsSilencedNotice())
    }
    // The unread line, as the table list builds it: after the last message read when the chat opened.
    chatRows.rebuildFromViewModel(showUnreadAfter: showUnreadAfter)
    observeStatusNotice()
  }

  // MARK: - Pinned message header

  private let initialPinnedMessage: PreparedPinnedMessage?
  private var pinnedHeaderHeight: CGFloat
  private var pinnedHeaderTopConstraint: NSLayoutConstraint?
  private var pinnedHeaderHeightConstraint: NSLayoutConstraint?

  /// The header hides while a bar floats under the toolbar (in-chat search), as in Telegram: its glass under the
  /// search panel's glass would flatten both.
  private var visiblePinnedHeaderHeight: CGFloat { topOverlayHeight > 0 ? 0 : pinnedHeaderHeight }

  private lazy var pinnedHeaderView: PinnedMessageHeaderView = {
    let view = PinnedMessageHeaderView(
      dependencies: dependencies, peerId: peerId, chatId: chat.id, initialPinnedMessage: initialPinnedMessage
    )
    view.onHeightChange = { [weak self] height in
      guard let self, pinnedHeaderHeight != height else { return }
      pinnedHeaderHeight = height
      pinnedHeaderHeightConstraint?.constant = height
      applyPinnedHeaderSuppression()
      guard hasPlacedInitialRows else { return }
      // Rows keep their place below the header as it comes and goes (bottom first, as other inset changes).
      list.setInsets(top: topInset, timing: .standard)
    }
    return view
  }()

  /// Under the toolbar, across the message column.
  private func installPinnedHeader(in root: NSView) {
    root.addSubview(pinnedHeaderView)
    let top = pinnedHeaderView.topAnchor.constraint(
      equalTo: root.topAnchor, constant: toolbarHeight + additionalTopContentInset
    )
    let height = pinnedHeaderView.heightAnchor.constraint(equalToConstant: pinnedHeaderHeight)
    pinnedHeaderTopConstraint = top
    pinnedHeaderHeightConstraint = height
    NSLayoutConstraint.activate([
      top,
      pinnedHeaderView.leadingAnchor.constraint(equalTo: messageColumnGuide.leadingAnchor),
      pinnedHeaderView.trailingAnchor.constraint(equalTo: messageColumnGuide.trailingAnchor),
      height,
    ])
    applyPinnedHeaderSuppression()
  }

  /// The header shows itself when it has a pin; a top overlay keeps it hidden.
  private func applyPinnedHeaderSuppression() {
    if topOverlayHeight > 0 {
      pinnedHeaderView.isHidden = true
    } else if pinnedHeaderHeight > 0 {
      pinnedHeaderView.isHidden = false
    }
  }

  // MARK: - Floating buttons: scroll to the newest message, next mention, next reaction

  private var activityNavigator: ChatActivityNavigator?
  private var isScrollToBottomButtonShown = false
  /// The newest incoming message the reader has seen: the scroll button's count falls as they scroll down.
  private var unreadCountReadFrontier: Int64 = 0
  private var appliedUnreadMark = false
  private var scrollToBottomBottomConstraint: NSLayoutConstraint?
  private var activityJumpBottomConstraint: NSLayoutConstraint?
  private var reactionJumpBottomConstraint: NSLayoutConstraint?

  private lazy var scrollToBottomButton: ScrollToBottomButtonHostingView = {
    let button = ScrollToBottomButtonHostingView()
    button.onClick = { [weak self] in
      guard let self else { return }
      scrollToLatest()
      setScrollToBottomButtonShown(false)
    }
    button.translatesAutoresizingMaskIntoConstraints = false
    button.setVisibility(false)
    return button
  }()

  private lazy var activityJumpButton: ActivityJumpButtonHostingView = {
    let button = ActivityJumpButtonHostingView(kind: .mention)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.onClick = { [weak self] in self?.jumpToNextActivity() }
    button.onMarkAllRead = { [weak self] in self?.activityNavigator?.markAllMentionsRead() }
    return button
  }()

  private lazy var reactionJumpButton: ActivityJumpButtonHostingView = {
    let button = ActivityJumpButtonHostingView(kind: .reaction)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.onClick = { [weak self] in self?.jumpToNextReaction() }
    button.onMarkAllRead = { [weak self] in self?.activityNavigator?.markAllReactionsRead() }
    return button
  }()

  /// The buttons sit on the compose side controls' axis (the mirror of the avatar column), stacked up from the
  /// composer: scroll to the newest, then @, then ♥; a hidden one takes no slot.
  private func installFloatingButtons(in root: NSView) {
    let size = ChatFloatingButtonMetrics.size
    root.addSubview(scrollToBottomButton)
    root.addSubview(activityJumpButton)
    root.addSubview(reactionJumpButton)
    let scrollBottom = scrollToBottomButton.bottomAnchor.constraint(
      equalTo: root.bottomAnchor, constant: jumpButtonBottomConstant(slot: 0)
    )
    let activityBottom = activityJumpButton.bottomAnchor.constraint(
      equalTo: root.bottomAnchor, constant: activityJumpBottomConstant
    )
    let reactionBottom = reactionJumpButton.bottomAnchor.constraint(
      equalTo: root.bottomAnchor, constant: reactionJumpBottomConstant
    )
    scrollToBottomBottomConstraint = scrollBottom
    activityJumpBottomConstraint = activityBottom
    reactionJumpBottomConstraint = reactionBottom
    NSLayoutConstraint.activate([
      scrollToBottomButton.centerXAnchor.constraint(
        equalTo: messageColumnGuide.trailingAnchor, constant: -ChatFloatingButtonMetrics.centerInset
      ),
      scrollBottom,
      scrollToBottomButton.widthAnchor.constraint(equalToConstant: size),
      scrollToBottomButton.heightAnchor.constraint(equalToConstant: size),
      activityJumpButton.centerXAnchor.constraint(equalTo: scrollToBottomButton.centerXAnchor),
      activityBottom,
      activityJumpButton.widthAnchor.constraint(equalToConstant: size),
      activityJumpButton.heightAnchor.constraint(equalToConstant: size),
      reactionJumpButton.centerXAnchor.constraint(equalTo: scrollToBottomButton.centerXAnchor),
      reactionBottom,
      reactionJumpButton.widthAnchor.constraint(equalToConstant: size),
      reactionJumpButton.heightAnchor.constraint(equalToConstant: size),
    ])
    startActivityNavigator()
  }

  private func jumpButtonBottomConstant(slot: Int) -> CGFloat {
    -bottomInset - CGFloat(slot) * (ChatFloatingButtonMetrics.size + ChatFloatingButtonMetrics.spacing)
  }

  private var activityJumpBottomConstant: CGFloat {
    jumpButtonBottomConstant(slot: isScrollToBottomButtonShown ? 1 : 0)
  }

  private var reactionJumpBottomConstant: CGFloat {
    jumpButtonBottomConstant(slot: (isScrollToBottomButtonShown ? 1 : 0) + (activityJumpButton.count > 0 ? 1 : 0))
  }

  private func updateFloatingButtonPositions(animate: Bool) {
    guard let scrollToBottomBottomConstraint, let activityJumpBottomConstraint, let reactionJumpBottomConstraint
    else { return }
    scrollToBottomBottomConstraint.constant = jumpButtonBottomConstant(slot: 0)
    guard animate, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
      activityJumpBottomConstraint.constant = activityJumpBottomConstant
      reactionJumpBottomConstraint.constant = reactionJumpBottomConstant
      return
    }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.25
      context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
      context.allowsImplicitAnimation = true
      activityJumpBottomConstraint.animator().constant = activityJumpBottomConstant
      reactionJumpBottomConstraint.animator().constant = reactionJumpBottomConstant
    }
  }

  /// Shown unless the newest message is in reach (the read follow zone, 44 pt): the live end's, or, while the history
  /// isn't certified yet, the newest one stored (the table list hid it at its bottom either way). Hidden too while the
  /// list is hidden for the unread fetch or on its way to the latest messages.
  private func updateScrollToBottomButton() {
    guard hasPlacedInitialRows, !isDisposed else { return }
    let layout = list.timelineLayout
    let nearNewest = layout.isAtBottom || (layout.distanceToNewest.map { $0 <= 44 } ?? false)
    let atLiveEnd = nearNewest && (chatRows.historyCoverage.isAtCertifiedLiveEnd || !chatRows.canLoadNewerFromLocal)
    setScrollToBottomButtonShown(!atLiveEnd && unreadFetchBoundary == nil && !latestJumpRunning)
  }

  private func setScrollToBottomButtonShown(_ shown: Bool) {
    guard isScrollToBottomButtonShown != shown else { return }
    isScrollToBottomButtonShown = shown
    scrollToBottomButton.setVisibility(shown)
    updateFloatingButtonPositions(animate: true)
  }

  private func startActivityNavigator() {
    guard activityNavigator == nil, chat.id > 0 else { return }
    let navigator = ChatActivityNavigator(peerId: peerId, chatId: chat.id)
    navigator.onChange = { [weak self] state in self?.applyActivityState(state, animate: true) }
    activityNavigator = navigator
    navigator.start()
    applyActivityState(navigator.state, animate: false)
  }

  private func applyActivityState(_ state: ChatActivityNavigator.State, animate: Bool) {
    // Marking the chat unread supersedes what this list read before; only a new mark (resetting on every emission
    // while marked put back counts the reader had scrolled past).
    if state.unreadMark, !appliedUnreadMark { unreadCountReadFrontier = 0 }
    appliedUnreadMark = state.unreadMark
    // The chat may be unread again (a mark, a count from the server, a cursor short of the last read): the next pass
    // at the live end reads it whole again.
    if state.unreadMark || state.unreadCount > 0 || state.readInboxMaxId < (readAllThrough ?? 0) {
      readAllThrough = nil
    }
    updateScrollToBottomCount()
    guard activityJumpButton.count != state.mentionsCount || reactionJumpButton.count != state.reactionsCount
    else { return }
    activityJumpButton.setCount(state.mentionsCount)
    reactionJumpButton.setCount(state.reactionsCount)
    updateFloatingButtonPositions(animate: animate)
  }

  /// Unread messages below the reader, falling as they scroll and kept across reopening.
  private func updateScrollToBottomCount() {
    let state = activityNavigator?.state ?? .empty
    scrollToBottomButton.setCount(ChatUnreadBadgeCount.resolve(
      unreadCount: state.unreadCount,
      readInboxMaxId: state.readInboxMaxId,
      readFrontier: unreadCountReadFrontier,
      coverage: chatRows.historyCoverage,
      loadedMessages: messages
    ))
  }

  private func jumpToNextActivity() {
    guard let navigator = activityNavigator else { return }
    Task { @MainActor [weak self] in
      guard let messageId = await navigator.nextMessageId(), let self, !isDisposed else { return }
      focus(ScrollToMessageRequest(messageId: messageId, reason: .mention))
    }
  }

  private func jumpToNextReaction() {
    guard let navigator = activityNavigator else { return }
    Task { @MainActor [weak self] in
      guard let messageId = await navigator.nextReactionMessageId(), let self, !isDisposed else { return }
      focus(ScrollToMessageRequest(messageId: messageId, reason: .mention))
    }
  }

  /// On-screen messages, so unseen mentions and replies are marked read after a short dwell (mentions arrive on
  /// others' messages, reactions on yours, so every message counts).
  private func reportVisibleActivity() {
    guard let activityNavigator else { return }
    guard hasPlacedInitialRows, AppActivityMonitor.shared.isActive, let window = view.window, window.isVisible,
          !view.isHiddenOrHasHiddenAncestor, unreadFetchBoundary == nil
    else {
      activityNavigator.clearVisible()
      return
    }
    let layout = list.timelineLayout
    let viewport = layout.viewport
    var ids: [Int64] = []
    for placement in layout.placements where placement.maxY > viewport.usableTop && placement.y < viewport.usableBottom {
      guard let found = message(for: placement.id) else { continue }
      let items = chatRows.album(forStableId: found.message.id)?.items ?? [found.message]
      ids.append(contentsOf: items.map(\.message.messageId).filter { $0 > 0 })
    }
    activityNavigator.noteVisible(messageIds: ids)
  }

  // MARK: - Reply thread side pane

  /// The thread showing in this window's side pane while this chat is the primary one, and its source message.
  private var replyThreadPanePeer: Peer?
  private var replyThreadSourceMessageId: Int64?
  private var isObservingReplyThreadPane = false

  private func observeReplyThreadPane() {
    guard !isDisposed, let nav3 = dependencies.nav3 else { return }
    let isInitial = !isObservingReplyThreadPane
    isObservingReplyThreadPane = true
    let threadPeer = withObservationTracking {
      nav3.currentReplyThreadPeer
    } onChange: { [weak self] in
      // Fires on willSet: read the new value on the next main-actor turn, before the pane's first width change.
      Task { @MainActor [weak self] in self?.observeReplyThreadPane() }
    }
    let panePeer = threadPeer == peerId ? nil : threadPeer
    let sourceMessageId = panePeer.flatMap { nav3.replyThreadSourceMessageId(threadPeer: $0, parentPeer: peerId) }
    guard panePeer != replyThreadPanePeer || sourceMessageId != replyThreadSourceMessageId else { return }
    let previousPanePeer = replyThreadPanePeer
    let previousSourceMessageId = replyThreadSourceMessageId
    replyThreadPanePeer = panePeer
    replyThreadSourceMessageId = sourceMessageId
    if !isInitial {
      // Opening holds the new source where it is while the pane slides in; closing holds the one leaving.
      holdReplyThreadSource(
        threadPeer: panePeer ?? previousPanePeer,
        sourceMessageId: panePeer == nil ? previousSourceMessageId : sourceMessageId
      )
    }
    refreshReplyThreadSourceHighlights(animated: !isInitial)
  }

  private func isReplyThreadSource(_ message: FullMessage) -> Bool {
    guard replyThreadPanePeer != nil else { return false }
    return isReplyThreadSource(message, threadPeer: replyThreadPanePeer, sourceMessageId: replyThreadSourceMessageId)
  }

  private func isReplyThreadSource(_ message: FullMessage, threadPeer: Peer?, sourceMessageId: Int64?) -> Bool {
    if let sourceMessageId, message.message.messageId == sourceMessageId { return true }
    guard let threadPeer else { return false }
    return message.message.replyThreadPeer == threadPeer
  }

  private func refreshReplyThreadSourceHighlights(animated: Bool) {
    guard hasPlacedInitialRows else { return }
    for (id, view) in list.placedViews {
      guard case .message = id, let cell = (view as? TimelineRowHost)?.content as? MessageTableCell,
            let found = message(for: id) else { continue }
      cell.setReplyThreadSourceHighlighted(isReplyThreadSource(found.message), animated: animated)
    }
  }

  /// The list holds one row at a distance from its top (or rests on the newest): the source message on screen becomes
  /// that row, where it is, so the width change as the pane slides keeps it in place, as the table list's anchor
  /// did. A reader resting on the newest message stays there while the source shows whole.
  private func holdReplyThreadSource(threadPeer: Peer?, sourceMessageId: Int64?) {
    guard hasPlacedInitialRows, !isDisposed, threadPeer != nil || sourceMessageId != nil else { return }
    let layout = list.timelineLayout
    let viewport = layout.viewport
    for placement in layout.visible {
      guard case .message = placement.id, let found = message(for: placement.id),
            isReplyThreadSource(found.message, threadPeer: threadPeer, sourceMessageId: sourceMessageId) else { continue }
      if layout.isAtBottom, placement.y >= viewport.usableTop, placement.maxY <= viewport.usableBottom { return }
      list.apply(TimelineTransaction(scroll: .to(placement.id, .top(placement.y - viewport.usableTop))))
      return
    }
  }

  // MARK: - Hover and quick actions (minimal style)

  private var messageHoverTrackingArea: NSTrackingArea?
  private var hoveredMessageStableId: Int64?
  private weak var hoveredMessageCell: MessageTableCell?
  private var messageHoverRefreshScheduled = false
  private var messageQuickActionsView: MessageQuickActionsView?
  private var isQuickActionsMenuOpen = false
  private weak var quickActionsReactionOverlay: ReactionOverlayWindow?
  private var isQuickActionsPresentationOpen: Bool {
    isQuickActionsMenuOpen || quickActionsReactionOverlay?.isVisible == true
  }

  /// Minimal rows show a hover state and a capsule of quick actions (reply, react, more) for the message under the
  /// pointer, as the table list does; only while the list rests.
  private func setupMessageHoverTracking() {
    guard renderStyle == .minimal, messageHoverTrackingArea == nil else { return }
    let area = NSTrackingArea(
      rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect], owner: self,
      userInfo: nil
    )
    list.addTrackingArea(area)
    messageHoverTrackingArea = area
  }

  override func mouseEntered(with event: NSEvent) {
    super.mouseEntered(with: event)
    updateHoveredMessage(at: list.convert(event.locationInWindow, from: nil))
  }

  override func mouseMoved(with event: NSEvent) {
    super.mouseMoved(with: event)
    updateHoveredMessage(at: list.convert(event.locationInWindow, from: nil))
  }

  override func mouseExited(with event: NSEvent) {
    super.mouseExited(with: event)
    guard !isQuickActionsPresentationOpen else { return }
    clearHoveredMessage()
  }

  /// After the rows moved under a still pointer (a rest, an update): the message now under it.
  private func scheduleMessageHoverRefresh() {
    guard renderStyle == .minimal, !isDisposed, !messageHoverRefreshScheduled else { return }
    messageHoverRefreshScheduled = true
    DispatchQueue.main.async(qos: .userInteractive) { [weak self] in
      guard let self else { return }
      messageHoverRefreshScheduled = false
      guard !isDisposed, let window = list.window else { return }
      updateHoveredMessage(at: list.convert(window.mouseLocationOutsideOfEventStream, from: nil), force: true)
    }
  }

  private func updateHoveredMessage(at point: NSPoint, force: Bool = false) {
    guard renderStyle == .minimal, hasPlacedInitialRows else { return }
    guard !list.isMoving else {
      clearHoveredMessage()
      return
    }
    guard !isQuickActionsPresentationOpen else { return }
    guard let target = messageHoverTarget(at: point) else {
      setHoveredMessage(stableId: nil, cell: nil, force: force)
      return
    }
    setHoveredMessage(stableId: target.stableId, cell: target.cell, force: force)
  }

  private func messageHoverTarget(at point: NSPoint) -> (stableId: Int64, cell: MessageTableCell)? {
    guard list.bounds.contains(point) else { return nil }
    // The capsule overlaps the row above its message: crossing that edge keeps it with its message.
    if let capsule = messageQuickActionsView, !capsule.isHidden,
       capsule.frame.contains(view.convert(point, from: list)),
       let stableId = hoveredMessageStableId, let cell = hoveredMessageCell,
       cell.quickActionsMessageView?.fullMessage.message.stableId == stableId
    {
      return (stableId, cell)
    }
    guard let id = list.row(atPresented: point), case let .message(stableId) = id,
          let cell = (list.view(for: id) as? TimelineRowHost)?.content as? MessageTableCell,
          cell.containsMessageHoverPoint(point, from: list)
    else { return nil }
    return (stableId, cell)
  }

  private func setHoveredMessage(stableId: Int64?, cell: MessageTableCell?, force: Bool = false) {
    guard force || hoveredMessageStableId != stableId || hoveredMessageCell !== cell else { return }
    let previousCell = hoveredMessageCell
    hoveredMessageStableId = stableId
    hoveredMessageCell = cell
    if previousCell !== cell {
      hideMessageQuickActions()
      previousCell?.setMessageHoverState(false)
    }
    cell?.setMessageHoverState(true)
    updateMessageQuickActions()
  }

  private func clearHoveredMessage() {
    hideMessageQuickActions()
    setHoveredMessage(stableId: nil, cell: nil)
  }

  private func hideMessageQuickActions() {
    // Already hidden: nothing to tear down (scroll frames and clears land here repeatedly).
    guard quickActionsReactionOverlay != nil || messageQuickActionsView?.isHidden == false else { return }
    let reactionOverlay = quickActionsReactionOverlay
    quickActionsReactionOverlay = nil
    reactionOverlay?.close()
    messageQuickActionsView?.setActiveAction(nil)
    messageQuickActionsView?.hideTooltips()
    messageQuickActionsView?.isHidden = true
    messageQuickActionsView?.onAction = nil
  }

  /// The capsule at the hovered message's top trailing corner, kept inside the usable area (not under the toolbar or
  /// the composer).
  private func updateMessageQuickActions() {
    guard renderStyle == .minimal, !isDisposed, !list.isMoving,
          let cell = hoveredMessageCell, let stableId = hoveredMessageStableId,
          let renderer = cell.quickActionsMessageView, renderer.fullMessage.message.stableId == stableId,
          renderer.window != nil
    else {
      hideMessageQuickActions()
      return
    }
    let anchor = renderer.quickActionsAnchorRect(in: view)
    let bounds = view.bounds
    let viewport = NSRect(
      x: bounds.minX, y: bounds.minY + topInset, width: bounds.width,
      height: max(0, bounds.height - topInset - bottomInset)
    )
    let size = MessageQuickActionsView.preferredSize
    guard anchor.intersects(viewport), viewport.width >= size.width + 16, viewport.height >= size.height + 8 else {
      hideMessageQuickActions()
      return
    }
    let capsule: MessageQuickActionsView
    if let existing = messageQuickActionsView {
      capsule = existing
    } else {
      capsule = MessageQuickActionsView(frame: NSRect(origin: .zero, size: size))
      messageQuickActionsView = capsule
    }
    capsule.setActionsEnabled(canReply: renderer.quickActionsCanReply, canReact: renderer.quickActionsCanReact)
    capsule.frame = NSRect(
      x: min(max(anchor.maxX - size.width - 8, viewport.minX + 8), viewport.maxX - size.width - 8),
      y: min(max(anchor.minY - size.height / 2, viewport.minY + 4), viewport.maxY - size.height - 4),
      width: size.width, height: size.height
    )
    if capsule.superview !== view {
      view.addSubview(capsule, positioned: .above, relativeTo: list)
    }
    capsule.isHidden = false
    capsule.refreshHoverState()
    capsule.onAction = { [weak self, weak cell, weak capsule] action, button in
      guard let self, let cell, let capsule, !isDisposed, hoveredMessageCell === cell,
            let renderer = cell.quickActionsMessageView, renderer.fullMessage.message.stableId == stableId
      else { return }
      if action == .reaction, let overlay = quickActionsReactionOverlay, overlay.isVisible {
        overlay.close()
        return
      }
      // Hover stays during the presentation as well as the synchronous menu loop.
      isQuickActionsMenuOpen = action == .more || action == .reaction
      quickActionsReactionOverlay?.close()
      capsule.setActiveAction(isQuickActionsMenuOpen ? action : nil)
      defer {
        isQuickActionsMenuOpen = false
        capsule.setActiveAction(quickActionsReactionOverlay?.isVisible == true ? .reaction : nil)
        scheduleMessageHoverRefresh()
      }
      if let overlay = renderer.performQuickAction(action, from: button, capsule: capsule) {
        quickActionsReactionOverlay = overlay
        overlay.toggleButton = button
        overlay.onClose = { [weak self, weak overlay] in
          guard let self, quickActionsReactionOverlay === overlay else { return }
          quickActionsReactionOverlay = nil
          messageQuickActionsView?.setActiveAction(nil)
          scheduleMessageHoverRefresh()
        }
      }
    }
  }

  // MARK: - Streaming

  // streaming: agents and bots stream by editing a message with ever-longer text. `MessageStreamPacer` reveals it at
  // the rate it arrives (Telegram's model, the iOS list's); the row is planned at the revealed line
  // (`MessageSizeCalculator`), each frame's count goes to its text views, and a new line re-plans the row on the
  // streaming timing, so the bubble grows a line at a time with its insides (`updateRow`) instead of a chunk an edit.

  /// The line each streaming message's row was last planned at.
  private var streamPlannedLine: [Int64: Int] = [:]

  private static var streamingTiming: TimelineTiming {
    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .none : .streamingLine
  }

  /// The texts of the placed messages an update changes, before it applies.
  private func streamTexts(before update: MessagesProgressiveViewModel.MessagesChangeSet) -> [Int64: String?] {
    guard hasPlacedInitialRows, case let .updated(updated, _, _) = update else { return [:] }
    var texts: [Int64: String?] = [:]
    for message in updated where list.view(for: .message(id: message.id)) != nil {
      if let current = self.message(for: .message(id: message.id)) { texts[message.id] = current.message.message.text }
    }
    return texts
  }

  private func feedStreams(_ update: MessagesProgressiveViewModel.MessagesChangeSet, oldTexts: [Int64: String?]) {
    guard !oldTexts.isEmpty, case let .updated(updated, _, _) = update else { return }
    let pacer = MessageStreamPacer.shared
    // The reveal ticks at the rate of the display this list is on.
    pacer.displayView = list
    for message in updated {
      guard let old = oldTexts[message.id] else { continue }
      let id = message.id
      pacer.messageChanged(id, from: old, to: message.message.text)
      guard pacer.isStreaming(id) else { continue }
      listenToStream(id)
    }
  }

  /// This list hears the stream's frames and its end (the pacer keeps one listener a message: the last list that
  /// fed or showed it), and the pacer ticks with this list's display.
  private func listenToStream(_ id: Int64) {
    let pacer = MessageStreamPacer.shared
    pacer.displayView = list
    pacer.attach(id, owner: self, reveal: { [weak self] length in
      self?.streamRevealed(id, length: length)
    }, finish: { [weak self] in
      self?.streamFinished(id)
    })
  }

  /// The text views of a row (the plain text's glyphs; a rich body's layer text views draw through the same class).
  private static func glyphViews(in root: NSView) -> [CoreTextGlyphView] {
    var found: [CoreTextGlyphView] = []
    var stack = [root]
    while let view = stack.popLast() {
      if let glyphs = view as? CoreTextGlyphView { found.append(glyphs) } else { stack.append(contentsOf: view.subviews) }
    }
    return found
  }

  /// The plan the row shows: a rich body (`RichBlockLayoutPlan.revealing`) maps the count through its blocks; plain
  /// text through its lines.
  private func richPlan(_ stableId: Int64) -> RichBlockLayoutPlan? {
    heights[streamRow(stableId)]?.plan.richBlockContent
  }

  /// The row showing a message here: its own, or a reply thread's parent row.
  private func streamRow(_ stableId: Int64) -> RowID {
    let parent = RowID.parentMessage(id: stableId)
    return list.view(for: .message(id: stableId)) == nil && list.view(for: parent) != nil ? parent : .message(id: stableId)
  }

  private static func richContent(in root: NSView) -> RichBlockContentView? {
    var stack = [root]
    while let view = stack.popLast() {
      if let content = view as? RichBlockContentView { return content }
      stack.append(contentsOf: view.subviews)
    }
    return nil
  }

  /// A configured row shows its message's revealed part while it streams, and all of it otherwise.
  private func applyReveal(to host: TimelineRowHost, stableId: Int64) {
    let length = MessageStreamPacer.shared.revealedLength(for: stableId)
    guard length != nil || host.revealsText else { return }
    // A row showing a stream this list didn't feed (opened mid-stream, another window's): it follows the reveal and
    // hears the end, or it kept the prefix it was configured with.
    if length != nil { listenToStream(stableId) }
    if richPlan(stableId) != nil {
      Self.richContent(in: host)?.reveal(length)
    } else {
      for glyphs in Self.glyphViews(in: host) { glyphs.revealedLength = length }
    }
    host.revealsText = length != nil
  }

  private func streamRevealed(_ stableId: Int64, length: Int) {
    let row = streamRow(stableId)
    guard !isDisposed, hasPlacedInitialRows, let host = list.view(for: row) as? TimelineRowHost else { return }
    if let rich = richPlan(stableId) {
      // A rich body: the frontier block draws the count; past the plan's limit (a new line, or a hidden block's first
      // character) the row is planned again.
      Self.richContent(in: host)?.reveal(length)
      host.revealsText = true
      if let limit = rich.revealLimit, length >= limit { replanStreamingRow(stableId) }
      return
    }
    guard heights[row]?.plan.text != nil else { return }
    let glyphs = Self.glyphViews(in: host)
    for view in glyphs { view.revealedLength = length }
    host.revealsText = true
    // A new line: the row is planned again at it and grows on the streaming timing.
    guard let layout = glyphs.first?.textLayout, layout.lineCount > 0 else { return }
    let line = layout.lines.firstIndex { NSMaxRange($0.range) > length } ?? layout.lineCount - 1
    guard let planned = streamPlannedLine[stableId] else {
      // First sight: the row was planned at this line.
      streamPlannedLine[stableId] = line
      return
    }
    guard line > planned else { return }
    streamPlannedLine[stableId] = line
    replanStreamingRow(stableId)
  }

  private func streamFinished(_ stableId: Int64) {
    streamPlannedLine[stableId] = nil
    guard !isDisposed, hasPlacedInitialRows else { return }
    if let host = list.view(for: streamRow(stableId)) as? TimelineRowHost {
      Self.richContent(in: host)?.reveal(nil)
      for view in Self.glyphViews(in: host) { view.revealedLength = nil }
      host.revealsText = false
    }
    replanStreamingRow(stableId)
  }

  private func replanStreamingRow(_ stableId: Int64) {
    revisions[stableId, default: 0] += 1
    list.apply(TimelineTransaction(changed: [streamRow(stableId)], timing: Self.streamingTiming))
  }

  // MARK: - Media warm-up

  private var mediaWarmupTask: Task<Void, Never>?
  private var mediaWarmups: [InlineTinyThumbnailWarmup] = []

  /// Photos and video thumbnails of the rows on screen and near them are decoded ahead at their display size, as the
  /// table list and the iOS timeline do, so a row coming on screen shows its media at once instead of decoding then.
  /// On the first rows, when the list rests and when rows land; each run replaces the last.
  private func scheduleMediaWarmup() {
    guard hasPlacedInitialRows, !isDisposed else { return }
    mediaWarmupTask?.cancel()
    mediaWarmupTask = Task { @MainActor [weak self] in
      guard let self, !isDisposed else { return }
      let previous = mediaWarmups
      mediaWarmups.removeAll()
      for warmup in previous { await InlineTinyThumbnailPrewarmer.cancel(warmup) }
      await Task.yield()
      guard !Task.isCancelled, !isDisposed else { return }
      let rows = mediaWarmupRows()
      let visibleMessages = rows.visible.compactMap { message(for: $0)?.message }
      let nearbyMessages = rows.nearby.compactMap { message(for: $0)?.message }
      var warmups: [InlineTinyThumbnailWarmup] = []
      if !visibleMessages.isEmpty {
        warmups.append(await InlineTinyThumbnailPrewarmer.beginWarmup(
          for: visibleMessages, includeSupportingMedia: true, priority: .visible
        ))
      }
      if !nearbyMessages.isEmpty, !Task.isCancelled {
        warmups.append(await InlineTinyThumbnailPrewarmer.beginWarmup(
          for: nearbyMessages, includeSupportingMedia: true, priority: .nearby
        ))
      }
      guard !Task.isCancelled, !isDisposed else {
        for warmup in warmups { await InlineTinyThumbnailPrewarmer.cancel(warmup) }
        return
      }
      mediaWarmups = warmups
      prewarmMedia(for: rows.visible + rows.nearby)
    }
  }

  /// The rows on screen, and the policy's lookahead of rows on each side (the reader can go either way).
  private func mediaWarmupRows() -> (visible: [RowID], nearby: [RowID]) {
    let visible = list.timelineLayout.visible.map(\.id)
    let rows = chatRows.rows
    guard let first = visible.first, let last = visible.last,
          let firstIndex = rows.firstIndex(of: first), let lastIndex = rows.lastIndex(of: last), firstIndex <= lastIndex
    else { return (visible, []) }
    let lookahead = InlineTinyThumbnailWarmupPolicy.adaptiveLookaheadRows()
    let above = rows[max(0, firstIndex - lookahead) ..< firstIndex]
    let below = rows[(lastIndex + 1) ..< min(rows.count, lastIndex + 1 + lookahead)]
    return (visible, Array(below) + Array(above.reversed()))
  }

  private func prewarmMedia(for ids: [RowID]) {
    let column = cellWidth(list.bounds.width)
    let scale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    for id in ids {
      guard !isDisposed else { return }
      guard case .message = id, let (_, message, _, plan) = messagePlan(id, column: column) else { continue }
      let hasCaption = message.message.text?.isEmpty == false
      if let photoInfo = message.photoInfo {
        prewarmPhotoDisplay(photoInfo, cacheKey: nil, targetSize: plan.photo?.size, hasCaption: hasCaption, scale: scale)
      }
      if let videoInfo = message.videoInfo, let thumbnail = videoInfo.thumbnail {
        let videoId = videoInfo.video.id ?? thumbnail.id
        prewarmPhotoDisplay(
          thumbnail, cacheKey: "video-thumb-\(videoId)", targetSize: plan.video?.size, hasCaption: hasCaption, scale: scale
        )
      }
    }
  }

  private func prewarmPhotoDisplay(
    _ photoInfo: PhotoInfo, cacheKey: String?, targetSize: CGSize?, hasCaption: Bool, scale: CGFloat
  ) {
    guard let photoSize = photoInfo.bestPhotoSize(), let localPath = photoSize.localPath, !localPath.isEmpty else { return }
    let url = FileCache.getUrl(for: .photos, localPath: localPath)
    let size: CGSize = if let targetSize, targetSize.width > 0, targetSize.height > 0 {
      targetSize
    } else if let width = photoSize.width, let height = photoSize.height {
      sizeCalculator.calculatePhotoSize(
        width: CGFloat(width), height: CGFloat(height), parentAvailableWidth: 320, hasCaption: hasCaption
      )
    } else {
      CGSize(width: 320, height: 320)
    }
    ImageCacheManager.shared.prewarm(for: url, cacheKey: cacheKey, targetSize: size, scale: scale)
  }

  // MARK: - Translation

  private lazy var translationViewModel = TranslationViewModel(peerId: peerId)
  private var hasAnalyzedInitialMessages = false
  private var deferredTranslationTask: Task<Void, Never>?
  private var hasDeferredInitialTranslation = false
  private var translationSettingCancellable: AnyCancellable?

  private func observeTranslationSetting() {
    translationSettingCancellable = AppSettings.shared.$translationUIEnabled
      .receive(on: DispatchQueue.main)
      .sink { [weak self] enabled in
        guard let self, !enabled else { return }
        // Stop pending work and forget what was analysed, so turning it back on works.
        deferredTranslationTask?.cancel()
        deferredTranslationTask = nil
        hasAnalyzedInitialMessages = false
        hasDeferredInitialTranslation = false
      }
  }

  /// Messages shown or changed are offered for translation, as the table list does; new ones are also analysed for
  /// the chat's language once.
  private func handleTranslationForUpdate(_ update: MessagesProgressiveViewModel.MessagesChangeSet) {
    guard AppSettings.shared.translationUIEnabled else { return }
    switch update {
      case .reload: scheduleTranslationWork(messages: messages, analyzeForDetection: true)
      case let .added(added, _): scheduleTranslationWork(messages: added, analyzeForDetection: true)
      case let .updated(updated, _, _): scheduleTranslationWork(messages: updated, analyzeForDetection: false)
      case .deleted: break
    }
  }

  private func scheduleTranslationWork(messages: [FullMessage], analyzeForDetection: Bool) {
    guard AppSettings.shared.translationUIEnabled else { return }
    let messages = messages.filter { !$0.message.isServiceMessage }
    guard !messages.isEmpty else { return }
    deferredTranslationTask?.cancel()
    deferredTranslationTask = Task(priority: .userInitiated) { [weak self] in
      await self?.performTranslationWork(messages: messages, analyzeForDetection: analyzeForDetection)
    }
  }

  private func performTranslationWork(messages: [FullMessage], analyzeForDetection: Bool) async {
    guard AppSettings.shared.translationUIEnabled else { return }
    // The first batch waits out the opening frames; translation is safe to delay.
    if !hasDeferredInitialTranslation {
      hasDeferredInitialTranslation = true
      try? await Task.sleep(nanoseconds: 250_000_000)
      if Task.isCancelled { return }
    }
    translationViewModel.messagesDisplayed(messages: messages)
    guard analyzeForDetection, !hasAnalyzedInitialMessages else { return }
    await TranslationDetector.shared.analyzeMessages(peer: peerId, messages: messages)
    hasAnalyzedInitialMessages = true
  }

  // MARK: - Status notice

  private var statusNoticeCancellable: AnyCancellable?
  private var integrationCheckTask: Task<Void, Never>?

  /// The other user of a DM (not a chat with oneself): their notice shows as the last row.
  private var statusNoticeUserId: Int64? {
    guard let userId = peerId.asUserId(), userId != Auth.shared.getCurrentUserId() else { return nil }
    return userId
  }

  private func observeStatusNotice() {
    guard let userId = statusNoticeUserId else { return }
    statusNoticeCancellable = ObjectCache.shared.getUserPublisher(id: userId)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] userInfo in
        guard let userInfo else { return }
        self?.setStatusNotice(userInfo.notificationsSilencedNotice())
      }
  }

  /// The notice is the last row, so it moves no row above it; a list resting on the newest message follows it.
  private func setStatusNotice(_ text: String?) {
    guard !isDisposed, chatRows.setStatusNotice(text) != .none, hasPlacedInitialRows else { return }
    list.apply(TimelineTransaction(rows: chatRows.rows, coverage: coverage(), timing: .standard, arrives: false))
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func loadView() {
    #if DEBUG
    Self.journeyCurrent = self
    #endif
    // The fling's shape: NSScrollView's (AppKit's calculator from 0.9 × the fingers' speed), or, to compare, the
    // system's momentum stream (about twice the travel):
    // `defaults write chat.inline.InlineMac.devbuild TimelineSystemMomentumFling -bool YES`, then open a chat.
    TimelineFling.followsNSScrollView = !UserDefaults.standard.bool(forKey: "TimelineSystemMomentumFling")
    let root = TimelineMessageListRootView()
    root.wantsLayer = true
    // Weak, not unowned: the list can outlive this controller (it stays in the window until the next chat's first
    // frame, and its delayed sweeps still run), and a call into a freed controller aborted the app (harness
    // `stream-switch`, 2026-11-27: the lingering-row sweep's recycle after a chat switch mid-stream).
    let list = TimelineListView<RowID>(rows: TimelineRows(
      height: { [weak self] id, width in self?.height(of: id, width: width) ?? 0 },
      make: { [weak self] id, width in self?.makeRow(id, width: width) ?? NSView() },
      update: { [weak self] id, view, width, timing in self?.updateRow(id, view, width: width, timing: timing) },
      recycle: { [weak self] id, view in self?.recycleRow(id, view) },
      pin: { [weak self] id, view in self?.stickyAvatarPin(id, view) },
      spanTop: { [weak self] id, _ in self?.stickyAvatarSpanTop(id) ?? 0 },
      spanEnd: { [weak self] id in self?.stickyAvatarGroup(for: id)?.last },
      spanStart: { [weak self] id in self?.stickyAvatarSpanStart(id) },
      passage: { [weak self] id, offset, from, to in self?.passageOffset(id, offset, from: from, to: to) ?? offset },
      removalFocus: { _, view in
        CGPoint(x: view.bounds.midX, y: view.bounds.midY)
      }
    ))
    // The day of the topmost message floats under the toolbar while the list moves (Telegram macOS): the day row's own
    // pill, taken over where it reaches the top and pushed off by the next day's; the row hides meanwhile.
    let floatingDate = TimelineFloatingDateView()
    floatingDate.onClick = { [weak self] day in self?.scrollToDayStart(day) }
    list.floatingHeader = TimelineFloatingHeader(
      view: floatingDate, height: TimelineDatePill.height, gap: TimelineDayRowView.pillTop,
      section: { [weak self] id in self?.daySection(for: id) },
      configure: { view, id in
        if case let .daySeparator(dayStart) = id { (view as? TimelineFloatingDateView)?.configure(dayStart: dayStart) }
      },
      ownInset: TimelineDayRowView.pillTop, hidesOwnRow: true
    )
    list.translatesAutoresizingMaskIntoConstraints = false
    list.onDemand = { [weak self] edges in self?.handleDemand(edges) }
    // Asked for history 80 rows before a loaded end (the engine's Mac default is 40): with short rows 40 was well
    // under a second of a fast fling, less than a page from the server takes.
    list.demandThreshold = 80
    list.onLayout = { [weak self] _ in
      self?.updateUnreadIfNeeded()
      self?.reportPlace()
      self?.updateScrollToBottomButton()
      self?.syncBubbleGradients()
      self?.schedulePlanPrefetch()
    }
    list.onScrollEnded = { [weak self] in
      self?.updateCellScrollState(.idle)
      self?.updateUnreadIfNeeded()
      self?.saveReadingPlace()
      self?.scheduleMediaWarmup()
      self?.scheduleMessageHoverRefresh()
      // A trim that waited for the list to rest; on the next turn, once the flight that ended is gone.
      DispatchQueue.main.async { [weak self] in
        guard let self, !isDisposed, let edge = pendingTrimEdge, loadingEdges.isEmpty else { return }
        trimWindow(keeping: edge)
      }
    }
    list.onScrollBegan = { [weak self] in
      guard let self else { return }
      updateCellScrollState(.scrolling)
      clearHoveredMessage()
      // The reader moving again retries edges that gave nothing (the table list retried on every scroll near an end).
      blockedEdges.removeAll()
      // The reader took the list: a message still to arrive no longer moves it, nor does a return to latest.
      pendingArrival = nil
      if latestJumpRunning { latestInterrupted = true }
      if dayStartSearching {
        dayStartSearching = false
        jumpTask?.cancel()
        jumpTask = nil
      }
    }
    #if DEBUG || DEBUG_BUILD
    list.onGestureRecord = { TimelineGestureLog.append($0) }
    #endif
    self.list = list
    textSelection.install() // selection
    // Hidden from the first frame while the unread line's history is fetched: the latest rows never flash first.
    if unreadFetchBoundary != nil { list.alphaValue = 0 }
    root.addSubview(list)
    toolbarBackground.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(toolbarBackground)
    root.addLayoutGuide(messageColumnGuide)
    // The column the composer lines up with: the list's width, at most the centred maximum. A constant set on each
    // layout (as the table list's scroll view does), not a width relation with a lower priority: that let the chat
    // view's fitting size pull the whole list down to the maximum, left-aligned.
    // Starts at the maximum (the first layout sets it): at zero, the views laid out on the column before that (the
    // selection bar's buttons) could not fit, and AppKit broke their constraints on every chat open. Just below
    // required, so a window too narrow for them widens the column instead of breaking anything.
    let column = messageColumnGuide.widthAnchor.constraint(equalToConstant: ChatLayoutMetrics.maximumWidth)
    column.priority = NSLayoutConstraint.Priority(999)
    columnWidth = column
    NSLayoutConstraint.activate([
      list.topAnchor.constraint(equalTo: root.topAnchor),
      list.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      list.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      list.bottomAnchor.constraint(equalTo: root.bottomAnchor),
      toolbarBackground.topAnchor.constraint(equalTo: root.topAnchor),
      toolbarBackground.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      toolbarBackground.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      toolbarBackground.heightAnchor.constraint(equalToConstant: 52),
      column,
      messageColumnGuide.centerXAnchor.constraint(equalTo: root.centerXAnchor),
      messageColumnGuide.topAnchor.constraint(equalTo: root.topAnchor),
      messageColumnGuide.bottomAnchor.constraint(equalTo: root.bottomAnchor),
    ])
    root.onLayout = { [weak self] in self?.rootDidLayout() }
    root.onEndLiveResize = { [weak self] in
      self?.replanAfterLiveResize()
      self?.schedulePlanPrefetch()
    }
    view = root
    installFloatingButtons(in: root)
    installPinnedHeader(in: root)
    setupMessageHoverTracking()
    observeReplyThreadPane()

    chatRows.observe { [weak self] update in
      self?.apply(update)
      self?.handleTranslationForUpdate(update)
    }
    observeTranslationSetting()
    observeChatEvents()
    // Whether the space's Notion integration can see this chat (the message menu's "Create Notion task").
    integrationCheckTask = Task { [weak self, peerId = self.peerId, spaceId = chat.spaceId] in
      await Task.yield()
      guard self != nil, !Task.isCancelled else { return }
      await NotionTaskService.shared.checkIntegrationAccess(peerId: peerId, spaceId: spaceId)
    }
    beginUnreadFetchIfNeeded()
    // Back in the app, what is on screen has been seen.
    activeObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.updateUnreadIfNeeded() }
    }
    // A menu opening holds the list still, as a touch does: a fling runs on through menu tracking, so rows recycled
    // under an open context menu, and its actions (which read the row's message when chosen) went to another message.
    menuObserver = NotificationCenter.default.addObserver(
      forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, !self.isDisposed, self.list.isMoving, self.view.window != nil else { return }
        self.list.stopScrolling()
      }
    }
  }

  // MARK: - Chat events (send, jumps)

  private var eventTask: Task<Void, Never>?
  /// A jump to a message or to the latest messages in flight; a newer jump or leaving the chat cancels it.
  private var jumpTask: Task<Void, Never>?
  /// Bumped by every jump, so a landing or highlight still waiting for an earlier one is dropped.
  private var jumpRevision = 0
  /// A message newer than the synced history (a push can precede sync): the list waits at the live end and lands on
  /// it when the update that brings it is applied (the table list's `pendingArrivalMessageID`).
  private var pendingArrival: ScrollToMessageRequest?
  /// A return to latest is fetching, and the reader scrolled meanwhile: its last window keeps their place.
  private var latestJumpRunning = false
  private var latestInterrupted = false
  /// A day pill's click is still finding the day's start (older pages can come from the server): the reader scrolling
  /// meanwhile drops it, so a slow fetch never yanks them back later.
  private var dayStartSearching = false

  private func observeChatEvents() {
    let state = ChatsManager.get(for: peerId, chatId: chat.id)
    eventTask = Task { @MainActor [weak self] in
      for await event in state.events {
        guard let self, !isDisposed else { return }
        switch event {
          case .scrollToBottom:
            ChatReadingPlaceStore.shared.clear(for: peerId)
            scrollToLatest()
          case let .scrollToMsg(request):
            focus(request)
        }
      }
    }
  }

  /// A move the reader asked for: it wins over the unread line still being fetched and over any earlier jump.
  private func beginJump() -> Int {
    endUnreadFetch(placesLine: false)
    jumpTask?.cancel()
    jumpTask = nil
    pendingArrival = nil
    latestJumpRunning = false
    latestInterrupted = false
    dayStartSearching = false
    jumpRevision &+= 1
    return jumpRevision
  }

  /// To the newest message, as the table list's `scrollToNewestAvailable`: at the certified live end, or resting at
  /// the newest local message (a send from there, which a window reload could drop), a scroll. A window short of it is
  /// replaced by the latest local window at once; when the cache does not reach the live end either, the server's
  /// latest page is fetched and the list lands on it.
  private func scrollToLatest() {
    let revision = beginJump()
    guard hasPlacedInitialRows else { return }
    let layout = list.timelineLayout
    let nearNewest = layout.isAtBottom || (layout.distanceToNewest.map { $0 <= 44 } ?? false)
    if !chatRows.canLoadNewerFromLocal, chatRows.historyCoverage.isAtCertifiedLiveEnd || nearNewest {
      list.apply(TimelineTransaction(scroll: .latest, timing: .standard, towards: .newer))
      return
    }
    let peer = peerId
    latestJumpRunning = true
    jumpTask = Task { @MainActor [weak self] in
      guard let self else { return }
      await applyLatestWindow(revision)
      guard !isDisposed, jumpRevision == revision, !chatRows.historyCoverage.isAtCertifiedLiveEnd else {
        if jumpRevision == revision { finishLatestJump() }
        return
      }
      // The coordinator retries a failed page; what the cache has by then is shown.
      await MessageHistoryRepairCoordinator.shared.loadLatest(peer: peer)
      guard !isDisposed, jumpRevision == revision else { return }
      await applyLatestWindow(revision)
      if jumpRevision == revision { finishLatestJump() }
    }
  }

  private func finishLatestJump() {
    jumpTask = nil
    latestJumpRunning = false
    latestInterrupted = false
  }

  /// The latest local window, and the list at its newest message (unless the reader took the list meanwhile, or a
  /// newer jump owns it: then only the rows follow the view model).
  private func applyLatestWindow(_ revision: Int) async {
    let loaded = (try? await chatRows.loadLatestWindow()) == true
    guard !isDisposed else { return }
    let current = jumpRevision == revision && !latestInterrupted
    let rowsChanged = loaded && chatRows.syncFromViewModelAfterManualMutation() != .none
    if rowsChanged {
      newWindow()
      pruneRowCaches()
    }
    guard rowsChanged || current else { return }
    list.apply(TimelineTransaction(
      rows: rowsChanged ? chatRows.rows : nil, coverage: coverage(), scroll: current ? .latest : .preserve,
      timing: .standard, arrives: false, towards: .newer
    ))
  }

  /// To a message, as the table list's `scrollToMsgAndHighlight`: when it is loaded and certified, the list goes there;
  /// otherwise history around it is fetched from the server (unless the cache certifies it), its window is loaded and
  /// the list lands on it, or on the nearest message across certified history when it is gone. It flashes once it
  /// lands (`highlightWhenLanded`).
  private func focus(_ request: ScrollToMessageRequest, opening: Bool = false) {
    let revision = beginJump()
    let messageId = request.messageId
    guard messageId > 0, hasPlacedInitialRows, !isDisposed else { return }
    if let target = row(forServerId: messageId), chatRows.historyCoverage.isCertifiedMessage(messageId) {
      land(on: target, request: request, revision: revision, opening: opening)
      return
    }
    let peer = peerId
    let limit = MessagesProgressiveViewModel.defaultInitialLimit()
    jumpTask = Task { @MainActor [weak self] in
      do {
        // Certified history is already in the cache: no round trip.
        var outcome: MessageHistoryRepairCoordinator.Outcome?
        if self?.chatRows.historyCoverage.isCertifiedMessage(messageId) != true {
          outcome = try await MessageHistoryRepairCoordinator.shared.loadAround(
            peer: peer, anchorID: messageId, limit: limit
          )
        }
        guard let self, !Task.isCancelled, !isDisposed, jumpRevision == revision else { return }
        jumpTask = nil
        if chatRows.historyCoverage.isAtCertifiedLiveEnd, messageId > (chatRows.highestPositiveMessageId ?? 0) {
          // A pushed message can precede sync: wait at the live end for the update that delivers it.
          pendingArrival = request
          list.apply(TimelineTransaction(scroll: .latest, timing: .standard, towards: .newer))
          return
        }
        // The fetch filled the gap inside the window shown.
        if let target = row(forServerId: messageId) {
          land(on: target, request: request, revision: revision, opening: opening)
          return
        }
        let towards = direction(to: messageId)
        guard outcome != .empty, chatRows.loadLocalWindowAroundMessage(messageId: messageId, publish: false) else {
          ToastCenter.shared.showError("Could not load that message")
          return
        }
        _ = chatRows.syncFromViewModelAfterManualMutation()
        newWindow()
        pruneRowCaches()
        let shown = nearestDisplayedMessageID(to: messageId)
        guard let shown, let target = row(forServerId: shown) else {
          // The window has neither the message nor a neighbour across certified history: show it near the spot.
          let fallback = nearestRow(to: messageId)
          list.apply(TimelineTransaction(
            rows: chatRows.rows, coverage: coverage(), scroll: fallback.map { .to($0, .center) } ?? .latest,
            timing: .standard, arrives: false, towards: towards
          ))
          ToastCenter.shared.showError("Could not load that message")
          return
        }
        chatRows.setHistoryAnchor(shown)
        // History all along: it comes in with the jump, sliding from the side it lies on.
        list.apply(TimelineTransaction(
          rows: chatRows.rows, coverage: coverage(), scroll: .to(target, .center), timing: .standard, arrives: false,
          towards: towards
        ))
        if shown == messageId {
          highlightWhenLanded(request, revision: revision, delay: opening ? 0.45 : 0.4)
        } else if !(shown < messageId && shown == chatRows.highestPositiveMessageId) {
          // Landing on the newest message below the target is the ordinary latest view, not a detour to announce.
          ToastCenter.shared.showInfo("Message unavailable. Showing nearby history.")
        }
      } catch is CancellationError {
        return
      } catch {
        guard let self, !Task.isCancelled, !isDisposed, jumpRevision == revision else { return }
        jumpTask = nil
        log.error("Failed to load history for message focus", error: error)
        ToastCenter.shared.showError("Could not load that message")
      }
    }
  }

  /// A loaded row: already in full view it flashes where it is, otherwise the list goes there (sliding when it is
  /// far) and it flashes once the motion has mostly landed.
  private func land(on target: RowID, request: ScrollToMessageRequest, revision: Int, opening: Bool) {
    let layout = list.timelineLayout
    let viewport = layout.viewport
    let inView = layout.placement(for: target).map {
      $0.y >= viewport.usableTop - 0.5 && $0.maxY <= viewport.usableBottom + 0.5
    } ?? false
    if !inView {
      list.apply(TimelineTransaction(
        scroll: .to(target, .center), timing: .standard, towards: direction(to: request.messageId)
      ))
    }
    highlightWhenLanded(request, revision: revision, delay: inView ? (opening ? 0.3 : 0) : 0.4)
  }

  /// The loaded message to land on for a server id: itself, or its nearest neighbour (newer first) when the
  /// history between them is certified, so nothing is skipped over (the table list's rule).
  private func nearestDisplayedMessageID(to coordinate: Int64) -> Int64? {
    let ids = messages.lazy.map(\.message.messageId).filter { $0 > 0 }
    if ids.contains(coordinate) { return coordinate }
    let neighbour = ids.filter { $0 > coordinate }.min() ?? ids.filter { $0 < coordinate }.max()
    return neighbour.flatMap {
      chatRows.historyCoverage.isCertifiedContinuation(between: coordinate, and: $0) ? $0 : nil
    }
  }

  /// The side a message lies on from the one at the top of the screen, for a jump to rows that are not near.
  private func direction(to messageId: Int64) -> TimelineEdge? {
    guard let shown = readingAnchor()?.messageId else { return nil }
    return messageId < shown ? .older : .newer
  }

  /// The row showing a message: an album's items share their album's row.
  private func row(forServerId messageId: Int64) -> RowID? {
    messages.first { $0.message.messageId == messageId }
      .flatMap { chatRows.rowIndex(forMessageStableId: $0.id) }
      .flatMap { chatRows.row(at: $0) }
  }

  // MARK: - Highlight

  /// Flashes the message once the list has landed on it (the table list's `highlightMessage`): the row, or the quoted
  /// text when given (a search also flashes the row). A quote out of view in a tall message is brought to the middle
  /// first. Dropped when another jump starts meanwhile.
  private func highlightWhenLanded(_ request: ScrollToMessageRequest, revision: Int, delay: TimeInterval) {
    guard delay > 0 else {
      highlight(request, centersQuote: true)
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
      guard let self, !isDisposed, jumpRevision == revision else { return }
      highlight(request, centersQuote: true)
    }
  }

  private func highlight(_ request: ScrollToMessageRequest, centersQuote: Bool) {
    guard let target = row(forServerId: request.messageId),
          let cell = (list.view(for: target) as? TimelineRowHost)?.content as? MessageTableCell else { return }
    let flashesRow = request.reason == .search
    if centersQuote, let quote = request.quote, let rect = cell.quoteRect(quote, in: list) {
      let viewport = list.timelineLayout.viewport
      if rect.minY < viewport.usableTop || rect.maxY > viewport.usableBottom {
        // Positive moves the content down: the quote's middle to the usable area's middle.
        let delta = (viewport.usableTop + viewport.usableBottom) / 2 - rect.midY
        list.apply(TimelineTransaction(scroll: .by(delta), timing: .standard))
        let revision = jumpRevision
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
          guard let self, !isDisposed, jumpRevision == revision else { return }
          highlight(request, centersQuote: false)
        }
        return
      }
    }
    cell.highlight(quote: request.quote, flashesRow: flashesRow)
  }

  // MARK: - Uncached unread line

  /// Opens a chat whose unread line the cache cannot show as the table list and the iOS timeline do (Telegram's way):
  /// the list stays hidden over its latest messages from the first frame while history around the line is fetched,
  /// with no deadline, then appears placed at the line. Offline, a lost connection, a failed fetch, or the reader
  /// sending or jumping shows the latest messages instead. Either way the list lands once and never re-anchors later.
  private func beginUnreadFetchIfNeeded() {
    guard let boundary = unreadFetchBoundary, unreadFetchTask == nil else { return }
    // Offline, the latest cached messages open as they are, in the first frame.
    guard Api.realtime.stateObject.connectionState != .connecting else {
      unreadFetchBoundary = nil
      list.alphaValue = 1
      return
    }
    list.alphaValue = 0
    let peer = peerId
    unreadFetchTask = Task { @MainActor [weak self] in
      var placesLine = false
      do {
        _ = try await MessageHistoryRepairCoordinator.shared.loadAround(
          peer: peer, anchorID: max(1, boundary), limit: ChatUnreadOpening.windowLimit
        )
        guard let self, unreadFetchBoundary == boundary, !Task.isCancelled else { return }
        placesLine = try await chatRows.loadUnreadOpeningWindow(boundary: boundary)
      } catch {
        if !(error is CancellationError) {
          self?.log.error("Unread history fetch failed; opening at the latest messages", error: error)
        }
      }
      guard let self, unreadFetchBoundary == boundary, !Task.isCancelled else { return }
      endUnreadFetch(placesLine: placesLine)
    }
    // A lost connection would keep the list hidden until it returns.
    unreadFetchConnection = Api.realtime.stateObject.$connectionState
      .sink { [weak self] state in
        guard state == .connecting else { return }
        DispatchQueue.main.async { self?.endUnreadFetch(placesLine: false) }
      }
    // A fast fetch shows the chat before any spinner does.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
      guard let self, unreadFetchBoundary == boundary, !isDisposed, unreadFetchSpinner == nil else { return }
      showUnreadFetchSpinner()
    }
  }

  /// Ends the fetch once: placed at the line when its window loaded, else left at the latest messages, and shown.
  private func endUnreadFetch(placesLine: Bool) {
    guard unreadFetchBoundary != nil, !isDisposed else { return }
    unreadFetchBoundary = nil
    // Cancelling also stops a window read in flight from replacing the rows shown.
    unreadFetchTask?.cancel()
    unreadFetchTask = nil
    unreadFetchConnection = nil
    if let spinner = unreadFetchSpinner {
      unreadFetchSpinner = nil
      spinner.stopAnimation(nil)
      spinner.removeFromSuperview()
    }
    if placesLine {
      _ = chatRows.syncFromViewModelAfterManualMutation()
      newWindow()
      pruneRowCaches()
      // Before the first layout, that layout places the line (`placeInitialRows`).
      if hasPlacedInitialRows {
        let scroll: TimelineScroll<RowID> = chatRows.rows.contains(.unreadSeparator)
          ? .to(.unreadSeparator, .top(8)) : .latest
        list.apply(TimelineTransaction(rows: chatRows.rows, coverage: coverage(), scroll: scroll, arrives: false))
      }
    }
    guard hasPlacedInitialRows else {
      // No frame was drawn yet: the first one shows the list.
      list.alphaValue = 1
      return
    }
    // On the turn after placement, so the first frame shown is settled.
    DispatchQueue.main.async { [weak self] in
      guard let self, !isDisposed else { return }
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.2
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        self.list.animator().alphaValue = 1
      }
      // Nothing was read or reported while the list was hidden.
      reportPlace()
      updateUnreadIfNeeded()
    }
  }

  private func showUnreadFetchSpinner() {
    let spinner = NSProgressIndicator()
    spinner.style = .spinning
    spinner.controlSize = .small
    spinner.isDisplayedWhenStopped = false
    spinner.translatesAutoresizingMaskIntoConstraints = false
    spinner.alphaValue = 0
    view.addSubview(spinner)
    NSLayoutConstraint.activate([
      spinner.centerXAnchor.constraint(equalTo: list.centerXAnchor),
      spinner.centerYAnchor.constraint(equalTo: list.centerYAnchor),
    ])
    spinner.startAnimation(nil)
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.2
      spinner.animator().alphaValue = 1
    }
    unreadFetchSpinner = spinner
  }

  // MARK: - Layout and insets

  override func viewDidLayout() {
    super.viewDidLayout()
    rootDidLayout()
  }

  override func viewDidAppear() {
    super.viewDidAppear()
    view.needsLayout = true
    rootDidLayout()
  }

  /// Places the rows in the first layout that gives the list a size, window or not (a chat switch can lay the new
  /// view out before it joins the window: waiting for the window cost the first frame). Without a window the
  /// toolbar's height is the standard one; the next pass corrects the insets, keeping the reading row.
  private func rootDidLayout() {
    noteWidthChange()
    if let window = view.window {
      let chrome = window.frame.height - window.contentLayoutRect.height
      if abs(chrome - toolbarHeight) > 0.5 || !hasMeasuredChrome {
        hasMeasuredChrome = true
        toolbarHeight = chrome
        toolbarBackground.isHidden = chrome < 1
        for constraint in toolbarBackground.constraints where constraint.firstAttribute == .height {
          constraint.constant = chrome
        }
        pinnedHeaderTopConstraint?.constant = chrome + additionalTopContentInset
      }
    }
    updateColumn()
    if !hasPlacedInitialRows {
      guard list.bounds.width > 0, list.bounds.height > 0 else { return }
      hasPlacedInitialRows = true
      placeInitialRows()
    } else {
      list.setInsets(top: topInset, bottom: bottomInset)
    }
  }

  private var hasMeasuredChrome = false

  private var topInset: CGFloat {
    toolbarHeight + additionalTopContentInset + topOverlayHeight + visiblePinnedHeaderHeight
  }
  private var bottomInset: CGFloat { Theme.messageListBottomInset + (composeInsetShown ?? composeInset) }

  private func updateColumn() {
    let constant = cellWidth(view.bounds.width)
    if let columnWidth, abs(columnWidth.constant - constant) > 0.25 { columnWidth.constant = constant }
  }

  /// The first frame, where the preloader decided with the rows: a message asked for (search, a link), the saved
  /// reading place, the unread line, or the newest message. In history, the view model's anchor is set with it, so
  /// the first reload stays there.
  private func placeInitialRows() {
    let ids = chatRows.rows
    var scroll: TimelineScroll<RowID> = .latest
    var anchor: Int64?
    if let target = initialTargetMessageId, let found = row(forServerId: target) {
      scroll = .to(found, .center)
      anchor = target
    } else if case let .saved(place) = openAnchor, let found = row(forServerId: place.messageId) {
      scroll = .to(found, .top(place.offset))
      anchor = place.messageId
    } else if showUnreadAfter != nil, let unread = ids.firstIndex(of: .unreadSeparator) {
      scroll = .to(ids[unread], .top(8))
    }
    if let anchor { chatRows.setHistoryAnchor(anchor) }
    list.apply(TimelineTransaction(
      rows: ids, coverage: coverage(), scroll: scroll, topInset: topInset, bottomInset: bottomInset
    ))
    // The messages the chat opened with, translated and analysed after the opening frames.
    scheduleTranslationWork(messages: messages, analyzeForDetection: true)
    scheduleMediaWarmup()
    // The chat navigation's measured span ends after the first layout, as the table list ends it.
    DispatchQueue.main.async { [weak self] in
      guard let self, !isDisposed else { return }
      dependencies.nav2?.endChatNavigationSignpost(peer: peerId, reason: "first_message_layout")
      dependencies.nav3?.endChatNavigationSignpost(peer: peerId, reason: "first_message_layout")
      // The message asked for flashes where the first frame placed it; one the window lacks is fetched and the list
      // goes there (the table list's `focusInitialTargetIfNeeded`).
      if let target = initialTargetMessageId {
        focus(ScrollToMessageRequest(messageId: target, reason: .link), opening: true)
      }
    }
  }

  // MARK: - Reading place

  /// Tells the view model where the reader is, as the iOS timeline and the table list do: at the live end, or the
  /// newest message on screen. Reloads (a history page, sync catching up, streamed edits) then keep this part of
  /// history instead of replacing the window with the latest messages, which put the list back at the bottom.
  private func reportPlace() {
    // Hidden over the latest rows for the unread fetch, the list is not where the reader is.
    guard hasPlacedInitialRows, !isDisposed, unreadFetchBoundary == nil else { return }
    let layout = list.timelineLayout
    let atBottom = layout.isAtBottom && chatRows.historyCoverage.isAtCertifiedLiveEnd
    var messageId: Int64?
    if !atBottom {
      for placement in layout.visible.reversed() {
        guard let found = message(for: placement.id) else { continue }
        // An album's newest item, so a reload around this place keeps the whole album.
        let newest = chatRows.album(forStableId: found.message.id)?.items.last ?? found.message
        if newest.message.messageId > 0 {
          messageId = newest.message.messageId
          break
        }
      }
    }
    if let reportedPlace, reportedPlace.atBottom == atBottom, reportedPlace.messageId == messageId { return }
    reportedPlace = (atBottom, messageId)
    chatRows.setAtBottom(atBottom)
    if let messageId { chatRows.setHistoryAnchor(messageId) }
  }

  /// Saves where the reader stopped when the newest message is off screen, clears it when it is on screen (the
  /// table list's rule); the next open lands there.
  private func saveReadingPlace() {
    guard hasPlacedInitialRows, !isDisposed, !list.isMoving, unreadFetchBoundary == nil else { return }
    let layout = list.timelineLayout
    let viewport = layout.viewport
    let store = ChatReadingPlaceStore.shared
    let lastMessage = layout.placements.last { if case .message = $0.id { true } else { false } }
    let newestShown = chatRows.historyCoverage.isAtCertifiedLiveEnd
      && (lastMessage.map { $0.y < viewport.usableBottom } ?? true)
      && lastMessage?.id == chatRows.rows.last { if case .message = $0 { true } else { false } }
    if newestShown {
      store.clear(for: peerId)
      return
    }
    for placement in layout.placements where placement.maxY > viewport.usableTop {
      guard case .message = placement.id, let found = message(for: placement.id), found.message.message.messageId > 0
      else { continue }
      store.save(ChatReadingPlace(messageId: found.message.message.messageId, offset: placement.y - viewport.usableTop), for: peerId)
      return
    }
  }

  // MARK: - Unread

  private var activeObserver: NSObjectProtocol?
  private var menuObserver: NSObjectProtocol?
  /// The newest message read through, once at the live end (a list resting there reads nothing new).
  private var readAllThrough: Int64?
  /// The newest incoming message on screen last reported, so a scroll back down does not report it again.
  private var lastVisibleRead: Int64 = 0

  private func updateUnreadIfNeeded() {
    guard hasPlacedInitialRows, !isDisposed, unreadFetchBoundary == nil, AppActivityMonitor.shared.isActive, isViewLoaded,
          let window = view.window, window.isVisible, !view.isHiddenOrHasHiddenAncestor
    else { return }
    let layout = list.timelineLayout
    // Resting on (or within 44 pt of) the newest message of the certified live end, as the table list's follow zone.
    let nearNewest = layout.isAtBottom || (layout.distanceToNewest.map { $0 <= 44 } ?? false)
    if nearNewest, chatRows.historyCoverage.isAtCertifiedLiveEnd {
      let newest = messages.last?.message.messageId ?? 0
      if readAllThrough != newest {
        readAllThrough = newest
        UnreadManager.shared.readAll(peerId, chatId: chat.id)
      }
      reportVisibleActivity()
      return
    }
    reportVisibleActivity()
    guard let highest = highestVisibleIncomingMessageID(in: layout), highest > lastVisibleRead else { return }
    lastVisibleRead = highest
    UnreadManager.shared.readVisible(peerId: peerId, chatId: chat.id, highestVisibleIncomingID: highest)
    if highest > unreadCountReadFrontier {
      unreadCountReadFrontier = highest
      updateScrollToBottomCount()
    }
  }

  /// The newest message someone else sent among the rows in the usable area (not under the toolbar or the composer);
  /// an album reads through its newest item.
  private func highestVisibleIncomingMessageID(in layout: TimelineLayout<RowID>) -> Int64? {
    let viewport = layout.viewport
    return layout.placements.compactMap { placement -> Int64? in
      guard placement.maxY > viewport.usableTop, placement.y < viewport.usableBottom,
            let found = message(for: placement.id)
      else { return nil }
      let newest = chatRows.album(forStableId: found.message.id)?.items.last ?? found.message
      guard newest.message.messageId > 0, newest.message.out != true else { return nil }
      return newest.message.messageId
    }.max()
  }

  /// Real ends only, as the iOS timeline's feed reports them: the oldest end once nothing older is local and the
  /// history there is certified; the newest at the certified live end.
  private func coverage() -> TimelineCoverage {
    let history = chatRows.historyCoverage
    return TimelineCoverage(
      reachesOldest: !chatRows.canLoadOlderFromLocal && history.hasCertifiedOlderEdge,
      reachesNewest: history.isAtCertifiedLiveEnd
    )
  }

  /// A new window has new edges.
  private func newWindow() {
    windowGeneration &+= 1
    blockedEdges.removeAll()
  }

  // MARK: - Data

  private static func traceLabel(_ update: MessagesProgressiveViewModel.MessagesChangeSet) -> String {
    switch update {
      case .added: "added"
      case .updated: "updated"
      case .deleted: "deleted"
      case .reload: "reload"
    }
  }

  private func apply(_ update: MessagesProgressiveViewModel.MessagesChangeSet) {
    guard !isDisposed, isViewLoaded else { return }
    // The same span as the table list's, so traces compare the two lists.
    let span = PerformanceTrace.begin(
      "MacMessagesApplyUpdate", category: .messages,
      "type=\(Self.traceLabel(update)) rows=\(chatRows.rows.count) messages=\(messages.count) list=timeline"
    )
    defer { span.end() }
    let before = hasPlacedInitialRows ? readingAnchor() : nil
    // streaming: an edit that extends a placed message's text streams; the pacer is fed before the row is planned.
    let streamedTexts = streamTexts(before: update)
    let kind = chatRows.apply(update)
    feedStreams(update, oldTexts: streamedTexts)
    var changed: Set<RowID> = []
    var timing: TimelineTiming = .none
    var arrives = false
    var scroll: TimelineScroll<RowID> = .preserve
    switch kind {
      case .none:
        // Rows the same, history maybe not: an end can open or close.
        let coverage = coverage()
        if hasPlacedInitialRows, coverage != lastCoverage {
          lastCoverage = coverage
          list.apply(TimelineTransaction(coverage: coverage))
        }
        return
      case let .reloadRows(indexes):
        for index in indexes {
          guard let row = chatRows.row(at: index) else { continue }
          changed.insert(row)
          if let id = chatRows.messageStableId(forRow: index) { revisions[id, default: 0] += 1 }
        }
        timing = .standard
        if followsNewest(kind, update) { scroll = .latest }
      case .insert, .remove:
        timing = .standard
        if case .added = update { arrives = true }
        if followsNewest(kind, update) { scroll = .latest }
      case .reloadAll:
        heights.removeAll(keepingCapacity: true)
        newWindow()
        // A window replaced around the reader keeps a row on screen and the list keeps it; one replaced elsewhere
        // keeps none, and the list would fall back to the newest message: land on the nearest message instead.
        if let before, !before.atBottom {
          let rows = Set(chatRows.rows)
          if !list.timelineLayout.visible.contains(where: { rows.contains($0.id) }), let nearest = nearestRow(to: before.messageId) {
            scroll = .to(nearest, .top(before.offset))
          }
        }
    }
    if case let .updated(_, _, animated) = update, animated == false { timing = .none }
    guard hasPlacedInitialRows else { return }
    // A message jumped to before it synced arrived, however it came: the list goes to it.
    var landed: ScrollToMessageRequest?
    if let request = pendingArrival, let target = row(forServerId: request.messageId) {
      pendingArrival = nil
      landed = request
      scroll = .to(target, .center)
      if !timing.isAnimated { timing = .standard }
    }
    list.apply(TimelineTransaction(
      rows: chatRows.rows, coverage: coverage(), scroll: scroll, changed: changed, timing: timing, arrives: arrives
    ))
    if let landed { highlightWhenLanded(landed, revision: jumpRevision, delay: 0.4) }
    pruneMessageSelection() // selection
    textSelection.setNeedsRefresh() // selection
    // New rows near the screen (a page, an arrival) get their media ready; a moving list does it when it rests.
    if !list.isMoving {
      scheduleMediaWarmup()
      scheduleMessageHoverRefresh()
    }
  }

  /// A reader resting on the newest row the window has stays on it, certified as the live end or not. The engine
  /// pins a list resting there again only at the certified live end (a loaded end's newest row must not be pulled to
  /// the end of a page landing below it), so between the open and the server's latest page, or offline, an arrival
  /// landed under the composer. The window's newest row there is still the newest message we have, and an arrival
  /// is new, not a page: the view model appends a realtime arrival only to a window that ends at the newest local
  /// message (`applyChanges`). So: an arrival that becomes the newest row is followed from the 44 pt follow zone (as
  /// the table list and the iOS timeline follow); a row changing or leaving keeps a list resting exactly on the
  /// newest row. History pages and reloads (`.reload`) never move it; at the certified live end, exactly on the newest
  /// row, the engine's own pin does it.
  private func followsNewest(
    _ kind: ChatRowListViewModel.UpdateKind, _ update: MessagesProgressiveViewModel.MessagesChangeSet
  ) -> Bool {
    let layout = list.timelineLayout
    guard hasPlacedInitialRows, !list.isTracking, !list.isFlinging, abs(layout.restShift) <= 0.5,
          !layout.placements.isEmpty
    else { return false }
    let certified = coverage().reachesNewest
    switch kind {
      case let .insert(indexes):
        guard case .added = update,
              let newest = chatRows.rows.lastIndex(where: { if case .message = $0 { true } else { false } }),
              indexes.contains(newest)
        else { return false }
        if layout.isAtBottom { return !certified }
        return layout.distanceToNewest.map { $0 <= 44 } ?? false
      case .reloadRows, .remove:
        return !certified && layout.isAtBottom
      case .none, .reloadAll:
        return false
    }
  }

  /// The top message on screen with a server id, its distance below the usable top, and whether the list is at the
  /// newest message.
  private func readingAnchor() -> (messageId: Int64, offset: CGFloat, atBottom: Bool)? {
    let layout = list.timelineLayout
    for placement in layout.visible {
      guard let found = message(for: placement.id), found.message.message.messageId > 0 else { continue }
      return (found.message.message.messageId, placement.y - layout.viewport.usableTop, layout.isAtBottom)
    }
    return nil
  }

  /// The row of the loaded message nearest to a server id.
  private func nearestRow(to messageId: Int64) -> RowID? {
    let nearest = messages.filter { $0.message.messageId > 0 }.min {
      abs($0.message.messageId - messageId) < abs($1.message.messageId - messageId)
    }
    return nearest.flatMap { chatRows.rowIndex(forMessageStableId: $0.id) }.flatMap { chatRows.row(at: $0) }
  }

  /// Server pages fetched ahead of the reader (`prefetchRemoteIfLocalRanOut`).
  private var remotePrefetches: [TimelineEdge: Task<Void, Never>] = [:]

  private func handleDemand(_ edges: Set<TimelineEdge>) {
    // Hidden over the latest rows while the unread line's history is fetched: that window is about to be replaced.
    guard unreadFetchBoundary == nil else { return }
    for edge in [TimelineEdge.older, .newer] where edges.contains(edge) { loadHistory(edge) }
  }

  /// One page at an edge: from the database when it has the messages, else from the server first (older or newer),
  /// then from the database. A page that failed or brought nothing blocks the edge for this window. Ported from the
  /// iOS timeline's `loadHistory`.
  private func loadHistory(_ edge: TimelineEdge) {
    // A trim rereads the window's metadata: a page waits for it (the trim's own transaction asks again).
    guard !isDisposed, !loadingEdges.contains(edge), !blockedEdges.contains(edge), trimTask == nil else { return }
    loadingEdges.insert(edge)
    let generation = windowGeneration
    historyTasks[edge] = Task { @MainActor [weak self] in
      guard let self else { return }
      var blocks = false
      defer {
        loadingEdges.remove(edge)
        historyTasks[edge] = nil
        if !Task.isCancelled, !isDisposed {
          if blocks, windowGeneration == generation { blockedEdges.insert(edge) }
          // The page's own transaction asked for more while this edge was still loading: ask again now, so a page
          // that leaves the list near the edge brings the next one without waiting for the reader to scroll.
          if !blocks { list.apply(TimelineTransaction(coverage: coverage())) }
        }
      }
      let direction: MessagesProgressiveViewModel.MessagesLoadDirection = edge == .older ? .older : .newer
      let local = edge == .older ? chatRows.canLoadOlderFromLocal : chatRows.canLoadNewerFromLocal
      var allowUnavailableLocal = !local
      var fetchesRemote = !local
      #if DEBUG
      // The perf harness has no server: its seeded history is all there is.
      if PerfHarnessFixture.isRequested {
        allowUnavailableLocal = true
        fetchesRemote = false
      }
      #endif
      if fetchesRemote {
        let boundary = edge == .older ? chatRows.messages.first?.message.messageId : chatRows.messages.last?.message.messageId
        guard let boundary, boundary > 0 else {
          blocks = true
          return
        }
        do {
          let outcome = edge == .older
            ? try await MessageHistoryRepairCoordinator.shared.loadOlder(peer: peerId, beforeID: boundary)
            : try await MessageHistoryRepairCoordinator.shared.loadNewer(peer: peerId, afterID: boundary)
          if outcome == .empty {
            blocks = true
            return
          }
        } catch is CancellationError {
          return
        } catch {
          log.error("Failed to load \(edge == .older ? "older" : "newer") messages", error: error)
          blocks = true
          return
        }
      }
      guard !Task.isCancelled, !isDisposed else { return }
      let loaded = await chatRows.loadBatchAsync(at: direction, publish: false, allowUnavailableLocal: allowUnavailableLocal)
      guard !Task.isCancelled, !isDisposed else { return }
      let rowUpdate = loaded ? chatRows.syncFromViewModelAfterManualMutation() : .none
      guard loaded, rowUpdate != .none else {
        blocks = true
        return
      }
      // History was there all along: it comes in with the scroll, nothing on screen moves.
      list.apply(TimelineTransaction(rows: chatRows.rows, coverage: coverage(), arrives: false))
      trimWindow(keeping: edge)
      prefetchRemoteIfLocalRanOut(edge)
    }
  }

  /// The database has nothing past the page just loaded: the server's next page is fetched now, in the background,
  /// while the reader still has this page to scroll through, so the next demand finds it local. Fetched only when the
  /// reader got there before, one page at a time, it arrived after a fling had run past the loaded top (Mo, 2026-11-27:
  /// "load more still doesn't seem to kick in quick enough, i frequently get stuck at top").
  private func prefetchRemoteIfLocalRanOut(_ edge: TimelineEdge) {
    #if DEBUG
    if PerfHarnessFixture.isRequested { return }
    #endif
    guard !isDisposed, remotePrefetches[edge] == nil, !blockedEdges.contains(edge) else { return }
    let ranOut = edge == .older ? !chatRows.canLoadOlderFromLocal : !chatRows.canLoadNewerFromLocal
    let reachesEnd = edge == .older ? coverage().reachesOldest : coverage().reachesNewest
    guard ranOut, !reachesEnd else { return }
    let boundary = edge == .older ? chatRows.messages.first?.message.messageId : chatRows.messages.last?.message.messageId
    guard let boundary, boundary > 0 else { return }
    let peer = peerId
    remotePrefetches[edge] = Task { @MainActor [weak self] in
      defer { self?.remotePrefetches[edge] = nil }
      do {
        _ = edge == .older
          ? try await MessageHistoryRepairCoordinator.shared.loadOlder(peer: peer, beforeID: boundary)
          : try await MessageHistoryRepairCoordinator.shared.loadNewer(peer: peer, afterID: boundary)
      } catch {
        // The demand path fetches again when the reader gets there.
      }
    }
  }

  /// After a page, a long window's far side leaves (the view model keeps about `maximumWindowMessages`), so paging
  /// through a long chat keeps planning, heights and memory bounded, as the iOS timeline's `trimWindow`. Never while
  /// the list moves, the other edge loads or a jump or the unread fetch owns the window: then it waits for the list to
  /// rest (`onScrollEnded`). Never cuts a row that is placed: the reader is not near the far side.
  private func trimWindow(keeping edge: TimelineEdge) {
    guard !isDisposed, hasPlacedInitialRows else { return }
    let model = chatRows.progressiveViewModel
    let maximum = MessagesProgressiveViewModel.maximumWindowMessages
    let step = MessagesProgressiveViewModel.windowTrimStep
    let count = model.messages.count
    guard count > maximum else {
      pendingTrimEdge = nil
      return
    }
    guard !list.isMoving, loadingEdges.subtracting([edge]).isEmpty, trimTask == nil, jumpTask == nil,
          unreadFetchBoundary == nil
    else {
      pendingTrimEdge = edge
      return
    }
    pendingTrimEdge = nil
    // The messages the view model would cut (its own rule): none of them may be placed.
    let removing = ((count - maximum + step - 1) / step) * step
    guard removing > 0, removing < count else { return }
    let chronological = model.reversed ? Array(model.messages.reversed()) : model.messages
    let cut = Set((edge == .older ? chronological.suffix(removing) : chronological.prefix(removing)).map(\.id))
    for placement in list.timelineLayout.placements {
      guard let found = message(for: placement.id) else { continue }
      let items = chatRows.album(forStableId: found.message.id)?.items ?? [found.message]
      if items.contains(where: { cut.contains($0.id) }) { return }
    }
    let generation = windowGeneration
    trimTask = Task { @MainActor [weak self] in
      guard let self else { return }
      let trimmed = await model.trimWindow(keeping: edge == .older ? .older : .newer)
      trimTask = nil
      guard !isDisposed else { return }
      // The view model's window changed either way when it trimmed; rows follow it.
      let rowUpdate = trimmed ? chatRows.syncFromViewModelAfterManualMutation() : .none
      if rowUpdate != .none {
        pruneRowCaches()
        // The trimmed side can page back in from the database.
        if windowGeneration == generation { blockedEdges.remove(edge == .older ? .newer : .older) }
      }
      // Also asks for pages again, which waited for the trim.
      list.apply(TimelineTransaction(rows: rowUpdate != .none ? chatRows.rows : nil, coverage: coverage(), arrives: false))
    }
  }

  /// Drops cached heights and revisions of rows no longer in the window, so a long session stays bounded.
  private func pruneRowCaches() {
    let rows = Set(chatRows.rows)
    heights = heights.filter { rows.contains($0.key) }
    previousPlans = previousPlans.filter { rows.contains($0.key) }
    let ids = Set(messages.map(\.id))
    revisions = revisions.filter { ids.contains($0.key) }
  }

  // MARK: - Rows

  private var messages: [FullMessage] { chatRows.messages }

  private func message(for id: RowID) -> (message: FullMessage, index: Int)? {
    switch id {
      case let .message(stableId), let .parentMessage(stableId):
        guard let index = chatRows.messageIndex(forStableMessageId: stableId), messages.indices.contains(index) else {
          if let anchor = chatRows.threadAnchor, anchor.id == stableId { return (anchor, -1) }
          return nil
        }
        return (messages[index], index)
      default:
        return nil
    }
  }

  private func canGroup(_ earlier: FullMessage, _ later: FullMessage) -> Bool {
    guard !earlier.message.isServiceMessage, !later.message.isServiceMessage else { return false }
    guard earlier.message.fromId == later.message.fromId else { return false }
    guard earlier.message.via == later.message.via else { return false }
    guard later.message.date.timeIntervalSince(earlier.message.date) <= 300 else { return false }
    return Calendar.current.isDate(earlier.message.date, inSameDayAs: later.message.date)
  }

  private func inputProps(for id: RowID) -> MessageViewInputProps? {
    guard let (message, index) = message(for: id) else { return nil }
    let isRTL = message.displayText.flatMap { BlockContentDirection.isRTL($0) } ?? false
    if case .parentMessage = id {
      return MessageViewInputProps(
        firstInGroup: true, lastInGroup: true, startsAfterDaySeparator: false, isLastMessage: true,
        isFirstMessage: true, isDM: false, isRtl: isRTL, translated: message.isTranslated, renderStyle: renderStyle,
        interactionMode: .threadAnchor, replyThreadTitle: message.threadCardTitle
      )
    }
    let album = chatRows.album(forStableId: message.id)
    let newestIndex = album.flatMap { chatRows.messageIndex(forStableMessageId: $0.newest.id) } ?? index
    let rowIndex = chatRows.rowIndex(forMessageStableId: message.id)
    var afterDay = false
    if let rowIndex, rowIndex > 0, case .daySeparator? = chatRows.row(at: rowIndex - 1) { afterDay = true }
    return MessageViewInputProps(
      firstInGroup: index <= 0 || !canGroup(messages[index - 1], message),
      lastInGroup: newestIndex >= messages.count - 1 || !canGroup(messages[newestIndex], messages[newestIndex + 1]),
      startsAfterDaySeparator: afterDay,
      isLastMessage: newestIndex == messages.count - 1,
      isFirstMessage: index == 0,
      isDM: chat.type == .privateChat,
      isRtl: isRTL,
      translated: message.isTranslated,
      renderStyle: renderStyle,
      interactionMode: .normal,
      replyThreadTitle: message.threadCardTitle,
      album: album
    )
  }

  private func propsKey(_ props: MessageViewInputProps) -> Int {
    var hasher = Hasher()
    hasher.combine(props.firstInGroup)
    hasher.combine(props.lastInGroup)
    hasher.combine(props.startsAfterDaySeparator)
    hasher.combine(props.isLastMessage)
    hasher.combine(props.isFirstMessage)
    hasher.combine(props.translated)
    hasher.combine(props.albumSignature)
    // Text laid out with other fonts (a text-size change) is another plan.
    hasher.combine(typographyRevision)
    return hasher.finalize()
  }

  // MARK: - Re-measuring

  /// Coalesces bursts (a dragged size slider, a held shortcut) into one re-plan per run loop turn.
  private var typographyReloadScheduled = false
  /// The fonts' revision the plans are made with (`ChatTypography.current` takes a lock; height keys are hashed on
  /// every frame of a scroll).
  private var typographyRevision = ChatTypography.current.revision

  @objc private func chatTypographyDidChange(_: Notification) {
    guard !typographyReloadScheduled else { return }
    typographyReloadScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      typographyReloadScheduled = false
      replanForTypographyChange()
    }
  }

  /// Every row is planned again with the new fonts: the typography revision is part of the height key, so no row
  /// keeps text laid out with the previous font. Rows on screen re-measure now (the list
  /// keeps the reading place, bottom first), the others when they are placed.
  private func replanForTypographyChange() {
    typographyRevision = ChatTypography.current.revision
    guard !isDisposed, hasPlacedInitialRows else { return }
    derivedRevision = (-1, -1)
    validateDerivedCaches()
    heights.removeAll(keepingCapacity: true)
    list.apply(TimelineTransaction(changed: Set(list.placedViews.map(\.0))))
  }

  /// A rich block of a message expanded, collapsed or changed its own layout: that message's rows are planned
  /// again. A disclosure toggle applies at once (a header moving under the pointer between mouse-down and mouse-up
  /// loses the next quick click), other changes animate with the row.
  @objc private func richBlockLayoutStateDidChange(_ notification: Notification) {
    guard !isDisposed, hasPlacedInitialRows,
          let stableId = notification.userInfo?["messageStableID"] as? Int64, stableId != 0
    else { return }
    let rows = Set(chatRows.rows.filter {
      switch $0 {
        case let .message(id), let .parentMessage(id): id == stableId
        default: false
      }
    })
    guard !rows.isEmpty else { return }
    revisions[stableId, default: 0] += 1
    let isDisclosureToggle = notification.object is RichBlockLocalStateStore
    let animate = !isDisclosureToggle && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    // A disclosure opened or closed by the reader: the message keeps its top where it shows, so the group's header
    // (what was clicked) stays put and its content grows downward (Mo, 2026-11-27: the reading anchor kept the bottom
    // and pushed the group's start up, off the screen).
    let layout = list.timelineLayout
    if isDisclosureToggle, let placement = layout.placements.first(where: { rows.contains($0.id) }) {
      let top = (list.presentedFrame(for: placement.id)?.minY ?? placement.y) - layout.viewport.usableTop
      list.apply(TimelineTransaction(scroll: .to(placement.id, .top(top)), changed: rows, timing: .none))
      return
    }
    list.apply(TimelineTransaction(changed: rows, timing: animate ? .standard : .none))
  }

  /// The width a message is measured and drawn at: the list's, or the centred column's.
  private func cellWidth(_ width: CGFloat) -> CGFloat {
    ceil(maximumContentWidth.map { min($0, width) } ?? width)
  }

  private func plan(for message: FullMessage, props: MessageViewInputProps, width: CGFloat) -> MessageSizeCalculator.LayoutPlans {
    // selection: the checkbox column takes its room from the message.
    let width = showsForwardSelection ? width - MessageTableCell.forwardSelectionInset : width
    let measured = props.album?.bubbleMessage ?? message
    if measured.message.isServiceMessage {
      return sizeCalculator.calculateServiceSize(for: measured, with: props, tableWidth: width).3
    }
    switch props.renderStyle {
      case .bubble: return sizeCalculator.calculateBubbleSize(for: measured, with: props, tableWidth: width).3
      case .minimal: return sizeCalculator.calculateMinimalSize(for: measured, with: props, tableWidth: width).3
    }
  }

  private func height(of id: RowID, width: CGFloat) -> CGFloat {
    switch id {
      case .daySeparator: return TimelineDayRowView.height
      case .unreadSeparator, .repliesSeparator: return UnreadSeparatorTableCell.height
      case .collapsedHistory: return CollapsedHistoryTableCell.height
      case .statusNotice: return StatusNoticeTableCell.height
      case .message, .parentMessage:
        return messagePlan(id, column: cellWidth(width))?.plan.totalHeight ?? 0
    }
  }

  /// A message row's inputs and layout plan at a column width, from the cache when its key still matches.
  private func messagePlan(
    _ id: RowID, column: CGFloat
  ) -> (inputs: MessageViewInputProps, message: FullMessage, index: Int, plan: MessageSizeCalculator.LayoutPlans)? {
    guard let inputs = cachedInputProps(for: id), let (message, index) = message(for: id) else { return nil }
    let stableId: Int64
    switch id {
      case let .message(value), let .parentMessage(value): stableId = value
      default: return nil
    }
    let key = HeightKey(width: column, props: propsKey(inputs), revision: revisions[stableId] ?? 0)
    if let cached = heights[id], cached.key == key { return (inputs, message, index, cached.plan) }
    // The plan before the last width change: a resize step asks for both widths (the reading passage maps from the
    // old one), and one plan per row re-planned an 80k-character message twice a step.
    if let previous = previousPlans[id], previous.key == key {
      previousPlans[id] = heights[id]
      heights[id] = previous
      return (inputs, message, index, previous.plan)
    }
    // A chat opened again: the plan its last list made, when the message, width and props are the same.
    if heights[id] == nil, let archived = Self.planArchive[peerId]?.plans[id], archived.width == column,
       archived.props == key.props, archived.style == renderStyle, archived.selecting == showsForwardSelection,
       archived.content == Self.contentHash(message)
    {
      heights[id] = (key, archived.plan)
      return (inputs, message, index, archived.plan)
    }
    // A very long message keeps its last plan while the width changes, and is planned once at the final width when
    // the resize settles (`replanAfterLiveResize`): re-wrapping 80k characters is ~7–18 ms, at every step of a resize
    // (chat 13274; Mo: "resizing the window with text heavy messages is extremely slow and laggy"). Re-planned every
    // 150 ms instead, it still lost ~500 frames over a resize while reading inside one.
    if isResizing, let current = heights[id], (message.message.text?.utf8.count ?? 0) >= Self.deferredReplanLength {
      liveResizePlans[id] = CACurrentMediaTime()
      return (inputs, message, index, current.plan)
    }
    let planStart = CACurrentMediaTime()
    let layout = plan(for: message, props: inputs, width: column)
    Self.planSeconds += CACurrentMediaTime() - planStart
    if let current = heights[id], current.key.width != key.width { previousPlans[id] = current }
    heights[id] = (key, layout)
    return (inputs, message, index, layout)
  }

  // MARK: Plans across opens

  /// The plans of the chats closed last (8), so opening one again lays its first rows out without planning them: the
  /// first frame's plans were ~10 ms of a switch (chat-switch notes), made again on every open since plans lived in
  /// the list. Keyed by the message's content (a message edited, reacted to or translated while the chat was closed
  /// plans again), the width and the props.
  private struct ArchivedPlan {
    var content: Int
    var width: CGFloat
    var props: Int
    /// What else plans are made for and the height key leaves out: the style, and the selection's checkbox column.
    var style: MessageRenderStyle
    var selecting: Bool
    var plan: MessageSizeCalculator.LayoutPlans
  }

  private static var planArchive: [Peer: (used: Int, plans: [RowID: ArchivedPlan])] = [:]
  private static var planArchiveClock = 0
  private static let planArchiveChats = 8

  private static func contentHash(_ message: FullMessage) -> Int {
    var hasher = Hasher()
    hasher.combine(message)
    return hasher.finalize()
  }

  /// On leaving: the plans of the rows placed now (the screen and its margins), which a re-open at the saved reading
  /// place shows first; not the whole window (hashing hundreds of messages would add to the switch itself). Streaming
  /// messages are left out: their plans hold a revealed part.
  private func archivePlans() {
    var plans: [RowID: ArchivedPlan] = [:]
    for placement in list.timelineLayout.placements {
      let id = placement.id
      guard let entry = heights[id], let (message, _) = message(for: id),
            !MessageStreamPacer.shared.isStreaming(message.id) else { continue }
      plans[id] = ArchivedPlan(
        content: Self.contentHash(message), width: entry.key.width, props: entry.key.props, style: renderStyle,
        selecting: showsForwardSelection, plan: entry.plan
      )
    }
    guard !plans.isEmpty else { return }
    Self.planArchiveClock += 1
    Self.planArchive[peerId] = (Self.planArchiveClock, plans)
    if Self.planArchive.count > Self.planArchiveChats,
       let oldest = Self.planArchive.min(by: { $0.value.used < $1.value.used })?.key
    {
      Self.planArchive[oldest] = nil
    }
  }

  /// Harness diagnostics (`stream-long`, `open`): time spent making plans and updating placed rows.
  static var planSeconds: CFTimeInterval = 0
  static var updateRowSeconds: CFTimeInterval = 0

  // MARK: Plans ahead of the list

  private var prefetchScheduled = false
  private var lastPlacedFirstIndex = 0
  private var movingTowardsOlder = true
  /// Rows beyond each end of the placed window whose plans are prepared ahead.
  private static let prefetchReach = 80

  /// After a layout: prepare plans for the rows the list may need next, in slices between frames.
  private func schedulePlanPrefetch() {
    // During a live resize every width is gone a frame later and plans are keyed by it: preparing rows ahead re-planned
    // up to 80 rows a step for nothing (a fifth of the list's resize time in the harness). The end of the resize
    // schedules it again.
    guard !prefetchScheduled, !isDisposed, !view.inLiveResize else { return }
    if let first = list.timelineLayout.placements.first {
      if first.index != lastPlacedFirstIndex { movingTowardsOlder = first.index < lastPlacedFirstIndex }
      lastPlacedFirstIndex = first.index
    }
    prefetchScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      prefetchScheduled = false
      prefetchPlans()
    }
  }

  /// One slice: plans for the unprepared message rows nearest the placed window, the side the list moves towards
  /// first; at most 2 ms while it moves (4 ms at rest), then the next slice on the next run-loop turn.
  private func prefetchPlans() {
    guard !isDisposed, hasPlacedInitialRows, let first = list.timelineLayout.placements.first,
          let last = list.timelineLayout.placements.last else { return }
    let rows = chatRows.rows
    let column = cellWidth(list.bounds.width)
    guard column > 0 else { return }
    let budget = list.isMoving ? 0.002 : 0.004
    let start = CACurrentMediaTime()
    for step in 1 ... Self.prefetchReach {
      let ahead = movingTowardsOlder ? first.index - step : last.index + step
      let behind = movingTowardsOlder ? last.index + step : first.index - step
      for index in [ahead, behind] where index >= 0 && index < rows.count {
        let id = rows[index]
        switch id {
          case .message, .parentMessage: break
          default: continue
        }
        if let cached = heights[id], cached.key.width == column { continue }
        _ = messagePlan(id, column: column)
        if CACurrentMediaTime() - start > budget {
          schedulePlanPrefetch()
          return
        }
      }
    }
  }

  /// What a row shows: the kind of cell (its pool key) and, for a message, the inputs and layout plan it is drawn with.
  private struct RowContent {
    struct Message {
      var inputs: MessageViewInputProps
      var message: FullMessage
      var index: Int
      var layout: MessageSizeCalculator.LayoutPlans
    }

    var key: String
    var message: Message?
  }

  private func rowContent(_ id: RowID, column: CGFloat) -> RowContent? {
    switch id {
      case .daySeparator: return RowContent(key: "day")
      case .unreadSeparator, .repliesSeparator: return RowContent(key: "unread")
      case .statusNotice: return RowContent(key: "status")
      case .collapsedHistory: return RowContent(key: "collapsed")
      case .message, .parentMessage:
        guard let (inputs, message, index, layout) = messagePlan(id, column: column) else { return nil }
        return RowContent(
          key: Self.poolKey(renderStyle: inputs.renderStyle, message: message.message, layout: layout),
          message: .init(inputs: inputs, message: message, index: index, layout: layout)
        )
    }
  }

  /// Rows the list let go of, with their cells still inside: most are still in the list's pooled slots, so in the
  /// window. A new row takes one whose cell is of its kind, preferring the one that last showed the same row (the list
  /// then reuses that row's own slot, and `MessageTableCell.configure` returns early for the same message). Pooling
  /// bare cells moved every cell's constraints out of the window's layout engine and back, and ran its appearance and
  /// content-style invalidation again, on every new row.
  private var hostPool: [TimelineRowHost] = []
  private static let hostPoolLimit = 32

  private func takeHost(for id: RowID, key: String) -> TimelineRowHost? {
    let index = hostPool.lastIndex { $0.shownRow == id && $0.poolKey == key }
      ?? hostPool.lastIndex { $0.poolKey == key && $0.superview != nil }
      ?? hostPool.lastIndex { $0.poolKey == key }
    return index.map { hostPool.remove(at: $0) }
  }

  private func makeRow(_ id: RowID, width: CGFloat) -> NSView {
    let content = rowContent(id, column: cellWidth(width))
    let host = content.flatMap { takeHost(for: id, key: $0.key) } ?? TimelineRowHost()
    // Its size before its cell is configured (heights are cached): a cell laid out at 0×0 broke its message view's
    // required constraints when the list laid the new row out.
    let frame = NSRect(x: 0, y: 0, width: width, height: height(of: id, width: width))
    if host.frame != frame { host.frame = frame }
    configureRow(id, host: host, width: width, content: content, animate: false)
    return host
  }

  private func updateRow(_ id: RowID, _ view: NSView, width: CGFloat, timing: TimelineTiming) {
    let updateStart = CACurrentMediaTime()
    defer { Self.updateRowSeconds += CACurrentMediaTime() - updateStart }
    guard let host = view as? TimelineRowHost else { return }
    let content = rowContent(id, column: cellWidth(width))
    // An animated change of the message the row already shows (an edit, a streamed line, a reaction): its insides move
    // to their new frames on the list's timing, as the row itself does, so the bubble grows and shrinks with the row
    // instead of jumping to its new size (its bottom stood 32–34 pt past the row's while a streamed line animated:
    // the message view laid out at once, then ran a 0.15 s group with nothing left to animate). The lab's hosts do
    // the same (`LabChat.update`, case `anim.height-seams`).
    // Any change that keeps the row's cell (a reaction or a reply changes the pool key, and a cell that adds and
    // removes its parts in place stays): views it already had move from where they were; new ones start in place.
    guard timing.isAnimated, case .message = id, host.shownRow == id,
          let cell = host.content as? MessageTableCell
    else {
      configureRow(id, host: host, width: width, content: content, animate: timing.isAnimated)
      return
    }
    let before = Self.insideFrames(of: cell)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    configureRow(id, host: host, width: width, content: content, animate: false)
    if host.content === cell {
      cell.layoutSubtreeIfNeeded()
      Self.trackInsides(of: cell, from: before, timing: timing)
    }
    CATransaction.commit()
  }

  /// The message view and the views in it whose frames an update moves: the bubble, its tail and contents, the text,
  /// the time, reactions and media.
  private static let insideDepth = 3

  private static func insideFrames(of root: NSView) -> [ObjectIdentifier: NSRect] {
    var frames: [ObjectIdentifier: NSRect] = [ObjectIdentifier(root): root.frame]
    // Shown views only: a part kept hidden (reactions with none) has a stale frame, and showing it is an appearance.
    func visit(_ view: NSView, depth: Int) {
      guard depth <= insideDepth else { return }
      for subview in view.subviews where !subview.isHidden {
        frames[ObjectIdentifier(subview)] = subview.frame
        visit(subview, depth: depth + 1)
      }
    }
    visit(root, depth: 1)
    return frames
  }

  /// Additive tracks from each moved view's old frame to its new one (in its superview's coordinates, so a parent's
  /// track and a child's compose).
  /// Harness diagnostics (`measure(bubbleGapOf:)`): inside tracks added so far.
  static var insideTracksAdded = 0
  static var insideTrackedClasses: Set<String> = []

  /// The cell itself is tracked too (`root`): the cell and the message views are unflipped (laid out from their
  /// bottom) inside the flipped host, so with the cell at its new height at once, everything anchored to its bottom
  /// started the row's growth below the row: a streamed line's bubble began 33 pt under its row and slid back up
  /// over the line's 0.15 s. With the cell's height tracked as well the bubble is on its row at every frame, its
  /// bottom held and its top rising with the row's. AppKit rig
  /// (`secret-sauce/.context/labs/2026-11-27-appkit-unflipped-cell-tracks.swift`), a row presented at 200–300 at a
  /// line's start: today's tracks put the bubble at 269–329, with the cell tracked at 236–296 (exact).
  private static func trackInsides(of root: NSView, from before: [ObjectIdentifier: NSRect], timing: TimelineTiming) {
    func track(_ view: NSView, depth: Int) {
      guard let old = before[ObjectIdentifier(view)], let layer = view.layer, !view.isHidden else { return }
      let new = view.frame
      if old != new {
        insideTracksAdded += 1
        #if DEBUG
        insideTrackedClasses.insert("\(type(of: view)) d\(depth) \(Int(old.height))→\(Int(new.height)) y\(Int(old.minY))→\(Int(new.minY))")
        #endif
      }
      if abs(old.minX - new.minX) > 0.25 { layer.addTrack(timing, keyPath: "position.x", from: old.minX - new.minX) }
      if abs(old.minY - new.minY) > 0.25 { layer.addTrack(timing, keyPath: "position.y", from: old.minY - new.minY) }
      if abs(old.width - new.width) > 0.25 {
        layer.addTrack(timing, keyPath: "bounds.size.width", from: old.width - new.width)
      }
      if abs(old.height - new.height) > 0.25 {
        layer.addTrack(timing, keyPath: "bounds.size.height", from: old.height - new.height)
      }
    }
    func visit(_ view: NSView, depth: Int) {
      guard depth <= insideDepth else { return }
      for subview in view.subviews where !subview.isHidden {
        guard before[ObjectIdentifier(subview)] != nil else {
          // A part that appears with this change (reactions, a reply preview, the name) fades in on its timing
          // instead of popping in while the row grows around it; only the outermost new view, so nested parts don't
          // multiply the fade. A rebuilt message view (depth 1) shows at once, as before.
          if depth >= 2 { subview.layer?.addTrack(timing, keyPath: "opacity", from: -1) }
          continue
        }
        track(subview, depth: depth)
        visit(subview, depth: depth + 1)
      }
    }
    track(root, depth: 0)
    visit(root, depth: 1)
  }

  private func recycleRow(_ id: RowID, _ view: NSView) {
    guard let host = view as? TimelineRowHost else { return }
    host.setAvatar(nil)
    guard host.content != nil else { return }
    hostPool.append(host)
    if hostPool.count > Self.hostPoolLimit { hostPool.removeFirst() }
  }

  /// What the list's motion means for a cell: while it moves, images decode off the main thread.
  private var cellScrollState: MessageListScrollState { list.isMoving ? .scrolling : .idle }

  /// Tells the placed cells the list started or stopped moving, as the table list's scroll notification does (the
  /// message views here have no enclosing scroll view to observe).
  private func updateCellScrollState(_ state: MessageListScrollState) {
    for (_, view) in list.placedViews {
      ((view as? TimelineRowHost)?.content as? MessageTableCell)?.setScrollState(state)
    }
  }

  private func configureRow(_ id: RowID, host: TimelineRowHost, width: CGFloat, content: RowContent?, animate: Bool) {
    let column = cellWidth(width)
    let sameRow = host.shownRow == id
    host.shownRow = id
    host.accessibilityMessage = nil
    guard let content else {
      host.setContent(nil, width: column, poolKey: nil)
      return
    }
    // Every cell goes into its host (at the row's size) before it is configured, so it is configured where it is shown.
    switch id {
      case let .daySeparator(dayStart):
        let cell = host.content as? TimelineDayRowView ?? TimelineDayRowView()
        host.setContent(cell, width: column, poolKey: content.key)
        cell.configure(dayStart: dayStart)
        cell.onClick = { [weak self] day in self?.scrollToDayStart(day) }
      case .unreadSeparator, .repliesSeparator:
        let cell = host.content as? UnreadSeparatorTableCell ?? UnreadSeparatorTableCell()
        host.setContent(cell, width: column, poolKey: content.key)
        if case .unreadSeparator = id {
          cell.configure(text: NSLocalizedString("Unread messages", comment: "Unread separator label"))
        } else {
          cell.configure(text: NSLocalizedString("Replies", comment: "Reply thread separator label"), showsBackground: false)
        }
      case .statusNotice:
        let cell = host.content as? StatusNoticeTableCell ?? StatusNoticeTableCell()
        host.setContent(cell, width: column, poolKey: content.key)
        cell.configure(text: chatRows.statusNotice ?? "")
      case .collapsedHistory:
        let cell = host.content as? CollapsedHistoryTableCell ?? CollapsedHistoryTableCell()
        host.setContent(cell, width: column, poolKey: content.key)
        cell.configure { [weak self] in
          Task { @MainActor [weak self] in try? await self?.collapseHistory(maxID: nil) }
        }
      case .message, .parentMessage:
        guard let shown = content.message else {
          host.setContent(nil, width: column, poolKey: nil)
          return
        }
        let inputProps = shown.inputs
        let cell: MessageTableCell
        // The row's own message changing shape (a reaction, a reply preview, the name) keeps its cell: the message views
        // add and remove those parts in place, and `updateRow` then moves what it had to the new layout. Swapped for
        // another kind's cell, the row rebuilt and snapped (and, unflipped in the flipped host, started below the row).
        if let current = host.content as? MessageTableCell, host.poolKey == content.key || sameRow {
          cell = current
        } else {
          // A placed row whose message changed kind (a reaction, a reply): its old cell waits for a row of that kind.
          if let old = host.content as? MessageTableCell, let oldKey = host.poolKey {
            var pool = cellPools[oldKey, default: []]
            if pool.count < 12 {
              pool.append(old)
              cellPools[oldKey] = pool
            }
          }
          cell = cellPools[content.key]?.popLast() ?? MessageTableCell()
        }
        host.setContent(cell, width: column, poolKey: content.key)
        cell.setDependencies(dependencies)
        cell.setAvatarSwipeProvider { [weak self] sourceView in self?.avatar(overlapping: sourceView) }
        let props = MessageViewProps(
          firstInGroup: inputProps.firstInGroup,
          lastInGroup: inputProps.lastInGroup,
          startsAfterDaySeparator: inputProps.startsAfterDaySeparator,
          isLastMessage: inputProps.isLastMessage,
          isFirstMessage: inputProps.isFirstMessage,
          isRtl: inputProps.isRtl,
          isDM: inputProps.isDM,
          renderStyle: inputProps.renderStyle,
          index: shown.index >= 0 ? shown.index : nil,
          translated: inputProps.translated,
          interactionMode: inputProps.interactionMode,
          replyThreadTitle: inputProps.replyThreadTitle,
          usesAvatarOverlay: usesStickyAvatars,
          album: inputProps.album,
          layout: shown.layout
        )
        cell.setScrollState(cellScrollState)
        cell.configure(with: inputProps.album?.bubbleMessage ?? shown.message, props: props, animate: animate)
        host.accessibilityMessage = (
          shown.message.message.out == true
            ? NSLocalizedString("You", comment: "VoiceOver: the sender of your own message")
            : shown.message.senderInfo.map { $0.user.firstName ?? $0.user.displayName } ?? "",
          shown.message.message.date
        )
        cell.setReplyThreadSourceHighlighted(isReplyThreadSource(shown.message), animated: false)
        applyReveal(to: host, stableId: shown.message.id) // streaming
        configureForwardSelection(cell, id: id, animated: animatesSelectionMode) // selection
        if let row = selectionRowIndex(id) { textSelection.cellDidConfigure(cell, row: row) } // selection
    }
  }

  /// The parts that decide a message view's subviews, as the table list's reuse identifier does.
  private static func poolKey(
    renderStyle: MessageRenderStyle, message: Message, layout: MessageSizeCalculator.LayoutPlans
  ) -> String {
    var key = renderStyle == .minimal ? "m" : "b"
    func flag(_ on: Bool, _ code: String) { if on { key += code } }
    flag(message.isServiceMessage, "S")
    flag(renderStyle == .bubble && message.out == true, "O")
    flag(layout.hasName, "n")
    flag(layout.hasAvatar, "a")
    flag(layout.hasReply, "r")
    flag(layout.hasForwardHeader, "f")
    flag(layout.hasPhoto, "p")
    flag(layout.hasVideo, "v")
    flag(layout.hasDocument, "d")
    flag(layout.hasAttachments, "t")
    flag(layout.hasReactions, "x")
    flag(layout.hasReplyThreadSummary, "s")
    flag(layout.hasActionsRows, "k")
    flag(layout.richBlockContent != nil, "B")
    return key
  }

  // MARK: - Passage across widths

  /// Where content inside a tall message sits at another list width, so the list keeps the passage being read at the
  /// usable top through a resize (`TimelineRows.passage`; the engine asks for the tall row straddling the top only,
  /// from the width the resize began at). A plain Core Text body maps the line holding the point to the line holding
  /// the same first character at the new width (the text's top in the row is the same at both widths: what sits above
  /// it doesn't rewrap); what's below the text moves with its end; anything else keeps its share of the row's height.
  /// Mo, 2026-09-26: "preserving a row's pixel offset does not necessarily preserve the passage being read inside a
  /// huge message".
  private func passageOffset(_ id: RowID, _ offset: CGFloat, from: CGFloat, to: CGFloat) -> CGFloat {
    let fromHeight = height(of: id, width: from)
    let toHeight = height(of: id, width: to)
    let share = fromHeight > 0 ? offset / fromHeight * toHeight : offset
    if let rich = richPassageOffset(id, offset, from: from, to: to) { return rich }
    guard let host = list.view(for: id) as? TimelineRowHost,
          let textView = Self.firstView(CoreTextMessageView.self, in: host),
          let glyphs = Self.glyphViews(in: textView).first,
          let fromPlan = messagePlan(id, column: cellWidth(from)), let toPlan = messagePlan(id, column: cellWidth(to)),
          fromPlan.plan.richBlockContent == nil,
          let fromWidth = fromPlan.plan.text?.size.width, let toWidth = toPlan.plan.text?.size.width
    else { return share }
    let text = textView.surfaceText
    guard text.length > 0 else { return share }
    let textTop = glyphs.convert(glyphs.bounds, to: host).minY
    // At the old width: what the view shows now (it is updated after this). Laid out again here, an 80k-character
    // message was typeset twice more on every resize step (its old width was out of the layout cache by then). At the
    // new width: the layout the view makes next, from the same cache.
    let shown = glyphs.textLayout
    let fromLayout = shown.lines.isEmpty
      ? CoreTextMessageText.layout(text, isRtl: fromPlan.inputs.isRtl, width: fromWidth) : shown
    let toLayout = CoreTextMessageText.layout(text, isRtl: toPlan.inputs.isRtl, width: toWidth)
    guard let last = fromLayout.lines.last, let first = toLayout.lines.first else { return share }
    let inText = offset - textTop
    guard inText >= 0 else { return offset }
    guard inText < last.frame.maxY else {
      return offset + ((toLayout.lines.last?.frame.maxY ?? last.frame.maxY) - last.frame.maxY)
    }
    let line = fromLayout.lines.first { $0.frame.maxY > inText } ?? last
    let fraction = line.frame.height > 0 ? (inText - line.frame.minY) / line.frame.height : 0
    let target = toLayout.lines.last { $0.range.location <= line.range.location } ?? first
    return textTop + target.frame.minY + fraction * target.frame.height
  }

  /// A rich body: the innermost block holding the point at the old width, the same block (by its path) at the new one,
  /// and the same share of its height; between blocks, the same distance below the block above. The rich content's
  /// top in the row is the same at both widths (what sits above it doesn't rewrap).
  private func richPassageOffset(_ id: RowID, _ offset: CGFloat, from: CGFloat, to: CGFloat) -> CGFloat? {
    guard let host = list.view(for: id) as? TimelineRowHost, let content = Self.richContent(in: host),
          let fromPlan = messagePlan(id, column: cellWidth(from))?.plan.richBlockContent,
          let toPlan = messagePlan(id, column: cellWidth(to))?.plan.richBlockContent
    else { return nil }
    let top = content.convert(content.bounds, to: host).minY
    let y = offset - top
    guard y >= 0 else { return offset }
    let blocks = fromPlan.nodes
    let holding = blocks.filter { $0.frame.minY <= y && y < $0.frame.maxY }.min { $0.frame.height < $1.frame.height }
    if let holding, let same = toPlan.nodes.first(where: { $0.path == holding.path }) {
      let fraction = holding.frame.height > 0 ? (y - holding.frame.minY) / holding.frame.height : 0
      return top + same.frame.minY + fraction * same.frame.height
    }
    // Between blocks, or past the last: keep the distance below the nearest block above.
    guard let above = blocks.filter({ $0.frame.maxY <= y }).max(by: { $0.frame.maxY < $1.frame.maxY }),
          let same = toPlan.nodes.first(where: { $0.path == above.path })
    else { return nil }
    return top + same.frame.maxY + (y - above.frame.maxY)
  }

  private static func firstView<T: NSView>(_ type: T.Type, in root: NSView) -> T? {
    var stack = [root]
    while let view = stack.popLast() {
      if let match = view as? T { return match }
      stack.append(contentsOf: view.subviews)
    }
    return nil
  }

  // MARK: - Sticky avatars and the floating date

  /// One avatar a sender group, held by the list so it stays beside the group while the group shows (the table list's
  /// overlay). Bubble style: groups from others, on the group's last message, kept to the visible bottom (`.bottom`
  /// mode). Minimal style: every group, on its first message, kept under the visible top and pushed off by the group's
  /// end (`.top` mode, like section headers). The cell leaves its place empty; the row host owns the view, laid out by
  /// frame so the list can move it.
  private var usesStickyAvatars: Bool {
    (renderStyle == .bubble || renderStyle == .minimal) && AppConfig.macMessageAvatarOverlayEnabled
  }

  /// The old overlay's gap under the visible top for minimal style's avatars.
  private static let topAvatarEdgeGap: CGFloat = 8

  private var groupRanges: [Int: ClosedRange<Int>] = [:]
  private var groupRangesRevision = -1

  private func groupRange(containing index: Int) -> ClosedRange<Int> {
    if groupRangesRevision != chatRows.messagesRevision {
      groupRanges.removeAll(keepingCapacity: true)
      groupRangesRevision = chatRows.messagesRevision
    }
    if let cached = groupRanges[index] { return cached }
    var start = index
    while start > messages.startIndex, canGroup(messages[start - 1], messages[start]) { start -= 1 }
    var end = index
    while end < messages.count - 1, canGroup(messages[end], messages[end + 1]) { end += 1 }
    let range = start ... end
    for member in range { groupRanges[member] = range }
    return range
  }

  /// The rows of the sticky-avatar group a message row belongs to, and the message whose sender it shows.
  private func stickyAvatarGroup(for id: RowID) -> (first: RowID, last: RowID, owner: FullMessage)? {
    guard usesStickyAvatars, case .message = id, let (message, index) = message(for: id), index >= 0,
          !message.message.isServiceMessage else { return nil }
    // Bubble style shows avatars on others' messages in groups and channels; minimal style on every group.
    if renderStyle == .bubble, chat.type == .privateChat || message.message.out == true { return nil }
    let range = groupRange(containing: index)
    guard let firstIndex = chatRows.rowIndex(forMessageStableId: messages[range.lowerBound].id),
          let lastIndex = chatRows.rowIndex(forMessageStableId: messages[range.upperBound].id),
          let first = chatRows.row(at: firstIndex), let last = chatRows.row(at: lastIndex) else { return nil }
    return (first, last, messages[renderStyle == .minimal ? range.lowerBound : range.upperBound])
  }

  /// Minimal style: the first row of the group a row is in, kept placed while any of the group shows (it holds the
  /// group's top pin).
  private func stickyAvatarSpanStart(_ id: RowID) -> RowID? {
    guard renderStyle == .minimal, let group = stickyAvatarGroup(for: id) else { return nil }
    return group.first
  }

  /// Minimal style's pin: on the group's first row, where the message view would draw its own avatar (the plan's
  /// wrapper and avatar spacing), held under the visible top until the group's last row pushes it off.
  private func stickyTopAvatarPin(_ id: RowID, host: TimelineRowHost, group: (first: RowID, last: RowID, owner: FullMessage))
    -> TimelinePin<RowID>?
  {
    guard group.first == id, let plan = heights[id]?.plan, let avatarPlan = plan.avatar else {
      host.setAvatar(nil)
      return nil
    }
    let size = avatarPlan.size.height
    let top = plan.wrapper.spacing.top + avatarPlan.spacing.top
    let owner = group.owner
    if host.avatarOwner != owner.id || host.avatar == nil {
      host.avatarOwner = owner.id
      host.setAvatar(
        owner.senderInfo ?? .deleted, viaMark: owner.viaPresentation?.mark, size: size,
        leading: avatarPlan.spacing.left
      ) { [weak self] in
        guard let self, let user = owner.senderInfo?.user else { return }
        self.openSenderProfile(user.id)
      }
    }
    guard let avatar = host.avatar else { return nil }
    return TimelinePin(
      view: avatar, top: top, height: size, spanStart: group.first, spanEnd: group.last, spanBottomInset: 0,
      edgeGap: Self.topAvatarEdgeGap
    )
  }

  private func stickyAvatarPin(_ id: RowID, _ view: NSView) -> TimelinePin<RowID>? {
    guard let host = view as? TimelineRowHost else { return nil }
    if renderStyle == .minimal {
      guard let group = stickyAvatarGroup(for: id) else {
        host.setAvatar(nil)
        return nil
      }
      return stickyTopAvatarPin(id, host: host, group: group)
    }
    guard let group = stickyAvatarGroup(for: id), group.last == id else {
      host.setAvatar(nil)
      return nil
    }
    let owner = group.owner
    if host.avatarOwner == owner.id, let avatar = host.avatar {
      return TimelinePin(
        view: avatar, bottom: host.bounds.height - Theme.messageOuterVerticalPadding, height: Theme.messageAvatarSize,
        spanStart: group.first
      )
    }
    host.avatarOwner = owner.id
    let avatar = host.setAvatar(owner.senderInfo ?? .deleted, viaMark: owner.viaPresentation?.mark) { [weak self] in
      guard let self, let user = owner.senderInfo?.user else { return }
      self.openSenderProfile(user.id)
    }
    guard let avatar else { return nil }
    // At rest: on the group's last bubble, its bottom a message gap above the row's bottom (the overlay's place).
    let size = Theme.messageAvatarSize
    return TimelinePin(
      view: avatar, bottom: host.bounds.height - Theme.messageOuterVerticalPadding, height: size, spanStart: group.first
    )
  }

  /// Bubbles draw a gradient anchored to the window (`MessageViewAppKit.syncContinuousBubbleGradient`), so it moves
  /// with each row's place, as the table list re-synced it on every scroll. Each layout, flights included (the
  /// content's model follows what is shown each frame, a frame's lead at most ahead).
  private func syncBubbleGradients() {
    guard renderStyle == .bubble, hasPlacedInitialRows else { return }
    let span = PerformanceTrace.begin("BubbleGradientSync", category: .messages)
    defer { span.end() }
    for placement in list.timelineLayout.visible {
      ((list.view(for: placement.id) as? TimelineRowHost)?.content as? MessageTableCell)?.reflectBoundsChange(fraction: 0)
    }
  }

  /// The sticky avatar beside a message being swiped to reply, which moves with it: the placed avatar whose place
  /// overlaps the message's height (the group's avatar rests on its last bubble or is pinned to the visible bottom).
  private func avatar(overlapping sourceView: NSView) -> NSView? {
    guard usesStickyAvatars else { return nil }
    let source = sourceView.convert(sourceView.bounds, to: list)
    for (_, view) in list.placedViews {
      guard let avatar = (view as? TimelineRowHost)?.avatar, !avatar.isHidden else { continue }
      let frame = avatar.convert(avatar.bounds, to: list)
      if frame.maxY > source.minY, frame.minY < source.maxY { return avatar }
    }
    return nil
  }

  /// Where a group's span begins in its first row: below the group gap and the sender's name.
  private func stickyAvatarSpanTop(_ id: RowID) -> CGFloat {
    Theme.messageGroupSpacing + Theme.messageOuterVerticalPadding + Theme.messageNameLabelHeight
  }

  /// A click on a day pill: to the day's start, with its day row at the top. The day's first message is found first
  /// (`ChatDayStart`: older history is fetched when a hole lies before the first one cached), then the list goes there
  /// as a jump to a message does: a scroll when it is loaded, otherwise its window is loaded and the screen slides out
  /// as the day slides in from its side (Mo, 2026-11-27: it went only as far up as was loaded).
  private func scrollToDayStart(_ dayStart: Date) {
    let revision = beginJump()
    guard hasPlacedInitialRows, !isDisposed else { return }
    let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
    let peer = peerId
    dayStartSearching = true
    jumpTask = Task { @MainActor [weak self] in
      do {
        let first = try await ChatDayStart.firstMessageId(peer: peer, dayStart: dayStart, dayEnd: dayEnd)
        guard let self, !Task.isCancelled, !isDisposed, jumpRevision == revision else { return }
        jumpTask = nil
        dayStartSearching = false
        guard let first else { return }
        showDay(dayStart, firstMessageId: first)
      } catch is CancellationError {
        return
      } catch {
        guard let self, !Task.isCancelled, !isDisposed, jumpRevision == revision else { return }
        jumpTask = nil
        dayStartSearching = false
        log.error("Failed to find the start of a day", error: error)
      }
    }
  }

  #if DEBUG
  /// The list showing a chat now, for the journey harness's day jumps.
  static weak var journeyCurrent: TimelineMessageListAppKit?
  func journeyJumpToDay(_ dayStart: Date) { scrollToDayStart(dayStart) }
  /// Back to the chat's newest message as the jump-to-latest button goes (a day jump leaves an older window).
  func journeyToLatest() { scrollToLatest() }
  /// The loaded message ids, oldest first (journeys).
  var journeyMessageIds: [Int64] { messages.map(\.message.messageId).filter { $0 > 0 } }
  #endif

  /// The day's row (or its first message's, when the window starts there) at the top of the usable area.
  private func showDay(_ dayStart: Date, firstMessageId: Int64) {
    func dayRow() -> RowID? {
      let day = RowID.daySeparator(dayStart: dayStart)
      return chatRows.rows.contains(day) ? day : row(forServerId: firstMessageId)
    }
    let towards = direction(to: firstMessageId)
    // Loaded: a scroll (the engine slides when it is far). The message is the day's proven first, so a window that
    // starts at it still lands on the day's start; older rows page in as the reader goes up.
    if row(forServerId: firstMessageId) != nil, let target = dayRow() {
      list.apply(TimelineTransaction(scroll: .to(target, .top(0)), timing: .standard, towards: towards))
      return
    }
    guard chatRows.loadLocalWindowAroundMessage(messageId: firstMessageId, publish: false) else { return }
    _ = chatRows.syncFromViewModelAfterManualMutation()
    newWindow()
    pruneRowCaches()
    chatRows.setHistoryAnchor(firstMessageId)
    guard let target = dayRow() else { return }
    // History all along: it comes in with the jump, sliding from the side it lies on.
    list.apply(TimelineTransaction(
      rows: chatRows.rows, coverage: coverage(), scroll: .to(target, .top(0)), timing: .standard, arrives: false,
      towards: towards
    ))
  }

  /// A click on a sender's avatar opens their profile (the table list's message view does the same), not in a DM.
  private func openSenderProfile(_ userId: Int64) {
    guard chat.type != .privateChat else { return }
    dependencies.openChatInfo(peer: .user(id: userId))
  }

  /// The day separator row that opens the day a row is in.
  private func daySection(for id: RowID) -> RowID? {
    validateDerivedCaches()
    if let cached = sectionCache[id] { return cached }
    let section = findDaySection(for: id)
    sectionCache[id] = .some(section)
    return section
  }

  private func findDaySection(for id: RowID) -> RowID? {
    switch id {
      case .daySeparator:
        return id
      case .message, .parentMessage:
        guard let (message, _) = message(for: id) else { return nil }
        return .daySeparator(dayStart: Calendar.autoupdatingCurrent.startOfDay(for: message.message.date))
      default:
        let rows = chatRows.rows
        guard var index = rows.firstIndex(of: id) else { return nil }
        while index >= 0 {
          if case .daySeparator = rows[index] { return rows[index] }
          index -= 1
        }
        return nil
    }
  }

  // MARK: - ChatMessageListController

  var viewModel: MessagesProgressiveViewModel { chatRows.progressiveViewModel }
  var highestPositiveMessageId: Int64? { chatRows.highestPositiveMessageId }
  var onMessageSelectionChange: ((MessageListSelectionUpdate) -> Void)?
  // selection
  var isMessageSelectionActive: Bool { messageSelection.isActive }
  /// A selected album acts on all of its items.
  var selectedMessagesInLoadedOrder: [FullMessage] {
    expandedAlbums(selectedStableIdsInLoadedOrder()).compactMap { id in
      chatRows.messageIndex(forStableMessageId: id).flatMap { messages.indices.contains($0) ? messages[$0] : nil }
    }
  }

  var messageSelectionRows: any MessageListRowGeometry { selectionRows }
  var messageSelectionInset: CGFloat?
  var selectedMessageStableIds: Set<Int64> { messageSelection.selectedStableIds }

  func setMaximumContentWidth(_ width: CGFloat?) {
    guard maximumContentWidth != width else { return }
    maximumContentWidth = width
    heights.removeAll(keepingCapacity: true)
    guard isViewLoaded else { return }
    updateColumn()
    if hasPlacedInitialRows {
      list.apply(TimelineTransaction(changed: Set(list.placedViews.map(\.0))))
    }
  }

  func setTopOverlayHeight(_ height: CGFloat) {
    topOverlayHeight = height
    applyPinnedHeaderSuppression()
    guard hasPlacedInitialRows else { return }
    list.setInsets(top: topInset, timing: .standard)
  }

  // selection: as the table list's, rows being indices into `chatRows.rows`.
  func canSelectMessage(atRow row: Int) -> Bool { selectableStableId(forRow: row) != nil }

  func isMessageSelected(atRow row: Int) -> Bool {
    guard let stableId = selectableStableId(forRow: row) else { return false }
    return messageSelection.isSelected(stableId)
  }

  func messageSelectionStableId(atRow row: Int) -> Int64? { selectableStableId(forRow: row) }
  func messageSelectionRow(forStableId stableId: Int64) -> Int? { chatRows.rowIndex(forMessageStableId: stableId) }

  func setSelectedMessageStableIds(_ stableIds: Set<Int64>) {
    emitMessageSelectionChange(messageSelection.replace(with: stableIds, orderedIds: selectableMessageStableIds))
  }

  @discardableResult
  func beginMessageSelection(atRow row: Int) -> Bool {
    guard let stableId = selectableStableId(forRow: row) else { return false }
    textSelection.clear()
    emitMessageSelectionChange(messageSelection.begin(with: stableId))
    return true
  }

  @discardableResult
  func toggleMessageSelection(atRow row: Int) -> Bool {
    guard let stableId = selectableStableId(forRow: row) else { return false }
    emitMessageSelectionChange(messageSelection.toggle(stableId, orderedIds: selectableMessageStableIds))
    return true
  }

  @discardableResult
  func extendMessageSelection(toRow row: Int) -> Bool {
    guard let stableId = selectableStableId(forRow: row) else { return false }
    emitMessageSelectionChange(messageSelection.selectRange(to: stableId, orderedIds: selectableMessageStableIds))
    return true
  }

  @discardableResult
  func selectAllMessages() -> Bool {
    let stableIds = selectableMessageStableIds
    emitMessageSelectionChange(messageSelection.selectAll(stableIds))
    return !stableIds.isEmpty
  }

  @discardableResult
  func clearMessageSelection() -> Bool {
    let changed = messageSelection.clear()
    emitMessageSelectionChange(changed)
    return !changed.isEmpty
  }

  func updateInsetForCompose(_ height: CGFloat, animate: Bool) {
    let inset = messageSelectionInset ?? height
    guard abs(inset - composeInset) > 0.25 else { return }
    composeInset = inset
    // The composer animates its height in an AppKit animation group and tells the list from inside it: the list's
    // inset (and the buttons above the composer) take the group's duration and curve, so they move as one motion.
    let timing = animate ? Self.timing(matching: NSAnimationContext.current) : .none
    if timing != .none {
      // In the composer's group: the buttons take its timing.
      scrollToBottomBottomConstraint?.animator().constant = jumpButtonBottomConstant(slot: 0)
      activityJumpBottomConstraint?.animator().constant = activityJumpBottomConstant
      reactionJumpBottomConstraint?.animator().constant = reactionJumpBottomConstant
    } else {
      updateFloatingButtonPositions(animate: false)
    }
    guard hasPlacedInitialRows else { return }
    // An animated change: the list follows the composer's height as it is shown, frame by frame, rather than running
    // its own curve beside it. On its own curve the list started a frame before the composer (whose constraint
    // animation runs on the main thread) and led it by up to 19 pt opening a reply (journey `reply`).
    if timing != .none, messageSelectionInset == nil {
      composeInsetShown = composeInsetShown ?? (list.bottomInset - Theme.messageListBottomInset)
      composerFollowEnd?.cancel()
      // Lands on the target if the composer's frames stop coming (or never moved).
      let end = DispatchWorkItem { [weak self] in self?.endComposerFollow() }
      composerFollowEnd = end
      var duration: CGFloat = 0.25
      switch timing {
        case let .curve(value, _, _, _, _), let .spring(_, _, _, value): duration = value
        case .none: break
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + Double(duration) + 0.1, execute: end)
      return
    }
    endComposerFollow(apply: false)
    // A reader at the newest message stays on it; a reader further up keeps their distance from the composer.
    list.setInsets(bottom: bottomInset, timing: timing)
  }

  func composerHeightDidChange(_ height: CGFloat) {
    guard composeInsetShown != nil, !isDisposed, hasPlacedInitialRows else { return }
    composeInsetShown = height
    list.setInsets(bottom: bottomInset, timing: .none)
    if abs(height - composeInset) < 0.25 { endComposerFollow(apply: false) }
  }

  private func endComposerFollow(apply: Bool = true) {
    composerFollowEnd?.cancel()
    composerFollowEnd = nil
    guard composeInsetShown != nil else { return }
    composeInsetShown = nil
    if apply, hasPlacedInitialRows, !isDisposed { list.setInsets(bottom: bottomInset, timing: .none) }
  }

  /// The timing of the AppKit animation group the caller runs in; none outside one (a call from a non-animated path
  /// still says `animate`).
  private static func timing(matching context: NSAnimationContext) -> TimelineTiming {
    guard context.allowsImplicitAnimation, context.duration > 0,
          !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return .none }
    var c1: [Float] = [0, 0]
    var c2: [Float] = [1, 1]
    if let function = context.timingFunction {
      function.getControlPoint(at: 1, values: &c1)
      function.getControlPoint(at: 2, values: &c2)
    } else {
      // AppKit's default curve: ease in-out.
      (c1, c2) = ([0.42, 0], [0.58, 1])
    }
    return .curve(duration: CGFloat(context.duration), c1x: c1[0], c1y: c1[1], c2x: c2[0], c2y: c2[1])
  }

  // selection: from the rendered text views when the message is placed, so rich structure survives copy.
  func clipboardBlocks(for message: FullMessage) -> [MessageClipboardDocument.Block] {
    textSelection.wholeMessageBlocks(message)
  }

  func collapseHistory(maxID: Int64?) async throws {
    let effectiveMaxID = try await Api.realtime.collapseHistory(peer: peerId.toInputPeer(), maxID: maxID)
    setCollapsedMaxId(effectiveMaxID)
  }

  func setCollapsedMaxId(_ collapsedMaxId: Int64?) {
    guard chatRows.setCollapsedMaxId(collapsedMaxId) != .none, hasPlacedInitialRows else { return }
    list.apply(TimelineTransaction(rows: chatRows.rows, coverage: coverage(), timing: .standard, arrives: false))
  }

  func dispose() {
    guard !isDisposed else { return }
    textSelection.uninstall() // selection
    // Leaving the chat: where the reader is, for the next open.
    saveReadingPlace()
    isDisposed = true
    for task in remotePrefetches.values { task.cancel() }
    remotePrefetches.removeAll()
    archivePlans()
    MessageStreamPacer.shared.detach(owner: self, view: list) // streaming
    // The list can stay in the window a while after this controller goes (until the next chat's first frame): it stops
    // its motion and delayed work now, so it never lays out rows this controller no longer has.
    list.invalidate()
    if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
    activeObserver = nil
    if let menuObserver { NotificationCenter.default.removeObserver(menuObserver) }
    menuObserver = nil
    eventTask?.cancel()
    jumpTask?.cancel()
    jumpTask = nil
    trimTask?.cancel()
    trimTask = nil
    unreadFetchTask?.cancel()
    unreadFetchTask = nil
    unreadFetchConnection = nil
    statusNoticeCancellable = nil
    translationSettingCancellable = nil
    integrationCheckTask?.cancel()
    integrationCheckTask = nil
    activityNavigator?.stop()
    activityNavigator = nil
    clearHoveredMessage()
    if let messageHoverTrackingArea { list?.removeTrackingArea(messageHoverTrackingArea) }
    messageHoverTrackingArea = nil
    mediaWarmupTask?.cancel()
    mediaWarmupTask = nil
    let warmups = mediaWarmups
    mediaWarmups = []
    if !warmups.isEmpty {
      Task { for warmup in warmups { await InlineTinyThumbnailPrewarmer.cancel(warmup) } }
    }
    deferredTranslationTask?.cancel()
    deferredTranslationTask = nil
    NotificationCenter.default.removeObserver(self, name: .richBlockLayoutStateDidChange, object: nil)
    NotificationCenter.default.removeObserver(self, name: ChatTypography.didChangeNotification, object: nil)
    for task in historyTasks.values { task.cancel() }
    historyTasks = [:]
    chatRows.dispose()
  }
}

// MARK: - Selection (text across messages; messages to forward or delete)

// selection: the table list's selection logic, rows being indices into `chatRows.rows`.
extension TimelineMessageListAppKit: MessageListTextSelectionHost {
  var textSelectionRows: any MessageListRowGeometry { selectionRows }
  var textSelectionRootView: NSView { view }

  func textSelectionStableId(atRow row: Int) -> Int64? { chatRows.messageStableId(forRow: row) }
  func textSelectionRow(forStableId stableId: Int64) -> Int? { chatRows.rowIndex(forMessageStableId: stableId) }
  func textSelectionMessage(atRow row: Int) -> FullMessage? { chatRows.row(at: row).flatMap { message(for: $0)?.message } }

  /// A row id's index in `chatRows.rows`: messages by the view model's map, the few other rows by a scan.
  fileprivate func selectionRowIndex(_ id: RowID) -> Int? {
    switch id {
      case let .message(stableId), let .parentMessage(stableId):
        if let index = chatRows.rowIndex(forMessageStableId: stableId), chatRows.row(at: index) == id { return index }
        return chatRows.rows.firstIndex(of: id)
      default:
        return chatRows.rows.firstIndex(of: id)
    }
  }

  fileprivate var selectableMessageStableIds: [Int64] {
    messages.filter { isForwardSelectable($0) && !chatRows.isAlbumMember($0.id) }.map(\.id)
  }

  /// Selected rows' messages, each album expanded to its items in order.
  fileprivate func expandedAlbums(_ stableIds: [Int64]) -> [Int64] {
    stableIds.flatMap { id in chatRows.album(forStableId: id)?.items.map(\.id) ?? [id] }
  }

  fileprivate func selectableStableId(forRow row: Int) -> Int64? {
    guard chatRows.canSelect(row: row), let id = chatRows.row(at: row), let message = message(for: id)?.message,
          isForwardSelectable(message) else { return nil }
    return chatRows.messageStableId(forRow: row)
  }

  fileprivate func selectedStableIdsInLoadedOrder() -> [Int64] {
    messageSelection.orderedSelection(in: selectableMessageStableIds)
  }

  fileprivate func isForwardSelectable(_ fullMessage: FullMessage) -> Bool {
    let message = fullMessage.message
    return message.messageId > 0 && !message.isServiceMessage && !message.isSubthreadPlacement
      && (message.status == nil || message.status == .sent)
  }

  /// Drops selected messages that left the loaded rows (or can no longer be selected).
  @discardableResult
  fileprivate func pruneMessageSelection() -> Bool {
    guard messageSelection.isActive else { return false }
    let stableIds = selectableMessageStableIds
    let changed = messageSelection.prune(validIds: Set(stableIds), orderedIds: stableIds)
    emitMessageSelectionChange(changed)
    return !changed.isEmpty
  }

  fileprivate func emitMessageSelectionChange(_ changed: Set<Int64>) {
    refreshForwardSelection()
    guard !changed.isEmpty else { return }
    hideMessageQuickActions()
    scheduleMessageHoverRefresh()
    let ordered = selectedStableIdsInLoadedOrder()
    onMessageSelectionChange?(MessageListSelectionUpdate(
      isActive: messageSelection.isActive,
      count: messageSelection.count,
      selectedStableIds: ordered,
      selectedMessageIds: selectedMessagesInLoadedOrder.map(\.message.messageId),
      changedStableIds: changed
    ))
  }

  /// Placed rows show the selection's checkboxes. Entering or leaving selection opens or closes the checkbox column:
  /// rows are measured again at the new width, and the list keeps the reading row (or stays on the newest).
  fileprivate func refreshForwardSelection() {
    guard isViewLoaded, hasPlacedInitialRows else { return }
    let active = messageSelection.isActive
    let modeChanged = showsForwardSelection != active
    showsForwardSelection = active
    guard modeChanged else {
      for (id, view) in list.placedViews {
        guard let cell = (view as? TimelineRowHost)?.content as? MessageTableCell else { continue }
        configureForwardSelection(cell, id: id, animated: true)
      }
      return
    }
    // Placed rows are configured again by the list as it re-measures them; their checkboxes and messages animate.
    heights.removeAll(keepingCapacity: true)
    animatesSelectionMode = true
    list.apply(TimelineTransaction(changed: Set(list.placedViews.map(\.0))))
    animatesSelectionMode = false
  }

  fileprivate func configureForwardSelection(_ cell: MessageTableCell, id: RowID, animated: Bool) {
    let stableId = selectionRowIndex(id).flatMap { selectableStableId(forRow: $0) }
    cell.setForwardSelection(
      active: messageSelection.isActive,
      selectable: stableId != nil,
      selected: stableId.map { messageSelection.isSelected($0) } ?? false,
      animated: animated
    ) { [weak self] in
      guard let self, let stableId, let row = chatRows.rowIndex(forMessageStableId: stableId) else { return }
      toggleMessageSelection(atRow: row)
    }
  }
}

/// The list's root: reports layout so insets follow the window's toolbar.
final class TimelineMessageListRootView: NSView {
  var onLayout: (() -> Void)?
  var onEndLiveResize: (() -> Void)?
  nonisolated override var isFlipped: Bool { true }

  override func layout() {
    super.layout()
    onLayout?()
  }

  override func viewDidEndLiveResize() {
    super.viewDidEndLiveResize()
    onEndLiveResize?()
  }
}

/// One placed row: holds a production cell at the column's width, centred in the list.
final class TimelineRowHost: NSView {
  private(set) var content: NSView?
  private(set) var poolKey: String?
  /// streaming: its text views draw a revealed prefix (cleared when it shows a message that isn't streaming).
  var revealsText = false
  /// The row it shows, or showed last while pooled.
  var shownRow: ChatRowListViewModel.Row?
  private var contentWidth: CGFloat = 0
  // Nonisolated: AppKit asks constantly during layout and drawing, and the main-actor check in the @objc thunk showed
  // in profiles of fast flings.
  nonisolated override var isFlipped: Bool { true }

  init() {
    super.init(frame: .zero)
    wantsLayer = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  /// The group's sticky avatar when this row holds it: laid out by frame, horizontally here; the list owns its
  /// vertical place while the row is placed.
  private(set) var avatar: UserAvatarView?
  /// The message whose sender the avatar shows, so an unchanged pin is not configured again on every frame.
  var avatarOwner: Int64?

  /// For VoiceOver: who sent the message the row shows, and when, read before its text (the list's row group takes
  /// this label). Made into words only when asked.
  var accessibilityMessage: (sender: String, date: Date)?

  private static let accessibilityTime: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .none
    formatter.timeStyle = .short
    return formatter
  }()

  override func accessibilityLabel() -> String? {
    guard let accessibilityMessage else { return super.accessibilityLabel() }
    let time = Self.accessibilityTime.string(from: accessibilityMessage.date)
    return accessibilityMessage.sender.isEmpty ? time : "\(accessibilityMessage.sender), \(time)"
  }

  /// The avatar's size and its x from the cell's leading edge: bubble style's by default, minimal style's when its
  /// group's avatar is held here.
  private(set) var avatarSize: CGFloat = Theme.messageAvatarSize
  private(set) var avatarLeading: CGFloat = MessageSizeCalculator.bubbleAvatarLeadingInset

  @discardableResult
  func setAvatar(
    _ userInfo: UserInfo?, viaMark: MessageViaPresentation.Mark? = nil, size: CGFloat = Theme.messageAvatarSize,
    leading: CGFloat = MessageSizeCalculator.bubbleAvatarLeadingInset, onClick: (() -> Void)? = nil
  ) -> UserAvatarView? {
    guard let userInfo else {
      avatar?.removeFromSuperview()
      avatar = nil
      avatarOwner = nil
      return nil
    }
    avatarSize = size
    avatarLeading = leading
    let view = avatar ?? UserAvatarView(userInfo: userInfo, size: size, viaMark: viaMark)
    if avatar == nil {
      view.translatesAutoresizingMaskIntoConstraints = true
      view.frame = NSRect(x: 0, y: 0, width: size, height: size)
      addSubview(view)
      avatar = view
    } else {
      view.update(userInfo: userInfo, size: size, viaMark: viaMark)
    }
    view.onClick = onClick
    layoutAvatar()
    return view
  }

  private func layoutAvatar() {
    guard let avatar else { return }
    let x = (content?.frame.minX ?? 0) + avatarLeading
    let size = avatarSize
    if abs(avatar.frame.minX - x) > 0.01 || avatar.frame.width != size || avatar.frame.height != size {
      avatar.frame = NSRect(x: x, y: avatar.frame.minY, width: size, height: size)
    }
  }

  func setContent(_ view: NSView?, width: CGFloat, poolKey: String?) {
    if content !== view {
      content?.removeFromSuperview()
      content = view
      if let view {
        view.translatesAutoresizingMaskIntoConstraints = true
        addSubview(view)
      }
    }
    self.poolKey = poolKey
    contentWidth = width
    needsLayout = true
    layoutContent()
  }

  override func layout() {
    super.layout()
    layoutContent()
  }

  private func layoutContent() {
    guard let content else { return }
    let width = min(bounds.width, contentWidth > 0 ? contentWidth : bounds.width)
    let frame = NSRect(x: floor((bounds.width - width) / 2), y: 0, width: width, height: bounds.height)
    if content.frame != frame { content.frame = frame }
    layoutAvatar()
  }
}

/// A day's title as a capsule. The day row draws one in its place and the floating header carries the same one on once
/// it reaches the top (Telegram macOS: one pill sticks under the toolbar until the next day's pushes it off), so the
/// two meet exactly: same view, same size, same place.
final class TimelineDatePill: NSView {
  /// 20 pt tall with a 13 pt title (Mo, 2026-11-27: "thinner, and 1px more font"; was 22 and 12).
  static let height: CGFloat = 20
  static let horizontalInset: CGFloat = 9
  static let fontSize: CGFloat = 13

  enum Style: String { case plain, glass }
  /// A light fill, or the system's glass (`defaults write <bundle id> TimelineDatePillStyle glass`), to compare
  /// (2026-11-27; the setting goes once one is chosen).
  static var style: Style {
    Style(rawValue: UserDefaults.standard.string(forKey: "TimelineDatePillStyle") ?? "") ?? .plain
  }

  private let label = NSTextField(labelWithString: "")
  private let background: NSView
  private let style: Style
  private var dayStart: Date?
  nonisolated override var isFlipped: Bool { true }

  override init(frame frameRect: NSRect) {
    style = Self.style
    if style == .glass, #available(macOS 26.0, *) {
      let glass = NSGlassEffectView()
      glass.style = .regular
      glass.cornerRadius = Self.height / 2
      background = glass
    } else if style == .glass {
      let material = NSVisualEffectView()
      material.material = .popover
      material.blendingMode = .withinWindow
      material.state = .active
      material.wantsLayer = true
      material.layer?.cornerRadius = Self.height / 2
      material.layer?.masksToBounds = true
      background = material
    } else {
      background = NSView()
      background.wantsLayer = true
      background.layer?.cornerRadius = Self.height / 2
      background.layer?.cornerCurve = .continuous
      background.layer?.borderWidth = 0.5
      background.layer?.shadowOffset = CGSize(width: 0, height: -0.5)
      background.layer?.shadowRadius = 1.5
    }
    super.init(frame: frameRect)
    wantsLayer = true
    label.font = .systemFont(ofSize: Self.fontSize, weight: .medium)
    label.textColor = .secondaryLabelColor
    label.alignment = .center
    label.lineBreakMode = .byTruncatingTail
    addSubview(background)
    addSubview(label)
    updateColors()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  var title: String { label.stringValue }
  /// The capsule, in this view's coordinates: where a click lands on the pill.
  var capsuleFrame: NSRect { background.frame }

  func configure(dayStart: Date) {
    guard self.dayStart != dayStart else { return }
    self.dayStart = dayStart
    label.stringValue = Self.title(for: dayStart)
    needsLayout = true
    layoutSubtreeIfNeeded()
  }

  static func title(for dayStart: Date) -> String {
    let calendar = Calendar.autoupdatingCurrent
    if calendar.isDateInToday(dayStart) { return NSLocalizedString("Today", comment: "Date separator label") }
    if calendar.isDateInYesterday(dayStart) { return NSLocalizedString("Yesterday", comment: "Date separator label") }
    return dayStart.formatted(date: .abbreviated, time: .omitted)
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateColors()
  }

  /// Plain: a soft gray capsule, nearly opaque so text under a floating one doesn't show through, a hairline edge and
  /// the faintest shadow: it reads on a white chat and over bubbles without the glass's weight.
  private func updateColors() {
    guard style == .plain, let layer = background.layer else { return }
    let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    layer.backgroundColor = (dark ? NSColor(white: 0.2, alpha: 0.97) : NSColor(white: 0.945, alpha: 0.98)).cgColor
    layer.borderColor = (dark ? NSColor(white: 1, alpha: 0.07) : NSColor(white: 0, alpha: 0.05)).cgColor
    layer.shadowColor = NSColor.black.cgColor
    layer.shadowOpacity = dark ? 0 : 0.05
  }

  override func layout() {
    super.layout()
    // The title's own width (a label's intrinsic width left it a few points short: "Feb 16, 20…").
    let font = label.font ?? .systemFont(ofSize: Self.fontSize, weight: .medium)
    let text = ceil((label.stringValue as NSString).size(withAttributes: [.font: font]).width)
    let width = min(bounds.width, text + 2 * Self.horizontalInset)
    let frame = NSRect(x: floor((bounds.width - width) / 2), y: 0, width: width, height: Self.height)
    if background.frame != frame {
      background.frame = frame
      background.layer?.shadowPath = CGPath(
        roundedRect: background.bounds, cornerWidth: Self.height / 2, cornerHeight: Self.height / 2, transform: nil
      )
    }
    // The label's cell draws its text 4 pt inside its frame on each side (cellSize 82.6 pt for a 74.6 pt title): sized
    // by its cell and centred on the capsule.
    let cell = label.cell?.cellSize ?? label.intrinsicContentSize
    let labelWidth = min(ceil(cell.width), bounds.width)
    let labelHeight = ceil(cell.height)
    label.frame = NSRect(
      x: floor(frame.midX - labelWidth / 2), y: floor((Self.height - labelHeight) / 2), width: labelWidth, height: labelHeight
    )
  }
}

/// A day row: its pill `pillTop` below the row's top. The floating header takes the pill over at that inset
/// (`TimelineFloatingHeader.ownInset`) and the list hides the row meanwhile.
final class TimelineDayRowView: NSView {
  static let height: CGFloat = 34
  static let pillTop: CGFloat = 7
  private let pill = TimelineDatePill()
  private var dayStart: Date?
  /// A click on the pill: the list scrolls to the day's start.
  var onClick: ((Date) -> Void)?
  nonisolated override var isFlipped: Bool { true }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    addSubview(pill)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  func configure(dayStart: Date) {
    self.dayStart = dayStart
    pill.configure(dayStart: dayStart)
  }

  override func layout() {
    super.layout()
    let frame = NSRect(x: 0, y: Self.pillTop, width: bounds.width, height: TimelineDatePill.height)
    if pill.frame != frame { pill.frame = frame }
  }

  /// Only the pill takes clicks; the rest of the row lets them through.
  override func hitTest(_ point: NSPoint) -> NSView? {
    guard let superview, !isHiddenOrHasHiddenAncestor else { return nil }
    let local = convert(point, from: superview)
    return pill.convert(pill.capsuleFrame, to: self).contains(local) ? self : nil
  }

  override func mouseDown(with event: NSEvent) {}

  override func mouseUp(with event: NSEvent) {
    let local = convert(event.locationInWindow, from: nil)
    guard let dayStart, pill.convert(pill.capsuleFrame, to: self).contains(local) else { return }
    onClick?(dayStart)
  }

  override func isAccessibilityElement() -> Bool { true }
  override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
  override func accessibilityLabel() -> String? { pill.title }
}

/// The floating day title: the day row's pill, carried on under the toolbar. A click on it scrolls to the day's start.
final class TimelineFloatingDateView: NSView {
  private let pill = TimelineDatePill()
  private var dayStart: Date?
  var onClick: ((Date) -> Void)?
  nonisolated override var isFlipped: Bool { true }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    addSubview(pill)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  /// The pill takes clicks while it shows (it is faded out at rest, and moved by layer animations during flights:
  /// what is presented decides).
  override func hitTest(_ point: NSPoint) -> NSView? {
    guard let superview, let layer, (layer.presentation() ?? layer).opacity > 0.5 else { return nil }
    let presented = (layer.presentation() ?? layer).frame
    let local = NSPoint(x: point.x - presented.minX, y: point.y - presented.minY)
    return pill.convert(pill.capsuleFrame, to: self).contains(local) && superview.bounds.contains(point) ? self : nil
  }

  override func mouseDown(with event: NSEvent) {}

  override func mouseUp(with event: NSEvent) {
    if let dayStart { onClick?(dayStart) }
  }

  func configure(dayStart: Date) {
    self.dayStart = dayStart
    pill.configure(dayStart: dayStart)
  }
  var title: String { pill.title }

  override func layout() {
    super.layout()
    let frame = NSRect(x: 0, y: 0, width: bounds.width, height: TimelineDatePill.height)
    if pill.frame != frame { pill.frame = frame }
  }
}

#if DEBUG || DEBUG_BUILD
/// Real-trackpad gestures as the new list played them, beside the system's momentum events, one JSON line each in
/// Application Support/<bundle id>/timeline-gestures.jsonl: every tracked event is kept, so a gesture can be replayed
/// in the lab into a plain NSScrollView and the list. (Feeding a live NSScrollView the list's events here instead
/// latched the gesture to it: the list got only the first event.)
enum TimelineGestureLog {
  private static let queue = DispatchQueue(label: "chat.inline.timeline-gesture-log", qos: .utility)

  static func append(_ record: TimelineGestureRecord) {
    guard let data = try? JSONEncoder().encode(record) else { return }
    queue.async {
      guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
      let folder = support.appendingPathComponent(Bundle.main.bundleIdentifier ?? "chat.inline.InlineMac", isDirectory: true)
      try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let url = folder.appendingPathComponent("timeline-gestures.jsonl")
      var line = data
      line.append(0x0A)
      if let handle = try? FileHandle(forWritingTo: url) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
      } else {
        try? line.write(to: url)
      }
    }
  }
}
#endif
