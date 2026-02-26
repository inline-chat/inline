import AppKit
import Combine
import InlineKit
import SwiftUI

class MainSidebar: NSViewController {
  private let dependencies: AppDependencies
  private let listView: MainSidebarList
  private let homeViewModel: HomeViewModel
  private let spacePickerState = SpacePickerState()

  private var activeMode: MainSidebarMode = .inbox

  // MARK: - Sizes

  // Used in header, collection view item, and collection view layout.

  static let iconSize: CGFloat = 24
  static let itemHeight: CGFloat = 34
  static let iconTrailingPadding: CGFloat = 8
  static let fontSize: CGFloat = 14
  static let fontWeight: NSFont.Weight = .regular
  static let font: NSFont = .systemFont(ofSize: fontSize, weight: fontWeight)
  static let itemSpacing: CGFloat = 0
  static let outerEdgeInsets: CGFloat = 10
  static let innerEdgeInsets: CGFloat = 8
  static let edgeInsets: CGFloat = MainSidebar.outerEdgeInsets + MainSidebar.innerEdgeInsets

  init(dependencies: AppDependencies) {
    self.dependencies = dependencies
    homeViewModel = HomeViewModel(db: dependencies.database)
    listView = MainSidebarList(dependencies: dependencies)

    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // Header
  private lazy var headerView: MainSidebarHeaderView = {
    let view = MainSidebarHeaderView(
      dependencies: dependencies,
      spacePickerState: spacePickerState
    )
    view.translatesAutoresizingMaskIntoConstraints = false
    // Space picker overlay is hosted in MainSidebar so it can render above the list.
    view.onSpacePickerChange = { [weak self] isVisible in
      self?.updateSpacePicker(isVisible: isVisible)
    }
    return view
  }()

  private var spacePickerPresenter: SpacePickerOverlayPresenter?
  private var spacePickerClickMonitor: Any?
  private var spacePickerEscapeUnsubscriber: (() -> Void)?
  private var spaceSwitcherCommandNumberUnsubscriber: (() -> Void)?
  private var didDismissSpacePickerFromHeaderMouseDown: Bool = false
  private var archiveEscapeUnsubscriber: (() -> Void)?

  private lazy var footerView: NSView = {
    let view = NSView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.wantsLayer = true
    view.layer?.masksToBounds = true
    return view
  }()

  private lazy var updateOverlayView: NSHostingView<AnyView> = {
    let view = NSHostingView(
      rootView: AnyView(
        UpdateSidebarOverlayButton(placement: .topCorner)
          .environmentObject(dependencies.updateInstallState)
      )
    )
    view.translatesAutoresizingMaskIntoConstraints = false
    view.isHidden = true
    return view
  }()

  private var updateOverlayCancellable: AnyCancellable?

  private lazy var footerHostingView: NSHostingView<AnyView> = {
    let view = NSHostingView(rootView: makeFooterRootView())
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private lazy var archiveEmptyView: NSStackView = {
    let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 30, weight: .regular)
    let symbolImage = NSImage(
      systemSymbolName: "archivebox",
      accessibilityDescription: "Archive"
    )?.withSymbolConfiguration(symbolConfiguration)

    let symbolView = NSImageView()
    symbolView.image = symbolImage
    symbolView.contentTintColor = .tertiaryLabelColor
    symbolView.imageScaling = .scaleProportionallyDown

    let titleLabel = NSTextField(labelWithString: "Your archive is empty")
    titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
    titleLabel.textColor = .secondaryLabelColor
    titleLabel.alignment = .center
    titleLabel.lineBreakMode = .byTruncatingTail

    let descriptionLabel = NSTextField(
      labelWithString: "Archived chats appear here and return to your main list when they get new messages."
    )
    descriptionLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
    descriptionLabel.textColor = .secondaryLabelColor
    descriptionLabel.alignment = .center
    descriptionLabel.lineBreakMode = .byWordWrapping

    let stack = NSStackView(views: [symbolView, titleLabel, descriptionLabel])
    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.spacing = 10
    stack.translatesAutoresizingMaskIntoConstraints = false
    return stack
  }()

  private lazy var archiveTitleLabel: NSTextField = {
    let label = NSTextField(labelWithString: "Archived Chats")
    label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
    label.textColor = .secondaryLabelColor
    label.lineBreakMode = .byTruncatingTail
    label.usesSingleLineMode = true
    label.translatesAutoresizingMaskIntoConstraints = false
    label.isHidden = true
    return label
  }()

  private var headerTopConstraint: NSLayoutConstraint?
  private var trafficLightsVisible = true
  private static let headerBaseTopInset: CGFloat = 14
  private static let headerTrafficLightInset: CGFloat = 34
  private var archiveTitleHeightConstraint: NSLayoutConstraint?
  private var archiveTitleTopConstraint: NSLayoutConstraint?
  private var archiveTitleBottomConstraint: NSLayoutConstraint?
  private var updateOverlayFallbackConstraints: [NSLayoutConstraint] = []
  private var updateOverlayTitlebarConstraints: [NSLayoutConstraint] = []
  private var updateOverlayLeadingToZoomConstraint: NSLayoutConstraint?
  private weak var updateOverlayTitlebarHostView: NSView?
  private weak var updateOverlayAnchorButton: NSButton?
  private var isUpdateReadyToInstall = false
  private var switchToInboxObserver: NSObjectProtocol?
  private static let footerHeight: CGFloat = MainSidebarFooterMetrics.height
  private static let archiveTitleHeight: CGFloat = 16
  private static let archiveTitleTopSpacing: CGFloat = 12
  private static let archiveTitleBottomSpacing: CGFloat = 4
  private static let updateButtonTrailingGapToTrafficLights: CGFloat = 8
  private static let updateButtonSidebarTrailingInset: CGFloat = 18
  private static let updateButtonFallbackTopInset: CGFloat = 10
  private static let updateButtonFallbackLeadingInset: CGFloat = 92

  override func loadView() {
    view = NSView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.wantsLayer = true
    setupViews()
  }

  private func setupViews() {
    view.addSubview(headerView)
    view.addSubview(archiveTitleLabel)
    view.addSubview(listView)
    view.addSubview(footerView)
    view.addSubview(updateOverlayView)
    footerView.addSubview(footerHostingView)
    view.addSubview(archiveEmptyView)

    headerTopConstraint = headerView.topAnchor.constraint(
      equalTo: view.topAnchor,
      constant: headerTopInset()
    )

    let archiveTitleTopConstraint = archiveTitleLabel.topAnchor.constraint(
      equalTo: headerView.bottomAnchor,
      constant: Self.archiveTitleTopSpacing
    )
    self.archiveTitleTopConstraint = archiveTitleTopConstraint
    let updateOverlayTopConstraint = updateOverlayView.topAnchor.constraint(
      equalTo: view.topAnchor,
      constant: Self.updateButtonFallbackTopInset
    )
    let updateOverlayLeadingConstraint = updateOverlayView.leadingAnchor.constraint(
      equalTo: view.leadingAnchor,
      constant: Self.updateButtonFallbackLeadingInset
    )
    let updateOverlayTrailingConstraint = updateOverlayView.trailingAnchor.constraint(
      lessThanOrEqualTo: view.trailingAnchor,
      constant: -Self.outerEdgeInsets
    )
    updateOverlayFallbackConstraints = [
      updateOverlayTopConstraint,
      updateOverlayLeadingConstraint,
      updateOverlayTrailingConstraint,
    ]

    NSLayoutConstraint.activate([
      headerView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Self.outerEdgeInsets),
      headerView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Self.outerEdgeInsets),
      headerTopConstraint!,

      archiveTitleLabel.leadingAnchor.constraint(
        equalTo: view.leadingAnchor,
        constant: Self.outerEdgeInsets + Self.innerEdgeInsets
      ),
      archiveTitleLabel.trailingAnchor.constraint(
        lessThanOrEqualTo: view.trailingAnchor,
        constant: -Self.outerEdgeInsets
      ),
      archiveTitleTopConstraint,

      listView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      listView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      listView.bottomAnchor.constraint(equalTo: footerView.topAnchor),

      footerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      footerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      footerView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      footerView.heightAnchor.constraint(equalToConstant: Self.footerHeight),

      updateOverlayTopConstraint,
      updateOverlayLeadingConstraint,
      updateOverlayTrailingConstraint,

      footerHostingView.leadingAnchor.constraint(equalTo: footerView.leadingAnchor),
      footerHostingView.trailingAnchor.constraint(equalTo: footerView.trailingAnchor),
      footerHostingView.topAnchor.constraint(equalTo: footerView.topAnchor),
      footerHostingView.bottomAnchor.constraint(equalTo: footerView.bottomAnchor),

      archiveEmptyView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      archiveEmptyView.centerYAnchor.constraint(equalTo: listView.centerYAnchor),
      archiveEmptyView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
      archiveEmptyView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
    ])

    let archiveTitleHeightConstraint = archiveTitleLabel.heightAnchor.constraint(equalToConstant: 0)
    let archiveTitleBottomConstraint = listView.topAnchor.constraint(
      equalTo: archiveTitleLabel.bottomAnchor,
      constant: 0
    )
    archiveTitleHeightConstraint.isActive = true
    archiveTitleBottomConstraint.isActive = true
    self.archiveTitleHeightConstraint = archiveTitleHeightConstraint
    self.archiveTitleBottomConstraint = archiveTitleBottomConstraint

    archiveEmptyView.isHidden = true

    listView.onChatCountChanged = { [weak self] mode, count in
      guard let self else { return }
      let isArchiveEmpty = mode == .archive && count == 0
      archiveEmptyView.isHidden = !isArchiveEmpty
      updateArchiveTitle(archiveCount: count)
    }

    updateOverlayCancellable = dependencies.updateInstallState.$isReadyToInstall
      .receive(on: DispatchQueue.main)
      .sink { [weak self] isReady in
        self?.isUpdateReadyToInstall = isReady
        self?.updateOverlayPlacement()
        self?.view.needsLayout = true
      }

    setContent(for: .inbox)
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    switchToInboxObserver = NotificationCenter.default.addObserver(
      forName: .switchToInbox,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.setContent(for: .inbox)
    }
  }

  override func viewWillAppear() {
    super.viewWillAppear()
    // Cmd+1...9: switch to Home / spaces (always active, doesn't require the picker to be open).
    // Install here (not viewDidLoad) so it reliably reattaches if the sidebar VC is ever removed/re-added.
    installSpaceSwitcherCommandNumberHandlerIfNeeded()
  }

  override func viewWillDisappear() {
    super.viewWillDisappear()
    hideSpacePicker()
    archiveEscapeUnsubscriber?()
    archiveEscapeUnsubscriber = nil
    spaceSwitcherCommandNumberUnsubscriber?()
    spaceSwitcherCommandNumberUnsubscriber = nil
  }

  deinit {
    if let switchToInboxObserver {
      NotificationCenter.default.removeObserver(switchToInboxObserver)
    }
    archiveEscapeUnsubscriber?()
    archiveEscapeUnsubscriber = nil
    spaceSwitcherCommandNumberUnsubscriber?()
    spaceSwitcherCommandNumberUnsubscriber = nil
  }

  private func installSpaceSwitcherCommandNumberHandlerIfNeeded() {
    guard spaceSwitcherCommandNumberUnsubscriber == nil else { return }
    guard let keyMonitor = dependencies.keyMonitor else { return }

    spaceSwitcherCommandNumberUnsubscriber = keyMonitor.addCommandNumberHandler(key: "sidebar_space_switcher") { [weak self] event in
      guard let self else { return false }
      guard let nav2 = self.dependencies.nav2 else { return false }

      guard let char = event.charactersIgnoringModifiers?.first,
            let digit = Int(String(char)),
            (1...9).contains(digit)
      else { return false }

      let index = digit - 1

      if AppSettings.shared.showMainTabStrip {
        // When tab strip is enabled, map Cmd+1...9 directly to visible tab indexes.
        guard nav2.tabs.indices.contains(index) else { return false }
        nav2.setActiveTab(index: index)
      } else {
        // Match the space picker's labeling:
        // Cmd+1 = Home, Cmd+2...9 = spaces in the same order as the picker list.
        let items = self.spacePickerItems()
        guard items.indices.contains(index) else { return false }
        self.handleSpacePickerSelection(items[index])
      }

      // If the picker is open, close it so the UI state stays coherent.
      if self.spacePickerState.isVisible {
        self.hideSpacePicker()
      }
      return true
    }
  }

  private func setContent(for mode: MainSidebarMode) {
    activeMode = mode
    refreshFooter()
    updateArchiveEscapeHandler()

    switch mode {
      case .archive:
        listView.setMode(.archive)
        let archiveCount = listView.lastChatItemCount
        archiveEmptyView.isHidden = archiveCount != 0
        updateArchiveTitle(archiveCount: archiveCount)
      case .inbox:
        listView.setMode(.inbox)
        archiveEmptyView.isHidden = true
        updateArchiveTitle(archiveCount: 0)
    }
  }

  private func updateArchiveEscapeHandler() {
    if activeMode == .archive {
      guard archiveEscapeUnsubscriber == nil else { return }
      guard let keyMonitor = dependencies.keyMonitor else { return }
      archiveEscapeUnsubscriber = keyMonitor.addHandler(
        for: .escape,
        key: "sidebar_archive_escape"
      ) { [weak self] _ in
        self?.setContent(for: .inbox)
      }

      // Keep the space picker ESC handler most-specific when it's visible.
      if spacePickerState.isVisible {
        removeSpacePickerKeyHandlers()
        installSpacePickerKeyHandlers()
      }
    } else {
      archiveEscapeUnsubscriber?()
      archiveEscapeUnsubscriber = nil
    }
  }

  private func refreshFooter() {
    footerHostingView.rootView = makeFooterRootView()
  }

  private func makeFooterRootView() -> AnyView {
    AnyView(
      MainSidebarFooterView(
        isArchiveActive: activeMode == .archive,
        isPreviewEnabled: AppSettings.shared.showSidebarMessagePreview,
        horizontalPadding: Self.edgeInsets,
        onToggleArchive: { [weak self] in self?.handleArchiveButton() },
        onSearch: { [weak self] in self?.handleSearchButton() },
        onNewSpace: { [weak self] in self?.handleNewSpace() },
        onInvite: { [weak self] in self?.handleInvite() },
        onNewThread: { [weak self] in self?.handleNewThread() },
        onSetCompact: { [weak self] in self?.handleDisplayModeCompact() },
        onSetPreview: { [weak self] in self?.handleDisplayModePreview() }
      )
      .environmentObject(dependencies.userSettings.notification)
    )
  }

  private func updateArchiveTitle(archiveCount: Int) {
    let shouldShow = activeMode == .archive && archiveCount > 0
    archiveTitleLabel.isHidden = !shouldShow
    archiveTitleTopConstraint?.constant = shouldShow ? Self.archiveTitleTopSpacing : 0
    archiveTitleHeightConstraint?.constant = shouldShow ? Self.archiveTitleHeight : 0
    archiveTitleBottomConstraint?.constant = shouldShow ? Self.archiveTitleBottomSpacing : 0
  }

  private func handleArchiveButton() {
    let nextMode: MainSidebarMode = activeMode == .archive ? .inbox : .archive
    setContent(for: nextMode)
  }

  private func handleSearchButton() {
    NotificationCenter.default.post(name: .focusSearch, object: nil)
  }

  private func updateSpacePicker(isVisible: Bool) {
    if isVisible {
      showSpacePicker()
    } else {
      hideSpacePicker()
    }
  }

  private func showSpacePicker() {
    guard let hostView = view.window?.contentView else {
      if spacePickerState.isVisible { spacePickerState.isVisible = false }
      return
    }

    let rootView = makeSpacePickerRootView()
    let presenter: SpacePickerOverlayPresenter
    if let existing = spacePickerPresenter {
      existing.update(rootView: rootView)
      presenter = existing
    } else {
      let new = SpacePickerOverlayPresenter(
        rootView: rootView,
        preferredWidth: SpacePickerOverlayStyle.preferredWidth
      )
      spacePickerPresenter = new
      presenter = new
    }

    presenter.show(
      in: hostView,
      anchorView: headerView.spacePickerAnchorView,
      xOffset: -(Self.outerEdgeInsets + 3)
    )
    installSpacePickerClickMonitor()
    installSpacePickerKeyHandlers()
  }

  private func hideSpacePicker(keepClickMonitorInstalled: Bool = false) {
    spacePickerPresenter?.hide()
    if spacePickerState.isVisible {
      spacePickerState.isVisible = false
    }
    let shouldKeepClickMonitor = keepClickMonitorInstalled || didDismissSpacePickerFromHeaderMouseDown
    if shouldKeepClickMonitor == false {
      removeSpacePickerClickMonitor()
    }
    removeSpacePickerKeyHandlers()
  }

  private func makeSpacePickerRootView() -> SpacePickerOverlayView {
    let items = spacePickerItems()
    let activeTab = dependencies.nav2?.activeTab ?? .home
    return SpacePickerOverlayView(
      items: items,
      activeTab: activeTab,
      onSelect: { [weak self] item in
        self?.handleSpacePickerSelection(item)
        self?.hideSpacePicker()
      },
      onCreateSpace: { [weak self] in
        self?.dependencies.nav2?.navigate(to: .createSpace)
        self?.hideSpacePicker()
      }
    )
  }

  private func spacePickerItems() -> [SpaceHeaderItem] {
    [.home] + homeViewModel.spaces.map { SpaceHeaderItem(space: $0.space) }
  }

  private func handleSpacePickerSelection(_ item: SpaceHeaderItem) {
    guard let nav2 = dependencies.nav2 else { return }
    switch item.kind {
      case .home:
        if let index = nav2.tabs.firstIndex(of: .home) {
          nav2.setActiveTab(index: index)
        }
      case .space:
        if let space = item.space {
          nav2.openSpace(space)
        }
    }
  }

  private func installSpacePickerClickMonitor() {
    guard spacePickerClickMonitor == nil else { return }
    spacePickerClickMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .otherMouseDown]
    ) { [weak self] event in
      guard let self else { return event }
      guard let window = view.window, event.window === window else { return event }

      // If we closed the picker on mouseDown in the header, swallow the corresponding mouseUp
      // so the header control doesn't immediately toggle it open again.
      if event.type == .leftMouseUp, didDismissSpacePickerFromHeaderMouseDown {
        didDismissSpacePickerFromHeaderMouseDown = false
        removeSpacePickerClickMonitor()
        return nil
      }

      guard let presenter = spacePickerPresenter, presenter.isVisible else { return event }
      guard let hostView = window.contentView else { return event }

      // While open, treat the header as a "toggle": any click in the header closes the picker.
      // This also avoids a subtle issue where clicking near the right edge of the picker control
      // might not close if hit-testing gets weird due to overlay positioning/clamping.
      let headerRectInWindow = headerView.convert(headerView.bounds, to: nil)
      if event.type != .leftMouseUp, headerRectInWindow.contains(event.locationInWindow) {
        didDismissSpacePickerFromHeaderMouseDown = true
        DispatchQueue.main.async { [weak self] in
          self?.hideSpacePicker(keepClickMonitorInstalled: true)
        }
        return nil
      }

      let pointInHost = hostView.convert(event.locationInWindow, from: nil)
      if presenter.containsPointInHostView(pointInHost) {
        return event
      }

      // Don't allow interacting with underlying UI while the picker is open.
      // We dismiss and swallow the event so nothing else receives the click.
      DispatchQueue.main.async { [weak self] in
        self?.hideSpacePicker()
      }
      return nil
    }
  }

  private func removeSpacePickerClickMonitor() {
    if let spacePickerClickMonitor {
      NSEvent.removeMonitor(spacePickerClickMonitor)
      self.spacePickerClickMonitor = nil
    }
  }

  private func installSpacePickerKeyHandlers() {
    guard spacePickerEscapeUnsubscriber == nil else { return }
    guard let keyMonitor = dependencies.keyMonitor else { return }
    spacePickerEscapeUnsubscriber = keyMonitor.addHandler(
      for: .escape,
      key: "space_picker_escape"
    ) { [weak self] _ in
      self?.hideSpacePicker()
    }
  }

  private func removeSpacePickerKeyHandlers() {
    spacePickerEscapeUnsubscriber?()
    spacePickerEscapeUnsubscriber = nil
  }

  private func handleDisplayModeCompact() {
    AppSettings.shared.showSidebarMessagePreview = false
    refreshFooter()
  }

  private func handleDisplayModePreview() {
    AppSettings.shared.showSidebarMessagePreview = true
    refreshFooter()
  }

  private func handleNewSpace() {
    dependencies.nav2?.navigate(to: .createSpace)
  }

  private func handleInvite() {
    dependencies.nav2?.navigate(to: .inviteToSpace)
  }

  private func handleNewThread() {
    NewThreadAction.start(dependencies: dependencies, spaceId: dependencies.nav2?.activeSpaceId)
  }

  private func headerTopInset() -> CGFloat {
    guard trafficLightsVisible else { return Self.headerBaseTopInset }
    guard let window = view.window,
          window.styleMask.contains(.fullSizeContentView)
    else {
      return Self.headerBaseTopInset
    }
    return Self.headerBaseTopInset + Self.headerTrafficLightInset
  }

  override func viewDidLayout() {
    super.viewDidLayout()
    headerTopConstraint?.constant = headerTopInset()
    updateOverlayPlacement()
    if spacePickerState.isVisible {
      spacePickerPresenter?.repositionIfPossible()
    }
  }

  func setTrafficLightsVisible(_ isVisible: Bool) {
    guard trafficLightsVisible != isVisible else { return }
    trafficLightsVisible = isVisible
    headerTopConstraint?.constant = headerTopInset()
    updateOverlayPlacement()
    view.needsLayout = true
  }

  private func updateOverlayPlacement() {
    let shouldShow = isUpdateReadyToInstall && trafficLightsVisible
    updateOverlayView.isHidden = !shouldShow
    guard shouldShow else { return }

    guard let window = view.window,
          let zoomButton = window.standardWindowButton(.zoomButton),
          let titlebarHost = zoomButton.superview
    else {
      ensureUpdateOverlayAttachedToSidebarFallback()
      return
    }

    ensureUpdateOverlayAttachedToTrafficLights(zoomButton: zoomButton, hostView: titlebarHost)
    updateOverlayHorizontalPosition(zoomButton: zoomButton, hostView: titlebarHost)
  }

  private func ensureUpdateOverlayAttachedToTrafficLights(zoomButton: NSButton, hostView: NSView) {
    let needsSuperviewUpdate = updateOverlayView.superview !== hostView
    let needsConstraintRefresh = updateOverlayTitlebarHostView !== hostView
      || updateOverlayAnchorButton !== zoomButton
      || updateOverlayTitlebarConstraints.isEmpty

    if needsSuperviewUpdate {
      NSLayoutConstraint.deactivate(updateOverlayFallbackConstraints)
      NSLayoutConstraint.deactivate(updateOverlayTitlebarConstraints)
      updateOverlayView.removeFromSuperview()
      hostView.addSubview(updateOverlayView)
    }

    guard needsSuperviewUpdate || needsConstraintRefresh else { return }

    NSLayoutConstraint.deactivate(updateOverlayTitlebarConstraints)
    let leadingConstraint = updateOverlayView.leadingAnchor.constraint(
      equalTo: zoomButton.trailingAnchor,
      constant: Self.updateButtonTrailingGapToTrafficLights
    )
    updateOverlayLeadingToZoomConstraint = leadingConstraint
    updateOverlayTitlebarConstraints = [
      leadingConstraint,
      updateOverlayView.centerYAnchor.constraint(equalTo: zoomButton.centerYAnchor),
      updateOverlayView.trailingAnchor.constraint(
        lessThanOrEqualTo: hostView.trailingAnchor,
        constant: -Self.outerEdgeInsets
      ),
    ]
    NSLayoutConstraint.activate(updateOverlayTitlebarConstraints)
    updateOverlayTitlebarHostView = hostView
    updateOverlayAnchorButton = zoomButton
  }

  private func ensureUpdateOverlayAttachedToSidebarFallback() {
    guard updateOverlayView.superview !== view else {
      if updateOverlayFallbackConstraints.contains(where: { $0.isActive == false }) {
        NSLayoutConstraint.deactivate(updateOverlayTitlebarConstraints)
        NSLayoutConstraint.activate(updateOverlayFallbackConstraints)
      }
      return
    }

    NSLayoutConstraint.deactivate(updateOverlayTitlebarConstraints)
    updateOverlayView.removeFromSuperview()
    view.addSubview(updateOverlayView)
    NSLayoutConstraint.activate(updateOverlayFallbackConstraints)
    updateOverlayLeadingToZoomConstraint = nil
    updateOverlayTitlebarHostView = nil
    updateOverlayAnchorButton = nil
  }

  private func updateOverlayHorizontalPosition(zoomButton: NSButton, hostView: NSView) {
    guard let leadingConstraint = updateOverlayLeadingToZoomConstraint else { return }

    let sidebarRectInHost = hostView.convert(view.bounds, from: view)
    let zoomRectInHost = hostView.convert(zoomButton.bounds, from: zoomButton)
    let buttonWidth = max(updateOverlayView.fittingSize.width, updateOverlayView.intrinsicContentSize.width)

    let minLeading = zoomRectInHost.maxX + Self.updateButtonTrailingGapToTrafficLights
    let desiredLeading = sidebarRectInHost.maxX - Self.updateButtonSidebarTrailingInset - buttonWidth
    let resolvedLeading = max(minLeading, desiredLeading)
    leadingConstraint.constant = resolvedLeading - zoomRectInHost.maxX
  }
}

private enum MainSidebarMode {
  case archive
  case inbox
}
