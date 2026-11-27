import Auth
import Combine
import InlineIOSUI
import InlineKit
import InlineMessageLayout
import InlineUI
import Logger
import Translation
import UIKit

/// The message list on `InlineTimeline`, hosted by `ChatContainerView`: the default list. Builds with
/// developer tools can switch back to the collection view (`experimental.iosTimeline`).
///
/// Rows come from the view model's row feed and are shown by the production `MessageView`, planned
/// exactly as the collection view's cell plans it. The container owns the keyboard and the composer
/// and reports one compose area; this view turns it into the list's bottom inset in the same call.
@MainActor
final class TimelineMessagesView: UIView, ChatMessageListHosting, SendMessageAnimationListGate,
  ChatMediaGalleryPresenting
{
  let viewModel: MessagesProgressiveViewModel
  let list: TimelineListView<ChatRowID>

  var onContextMenuWillDisplay: (() -> Void)?
  var onContextMenuDidEnd: (() -> Void)?
  var onScrollAffordanceChanged: ((ChatScrollAffordanceState) -> Void)? {
    didSet { onScrollAffordanceChanged?(affordance) }
  }

  var onVisibleMessagesChanged: (([Int64]?) -> Void)?
  /// The container's keyboard is up; the message menu draws over it only then.
  var isKeyboardVisible: () -> Bool = { false } {
    didSet { menu.isKeyboardVisible = isKeyboardVisible }
  }

  private let peer: Peer
  private let chatId: Int64?
  private let spaceId: Int64?
  /// The chat list's preview, as the collection view showed it: the latest messages without the unread
  /// line, nothing read, saved, loaded or offered for translation, no status notice. It takes no touches
  /// (the container turns them off).
  private let isPreview: Bool
  /// Where the chat opens. Becomes the unread line once history around an uncached line arrives.
  private var openAnchor: ChatOpenAnchor
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
  /// Rows whose update waits for UIKit's menu to let go of their live bubble (`TimelineMessageMenu.liveSourceID`).
  private var heldRows: Set<ChatRowID> = []

  // Send flight
  weak var sendAnimationCoordinator: SendMessageAnimationCoordinator?
  /// Rows of sent messages whose bubble is still flying in from the composer.
  private var flightTargets: Set<ChatRowID> = []
  /// Where each flight is headed (the bubble, in the window), so only a row that moved retargets it.
  private var flightFrames: [ChatRowID: CGRect] = [:]

  // Floating date
  private let datePill = TimelineDatePill(floating: true)
  /// The strip the floating date stands in; it grows with the text size.
  private var datePillHeight: CGFloat { TimelineDatePill.height(traitCollection) }
  /// Where each day starts in the rows, oldest first.
  private var dayRows: [(index: Int, day: Date)] = []
  /// Each message row's sender group, as row indexes, built once per snapshot: the list asks for a
  /// group's ends on every frame of a fling (pins, the avatar row kept placed).
  private var groupSpans: [ChatRowID: (start: Int, end: Int)] = [:]
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
  /// While a message menu is open the list keeps its place, as the collection view froze its viewport:
  /// compose-area changes (the menu putting the keyboard away) wait, and after the menu the keyboard
  /// coming back meets the list where it was. `latest` is the newest held inset.
  private var menuInsetHold: (atStart: CGFloat, latest: CGFloat?)?
  private var awaitsMenuKeyboard = false
  private var menuInsetRelease: DispatchWorkItem?
  private var holdsComposeInsetForSend = false
  private var composeInsetHoldTask: Task<Void, Never>?
  private var pinnedHeaderHeight: CGFloat = 0
  /// The chat opened at the unread line or a saved place and the reader hasn't moved since: a pinned
  /// header that appears later keeps that place the same distance below it, as the collection view did.
  private var holdsOpeningPlace = false
  private var lastNavigationInset: CGFloat = 0
  private static let bottomPadding: CGFloat = 12

  // History, jumps, read state
  private var loadingEdges: Set<TimelineEdge> = []
  /// Edges whose last page failed or brought nothing: the list asks again after the reader's next drag,
  /// not on every layout pass near the edge, as the collection view's pagination waited for a gesture.
  private var blockedEdges: Set<TimelineEdge> = []
  /// Bumped when the list shows another window (a jump), so a page that finishes for the old one blocks nothing.
  private var windowGeneration = 0
  private var historyTasks: [TimelineEdge: Task<Void, Never>] = [:]
  /// A trim that waits for the scroll to end (`trimWindow(keeping:)`).
  private var pendingTrimEdge: TimelineEdge?
  /// What the view model was last told about the reader's place.
  private var reportedPlace: (atBottom: Bool, messageId: Int64?)?
  private var jumpTask: Task<Void, Never>?
  private var returnToLatestTask: Task<Void, Never>?
  /// A drag during a return to latest: its fetch finishes, but it no longer moves the list.
  private var returnToLatestInterrupted = false
  private var returnToLatestGeneration = 0
  private var pendingFocus: PendingFocus?
  /// Bumped by every new focus or cancel, so a highlight still waiting for its jump to land is dropped.
  private var focusRevision = 0
  /// The message a jump highlighted and when its highlight ends, so a row shown again gets the rest.
  private var focusHighlight: (messageId: Int64, endsAt: CFTimeInterval)?
  private var lastReadCandidate: Int64 = 0
  /// The coverage the last read was sent under; a new window reads its messages again.
  private var lastReadCoverage: MessageHistoryCoverageProjection?
  private var readFrontier: Int64 = 0
  private var unreadState: ChatActivityNavigator.State = .empty
  private var affordance = ChatScrollAffordanceState()
  private var lastReadPass: CFTimeInterval = 0
  /// The newest message the last read of the whole chat ran for (0 for none loaded). At the live end a
  /// pass reads the chat again only for a newer message, or once the chat may be unread again (a mark,
  /// a count, the app or the list coming back): each read is a write and a notification-center query,
  /// and passes run a few times a second while the list moves and after every row update.
  private var readAllThrough: Int64?
  /// Scroll-end work that waits for the list to rest a moment, so a reader who stops and goes on does
  /// not trim, warm media and save the place at every stop (`listSettled`).
  private var settleWork: DispatchWorkItem?

  // Media warm-up
  /// Rows whose images were asked for ahead of time, so they can be let go when they move away.
  private var prefetched: [ChatRowID: [FullMessage]] = [:]
  private var prefetchKey: (first: Int, last: Int, revision: UInt64)?
  /// What the last warm-up was asked for: the rows on screen and the snapshot.
  private var warmedKey: (first: Int, last: Int, revision: UInt64)?
  private var warmupTask: Task<Void, Never>?
  private var warmups: [InlineTinyThumbnailWarmup] = []

  // Translation
  private let translation: TranslationViewModel
  private var hasDetectedLanguages = false

  // Uncached unread line
  /// The unread line was not cached when the chat opened: the list stays empty and hidden while
  /// history around the line is fetched, then opens at the line, or at the latest messages when the
  /// fetch fails, the app is offline or the connection drops. As the collection view does.
  private var unreadFetchBoundary: Int64?
  private var unreadFetchTask: Task<Void, Never>?
  private var unreadFetchConnection: AnyCancellable?
  private var unreadFetchSpinner: UIActivityIndicatorView?

  /// A message the list was asked to show (a reply, the pinned header, search, a notification).
  private struct PendingFocus {
    var messageId: Int64
    /// Only this message will do: no nearby one when it is gone.
    var requiresExact: Bool
    /// Asked for before the list was on screen: it is placed without motion, as the chat opens.
    var animated: Bool
    /// A message newer than the synced history: the list stays at the live end until an update
    /// brings it.
    var awaitsArrival = false
    /// The landed message flashes; a return to where a reply jump started lands quietly.
    var highlights = true
  }

  /// A message the reader jumped from to the one its reply quotes. As Telegram keeps them, the scroll
  /// button goes back to the last of these before it goes to the newest messages, and one is dropped
  /// once the reader scrolls back down to it.
  private struct ReplyReturn {
    var messageId: Int64
    /// The message has been below the screen since the jump, so coming back down to it can be told
    /// apart from the jump's own first frames.
    var hasLeftScreen = false
  }

  private var replyReturns: [ReplyReturn] = []

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
  /// The harness's stand-in for the server when an uncached unread line is fetched: it brings the
  /// history around a message into the fixture, or throws.
  static var debugLoadAround: ((Int64) async throws -> Void)?
  private var probe: TimelineProbe?
  #endif

  /// Rows move on Telegram's list spring, the one `MessageMotion.standard` moves their contents on.
  /// With Reduce Motion they change at once, as the collection view skipped its animated updates.
  private static var rowTiming: TimelineTiming {
    UIAccessibility.isReduceMotionEnabled ? .none : .standard
  }

  /// A streamed message growing by a line; at once with Reduce Motion.
  private static var streamingLineTiming: TimelineTiming {
    UIAccessibility.isReduceMotionEnabled ? .none : .streamingLine
  }

  /// Telegram's send transition: 0.3 s on its vertical curve, which the bubble's flight rises on.
  private static var sendTiming: TimelineTiming {
    let c1 = SendMessageAnimationTiming.verticalControlPoint1
    let c2 = SendMessageAnimationTiming.verticalControlPoint2
    return .curve(
      duration: SendMessageAnimationTiming.duration, c1x: Float(c1.x), c1y: Float(c1.y), c2x: Float(c2.x), c2y: Float(c2.y)
    )
  }

  /// A jump beyond the placed rows: Telegram's jump curve, UIKit's critically damped scroll-to-top
  /// spring played over 1.15 s (response 0.43). With Reduce Motion the list goes there at once.
  private static var jumpTiming: TimelineTiming {
    UIAccessibility.isReduceMotionEnabled
      ? .none
      : .spring(mass: 1, stiffness: 212.3, damping: 29.14, duration: 1.15)
  }

  init(
    peer: Peer, chatId: Int64?, spaceId: Int64?, initialState: MessagesProgressiveViewModel.InitialState?,
    collapsedMaxId: Int64?, theme: IOSThemeSnapshot, isPreview: Bool = false
  ) {
    self.peer = peer
    self.chatId = chatId
    self.spaceId = spaceId
    self.theme = theme
    self.isPreview = isPreview
    openAnchor = isPreview ? .latest : initialState?.openAnchor ?? .latest
    unreadFetchBoundary = isPreview ? nil : initialState?.uncachedUnreadBoundary
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
    translation = TranslationViewModel(peerId: peer)
    super.init(frame: .zero)
    setUpMenu()
    backgroundColor = .clear
    list.rows = TimelineRows(
      height: { [unowned self] id, width in height(of: id, width: width) },
      make: { [unowned self] id, width in makeRow(id, width: width) },
      update: { [unowned self] id, view, width, timing in
        (view as? TimelineRowView).map { configure($0, id: id, width: width, timing: timing) }
      },
      recycle: { [unowned self] id, view in
        // A row planned mid-stream is measured again when it comes back: the pacer goes on revealing and
        // finishes with no view to replan it, so its kept height would be short of what it then shows.
        if plans[id]?.streamLength != nil {
          plans[id] = nil
          heights[id] = nil
        }
        // Reset even when the pool is full: the list keeps the row in a hidden slot it may reuse.
        guard let row = view as? TimelineRowView else { return }
        row.prepareForReuse()
        if rowPool.count < 24 { rowPool.append(row) }
      },
      // The sender's avatar stays in sight beside its group, as the collection view's overlay keeps it.
      pin: { [unowned self] id, view in
        guard let avatar = (view as? TimelineRowView)?.pinnedAvatar else { return nil }
        return TimelinePin(view: avatar.view, bottom: avatar.bottom, height: avatar.height, spanStart: groupStart(of: id))
      },
      spanTop: { _, view in (view as? TimelineRowView)?.bubbleTop ?? 0 },
      // The group's last row holds its avatar: it stays placed while any of the group is in sight, as the
      // collection view's overlay drew the avatar for any visible row of a group.
      spanEnd: { [unowned self] id in avatarGroupEnd(of: id) },
      // The bubble gradient spans the screen, as the collection view's per-frame sync lays it.
      screen: { _, view, screen in (view as? TimelineRowView)?.followScreen(screen) },
      // A deleted message shrinks into its bubble's centre, as Telegram's does.
      removalFocus: { _, view in (view as? TimelineRowView)?.bubbleCenter }
    )
    list.onDemand = { [weak self] edges in edges.forEach { self?.loadHistory($0) } }
    list.onLayout = { [weak self] _ in self?.layoutChanged() }
    list.onScrollEnded = { [weak self] in self?.scrollEnded() }
    list.onDragBegan = { [weak self] in self?.dragBegan() }
    list.onScrollToTop = { [weak self] in self?.statusBarTapped() }
    list.accessibilityPageDescription = { [weak self] _ in self?.accessibilityPageDescription() }
    addSubview(list)
    datePill.alpha = 0
    datePill.onTap = { [weak self] in self?.jumpToDatePillDay() }
    // While the list moves, a finger on the pill is a finger on the list: it catches the fling.
    datePill.passesTouches = { [weak self] in self.map { $0.list.isTracking || $0.list.isDecelerating } ?? false }
    addSubview(datePill)

    // As the collection view drew them: the unread line under its day's badge.
    viewModel.rowFeed.unreadLineFollowsDay = true
    if isPreview {
      viewModel.rowFeed.setUnreadBoundary(nil)
    } else {
      observeStatusNotice()
    }
    viewModel.rowFeed.isPublishing = true
    viewModel.rowFeed.updates.sink { [weak self] update in self?.apply(update) }.store(in: &cancellables)
    TranslationState.shared.subject.sink { [weak self] peer, enabled in
      guard let self, peer == self.peer else { return }
      translationToggled(enabled)
    }.store(in: &cancellables)
    NotificationCenter.default.addObserver(
      self, selector: #selector(scrollToRepliedMessage(_:)), name: Notification.Name("ScrollToRepliedMessage"),
      object: nil
    )
    NotificationCenter.default.addObserver(
      self, selector: #selector(applicationDidBecomeActive), name: UIApplication.didBecomeActiveNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self, selector: #selector(applicationDidEnterBackground), name: UIApplication.didEnterBackgroundNotification,
      object: nil
    )
    // The actions button follows the hold action, and VoiceOver picks UIKit's menu.
    INUserSettings.current.messageGestures.objectWillChange
      .receive(on: DispatchQueue.main)
      .sink { [weak self] in self?.refreshMessageActions() }
      .store(in: &cancellables)
    NotificationCenter.default.addObserver(
      self, selector: #selector(refreshMessageActions), name: UIAccessibility.voiceOverStatusDidChangeNotification,
      object: nil
    )
    if !isPreview { viewModel.ensureThreadAnchorCached() }
    #if DEBUG
    NotificationCenter.default.addObserver(
      self, selector: #selector(debugAccessibility(_:)), name: Self.debugAccessibilityNotification, object: nil
    )
    #endif
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  private func setUpMenu() {
    menu = TimelineMessageMenu(list: list, actions: menuActions) { [weak self] id in self?.row(id) }
    menu.navigationInset = { [weak self] in self?.lastNavigationInset ?? 0 }
    menu.onWillDisplay = { [weak self] in
      self?.beginMenuInsetHold()
      self?.onContextMenuWillDisplay?()
    }
    menu.onDidEnd = { [weak self] in
      guard let self else { return }
      onContextMenuDidEnd?()
      // The container said neither way (it waits for the emoji sheet, or had nothing to restore).
      if menuInsetHold != nil, !awaitsMenuKeyboard, !menuActions.isReactionPickerPresented {
        endMenuInsetHold(timing: Self.rowTiming)
      }
    }
    menu.onLiveSourceReleased = { [weak self] id in
      guard let self, heldRows.remove(id) != nil else { return }
      // Once UIKit has finished with the bubble, the row takes its update and moves like one.
      DispatchQueue.main.async { [weak self] in self?.replan(id, timing: Self.rowTiming) }
    }
    menuActions.presenter = { [weak self] in self?.findViewController() }
    menuActions.containerWidth = { [weak self] in
      self?.window?.bounds.width ?? self?.bounds.width ?? UIScreen.main.bounds.width
    }
    menuActions.currentMessage = { [weak self] stableId, messageId, chatId, randomId in
      self?.snapshot?.rows.lazy.flatMap(\.content.messages).first { message in
        message.id == stableId
          || (message.message.messageId == messageId && message.message.chatId == chatId)
          || (randomId != nil && message.message.randomId == randomId && message.message.chatId == chatId)
      }
    }
    menuActions.react = { [weak self] _, toggle in
      guard let self else { return toggle() }
      menu.react(toggle)
    }
    // Over the open menu's own window, so the sheet shows above it; over UIKit's menu, the list's window.
    menuActions.emojiSheetOverWindow = { [weak self] in
      guard let self else { return nil }
      return menu.controller?.moveToOwnWindow() ?? (menu.isActive ? window : nil)
    }
    menuActions.onEmojiSheetDismissed = { [weak self] in
      guard let self, !menu.isActive else { return }
      onContextMenuDidEnd?()
    }
    if !isPreview { menuActions.loadIntegrations() }
  }

  isolated deinit {
    #if DEBUG
    FileHandle.standardError.write(Data("TIMELINE_DEBUG deinit messages view\n".utf8))
    #endif
    for task in historyTasks.values { task.cancel() }
    jumpTask?.cancel()
    returnToLatestTask?.cancel()
    warmupTask?.cancel()
    settleWork?.cancel()
    unreadFetchTask?.cancel()
    unreadFetchSpinner?.removeFromSuperview()
    let warmups = warmups
    let prefetched = Array(prefetched.values.joined())
    Task {
      for warmup in warmups { await InlineTinyThumbnailPrewarmer.cancel(warmup) }
      await ImagePrefetcher.shared.cancelPrefetching(for: prefetched)
    }
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

  override func willMove(toWindow newWindow: UIWindow?) {
    super.willMove(toWindow: newWindow)
    // Leaving mid-fling: read what is on screen before reading stops, as Telegram does.
    if newWindow == nil, window != nil { readPass(force: true, leaving: true) }
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window == nil {
      for task in historyTasks.values { task.cancel() }
      // A jump still loading lands when the chat is back, as the collection view's did.
      returnToLatestTask?.cancel()
      // The menu's overlay belongs to the window and would outlive the chat.
      menu.dismissImmediately()
      // A settle still waiting is done now: the place is saved as the chat is left.
      settleWork?.cancel()
      settleWork = nil
      saveReadingPlace()
      onVisibleMessagesChanged?(nil)
      #if DEBUG
      probe?.stop()
      probe = nil
      #endif
    } else {
      // Back on screen: what it shows is read again, as the collection view's did.
      lastReadCandidate = 0
      readAllThrough = nil
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

  func composeAreaDidChange(bottomInset: CGFloat, timing: TimelineTiming, isInteractive: Bool) {
    // A finger on the keyboard ends any hold: the list follows it.
    if isInteractive, menuInsetHold != nil {
      menuInsetHold = nil
      awaitsMenuKeyboard = false
      menuInsetRelease?.cancel()
    }
    if let hold = menuInsetHold {
      menuInsetHold?.latest = bottomInset
      // The keyboard is back after the menu (or a reply bar rose): the list moves only by what changed.
      if awaitsMenuKeyboard, bottomInset >= hold.atStart - 0.5 { endMenuInsetHold(timing: timing) }
      return
    }
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
    guard abs(height - pinnedHeaderHeight) > 0.5 else { return }
    pinnedHeaderHeight = height
    guard holdsOpeningPlace, hasOpened, !list.layout.isAtBottom, let anchor = topRowPlace() else {
      applyInsets(UIView.inheritedAnimationDuration > 0 ? Self.rowTiming : .none)
      return
    }
    applyInsets(.none)
    list.apply(TimelineTransaction(scroll: .to(anchor.id, .top(anchor.offset))))
  }

  /// The topmost row on screen and how far its top sits below the usable top (negative when cut off).
  private func topRowPlace() -> (id: ChatRowID, offset: CGFloat)? {
    let layout = list.layout
    let top = layout.viewport.usableTop
    guard let placement = layout.placements.first(where: { $0.maxY > top + 0.5 }) else { return nil }
    return (placement.id, placement.y - top)
  }

  // The container reports the whole compose area; these older, partial reports are not needed.
  func setInitialComposeHeight(_: CGFloat) {}
  func updateComposeInset(composeHeight _: CGFloat, animation _: ComposeHeightChangeAnimation) {}
  func setComposeBottomOffset(_: CGFloat) {}

  // MARK: - Rows

  private func row(_ id: ChatRowID) -> ChatRow? { snapshot?.row(for: id) }

  /// A message of this chat. The thread's parent is the parent chat's message, numbered in that chat, so
  /// reads, the reading place, the history anchor and jumps leave it out, as the collection view's
  /// thread anchor was left out of them.
  private static func chatMessage(_ row: ChatRow?) -> FullMessage? {
    switch row?.content {
      case let .message(message, _)?: message
      case let .album(album, _)?: album.lead
      default: nil
    }
  }

  /// Every message of this chat a row draws, oldest first: an album's items, or its one message.
  private static func chatMessages(_ row: ChatRow?) -> [FullMessage] {
    switch row?.content {
      case let .message(message, _)?: [message]
      case let .album(album, _)?: album.items
      default: []
    }
  }

  /// The message a message row's own actions go to (reply swipe, actions button, menu): the
  /// message itself, or an album's caption (or first) item. Nil for the thread's parent and
  /// rows without a message.
  static func actionMessage(of content: ChatRowContent) -> FullMessage? {
    switch content {
      case let .message(message, _): message
      // A failed item first, so the bubble's actions offer its retry.
      case let .album(album, _): album.items.first { $0.message.status == .failed } ?? album.primary
      default: nil
    }
  }

  /// The thread's parent message stands alone; when someone else wrote it, it shows their avatar and
  /// name, as the collection view's thread layout did.
  private static func threadParentGrouping(_ message: FullMessage) -> ChatRowGrouping {
    let incoming = message.message.out != true && !message.message.isServiceMessage && message.senderInfo != nil
    return ChatRowGrouping(isFirstInGroup: true, isLastInGroup: true, showsSenderName: incoming, showsAvatar: incoming)
  }

  /// The last row of the avatar group a message row belongs to, when that is another row.
  private func avatarGroupEnd(of id: ChatRowID) -> ChatRowID? {
    guard let span = groupSpans[id], let rows = snapshot?.rows, rows.indices.contains(span.end) else { return nil }
    let end = rows[span.end]
    guard end.id != id, let grouping = end.content.grouping, grouping.showsAvatar else { return nil }
    return end.id
  }

  /// The first row of the sender group a message row ends.
  private func groupStart(of id: ChatRowID) -> ChatRowID {
    guard let span = groupSpans[id], let rows = snapshot?.rows, rows.indices.contains(span.start) else { return id }
    return rows[span.start].id
  }

  private func height(of id: ChatRowID, width: CGFloat) -> CGFloat {
    if let cached = heights[id], abs(cached.width - width) < 0.5 { return cached.height }
    // The list can still ask for a row of the previous snapshot: a jump that takes over a fling first
    // settles the fling on the rows it had. That row is not measured or remembered here; a cached zero
    // would stack it on its neighbours when a later window brings it back.
    guard row(id) != nil else { return 0 }
    let height = measure(id, width: width)
    heights[id] = (width, height)
    return height
  }

  private func measure(_ id: ChatRowID, width: CGFloat) -> CGFloat {
    guard let row = row(id) else { return 0 }
    switch row.content {
      case let .message(message, grouping):
        return messageHeight(row, message, grouping, isThreadAnchor: false, width: width)
      case let .album(album, grouping):
        return messageHeight(row, album.lead, grouping, isThreadAnchor: false, width: width)
      case let .threadParent(message):
        return messageHeight(row, message, Self.threadParentGrouping(message), isThreadAnchor: true, width: width)
      // The collection view's heights, growing with the text size (`TimelineLabelMetrics`).
      case .daySeparator: return TimelineLabelMetrics.dayRowHeight(traitCollection)
      case .unreadLine: return TimelineLabelMetrics.unreadRowHeight(traitCollection)
      case .statusNotice: return TimelineLabelMetrics.noticeRowHeight(traitCollection)
      case .collapsedHistory: return TimelineLabelMetrics.actionRowHeight(traitCollection)
      // The collection view showed the parent alone, without a header.
      case .threadRepliesHeader: return 0
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

  #if DEBUG
  private static let forcesLegacyRows = CommandLine.arguments.contains("--timeline-legacy-rows")
  #endif

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
    let album = row.content.album
    guard width > 0,
          MessageViewContent.supports(message, displayMode: isThreadAnchor ? .threadAnchor : .normal, album: album)
    else { return nil }
    #if DEBUG
    // The harness can show every message with the older view, to check the fallback rows.
    if Self.forcesLegacyRows { return nil }
    #endif
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
      message, album: album, context: context, footer: pacer.isStreaming(message.id) ? .reserved : .visible,
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
    configure(view, id: id, width: width, timing: .none, isNew: true)
    return view
  }

  private func configure(
    _ view: TimelineRowView, id: ChatRowID, width: CGFloat, timing: TimelineTiming, isNew: Bool = false
  ) {
    guard let row = row(id) else { return }
    // A row a menu holds live keeps what it shows; a view made for it now shows the row as it is.
    if !isNew, heldRows.contains(id), menu.liveSourceID == id { return }
    defer {
      view.isMenuSourceHidden = menu.isSource(id)
      view.isSendTargetHidden = flightTargets.contains(id)
      // A swipe replies to a message that can take a reply; never to the thread's parent. On an
      // album it replies to the album's caption (or first) item.
      if let message = Self.actionMessage(of: row.content), message.canReply {
        view.replyMessage = message
      } else {
        view.replyMessage = nil
      }
      view.messageActions = messageActions(for: row)
      if let message = Self.actionMessage(of: row.content),
         let remaining = row.content.messages.lazy.compactMap({ self.focusHighlightRemaining(for: $0.message.messageId) }).first
      {
        view.highlightBubble(outgoing: message.message.out == true, theme: theme, hold: remaining, fadeIn: false)
      }
    }
    switch row.content {
      case let .message(message, grouping):
        configureMessage(view, row, message, grouping, isThreadAnchor: false, width: width, timing: timing)
      case let .album(album, grouping):
        configureMessage(view, row, album.lead, grouping, isThreadAnchor: false, width: width, timing: timing)
      case let .threadParent(message):
        configureMessage(
          view, row, message, Self.threadParentGrouping(message), isThreadAnchor: true, width: width, timing: timing
        )
      case let .daySeparator(dayStart):
        // As the collection view's day badges: a tap puts the day's first message at the top.
        view.showLabel(Self.dayTitle(dayStart), style: .pill, theme: theme) { [weak self] in
          // A tap that stops a fling only stops it, as on the floating date.
          guard let self, CACurrentMediaTime() - list.lastFlightCatch > 0.15 else { return }
          jumpToDay(dayStart)
        }
      case .unreadLine:
        view.showLabel("Unread messages", style: .line, theme: theme)
      case let .statusNotice(text):
        view.showLabel(text, style: .notice, theme: theme)
      case .collapsedHistory:
        // As the collection view: tapping brings the hidden history back.
        view.showLabel("Cleared", style: .action, theme: theme) { [weak self] in
          Task { @MainActor in
            do {
              try await self?.collapseHistory(maxID: nil)
            } catch {
              Log.shared.error("Failed to show collapsed history", error: error)
            }
          }
        }
      case .threadRepliesHeader:
        view.showLabel("", style: .plain, theme: theme)
        view.accessibilityElementsHidden = true
    }
  }

  private func configureMessage(
    _ view: TimelineRowView, _ row: ChatRow, _ message: FullMessage, _ grouping: ChatRowGrouping,
    isThreadAnchor: Bool, width: CGFloat, timing: TimelineTiming
  ) {
    let id = row.id
    let openSender = { [weak self] in
      guard let from = self?.row(id)?.content.message?.from else { return }
      NotificationCenter.default.post(
        name: Notification.Name("NavigateToUser"), object: nil, userInfo: ["userId": from.id]
      )
    }
    guard let plan = plan(row, message, grouping, isThreadAnchor: isThreadAnchor, width: width) else {
      view.onAvatarTap = openSender
      view.showLegacy(
        message, grouping: grouping, isThreadAnchor: isThreadAnchor, width: width, theme: theme, spaceId: spaceId,
        environment: environmentRevision
      )
      // As the collection view's cell wired the older view: photos open the gallery, and a double tap
      // set to the reactions menu opens the emoji sheet.
      view.shownLegacyView?.onPhotoTap = { [weak self] message, _, image, url in
        self?.presentPhoto(message, image: image, url: url)
      }
      view.shownLegacyView?.onReactionsMenu = { [weak self] message in self?.menuActions.showReactionEmojiPicker(for: message) }
      return
    }
    let messageView = view.showMessage()
    messageView.spaceId = spaceId
    messageView.onAvatarTap = openSender
    messageView.onPhotoTap = { [weak self] message, _, image, url in self?.presentPhoto(message, image: image, url: url) }
    messageView.onReactionsMenu = { [weak self] message in self?.menuActions.showReactionEmojiPicker(for: message) }
    // A disclosure opened or closed, or a streamed line was revealed: the row is planned again
    // and the list moves with it.
    messageView.onContentStateChange = { [weak self] _ in self?.replanKeepingTop(id) }
    messageView.onRevealLineChange = { [weak self] _ in self?.replan(id, timing: Self.streamingLineTiming) }
    messageView.apply(plan.content, layout: plan.layout, motion: Self.motion(for: timing))
  }

  /// The actions button of a message row, shown when the user gave the hold another action; it opens
  /// the menu a hold would. Never on the thread's parent, as the collection view's cells.
  private func messageActions(for row: ChatRow) -> TimelineRowView.MessageActions? {
    guard !isPreview, let message = Self.actionMessage(of: row.content),
          TimelineMessageMenu.customHoldAction(for: message) != nil
    else { return nil }
    let id = row.id
    if menu.usesSystemMenu {
      return .menu { [weak self] in self?.menu.pullDownMenu(id) ?? UIMenu(children: []) }
    }
    return .open { [weak self] in self?.menu.open(id) }
  }

  /// The hold action changed or VoiceOver started or stopped: the rows on screen update their button.
  @objc private func refreshMessageActions() {
    for placement in list.layout.placements {
      guard let view = list.view(for: placement.id) as? TimelineRowView, let row = row(placement.id) else { continue }
      view.messageActions = messageActions(for: row)
    }
  }

  /// A disclosure the reader opened or closed: the row keeps its top, so the control stays under the
  /// finger, and grows downward. Only when its bottom would pass the usable bottom does it rise, never
  /// above the usable top. A row cut off at the top keeps its place.
  private func replanKeepingTop(_ id: ChatRowID) {
    let layout = list.layout
    guard let placement = layout.placement(for: id), let width = heights[id]?.width,
          placement.maxY > layout.viewport.usableTop, placement.y < layout.viewport.usableBottom
    else { return replan(id, timing: Self.rowTiming) }
    plans[id] = nil
    heights[id] = nil
    let newHeight = height(of: id, width: width)
    let top = placement.y - layout.viewport.usableTop
    let target = top < 0 ? top : max(0, min(top, layout.viewport.usableHeight - newHeight))
    list.apply(TimelineTransaction(scroll: .to(id, .top(target)), changed: [id], timing: Self.rowTiming))
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
    // "Mon, November 16", as the collection view's sections read.
    let format = Date.FormatStyle.dateTime.weekday(.abbreviated).month(.wide).day()
    return day.formatted(sameYear ? format : format.year())
  }

  /// Theme, text size or direction changed: every row is planned again where it stands.
  private func environmentChanged(timing: TimelineTiming = .none) {
    environmentRevision &+= 1
    plans.removeAll()
    legacyHeights.removeAll()
    heights.removeAll()
    guard let snapshot else { return }
    list.apply(TimelineTransaction(changed: Set(snapshot.ids), timing: timing))
  }

  // MARK: - Media warm-up

  /// The collection view's prefetching: rows up to the lookahead beyond the placed ones have their
  /// images and stripped thumbnails asked for before they are made, and are let go once they are
  /// beyond the lookahead again. The placed window already reaches ahead of a fling by its speed.
  private func prefetchMedia() {
    guard let snapshot, let first = list.layout.placements.first?.index,
          let last = list.layout.placements.last?.index else { return }
    if let key = prefetchKey, key.first == first, key.last == last, key.revision == snapshot.revision { return }
    prefetchKey = (first, last, snapshot.revision)
    let lookahead = InlineTinyThumbnailWarmupPolicy.adaptiveLookaheadRows()
    let rows = snapshot.rows
    let lower = max(0, first - lookahead), upper = min(rows.count - 1, last + lookahead)
    var window = Set<ChatRowID>()
    var arriving: [FullMessage] = []
    if lower <= upper {
      for index in lower ... upper {
        let row = rows[index]
        window.insert(row.id)
        // A placed row loads its own media; one that becomes placed keeps what was asked for it.
        let messages = row.content.messages
        guard index < first || index > last, prefetched[row.id] == nil, !messages.isEmpty else { continue }
        prefetched[row.id] = messages
        arriving.append(contentsOf: messages)
      }
    }
    var leaving: [FullMessage] = []
    for (id, messages) in prefetched where !window.contains(id) {
      prefetched[id] = nil
      leaving.append(contentsOf: messages)
    }
    if !leaving.isEmpty { Task.detached(priority: .utility) { await ImagePrefetcher.shared.cancelPrefetching(for: leaving) } }
    if !arriving.isEmpty { Task.detached(priority: .utility) { await ImagePrefetcher.shared.prefetchImages(for: arriving) } }
  }

  /// After an update and when scrolling stops, as the collection view does: the stripped thumbnails
  /// of the rows on screen first, then of the two newer rows and the lookahead's older ones.
  /// `unlessWarmed`: a scroll that stopped where the last warm-up was asked for (a tap that caught a
  /// fling, a pause between drags) leaves that one running instead of cancelling and asking again.
  private func warmMedia(unlessWarmed: Bool = false) {
    let shown = list.layout.visible
    if let snapshot, let first = shown.first?.index, let last = shown.last?.index {
      if unlessWarmed, let key = warmedKey, key.first == first, key.last == last, key.revision == snapshot.revision {
        return
      }
      warmedKey = (first, last, snapshot.revision)
    }
    warmupTask?.cancel()
    warmupTask = Task { @MainActor [weak self] in
      guard let self else { return }
      let previous = warmups
      warmups.removeAll()
      for warmup in previous { await InlineTinyThumbnailPrewarmer.cancel(warmup) }
      await Task.yield()
      guard !Task.isCancelled, let snapshot else { return }
      let visible = list.layout.visible
      guard let first = visible.first?.index, let last = visible.last?.index else { return }
      let rows = snapshot.rows
      let lookahead = InlineTinyThumbnailWarmupPolicy.adaptiveLookaheadRows()
      func messages(_ range: some Sequence<Int>) -> [FullMessage] {
        range.flatMap { rows.indices.contains($0) ? rows[$0].content.messages : [] }
      }
      let onScreen = messages(first ... last)
      let nearby = messages(Array(max(0, first - lookahead) ..< first) + Array((last + 1) ..< (last + 3)))
      var started: [InlineTinyThumbnailWarmup] = []
      if !onScreen.isEmpty {
        started.append(await ImagePrefetcher.shared.prepareThumbnails(for: onScreen, priority: .visible))
      }
      if !nearby.isEmpty, !Task.isCancelled {
        started.append(await ImagePrefetcher.shared.prepareThumbnails(for: nearby, priority: .nearby))
      }
      guard !Task.isCancelled else {
        for warmup in started { await InlineTinyThumbnailPrewarmer.cancel(warmup) }
        return
      }
      warmups = started
    }
  }

  // MARK: - Translation

  /// Messages loaded or changed are offered for translation, as the collection view offers them; the
  /// translations arrive as message updates. The first batch also detects the chat's languages.
  private func offerForTranslation(_ ids: some Sequence<ChatRowID>) {
    guard !isPreview, let snapshot else { return }
    // Not the thread's parent: a request names this chat's peer and its first message's chat. Every
    // item of an album is offered.
    let messages = ids.flatMap { Self.chatMessages(snapshot.row(for: $0)) }.filter { !$0.message.isServiceMessage }
    guard !messages.isEmpty else { return }
    translation.messagesDisplayed(messages: messages)
    if !hasDetectedLanguages {
      hasDetectedLanguages = true
      let peer = peer
      Task { await TranslationDetector.shared.analyzeMessages(peer: peer, messages: messages) }
    }
  }

  /// Translation was turned on or off for this chat: every row is shown again in the other text where
  /// it stands, and turning it on asks for the loaded messages' translations.
  private func translationToggled(_ enabled: Bool) {
    environmentChanged(timing: Self.rowTiming)
    if enabled, let snapshot { offerForTranslation(snapshot.ids) }
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
    // Nothing is placed until the fetch ends, so no frame shows the latest messages first.
    if unreadFetchBoundary != nil {
      beginUnreadFetchIfNeeded()
      if unreadFetchBoundary != nil { return }
    }
    hasOpened = true
    if !isPreview {
      ChatOpenTrace.listOpened(peer: peer, list: "timeline")
      // The window read ahead was this open's; a later open reads again, from where this one leaves the chat.
      ChatOpenPreparation.shared.discard(peer: peer)
    }
    self.snapshot = snapshot
    rebuildDayRows()
    var scroll = TimelineScroll<ChatRowID>.latest
    // A focus asked for as the chat opened wins over the opening place, placed without motion. Only its
    // own message: a nearby one stands in only after the window around it loaded (`apply`).
    // Its load already ran (its window was published before the list opened): a nearby message stands in.
    let focusLoaded = pendingFocus.map { !$0.awaitsArrival && jumpTask == nil } ?? false
    if let focus = resolveFocus(in: snapshot, exactOnly: !focusLoaded) {
      list.apply(TimelineTransaction(rows: snapshot.ids, coverage: coverage(snapshot), scroll: .to(focus.row, .center)))
      focusResolved(focus, opening: true)
      readPass(force: true)
      warmMedia()
      offerForTranslation(snapshot.ids)
      return
    }
    if focusLoaded {
      pendingFocus = nil
      ToastManager.shared.showToast("Message unavailable", type: .error, systemImage: "exclamationmark.triangle.fill")
    }
    switch openAnchor {
      case .latest:
        break
      case .unread:
        // Below where the date pill sits, as the collection view places it.
        if snapshot.index(of: .unreadLine) != nil { scroll = .to(.unreadLine, .top(datePillHeight)) }
      case let .saved(place):
        if let row = snapshot.rows.first(where: { Self.chatMessages($0).contains { $0.message.messageId == place.messageId } }) {
          scroll = .to(row.id, .top(place.offset))
        }
    }
    list.apply(TimelineTransaction(rows: snapshot.ids, coverage: coverage(snapshot), scroll: scroll))
    if case .to = scroll, !list.layout.isAtBottom { holdsOpeningPlace = true }
    #if DEBUG
    let top = topRowPlace().flatMap { place in Self.chatMessage(row(place.id)).map { ($0.message.messageId, place.offset) } }
    debugLog("TIMELINE_DEBUG opened anchor=\(openAnchor) top=\(top.map { "\($0.0)@\(Int($0.1))" } ?? "-") window=\(viewModel.oldestLoadedMessageId ?? -1)...\(viewModel.newestLoadedMessageId ?? -1)")
    #endif
    readPass(force: true)
    warmMedia()
    offerForTranslation(snapshot.ids)
  }

  private func coverage(_ snapshot: ChatRowSnapshot) -> TimelineCoverage {
    TimelineCoverage(reachesOldest: snapshot.coverage.reachesOldest, reachesNewest: snapshot.coverage.reachesNewest)
  }

  private func apply(_ update: ChatRowUpdate) {
    guard hasOpened else {
      // A send while the unread line is fetched opens at the latest messages, with the sent one.
      if unreadFetchBoundary != nil, update.snapshot.reason == .localSend { endUnreadFetch(placesLine: false) }
      return
    }
    // Read before the rows on screen leave with the old snapshot.
    let shownMessageId = messageIdOnScreen()
    let previous = self.snapshot
    let snapshot = update.snapshot
    if snapshot.reason == .localSend {
      SendMessageAnimationDiagnostics.debug("timeline localSend received inserted=\(update.diff.insertions.count)")
    }
    self.snapshot = snapshot
    rebuildDayRows()
    let diff = update.diff
    // An edit that extends a placed row's text streams: the pacer reveals it over the next frames and
    // keeps the time hidden until edits stop, as the collection view feeds it. Before the row is planned.
    for change in diff.updates where list.layout.placement(for: change.id) != nil {
      guard let new = snapshot.row(for: change.id)?.content.message,
            let old = previous?.row(for: change.id)?.content.message else { continue }
      MessageStreamPacer.shared.messageChanged(new.id, from: old.displayText, to: new.displayText)
    }
    for change in diff.removals {
      plans[change.id] = nil
      legacyHeights[change.id] = nil
      heights[change.id] = nil
    }
    let changed = Set(diff.updates.map(\.id))
    // A row a menu holds live keeps its height and content until the menu lets go.
    if let held = menu.liveSourceID, changed.contains(held) { heldRows.insert(held) }
    for id in changed where id != menu.liveSourceID { heights[id] = nil }

    var timing = TimelineTiming.none
    var scroll = TimelineScroll<ChatRowID>.preserve
    var towards: TimelineEdge?
    var landed: (row: ChatRowID, messageId: Int64, exact: Bool)?
    switch snapshot.reason {
      case .liveAdd, .liveUpdate, .delete, .sendAck:
        timing = Self.rowTiming
        // Resting just above the newest message (within 44 pt), a new or growing message brings the list
        // to it, as the collection view followed from there.
        // Never during a fling or under an open menu; an update only when it is the newest message's
        // (the status notice can be the last row, under it).
        if snapshot.reason == .liveAdd
          || (snapshot.reason == .liveUpdate
            && snapshot.rows.last(where: { $0.content.message != nil }).map({ changed.contains($0.id) }) == true),
           !list.isTracking, !list.isDecelerating, !menu.isActive, menuInsetHold == nil,
           distanceFromBottom > 0.5, distanceFromBottom <= 44, viewModel.historyCoverage.isAtCertifiedLiveEnd
        {
          scroll = .latest
        }
      case .localSend:
        // A send with a flight scrolls on the flight's vertical curve, as Telegram's list moves with the
        // bubble; one without moves like any new row.
        timing = sendAnimationCoordinator?.hasPreparedSource == true && !UIAccessibility.isReduceMotionEnabled
          ? Self.sendTiming : Self.rowTiming
        scroll = .latest
        holdsOpeningPlace = false
        ChatReadingPlaceStore.shared.clear(for: peer)
      case let .jump(target):
        // A new window has new edges.
        blockedEdges.removeAll()
        windowGeneration &+= 1
        towards = direction(of: target, from: shownMessageId)
        if pendingFocus != nil, case .message = target {
          landed = resolveFocus(in: snapshot)
          scroll = landed.map { .to($0.row, .center) } ?? .latest
          timing = pendingFocus?.animated == false ? .none : Self.jumpTiming
          if landed == nil {
            pendingFocus = nil
            ToastManager.shared.showToast(
              "Message unavailable", type: .error, systemImage: "exclamationmark.triangle.fill"
            )
          }
        } else if case .latest = target, list.isTracking {
          // The reader took the list during a return to latest: the new window keeps their place.
          scroll = .preserve
        } else {
          scroll = jumpScroll(for: target, in: snapshot)
          timing = Self.jumpTiming
        }
      case .presentation:
        // The notice comes and goes under the newest message as rows do; a pinned list follows it.
        if diff.insertions.contains(where: { $0.id == .statusNotice }) || diff.removals.contains(where: { $0.id == .statusNotice }) {
          timing = Self.rowTiming
        }
      case .initialOpen, .olderPage, .newerPage, .refresh, .trim:
        break
    }
    // A focused message newer than the synced history arrived, however it came.
    if landed == nil, pendingFocus?.awaitsArrival == true, let focus = resolveFocus(in: snapshot) {
      landed = focus
      scroll = .to(focus.row, .center)
      if case .none = timing { timing = Self.rowTiming }
    }
    // The sent row and the composer's shrink move as one.
    let releasedInset = snapshot.reason == .localSend ? releaseComposeInsetHold(applying: false) : nil
    // One commit for the list and the flights: on its own the list's transaction reaches the screen at
    // once, and the sent row would rise into view while its bubble is snapshotted, before it is hidden.
    CATransaction.begin()
    list.apply(TimelineTransaction(
      rows: snapshot.ids, coverage: coverage(snapshot), scroll: scroll,
      bottomInset: releasedInset.map { $0 + Self.bottomPadding }, changed: changed, timing: timing,
      // A jump's new rows are history it loaded: they come in with the scroll, not as new messages.
      towards: towards, arrives: { if case .jump = snapshot.reason { false } else { true } }()
    ))
    let inserted = diff.insertions.map(\.id)
    if !inserted.isEmpty { beginSendFlights(inserted) }
    retargetSendFlights(excluding: Set(inserted))
    CATransaction.commit()
    if let landed { focusResolved(landed, opening: false) }
    menu.rowsDidUpdate(changed)
    if !isPreview { viewModel.ensureThreadAnchorCached() }
    readPass(force: true)
    warmMedia()
    offerForTranslation(diff.insertions.map(\.id) + diff.updates.map(\.id))
  }

  /// Tells the view model where the reader is, as the collection view does on every scroll: at the
  /// live end, or the newest message on screen. Reloads stay in that part of history, and a trim
  /// never removes it.
  private func reportPlace() {
    let layout = list.layout
    let atBottom = layout.isAtBottom
    var messageId: Int64?
    if !atBottom {
      for placement in layout.visible.reversed() {
        // An album's newest item, so a trim around this place keeps the whole album.
        if let id = Self.chatMessages(row(placement.id)).last?.message.messageId, id > 0 {
          messageId = id
          break
        }
      }
    }
    if let reportedPlace, reportedPlace.atBottom == atBottom, reportedPlace.messageId == messageId { return }
    reportedPlace = (atBottom, messageId)
    viewModel.setAtBottom(atBottom)
    if let messageId { viewModel.setHistoryAnchor(messageId) }
  }

  /// The server id of a message on screen, to tell which way a jump to another window goes.
  private func messageIdOnScreen() -> Int64? {
    for placement in list.layout.visible.reversed() {
      if let id = Self.chatMessage(row(placement.id))?.message.messageId, id > 0 { return id }
    }
    return nil
  }

  private func direction(of target: ChatRowJumpTarget, from shown: Int64?) -> TimelineEdge? {
    let destination: Int64
    switch target {
      case .latest: return .newer
      case let .message(id): destination = pendingFocus?.messageId ?? id
      case let .unreadLine(boundary): destination = boundary
    }
    guard let shown else { return nil }
    return destination < shown ? .older : .newer
  }

  private func jumpScroll(for target: ChatRowJumpTarget, in snapshot: ChatRowSnapshot) -> TimelineScroll<ChatRowID> {
    switch target {
      case .latest:
        return .latest
      case .unreadLine:
        return snapshot.index(of: .unreadLine) != nil ? .to(.unreadLine, .top(datePillHeight)) : .latest
      case let .message(messageId):
        guard let row = snapshot.rows.first(where: { Self.chatMessages($0).contains { $0.message.messageId == messageId } })
        else { return .latest }
        return .to(row.id, .center)
    }
  }

  // MARK: - Uncached unread line

  /// Offline (the realtime connection is still connecting), the chat opens at the latest cached
  /// messages rather than waiting on a fetch.
  private var isOfflineForUnreadFetch: Bool {
    #if DEBUG
    if Self.debugLoadAround != nil { return false }
    #endif
    return Api.realtime.stateObject.connectionState == .connecting
  }

  private func beginUnreadFetchIfNeeded() {
    guard let boundary = unreadFetchBoundary, unreadFetchTask == nil else { return }
    guard !isOfflineForUnreadFetch else {
      unreadFetchBoundary = nil
      return
    }
    alpha = 0
    let peer = peer
    unreadFetchTask = Task { @MainActor [weak self] in
      var placesLine = false
      do {
        #if DEBUG
        if let load = Self.debugLoadAround {
          try await load(boundary)
        } else {
          _ = try await MessageHistoryRepairCoordinator.shared.loadAround(
            peer: peer, anchorID: max(1, boundary), limit: ChatUnreadOpening.windowLimit
          )
        }
        #else
        _ = try await MessageHistoryRepairCoordinator.shared.loadAround(
          peer: peer, anchorID: max(1, boundary), limit: ChatUnreadOpening.windowLimit
        )
        #endif
        guard let self, unreadFetchBoundary == boundary, !Task.isCancelled else { return }
        placesLine = try await viewModel.loadUnreadOpeningWindowAsync(boundary: boundary)
      } catch {
        Log.shared.error("Unread history fetch failed; opening at the latest messages", error: error)
      }
      guard let self, unreadFetchBoundary == boundary, !Task.isCancelled else { return }
      endUnreadFetch(placesLine: placesLine)
    }
    #if DEBUG
    let watchesConnection = Self.debugLoadAround == nil
    #else
    let watchesConnection = true
    #endif
    if watchesConnection {
      // A lost connection would keep the list hidden until it returns.
      unreadFetchConnection = Api.realtime.stateObject.$connectionState
        .sink { [weak self] state in
          guard state == .connecting else { return }
          DispatchQueue.main.async { self?.endUnreadFetch(placesLine: false) }
        }
    }
    // A fast fetch shows the chat before any spinner does.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
      guard let self, unreadFetchBoundary == boundary, unreadFetchSpinner == nil, let superview else { return }
      let spinner = UIActivityIndicatorView(style: .medium)
      spinner.center = CGPoint(x: frame.midX, y: frame.midY)
      spinner.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin, .flexibleTopMargin, .flexibleBottomMargin]
      superview.addSubview(spinner)
      spinner.startAnimating()
      unreadFetchSpinner = spinner
    }
  }

  /// Ends the fetch once: the list opens at the line when its window loaded, else at the latest
  /// messages, and fades in.
  private func endUnreadFetch(placesLine: Bool) {
    guard let boundary = unreadFetchBoundary else { return }
    unreadFetchBoundary = nil
    unreadFetchTask?.cancel()
    unreadFetchTask = nil
    unreadFetchConnection = nil
    unreadFetchSpinner?.removeFromSuperview()
    unreadFetchSpinner = nil
    if placesLine { openAnchor = .unread(boundary: boundary) }
    setNeedsLayout()
    layoutIfNeeded()
    UIView.animate(withDuration: 0.15) { self.alpha = 1 }
    // The open's read ran while the list was still hidden; read what the fade reveals.
    readPass(force: true)
  }

  // MARK: - History

  private func loadHistory(_ edge: TimelineEdge) {
    guard !isPreview, !loadingEdges.contains(edge), !blockedEdges.contains(edge), window != nil else { return }
    loadingEdges.insert(edge)
    historyTasks[edge] = Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        loadingEdges.remove(edge)
        historyTasks[edge] = nil
      }
      let generation = windowGeneration
      // A page that failed or brought nothing for this window blocks its edge; a cancelled one or one
      // for a window since replaced does not.
      let block = { [weak self] in
        guard let self, !Task.isCancelled, windowGeneration == generation else { return }
        blockedEdges.insert(edge)
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
          if outcome == .empty {
            block()
            return
          }
        } catch {
          block()
          return
        }
      }
      if await viewModel.loadBatchAsync(at: direction, allowUnavailableLocal: !local) {
        trimWindow(keeping: edge)
      } else {
        block()
      }
    }
  }

  /// After a page, a long window's far side leaves (the view model keeps about 600 messages), so
  /// paging through a long chat keeps planning and memory bounded. Never while a finger is down,
  /// a fling runs or the other edge loads: then it waits for the scroll to end.
  private func trimWindow(keeping edge: TimelineEdge) {
    guard !list.isTracking, !list.isDecelerating, loadingEdges.subtracting([edge]).isEmpty else {
      pendingTrimEdge = edge
      return
    }
    pendingTrimEdge = nil
    Task { @MainActor [weak self] in
      guard let self else { return }
      _ = await viewModel.trimWindow(keeping: edge == .older ? .older : .newer)
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
    guard let coordinator = sendAnimationCoordinator else { return }
    for id in inserted {
      guard case let .message(message, _)? = row(id)?.content,
            let identity = coordinator.pendingIdentity(for: message),
            !coordinator.isAnimating(identity: identity)
      else { continue }
      guard let (target, rowView) = flightTarget(for: id, message: message, identity: identity) else {
        coordinator.cancel(identity: identity)
        continue
      }
      flightTargets.insert(id)
      flightFrames[id] = target.bubbleFrameInWindow
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

  /// Flights already in the air land where their rows are now: a second send or a message arriving
  /// mid-flight moves the row, as the collection view retargeted them.
  private func retargetSendFlights(excluding begun: Set<ChatRowID>) {
    guard let coordinator = sendAnimationCoordinator, !flightTargets.isEmpty else { return }
    for (stableId, identity) in coordinator.activeAnimatingIdentitiesByStableMessageId() {
      let id = ChatRowID.message(stableId)
      guard flightTargets.contains(id), !begun.contains(id) else { continue }
      // An ack or a change elsewhere leaves the row where it was: the flight goes on undisturbed (and no
      // snapshot is taken).
      if let current = flightFrames[id], let window, let messageView = (list.view(for: id) as? TimelineRowView)?.shownMessageView,
         let frames = messageView.sendAnimationTargetFrames()
      {
        let bubble = messageView.convert(frames.bubble, to: window)
        if abs(current.minY - bubble.minY) < 0.5, abs(current.minX - bubble.minX) < 0.5,
           abs(current.height - bubble.height) < 0.5, abs(current.width - bubble.width) < 0.5
        {
          continue
        }
      }
      guard case let .message(message, _)? = row(id)?.content,
            let (target, _) = flightTarget(for: id, message: message, identity: identity)
      else {
        endFlight(id)
        coordinator.cancel(identity: identity)
        continue
      }
      flightFrames[id] = target.bubbleFrameInWindow
      let duration = coordinator.retargetDuration(for: identity) ?? SendMessageAnimationTiming.duration
      coordinator.retargetIfPossible(target: target, duration: duration) { [weak self] _ in self?.endFlight(id) }
    }
  }

  /// Where a sent row's bubble and text settle, in window coordinates. The row and the list are at their
  /// settled places in the model; the motion on screen is additive tracks.
  private func flightTarget(
    for id: ChatRowID, message: FullMessage, identity: SendMessageAnimationIdentity
  ) -> (SendMessageAnimationTarget, TimelineRowView)? {
    guard let window, let rowView = list.view(for: id) as? TimelineRowView, let messageView = rowView.shownMessageView,
          let frames = messageView.sendAnimationTargetFrames()
    else { return nil }
    // The background grows out of the composer's field under the content, as Telegram's does; a
    // bubbleless message flies whole.
    let parts = messageView.sendAnimationBubbleParts()
    guard let snapshot = parts?.content ?? messageView.sendAnimationBubbleSnapshot() else { return nil }
    let bubbleFrame = messageView.convert(frames.bubble, to: window)
    let textFrame = messageView.convert(frames.text, to: window)
    let baseline = messageView.convert(CGPoint(x: 0, y: frames.firstBaseline), to: window).y
    guard bubbleFrame.isFiniteAndVisible, textFrame.isFiniteAndVisible, baseline.isFinite else { return nil }
    let target = SendMessageAnimationTarget(
      identity: identity,
      messageStableId: message.id,
      bubbleFrameInWindow: bubbleFrame,
      textFrameInWindow: textFrame,
      bubbleSnapshotView: snapshot,
      bubbleBackground: parts?.background,
      textFrameInBubble: frames.text.offsetBy(dx: -frames.bubble.minX, dy: -frames.bubble.minY),
      textFirstBaselineYInWindow: baseline,
      textFirstBaselineYInBubble: frames.firstBaseline - frames.bubble.minY,
      bubbleTailSide: message.message.out == true ? .trailing : .leading
    )
    return (target, rowView)
  }

  private func endFlight(_ id: ChatRowID) {
    flightTargets.remove(id)
    flightFrames[id] = nil
    (list.view(for: id) as? TimelineRowView)?.isSendTargetHidden = false
  }

  /// The scroll button: back to where the last reply jump started, then to the newest messages.
  func scrollToBottom() {
    let onScreen = Set(visibleMessages().map(\.message.messageId))
    while let last = replyReturns.popLast() {
      // A jump that left its reply on screen has nothing to go back to.
      guard !onScreen.contains(last.messageId) else { continue }
      #if DEBUG
      debugLog("TIMELINE_DEBUG reply return \(last.messageId)")
      #endif
      focus(last.messageId, requiresExactMessage: false, highlights: false)
      return
    }
    scrollToLatest()
  }

  private func scrollToLatest() {
    replyReturns.removeAll()
    endUnreadFetch(placesLine: false)
    ChatReadingPlaceStore.shared.clear(for: peer)
    if viewModel.historyCoverage.isAtCertifiedLiveEnd {
      cancelPendingMessageFocus()
      // Near: the rows travel there. Far: the screen slides out and the newest rows in.
      let near = distanceFromBottom < bounds.height * 3
      list.apply(TimelineTransaction(scroll: .latest, timing: near ? Self.rowTiming : Self.jumpTiming, towards: .newer))
      return
    }
    if let running = returnToLatestTask {
      // A tap after the reader scrolled away from the first landing starts over.
      guard returnToLatestInterrupted else { return }
      running.cancel()
      returnToLatestTask = nil
    }
    cancelPendingMessageFocus()
    returnToLatestInterrupted = false
    returnToLatestGeneration &+= 1
    let generation = returnToLatestGeneration
    let account = try? Auth.shared.handle.beginAccountMutation()
    returnToLatestTask = Task { @MainActor [weak self] in
      guard let self else { return }
      defer { if returnToLatestGeneration == generation { returnToLatestTask = nil } }
      do {
        // The cached latest window first (its publish moves the list), then the server's.
        _ = try await viewModel.loadLatestWindowAsync()
        try Task.checkCancellation()
        var transaction = GetChatHistoryTransaction(peer: peer, mode: .historyModeLatest)
        transaction.type = .ephemeral()
        _ = try await Api.realtime.send(transaction, expectedAccount: account)
        try Task.checkCancellation()
        // A reader who scrolled since landing keeps their place: replacing the window would move it.
        guard !returnToLatestInterrupted else { return }
        _ = try await viewModel.loadLatestWindowAsync()
      } catch is CancellationError {
        return
      } catch {
        guard !Task.isCancelled else { return }
        if !returnToLatestInterrupted {
          // A useful cached latest window, with the coverage still unknown.
          _ = try? await viewModel.loadLatestWindowAsync()
        }
        ToastManager.shared.showToast("Could not load latest history", type: .error)
      }
    }
  }

  /// A finger on the list: a focus still waiting for its message to sync no longer moves the list,
  /// and a return to latest still fetching stops moving it, as the collection view's drag did.
  private func dragBegan() {
    // The reader goes on: the last stop's settle work waits for the next one.
    settleWork?.cancel()
    settleWork = nil
    holdsOpeningPlace = false
    blockedEdges.removeAll()
    if pendingFocus?.awaitsArrival == true, jumpTask == nil { pendingFocus = nil }
    if returnToLatestTask != nil { returnToLatestInterrupted = true }
  }

  func cancelPendingMessageFocus() {
    // A move the reader asked for (a focus, the latest messages, a day) leaves the opening place.
    holdsOpeningPlace = false
    jumpTask?.cancel()
    jumpTask = nil
    pendingFocus = nil
    focusRevision &+= 1
  }

  func scrollToMessageWhenAvailable(_ messageID: Int64, requiresExactMessage: Bool) {
    focus(messageID, requiresExactMessage: requiresExactMessage, highlights: true)
  }

  private func focus(_ messageID: Int64, requiresExactMessage: Bool, highlights: Bool) {
    // An explicit focus wins over the unread line still being fetched and a return to latest.
    endUnreadFetch(placesLine: false)
    cancelPendingMessageFocus()
    returnToLatestTask?.cancel()
    returnToLatestTask = nil
    guard !requiresExactMessage || !isHiddenByCollapsedHistory(messageID) else {
      #if DEBUG
      debugLog("TIMELINE_DEBUG focus unavailable (cleared) \(messageID)")
      #endif
      ToastManager.shared.showToast("Message unavailable", type: .error, systemImage: "exclamationmark.triangle.fill")
      return
    }
    pendingFocus = PendingFocus(
      messageId: messageID, requiresExact: requiresExactMessage, animated: hasOpened, highlights: highlights
    )
    // A row already loaded: there now, or where the chat opens (the first layout places it).
    if viewModel.historyCoverage.isCertifiedMessage(messageID) {
      if hasOpened, let snapshot, let focus = resolveFocus(in: snapshot, exactOnly: true) {
        let near = list.layout.placement(for: focus.row) != nil
        list.apply(TimelineTransaction(
          scroll: .to(focus.row, .center), timing: near ? Self.rowTiming : Self.jumpTiming,
          towards: direction(of: .message(messageID), from: messageIdOnScreen())
        ))
        focusResolved(focus, opening: false)
        return
      }
      if !hasOpened, let snapshot = viewModel.rowFeed.snapshot, messageRow(messageID, in: snapshot) != nil { return }
    }
    let unavailable = requiresExactMessage ? "Message unavailable" : "Could not load that message"
    let limit = MessagesProgressiveViewModel.defaultInitialLimit()
    let peer = peer
    jumpTask = Task { @MainActor [weak self] in
      do {
        // Certified history is already in the cache: no round trip.
        var outcome: MessageHistoryRepairCoordinator.Outcome?
        if self?.viewModel.historyCoverage.isCertifiedMessage(messageID) != true {
          outcome = try await MessageHistoryRepairCoordinator.shared.loadAround(
            peer: peer, anchorID: messageID, limit: limit
          )
        }
        guard let self, !Task.isCancelled, pendingFocus?.messageId == messageID else { return }
        jumpTask = nil
        if !requiresExactMessage, isAheadOfLoadedLiveEnd(messageID) {
          // A pushed message can precede sync: stay at the live end until the update that brings it.
          pendingFocus?.awaitsArrival = true
          #if DEBUG
          debugLog("TIMELINE_DEBUG focus awaits arrival \(messageID)")
          #endif
          if hasOpened {
            list.apply(TimelineTransaction(scroll: .latest, timing: Self.rowTiming, towards: .newer))
          }
          return
        }
        // The window's publish places the message, or its nearest neighbour (`apply`).
        guard !requiresExactMessage || !isHiddenByCollapsedHistory(messageID), outcome != .empty,
              viewModel.loadLocalWindowAroundMessage(messageId: messageID)
        else {
          // An empty window's publish may have said so already (`apply`).
          guard pendingFocus?.messageId == messageID else { return }
          pendingFocus = nil
          ToastManager.shared.showToast(unavailable, type: .error, systemImage: "exclamationmark.triangle.fill")
          return
        }
      } catch is CancellationError {
        return
      } catch {
        guard let self, !Task.isCancelled, pendingFocus?.messageId == messageID else { return }
        jumpTask = nil
        pendingFocus = nil
        Log.shared.error("Failed to load focused message", error: error)
        ToastManager.shared.showToast(unavailable, type: .error, systemImage: "exclamationmark.triangle.fill")
      }
    }
  }

  private func isHiddenByCollapsedHistory(_ messageID: Int64) -> Bool {
    guard let boundary = viewModel.rowFeed.collapsedMaxId else { return false }
    return messageID > 0 && messageID <= boundary
  }

  private func isAheadOfLoadedLiveEnd(_ messageID: Int64) -> Bool {
    viewModel.historyCoverage.isAtCertifiedLiveEnd && messageID > (highestPositiveMessageId ?? 0)
  }

  private func messageRow(_ messageID: Int64, in snapshot: ChatRowSnapshot) -> ChatRow? {
    snapshot.rows.first { row in
      switch row.content {
        case .message, .album: row.content.contains(messageId: messageID)
        default: false
      }
    }
  }

  /// The row a pending focus lands on: its message, or (unless only that message will do) the nearest
  /// loaded one across certified history, newer first, as the collection view picked it.
  private func resolveFocus(
    in snapshot: ChatRowSnapshot, exactOnly: Bool = false
  ) -> (row: ChatRowID, messageId: Int64, exact: Bool)? {
    guard let focus = pendingFocus else { return nil }
    if let row = messageRow(focus.messageId, in: snapshot) { return (row.id, focus.messageId, true) }
    guard !exactOnly, !focus.requiresExact, !focus.awaitsArrival else { return nil }
    let ids = snapshot.rows.flatMap { row -> [Int64] in
      switch row.content {
        case .message, .album: row.content.messages.map(\.message.messageId).filter { $0 > 0 }
        default: []
      }
    }
    let target = focus.messageId
    guard let neighbour = ids.filter({ $0 > target }).min() ?? ids.filter({ $0 < target }).max(),
          viewModel.historyCoverage.isCertifiedContinuation(between: target, and: neighbour),
          let row = messageRow(neighbour, in: snapshot)
    else { return nil }
    return (row.id, neighbour, false)
  }

  /// The list is on its way to a focused message: the focus ends, and once the motion has mostly landed
  /// the message is highlighted. A nearby message stands in without a highlight, and says so unless it
  /// is simply the newest one.
  private func focusResolved(_ focus: (row: ChatRowID, messageId: Int64, exact: Bool), opening: Bool) {
    let requested = pendingFocus?.messageId
    let animated = pendingFocus?.animated ?? true
    let highlights = pendingFocus?.highlights ?? true
    pendingFocus = nil
    jumpTask = nil
    #if DEBUG
    debugLog("TIMELINE_DEBUG focus requested=\(requested ?? -1) landed=\(focus.messageId) exact=\(focus.exact) opening=\(opening)")
    #endif
    // Back where a reply jump started: no flash, and a reply deleted since lands on its neighbour quietly.
    guard highlights else { return }
    guard focus.exact else {
      if let requested, !(focus.messageId < requested && focus.messageId == highestPositiveMessageId) {
        ToastManager.shared.showToast("Message unavailable. Showing nearby history.", type: .info)
      }
      return
    }
    focusRevision &+= 1
    let revision = focusRevision
    // An opening waits out the push so the highlight is seen.
    let delay = opening || !animated ? 0.55 : 0.35
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
      guard let self, focusRevision == revision else { return }
      let hold = TimelineRowView.focusHighlightHold
      focusHighlight = (focus.messageId, CACurrentMediaTime() + TimelineRowView.focusHighlightFadeIn + hold)
      for placement in list.layout.placements {
        (list.view(for: placement.id) as? TimelineRowView)?.clearHighlight()
      }
      guard let snapshot, let row = messageRow(focus.messageId, in: snapshot),
            let message = row.content.message,
            let view = list.view(for: row.id) as? TimelineRowView else { return }
      view.highlightBubble(outgoing: message.message.out == true, theme: theme, hold: hold, fadeIn: true)
    }
  }

  /// What is left of a running jump highlight, for a row that is shown again.
  private func focusHighlightRemaining(for messageId: Int64) -> TimeInterval? {
    guard let focusHighlight, focusHighlight.messageId == messageId else { return nil }
    let remaining = focusHighlight.endsAt - CACurrentMediaTime()
    guard remaining > 0.05 else {
      self.focusHighlight = nil
      return nil
    }
    return remaining
  }

  @objc private func scrollToRepliedMessage(_ note: Notification) {
    guard let messageId = note.userInfo?["repliedToMessageId"] as? Int64,
          let noteChatId = note.userInfo?["chatId"] as? Int64, noteChatId == chatId, window != nil else { return }
    // A reply tapped in the list: the scroll button comes back to it (an older message is what replies quote).
    if let source = note.userInfo?["sourceMessageId"] as? Int64, source > messageId {
      replyReturns.removeAll { $0.messageId == source }
      replyReturns.append(ReplyReturn(messageId: source))
      if replyReturns.count > 32 { replyReturns.removeFirst() }
    }
    scrollToMessageWhenAvailable(messageId, requiresExactMessage: false)
  }

  /// Drops the reply returns the reader has scrolled back down to.
  private func updateReplyReturns() {
    guard !replyReturns.isEmpty, let newest = messageIdOnScreen() else { return }
    for index in replyReturns.indices where newest < replyReturns[index].messageId {
      replyReturns[index].hasLeftScreen = true
    }
    replyReturns.removeAll { $0.hasLeftScreen && newest >= $0.messageId }
  }

  // MARK: - Status bar, VoiceOver

  /// The status bar's tap, as the collection view took it: UIKit scrolls that inverted scroll view
  /// to its content's top, which is the newest message at the bottom of the screen.
  private func statusBarTapped() {
    #if DEBUG
    debugLog("TIMELINE_DEBUG status bar tap")
    #endif
    guard hasOpened, !menu.isActive else { return }
    scrollToLatest()
  }

  /// What VoiceOver says after a page: when the messages on screen were sent, and whether the page
  /// reached an end of the chat.
  private func accessibilityPageDescription() -> String? {
    guard let snapshot else { return nil }
    let dates = list.layout.visible.compactMap { snapshot.row(for: $0.id)?.content.message?.message.date }
    guard let first = dates.min(), let last = dates.max() else { return nil }
    let calendar = Calendar.autoupdatingCurrent
    let time = { (date: Date) in date.formatted(date: .omitted, time: .shortened) }
    var words = "\(Self.dayTitle(calendar.startOfDay(for: first))) \(time(first))"
    if last.timeIntervalSince(first) >= 60 {
      words += calendar.isDate(first, inSameDayAs: last)
        ? " to \(time(last))"
        : " to \(Self.dayTitle(calendar.startOfDay(for: last))) \(time(last))"
    }
    if distanceFromBottom <= 12, viewModel.historyCoverage.isAtCertifiedLiveEnd {
      words += ", latest messages"
    } else if list.layout.distanceToOldest.map({ $0 <= 0.5 }) == true, snapshot.coverage.reachesOldest {
      words += ", start of the conversation"
    }
    return words
  }

  #if DEBUG
  /// The harness's stand-in for VoiceOver, which the simulator cannot drive: the object names what
  /// to do ("older", "newer", "dump", "focusTop", "focusBottom"); results go to standard output.
  static let debugAccessibilityNotification = Notification.Name("TimelineDebugAccessibility")

  /// Unbuffered, so a harness run's output is there while the app still runs.
  private func debugLog(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
  }

  @objc private func debugAccessibility(_ note: Notification) {
    guard window != nil, let action = note.object as? String else { return }
    let rows = (list.accessibilityElements ?? []).compactMap { $0 as? UIView }
    func describe(_ row: UIView) -> String {
      var labels: [String] = []
      func walk(_ object: Any, depth: Int) {
        guard depth < 8, labels.count < 2 else { return }
        if let element = object as? NSObject, element.isAccessibilityElement, let label = element.accessibilityLabel,
           !label.isEmpty
        {
          labels.append(String(label.prefix(40)))
          return
        }
        if let view = object as? UIView, view.isHidden || view.accessibilityElementsHidden { return }
        let children = (object as? NSObject)?.accessibilityElements ?? (object as? UIView)?.subviews ?? []
        for child in children { walk(child, depth: depth + 1) }
      }
      walk(row, depth: 0)
      let y = row.convert(row.bounds, to: list).minY
      return "y=\(Int(y)) \(labels.joined(separator: " | "))"
    }
    switch action {
      case "older", "newer":
        let moved = list.accessibilityScroll(action == "older" ? .down : .up)
        debugLog("TIMELINE_DEBUG a11y page \(action) moved=\(moved) says=\(accessibilityPageDescription() ?? "nil") rows=\(list.layout.placements.first?.index ?? -1)...\(list.layout.placements.last?.index ?? -1) of \(snapshot?.rows.count ?? 0)")
      case "dump":
        debugLog("TIMELINE_DEBUG a11y elements \(rows.count):")
        for row in rows { debugLog("TIMELINE_DEBUG   \(describe(row))") }
      case "focusTop", "focusBottom":
        guard let row = action == "focusTop" ? rows.first : rows.last else { return }
        let revealed = list.revealAccessibilityElement(row)
        debugLog("TIMELINE_DEBUG a11y focus \(action) revealed=\(revealed) \(describe(row)) rows=\(list.layout.placements.first?.index ?? -1)...\(list.layout.placements.last?.index ?? -1) of \(snapshot?.rows.count ?? 0)")
      default:
        break
    }
  }
  #endif

  // MARK: - Read state, reading place, scroll button

  func setUnreadState(_ state: ChatActivityNavigator.State) {
    // Marking the chat unread supersedes what this list read before; only when newly marked, or every
    // later emission while the mark is set would undo scroll reads.
    if state.unreadMark, !unreadState.unreadMark {
      readFrontier = 0
      lastReadCandidate = 0
    }
    // The chat may be unread again (a mark, a count from the server, a cursor short of the last read):
    // the next pass at the live end reads it whole again.
    if state.unreadMark || state.unreadCount > 0 || state.readInboxMaxId < (readAllThrough ?? 0) {
      readAllThrough = nil
    }
    unreadState = state
    updateAffordance(force: true)
  }

  private func layoutChanged() {
    reportPlace()
    prefetchMedia()
    updateReplyReturns()
    // The count follows every frame; the read itself is written a few times a second at most.
    advanceReadFrontier()
    updateAffordance(force: false)
    updateDatePill()
    readPass(force: false)
  }

  private func scrollEnded() {
    scheduleDatePillHide()
    // What the list stopped on is read at once.
    readPass(force: true)
    settleWork?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.listSettled() }
    settleWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
  }

  /// The list rested after a scroll: a trim that waited for it, the stripped thumbnails around the rows on
  /// screen, and the reading place. A drag in the meantime cancels it (`dragBegan`); leaving the chat
  /// saves the place itself.
  private func listSettled() {
    settleWork = nil
    guard !list.isTracking, !list.isDecelerating else { return }
    if let edge = pendingTrimEdge, loadingEdges.isEmpty { trimWindow(keeping: edge) }
    warmMedia(unlessWarmed: true)
    saveReadingPlace()
  }

  @objc private func applicationDidBecomeActive() {
    lastReadCandidate = 0
    // Notifications may have landed for messages already read here; reading the chat clears them.
    readAllThrough = nil
    readPass(force: true)
  }

  /// The system may end the app from the background without the chat ever leaving the screen, so
  /// the place is saved here too, as Telegram saves its scroll state: a jump that ended without a
  /// scroll (a reply, a pin, a search result) has saved nothing yet.
  @objc private func applicationDidEnterBackground() {
    guard window != nil else { return }
    saveReadingPlace()
  }

  private func visibleMessages() -> [FullMessage] {
    guard let snapshot else { return [] }
    // Every item of an album on screen is seen.
    return list.layout.visible.flatMap { Self.chatMessages(snapshot.row(for: $0.id)) }
      .filter { $0.message.messageId > 0 }
  }

  /// What is on screen counts as seen: a list on screen in an active, foreground scene, placed, and not on
  /// its way to a focused message. A focus waiting for its message to sync keeps the list at the live end,
  /// whose rows are read as usual: the message may never arrive (deleted, or the push ran ahead of a
  /// failed sync).
  private var readsWhatIsShown: Bool {
    guard !isPreview, hasOpened, chatId != nil, let window, !isHidden, alpha > 0.01,
          window.windowScene?.activationState == .foregroundActive,
          UIApplication.shared.applicationState == .active,
          unreadFetchBoundary == nil, pendingFocus == nil || pendingFocus?.awaitsArrival == true
    else { return false }
    return true
  }

  /// The newest message others sent among the rows on screen, service rows and every item of an album
  /// included. Runs on every layout of a scroll, so it builds no arrays.
  private func newestVisibleIncomingId() -> Int64? {
    guard let snapshot else { return nil }
    var newest: Int64 = 0
    func see(_ message: FullMessage) {
      let id = message.message.messageId
      if id > newest, message.message.out != true { newest = id }
    }
    for placement in list.layout.visible {
      switch snapshot.row(for: placement.id)?.content {
        case let .message(message, _)?: see(message)
        case let .album(album, _)?: for item in album.items { see(item) }
        default: break
      }
    }
    return newest > 0 ? newest : nil
  }

  /// The newest stored message the window holds, yours included, or 0: what a read of the whole chat
  /// reads through.
  private func newestLoadedMessageId() -> Int64 {
    guard let rows = snapshot?.rows else { return 0 }
    for row in rows.reversed() {
      let ids = Self.chatMessages(row).map(\.message.messageId).filter { $0 > 0 }
      if let newest = ids.max() { return newest }
    }
    return 0
  }

  /// Lowers the scroll button's count as incoming messages come into view, on every layout, as the
  /// collection view's count followed the scroll: only the list's own frontier moves, which
  /// `ChatUnreadBadgeCount` subtracts until the read written by `readPass` lands.
  private func advanceReadFrontier() {
    guard readsWhatIsShown, let candidate = newestVisibleIncomingId(), candidate > readFrontier else { return }
    readFrontier = candidate
    updateAffordance(force: true)
  }

  /// Marks what the reader has seen: only for a list on screen in an active, foreground scene, placed,
  /// and not on its way to a focused message. Reads as the list moves, a few times a second, like
  /// Telegram: the write is local, so the scroll button, the chat list and the icon fall together,
  /// and the read sync tells the server. A list update no longer re-renders the chat (the root
  /// observes only the tab badge, and a covered list holds its updates), which is what used to make
  /// mid-scroll reads hitch.
  private func readPass(force: Bool, leaving: Bool = false) {
    let now = CACurrentMediaTime()
    guard force || now - lastReadPass > 0.3 else { return }
    lastReadPass = now
    guard readsWhatIsShown, let chatId else {
      if window == nil || UIApplication.shared.applicationState != .active { onVisibleMessagesChanged?(nil) }
      return
    }
    // Everything others sent that is on screen is seen, service rows included.
    let candidate = newestVisibleIncomingId()
    let isMoving = (list.isTracking || list.isDecelerating) && !leaving
    // The count falls with what is seen, before the write lands; at the live end too.
    if let candidate, candidate > readFrontier {
      readFrontier = candidate
      updateAffordance(force: true)
    }
    if distanceFromBottom <= 12, viewModel.historyCoverage.isAtCertifiedLiveEnd {
      // Only the real live end stands for every message; a window's bottom does not. Once per newest
      // message: a drag resting at the bottom, or a reply streaming in, reads nothing new.
      let newest = newestLoadedMessageId()
      if readAllThrough != newest {
        readAllThrough = newest
        #if DEBUG
        if pendingFocus != nil { debugLog("TIMELINE_DEBUG read all while a focus awaits its message") }
        debugLog("TIMELINE_DEBUG read all through \(newest)")
        #endif
        UnreadManager.shared.readAll(peer, chatId: chatId)
      }
    } else {
      if viewModel.historyCoverage != lastReadCoverage {
        lastReadCoverage = viewModel.historyCoverage
        lastReadCandidate = 0
      }
      // What is on screen, then a newer row seen since the last write that has left the screen again
      // (`advanceReadFrontier`), as the count already shows. Both, so a read is never held up by a message
      // deleted after it was seen.
      for seen in [candidate ?? 0, readFrontier] where seen > lastReadCandidate {
        lastReadCandidate = seen
        #if DEBUG
        debugLog("TIMELINE_DEBUG read visible through \(seen)")
        #endif
        UnreadManager.shared.readVisible(peerId: peer, chatId: chatId, highestVisibleIncomingID: seen)
      }
    }
    // Mentions and reactions on screen are reported once the list settles, as before.
    guard !isMoving else { return }
    onVisibleMessagesChanged?(visibleMessages().map(\.message.messageId))
  }

  /// Saves where the reader is when the newest message is off screen, and clears it otherwise. A window
  /// read ahead for this chat no longer matches where it opens, so it goes too.
  private func saveReadingPlace() {
    guard !isPreview, hasOpened, let snapshot else { return }
    defer { ChatOpenPreparation.shared.discard(peer: peer) }
    // The chat's newest message on screen at all: there is no place to keep. The window's newest row
    // is not enough: past a jump's window, or at the edge of history paged in, newer history is still
    // unknown, and Telegram keeps the place there too (`laterId != nil`).
    if viewModel.historyCoverage.isAtCertifiedLiveEnd,
       let newest = snapshot.rows.last(where: { $0.content.message != nil })?.id,
       list.layout.visible.contains(where: { $0.id == newest })
    {
      #if DEBUG
      debugLog("TIMELINE_DEBUG place cleared: the chat's newest message is on screen")
      #endif
      ChatReadingPlaceStore.shared.clear(for: peer)
      return
    }
    let top = list.layout.viewport.usableTop
    for placement in list.layout.visible {
      guard let messageId = Self.chatMessage(snapshot.row(for: placement.id))?.message.messageId, messageId > 0,
            placement.y >= top - 0.5 || placement.id == list.layout.visible.last?.id else { continue }
      #if DEBUG
      debugLog("TIMELINE_DEBUG place saved \(messageId)@\(Int(placement.y - top))")
      #endif
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
    let next = ChatScrollAffordanceState(isVisible: visible, unreadCount: count)
    guard next != affordance else { return }
    affordance = next
    onScrollAffordanceChanged?(next)
  }

  // MARK: - Floating date

  private func rebuildDayRows() {
    dayRows = snapshot?.rows.enumerated().compactMap { index, row in
      if case let .daySeparator(day) = row.content { (index, day) } else { nil }
    } ?? []
    rebuildGroupSpans()
  }

  private func rebuildGroupSpans() {
    groupSpans.removeAll(keepingCapacity: true)
    guard let rows = snapshot?.rows else { return }
    var start: Int?
    for (index, row) in rows.enumerated() {
      guard let grouping = row.content.grouping else {
        start = nil
        continue
      }
      if grouping.isFirstInGroup || start == nil { start = index }
      let nextIsMessage = index + 1 < rows.count && rows[index + 1].content.grouping != nil
      if grouping.isLastInGroup || !nextIsMessage {
        let span = (start ?? index, index)
        for member in span.0 ... span.1 { groupSpans[rows[member].id] = span }
        start = nil
      }
    }
  }

  /// The day of the topmost row floats at the top edge while the reader scrolls. The next day's row
  /// pushes it up; when the day's own row is on screen, that row shows the date instead.
  private func updateDatePill() {
    let layout = list.layout
    let top = layout.viewport.usableTop
    datePill.frame = CGRect(x: 0, y: datePill.frame.minY, width: bounds.width, height: datePillHeight)
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
      y = min(top, row.y - datePillHeight)
    }
    datePill.frame.origin.y = y
    // This runs every frame of a scroll; the title is formatted only when the day changes.
    if datePillDay != current.day {
      datePillDay = current.day
      datePill.configure(title: Self.dayTitle(current.day))
    }
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
    jumpToDay(day)
  }

  private func jumpToDay(_ day: Date) {
    cancelPendingMessageFocus()
    let id = ChatRowID.daySeparator(day)
    let near = list.layout.placement(for: id) != nil
    list.apply(TimelineTransaction(scroll: .to(id, .top(0)), timing: near ? Self.rowTiming : Self.jumpTiming))
    scheduleDatePillHide()
  }

  // MARK: - Status notice

  /// "Sam has notifications silenced" under the newest message of a DM, as the collection view shows it:
  /// seeded from memory for the first frame, then following the user's focus status.
  private func observeStatusNotice() {
    guard let userId = peer.asUserId(), userId != Auth.shared.getCurrentUserId() else { return }
    viewModel.rowFeed.setStatusNotice(ObjectCache.shared.getCachedUser(id: userId)?.notificationsSilencedNotice())
    ObjectCache.shared.getUserPublisher(id: userId)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] userInfo in
        guard let userInfo else { return }
        self?.viewModel.rowFeed.setStatusNotice(userInfo.notificationsSilencedNotice())
      }
      .store(in: &cancellables)
  }

  // MARK: - The rest of the container's contract

  var highestPositiveMessageId: Int64? {
    viewModel.messages.map(\.message.messageId).filter { $0 > 0 }.max()
  }

  var isContextMenuInteractionActive: Bool { menu.isActive }
  var isReactionPickerPresented: Bool { menuActions.isReactionPickerPresented }
  private func beginMenuInsetHold() {
    menuInsetRelease?.cancel()
    awaitsMenuKeyboard = false
    guard menuInsetHold == nil else { return }
    menuInsetHold = (composeBottomInset, nil)
  }

  /// The menu ended and the container brings the composer's focus back: the hold waits for the keyboard,
  /// a moment at most.
  func preserveContextMenuViewportForKeyboardRestoration() {
    guard let hold = menuInsetHold else { return }
    // Nothing moved while the menu was open (it drew over the keyboard, or kept it): nothing to wait for.
    guard hold.latest != nil else {
      endMenuInsetHold(timing: .none)
      return
    }
    awaitsMenuKeyboard = true
    menuInsetRelease?.cancel()
    let release = DispatchWorkItem { [weak self] in self?.endMenuInsetHold(timing: Self.rowTiming) }
    menuInsetRelease = release
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: release)
  }

  /// The menu ended without bringing focus back: the list follows the composer now.
  func cancelContextMenuKeyboardRestoration() {
    endMenuInsetHold(timing: Self.rowTiming)
  }

  private func endMenuInsetHold(timing: TimelineTiming) {
    guard let hold = menuInsetHold else { return }
    menuInsetHold = nil
    awaitsMenuKeyboard = false
    menuInsetRelease?.cancel()
    menuInsetRelease = nil
    guard let latest = hold.latest else { return }
    composeAreaDidChange(bottomInset: latest, timing: timing, isInteractive: false)
  }

  func setCollapsedMaxId(_ collapsedMaxId: Int64?) {
    viewModel.rowFeed.setCollapsedMaxId(collapsedMaxId)
  }

  func collapseHistory(maxID: Int64?) async throws {
    let effectiveMaxID = try await Api.realtime.collapseHistory(peer: peer.toInputPeer(), maxID: maxID)
    setCollapsedMaxId(effectiveMaxID)
  }

  // MARK: - Media gallery

  private var isPresentingGallery = false

  private func presentPhoto(_ message: FullMessage, image: UIImage?, url: URL) {
    let anchor = MediaGalleryItem(message: message.message, photo: message.photoInfo, video: message.videoInfo)
      ?? MediaGalleryItem.photo(url: url, id: message.message.messageId)
    presentMediaGallery(anchor: anchor, sourceImage: image)
  }

  /// A video bubble opens the chat's gallery here (`NewVideoView`), so it streams while it plays.
  func presentMediaGallery(for message: FullMessage, sourceImage: UIImage?) -> Bool {
    guard let anchor = MediaGalleryItem(message: message.message, photo: message.photoInfo, video: message.videoInfo)
    else { return false }
    return presentMediaGallery(anchor: anchor, sourceImage: sourceImage)
  }

  /// Every photo and video in the chat, paged from cache and server, starting at `anchor`, with the
  /// collection view's actions: show in chat, forward, delete.
  @discardableResult
  private func presentMediaGallery(anchor: MediaGalleryItem, sourceImage: UIImage?) -> Bool {
    guard anchor.message?.isSticker != true, !isPresentingGallery, let chatId,
          let viewController = findViewController(), viewController.presentedViewController == nil,
          !viewController.isBeingPresented, !viewController.isBeingDismissed
    else { return false }
    var actions = MediaGalleryViewController.Actions()
    actions.showInChat = { [weak self] item in self?.scrollToMessageWhenAvailable(item.id) }
    actions.forward = { [weak self] item in
      guard let self, let message = item.message,
            let fullMessage = try? FullMessage.get(messageId: message.messageId, chatId: chatId)
      else { return }
      menuActions.presentForwardSheet(fullMessage)
    }
    // The server's rule: anyone in a DM, in a space your own messages or any as an admin.
    let canDeleteMessage = MessageDeletePolicy.checker(peer: peer)
    actions.canDelete = { item in item.message.map(canDeleteMessage) ?? false }
    actions.delete = { item in
      guard let message = item.message else { return }
      MessageViewActions.sendDeleteMessage(messageId: message.messageId, peerId: message.peerId, chatId: message.chatId)
    }
    let viewer = MediaGalleryViewController(
      source: ChatMediaGallerySource(chatId: chatId, peer: peer, anchor: anchor),
      initialItemID: anchor.id, sourceImage: sourceImage, actions: actions,
      // The zoom starts from and returns to the photo or the video's thumbnail, not the whole row; the
      // thread's parent too, as the collection view found its anchor cell.
      sourceViewProvider: { [weak self] item in
        guard let self, let stableId = item.messageStableId else { return nil }
        // An album item zooms from its own tile, inside the album's row.
        if let row = snapshot?.rows.first(where: { $0.content.album?.contains(stableId: stableId) == true }),
           let item = row.content.album?.items.first(where: { $0.id == stableId }),
           let albumView = (list.view(for: row.id) as? TimelineRowView)?.shownMessageView?.albumView,
           let tile = albumView.tileView(messageId: item.message.messageId)
        {
          if let photo = tile as? NewPhotoView { return photo.imageView }
          if let video = tile as? NewVideoView { return video.gallerySourceView }
          return tile
        }
        return (list.view(for: .message(stableId)) ?? list.view(for: .threadParent(stableId)))
          .flatMap(Self.galleryMediaView(in:))
      }
    )
    viewer.onDismiss = { [weak self] in self?.isPresentingGallery = false }
    isPresentingGallery = true
    viewController.present(viewer, animated: false)
    return true
  }

  /// The photo or video thumbnail inside a row, for gallery transitions.
  private static func galleryMediaView(in view: UIView) -> UIView? {
    for subview in view.subviews where !subview.isHidden {
      if let photoView = subview as? NewPhotoView { return photoView.imageView }
      if let videoView = subview as? NewVideoView { return videoView.gallerySourceView }
      if let found = galleryMediaView(in: subview) { return found }
    }
    return nil
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
