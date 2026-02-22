import AppKit
import Combine
import InlineKit
import InlineMacWindow
import Logger
import Observation
import SwiftUI

@MainActor
class MainSplitView: NSViewController {
  let dependencies: AppDependencies
  private let log = Log.scoped("MainSplitView")
  private let quickSearchViewModel: QuickSearchViewModel

  // Views

  lazy var tabsArea: NSView = .init()

  lazy var sideArea: NSView = .init()

  lazy var contentContainer: NSView = .init()

  lazy var contentArea: NSView = {
    let view = ContentAreaView()
    view.wantsLayer = true
    return view
  }()

  lazy var toolbarArea: MainToolbarView = {
    let view = MainToolbarView(dependencies: dependencies)
    view.translatesAutoresizingMaskIntoConstraints = false
    view.wantsLayer = true
    view.transparent = true
    return view
  }()

  // Constants

  private var tabsHeight: CGFloat = Theme.tabBarHeight
  private var sideWidth: CGFloat = Theme.idealSidebarWidth
  private var innerPadding: CGFloat = Theme.mainSplitViewUseFullBleedContent ? 0 : Theme.mainSplitViewInnerPadding
  private var contentRadius: CGFloat = Theme.mainSplitViewUseFullBleedContent ? 0 : Theme.mainSplitViewContentRadius
  private var sidebarCollapsed = false
  private var trafficLightsVisible = true

  private enum ToolbarMetrics {
    /// Baseline toolbar padding when we are not reserving space for traffic lights.
    static let defaultLeadingPadding: CGFloat = 10
    /// Fixed padding when the sidebar is collapsed and traffic lights are visible.
    static let collapsedLeadingPadding: CGFloat = 90
  }

  private enum TabStripMetrics {
    /// Baseline pinned action padding in the tab strip.
    static let defaultLeadingPadding: CGFloat = 12
    /// Shift pinned actions right when traffic lights overlap with the collapsed sidebar.
    static let collapsedLeadingPadding: CGFloat = 86
  }

  private enum SidebarAnimation {
    static let openDuration: TimeInterval = 0.2
    static let closeDuration: TimeInterval = 0.18

    static func timing(forCollapsed isCollapsed: Bool) -> CAMediaTimingFunction {
      return CAMediaTimingFunction(name: .easeInEaseOut)
    }

    static func duration(forCollapsed isCollapsed: Bool) -> TimeInterval {
      isCollapsed ? closeDuration : openDuration
    }
  }

  private var lastRenderedRoute: Nav2Route?
  private var escapeKeyUnsubscriber: (() -> Void)?
  private var quickSearchObserver: NSObjectProtocol?
  private var appActiveObserver: NSObjectProtocol?
  private var trafficLightPresenceObserver: UUID?
  private var quickSearchEscapeUnsubscriber: (() -> Void)?
  private var quickSearchArrowUnsubscriber: (() -> Void)?
  private var quickSearchVimUnsubscriber: (() -> Void)?
  private var quickSearchReturnUnsubscriber: (() -> Void)?
  private var settingsCancellables = Set<AnyCancellable>()

  private var quickSearchWidthConstraint: NSLayoutConstraint?
  private var quickSearchHeightConstraint: NSLayoutConstraint?
  private var tabsHeightConstraint: NSLayoutConstraint?
  private var contentTopConstraint: NSLayoutConstraint?
  private var sidebarWidthConstraint: NSLayoutConstraint?
  private var sidebarLeadingConstraint: NSLayoutConstraint?
  private var contentLeadingToSidebarConstraint: NSLayoutConstraint?

  private lazy var quickSearchOverlayBackground: NSView = {
    let view = PassthroughView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.wantsLayer = true
    view.layer?.backgroundColor = NSColor.clear.cgColor
    view.isHidden = true
    return view
  }()

  private lazy var quickSearchOverlayContainer: NSView = {
    let view = NSView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.wantsLayer = true
    view.isHidden = true
    return view
  }()

  private var quickSearchHostingView: NSHostingView<AnyView>?
  private var isQuickSearchVisible: Bool = false
  private var didPrewarmQuickSearch: Bool = false
  private var quickSearchClickMonitor: Any?
  private var quickSearchClickMonitorIgnoreUntil: TimeInterval = 0

  private var isTabStripEnabled: Bool {
    AppSettings.shared.showMainTabStrip
  }

  // ....

  init(dependencies: AppDependencies) {
    self.dependencies = dependencies
    quickSearchViewModel = QuickSearchViewModel(dependencies: dependencies)
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init(coder _: NSCoder) {
    fatalError("Not implemented")
  }

  override func loadView() {
    let rootView = WindowDragHandleView()
    view = rootView
    view.wantsLayer = true

    view.addSubview(contentContainer)

    contentContainer.addSubview(contentArea)
    contentArea.addSubview(toolbarArea)

    // Keep tab strip above content surface so content shadow does not bleed over melting tabs.
    view.addSubview(tabsArea)
    view.addSubview(sideArea)

    tabsArea.translatesAutoresizingMaskIntoConstraints = false
    sideArea.translatesAutoresizingMaskIntoConstraints = false
    contentContainer.translatesAutoresizingMaskIntoConstraints = false
    contentArea.translatesAutoresizingMaskIntoConstraints = false

    tabsArea.wantsLayer = true
    sideArea.wantsLayer = true
    contentContainer.wantsLayer = true
    contentArea.wantsLayer = true

    tabsArea.layer?.backgroundColor = .clear
    tabsArea.layer?.masksToBounds = true
    tabsArea.alphaValue = 0
    sideArea.layer?.backgroundColor = .clear

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.1)
    shadow.shadowBlurRadius = 2.0
    shadow.shadowOffset = .init(width: 0.0, height: -1.0)
    contentContainer.shadow = shadow

    contentContainer.layer?.cornerRadius = contentRadius
    contentContainer.layer?.cornerCurve = .continuous

    contentArea.layer?.cornerRadius = contentRadius
    contentArea.layer?.cornerCurve = .continuous
    contentArea.layer?.maskedCorners = [
      .layerMinXMinYCorner,
      .layerMaxXMinYCorner,
      .layerMinXMaxYCorner,
      .layerMaxXMaxYCorner,
    ]
    contentArea.layer?.masksToBounds = true

    let sideWidthConstraint = sideArea.widthAnchor.constraint(equalToConstant: sideWidth)
    let tabsHeightConstraint = tabsArea.heightAnchor.constraint(equalToConstant: tabsHeight)
    let sideLeadingConstraint = sideArea.leadingAnchor.constraint(equalTo: view.leadingAnchor)
    let contentLeadingToSidebar = contentContainer.leadingAnchor.constraint(equalTo: sideArea.trailingAnchor)
    let initialTabStripVisible = AppSettings.shared.showMainTabStrip
    let hiddenContentTop = innerPadding - tabsHeight
    let contentTopConstraint = contentContainer.topAnchor.constraint(
      equalTo: tabsArea.bottomAnchor,
      constant: initialTabStripVisible ? 0 : hiddenContentTop
    )
    self.tabsHeightConstraint = tabsHeightConstraint
    self.contentTopConstraint = contentTopConstraint
    sidebarWidthConstraint = sideWidthConstraint
    sidebarLeadingConstraint = sideLeadingConstraint
    contentLeadingToSidebarConstraint = contentLeadingToSidebar

    NSLayoutConstraint.activate([
      tabsHeightConstraint,
      sideWidthConstraint,

      sideLeadingConstraint,
      sideArea.topAnchor.constraint(equalTo: view.topAnchor),
      sideArea.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      contentLeadingToSidebar,
      contentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -innerPadding),

      tabsArea.leadingAnchor.constraint(equalTo: sideArea.trailingAnchor),
      tabsArea.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      tabsArea.topAnchor.constraint(equalTo: view.topAnchor),

      toolbarArea
        .leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
      toolbarArea
        .trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
      toolbarArea
        .topAnchor.constraint(equalTo: contentContainer.topAnchor),
      toolbarArea
        .heightAnchor.constraint(equalToConstant: Theme.toolbarHeight),

      contentTopConstraint,
      contentContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -innerPadding),

      contentArea.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
      contentArea.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
      contentArea.topAnchor.constraint(equalTo: contentContainer.topAnchor),
      contentArea.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
    ])

    setupQuickSearchOverlay()
    setTabStrip(viewController: MainTabStripController(dependencies: dependencies))
    setSidebar(viewController: MainSidebar(dependencies: dependencies))
    applyTabStripVisibility(animated: false)
    setupNav()
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    fetchInitialData()
  }

  override func viewWillAppear() {
    super.viewWillAppear()
    setupQuickSearchObserver()
    setupAppActiveObserver()
    setupSettingsObserver()
  }

  override func viewDidAppear() {
    super.viewDidAppear()
    prewarmQuickSearchOverlay()
    setupTrafficLightController()
    applyTabStripVisibility(animated: false)
    applySidebarVisibility(animated: false)
  }

  override func viewWillDisappear() {
    super.viewWillDisappear()
    tearDownObservers()
  }

  deinit {
    // Cleanup happens in viewWillDisappear to stay on the main actor.
  }

  @MainActor
  private func tearDownObservers() {
    escapeKeyUnsubscriber?()
    escapeKeyUnsubscriber = nil
    removeQuickSearchKeyHandlers()
    if let quickSearchObserver {
      NotificationCenter.default.removeObserver(quickSearchObserver)
      self.quickSearchObserver = nil
    }
    if let appActiveObserver {
      NotificationCenter.default.removeObserver(appActiveObserver)
      self.appActiveObserver = nil
    }
    if let trafficLightPresenceObserver, let controller = dependencies.trafficLightController {
      controller.removePresenceObserver(trafficLightPresenceObserver)
      self.trafficLightPresenceObserver = nil
    }
    removeQuickSearchClickMonitor()
    settingsCancellables.removeAll()
  }

  private func setupSettingsObserver() {
    guard settingsCancellables.isEmpty else { return }

    AppSettings.shared.$translationUIEnabled
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        guard let self, let nav2 = self.dependencies.nav2 else { return }
        let toolbar = self.toolbar(for: nav2.currentRoute)
        self.toolbarArea.update(with: toolbar)
      }
      .store(in: &settingsCancellables)

    AppSettings.shared.$showMainTabStrip
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        self?.applyTabStripVisibility(animated: false)
        self?.updateTrafficLightLayout(animated: false)
      }
      .store(in: &settingsCancellables)
  }

  private func setupAppActiveObserver() {
    guard appActiveObserver == nil else { return }
    appActiveObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.refetchChats()
    }
  }

  private func fetchInitialData() {
    let realtime = dependencies.realtimeV2
    let data = dependencies.data

    Task.detached {
      do {
        try await realtime.send(.getMe())
        Task.detached {
          try? await data.getSpaces()
        }
      } catch {
        Log.shared.error("Error fetching getMe info", error: error)
      }
    }

    Task.detached {
      do {
        try await realtime.send(.getChats())
      } catch {
        Log.shared.error("Error fetching getChats", error: error)
      }
    }
  }

  private func refetchChats() {
    let realtime = dependencies.realtimeV2
    Task.detached {
      do {
        try await realtime.send(.getChats())
      } catch {
        Log.shared.error("Error refetching getChats", error: error)
      }
    }
  }

  private func setupNav() {
    guard let nav2 = dependencies.nav2 else { return }

    // Render immediately so we have the right content on first load.
    updateContent(for: nav2.currentRoute)
    updateEscapeHandler(for: nav2)

    // Re-register observation on every change (Observation doesn't keep watchers alive).
    withObservationTracking { [weak self] in
      guard let self else { return }
      _ = nav2.currentRoute
      _ = nav2.activeTab
      // updateContent(for: nav2.currentRoute)
    } onChange: { [weak self] in
      // Re-arm observation immediately to avoid missing rapid successive changes.
      // `onChange` is not guaranteed to run on the main actor.
      Task { @MainActor [weak self] in
        self?.setupNav()
      }
    }
  }

  private func updateEscapeHandler(for nav2: Nav2) {
    let shouldHandleEscape = escapeTargetRoute(for: nav2) != nil

    if shouldHandleEscape {
      guard escapeKeyUnsubscriber == nil else { return }
      guard let keyMonitor = dependencies.keyMonitor else { return }
      escapeKeyUnsubscriber = keyMonitor.addHandler(for: .escape, key: "nav2_escape") { [weak self] _ in
        self?.handleEscape()
      }
    } else {
      escapeKeyUnsubscriber?()
      escapeKeyUnsubscriber = nil
    }
  }

  private func handleEscape() {
    guard let nav2 = dependencies.nav2 else { return }
    guard let targetRoute = escapeTargetRoute(for: nav2) else { return }
    nav2.navigate(to: targetRoute)
  }

  private func escapeTargetRoute(for nav2: Nav2) -> Nav2Route? {
    switch nav2.activeTab {
      case .home:
        return nav2.currentRoute == .empty ? nil : .empty
      case .space:
        return nav2.currentRoute == .empty ? nil : .empty
    }
  }

  // MARK: - Public API

  private var sidebarVC: NSViewController?
  private var tabStripVC: NSViewController?
  private var contentVC: NSViewController?

  var isSidebarCollapsed: Bool {
    sidebarCollapsed
  }

  func setSidebar(viewController: NSViewController) {
    // Remove previous
    sidebarVC?.removeFromParent()
    sidebarVC?.view.removeFromSuperview()
    sidebarVC = viewController

    // Add new view
    addChild(viewController)
    sideArea.addSubview(viewController.view)

    // Pin to superview
    viewController.view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      viewController.view.topAnchor.constraint(equalTo: sideArea.topAnchor),
      viewController.view.bottomAnchor.constraint(equalTo: sideArea.bottomAnchor),
      viewController.view.leadingAnchor.constraint(equalTo: sideArea.leadingAnchor),
      viewController.view.trailingAnchor.constraint(equalTo: sideArea.trailingAnchor),
    ])
    updateSidebarTrafficLightPresence(trafficLightsVisible)
  }

  private func setTabStrip(viewController: NSViewController) {
    tabStripVC?.removeFromParent()
    tabStripVC?.view.removeFromSuperview()
    tabStripVC = viewController

    addChild(viewController)
    tabsArea.addSubview(viewController.view)

    viewController.view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      viewController.view.topAnchor.constraint(equalTo: tabsArea.topAnchor),
      viewController.view.bottomAnchor.constraint(equalTo: tabsArea.bottomAnchor),
      viewController.view.leadingAnchor.constraint(equalTo: tabsArea.leadingAnchor),
      viewController.view.trailingAnchor.constraint(equalTo: tabsArea.trailingAnchor),
    ])

    updateTabStripLeadingPadding(animated: false, duration: 0)
  }

  private func setContentArea(viewController: NSViewController) {
    contentVC?.removeFromParent()
    contentVC?.view.removeFromSuperview()
    contentVC = viewController

    addChild(viewController)
    contentArea.addSubview(viewController.view, positioned: .below, relativeTo: toolbarArea)

    // Pin to superview
    viewController.view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      viewController.view.topAnchor.constraint(equalTo: contentArea.topAnchor),
      viewController.view.bottomAnchor.constraint(equalTo: contentArea.bottomAnchor),
      viewController.view.leadingAnchor.constraint(equalTo: contentArea.leadingAnchor),
      viewController.view.trailingAnchor.constraint(equalTo: contentArea.trailingAnchor),
    ])
  }

  @MainActor
  private func updateContent(for route: Nav2Route) {
    guard route != lastRenderedRoute else { return }
    lastRenderedRoute = route

    let viewController = viewController(for: route)
    let toolbar = toolbar(for: route)
    toolbarArea.update(with: toolbar)
    setContentArea(viewController: viewController)
  }

  private func applyTabStripVisibility(animated _: Bool) {
    guard let tabsHeightConstraint, let contentTopConstraint else { return }

    let shouldShow = AppSettings.shared.showMainTabStrip
    let hiddenContentTop = innerPadding - tabsHeight
    let targetContentTop = shouldShow ? 0 : hiddenContentTop

    tabsArea.isHidden = false

    // Animations disabled by request.
    // let shouldAnimate = animated
    //   && view.window != nil
    //   && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    // NSAnimationContext.runAnimationGroup { ... }
    tabsHeightConstraint.constant = tabsHeight
    contentTopConstraint.constant = targetContentTop
    tabsArea.alphaValue = shouldShow ? 1 : 0
    tabsArea.isHidden = !shouldShow
    view.layoutSubtreeIfNeeded()
  }

  // MARK: - Quick Search

  private func setupQuickSearchOverlay() {
    view.addSubview(quickSearchOverlayBackground)
    view.addSubview(quickSearchOverlayContainer)

    NSLayoutConstraint.activate([
      quickSearchOverlayBackground.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      quickSearchOverlayBackground.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      quickSearchOverlayBackground.topAnchor.constraint(equalTo: view.topAnchor),
      quickSearchOverlayBackground.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      quickSearchOverlayContainer.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      quickSearchOverlayContainer.topAnchor.constraint(equalTo: view.topAnchor, constant: 56),
    ])

    let widthConstraint = quickSearchOverlayContainer.widthAnchor.constraint(equalToConstant: 420)
    let heightConstraint = quickSearchOverlayContainer.heightAnchor.constraint(equalToConstant: 220)
    widthConstraint.isActive = true
    heightConstraint.isActive = true
    quickSearchWidthConstraint = widthConstraint
    quickSearchHeightConstraint = heightConstraint

    let rootView = AnyView(
      QuickSearchOverlayView(
        viewModel: quickSearchViewModel,
        onDismiss: { [weak self] in
          self?.hideQuickSearchOverlay()
        },
        onSizeChange: { [weak self] size in
          self?.updateQuickSearchSize(size)
        }
      )
      .environment(dependencies: dependencies)
    )

    let hostingView = NSHostingView(rootView: rootView)
    hostingView.translatesAutoresizingMaskIntoConstraints = false
    quickSearchOverlayContainer.addSubview(hostingView)
    NSLayoutConstraint.activate([
      hostingView.leadingAnchor.constraint(equalTo: quickSearchOverlayContainer.leadingAnchor),
      hostingView.trailingAnchor.constraint(equalTo: quickSearchOverlayContainer.trailingAnchor),
      hostingView.topAnchor.constraint(equalTo: quickSearchOverlayContainer.topAnchor),
      hostingView.bottomAnchor.constraint(equalTo: quickSearchOverlayContainer.bottomAnchor),
    ])
    quickSearchHostingView = hostingView
  }

  private func prewarmQuickSearchOverlay() {
    guard didPrewarmQuickSearch == false else { return }
    didPrewarmQuickSearch = true
    guard quickSearchHostingView != nil else { return }

    quickSearchOverlayContainer.alphaValue = 0
    quickSearchOverlayContainer.isHidden = false
    view.layoutSubtreeIfNeeded()
    quickSearchHostingView?.layoutSubtreeIfNeeded()

    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      guard self.isQuickSearchVisible == false else { return }
      self.quickSearchOverlayContainer.isHidden = true
      self.quickSearchOverlayContainer.alphaValue = 1
    }
  }

  private func setupQuickSearchObserver() {
    guard quickSearchObserver == nil else { return }
    quickSearchObserver = NotificationCenter.default.addObserver(
      forName: .focusSearch,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      if self.isQuickSearchVisible {
        self.log.debug("Ignoring focusSearch; quick search is already visible")
      }
      self.showQuickSearchOverlay()
    }
  }

  func setSidebarCollapsed(_ collapsed: Bool, animated: Bool) {
    guard collapsed != sidebarCollapsed else { return }
    sidebarCollapsed = collapsed
    applySidebarVisibility(animated: animated)
  }

  private func applySidebarVisibility(animated: Bool = true) {
    let targetCollapsed = sidebarCollapsed
    let targetLeading = targetCollapsed ? -sideWidth : 0
    let targetContentLeading = targetCollapsed ? innerPadding : 0

    guard let sidebarLeadingConstraint, let contentLeadingToSidebarConstraint else { return }

    let shouldAnimate = animated
      && view.window != nil
      && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    updateTrafficLightLayout(
      animated: shouldAnimate,
      duration: SidebarAnimation.duration(forCollapsed: targetCollapsed)
    )

    if shouldAnimate {
      view.layoutSubtreeIfNeeded()
      NSAnimationContext.runAnimationGroup { context in
        context.duration = SidebarAnimation.duration(forCollapsed: targetCollapsed)
        context.timingFunction = SidebarAnimation.timing(forCollapsed: targetCollapsed)
        context.allowsImplicitAnimation = true
        sidebarLeadingConstraint.animator().constant = targetLeading
        contentLeadingToSidebarConstraint.animator().constant = targetContentLeading
        view.layoutSubtreeIfNeeded()
      }
    } else {
      sidebarLeadingConstraint.constant = targetLeading
      contentLeadingToSidebarConstraint.constant = targetContentLeading
      view.layoutSubtreeIfNeeded()
    }
  }

  private func setupTrafficLightController() {
    guard trafficLightPresenceObserver == nil,
          let controller = dependencies.trafficLightController
    else { return }
    trafficLightPresenceObserver = controller.addPresenceObserver { [weak self] visible in
      guard let self else { return }
      trafficLightsVisible = visible
      updateTrafficLightLayout(
        animated: false,
        duration: SidebarAnimation.duration(forCollapsed: sidebarCollapsed)
      )
      updateSidebarTrafficLightPresence(visible)
    }
    controller.setInsetPreset(currentTrafficLightInsetPreset())
    updateTrafficLightLayout(
      animated: false,
      duration: SidebarAnimation.duration(forCollapsed: sidebarCollapsed)
    )
  }

  private func updateSidebarTrafficLightPresence(_ isVisible: Bool) {
    if let sidebar = sidebarVC as? MainSidebar {
      sidebar.setTrafficLightsVisible(isVisible)
    }
  }

  private func updateTrafficLightLayout(
    animated: Bool = false,
    duration: TimeInterval = 0.2
  ) {
    dependencies.trafficLightController?.setInsetPreset(currentTrafficLightInsetPreset())
    updateToolbarLeadingPadding(animated: animated, duration: duration)
    updateTabStripLeadingPadding(animated: animated, duration: duration)
  }

  private func currentTrafficLightInsetPreset() -> TrafficLightInsetPreset {
    if sidebarCollapsed {
      return isTabStripEnabled ? .sidebarHiddenWithTabStrip : .sidebarHidden
    }
    return isTabStripEnabled ? .sidebarVisibleWithTabStrip : .sidebarVisible
  }

  private func updateToolbarLeadingPadding(
    animated: Bool = false,
    duration: TimeInterval = 0.2
  ) {
    guard trafficLightsVisible, sidebarCollapsed, !isTabStripEnabled else {
      toolbarArea.updateLeadingPadding(
        ToolbarMetrics.defaultLeadingPadding,
        animated: animated,
        duration: duration
      )
      return
    }
    toolbarArea.updateLeadingPadding(
      ToolbarMetrics.collapsedLeadingPadding,
      animated: animated,
      duration: duration
    )
  }

  private func updateTabStripLeadingPadding(
    animated: Bool = false,
    duration: TimeInterval = 0.2
  ) {
    let padding: CGFloat = if trafficLightsVisible && sidebarCollapsed && isTabStripEnabled {
      TabStripMetrics.collapsedLeadingPadding
    } else {
      TabStripMetrics.defaultLeadingPadding
    }

    if let tabStrip = tabStripVC as? MainTabStripController {
      tabStrip.updateLeadingPadding(
        padding,
        animated: animated,
        duration: duration
      )
    }
  }

  private func toggleQuickSearchOverlay() {
    if isQuickSearchVisible {
      hideQuickSearchOverlay()
    } else {
      showQuickSearchOverlay()
    }
  }

  private func showQuickSearchOverlay() {
    guard isQuickSearchVisible == false else { return }
    isQuickSearchVisible = true
    quickSearchOverlayBackground.isHidden = false
    quickSearchOverlayContainer.isHidden = false
    quickSearchOverlayContainer.alphaValue = 1
    let baselineEventTimestamp = NSApp.currentEvent?.timestamp ?? 0
    let baselineUptime = ProcessInfo.processInfo.systemUptime
    quickSearchClickMonitorIgnoreUntil = max(baselineEventTimestamp, baselineUptime) + 0.12
    quickSearchViewModel.requestFocus()
    installQuickSearchKeyHandlers()
    installQuickSearchClickMonitor()
    log.debug("Quick search shown")
    NotificationCenter.default.post(
      name: .quickSearchVisibilityChanged,
      object: nil,
      userInfo: ["isVisible": true]
    )
  }

  private func hideQuickSearchOverlay() {
    guard isQuickSearchVisible else { return }
    isQuickSearchVisible = false
    quickSearchOverlayBackground.isHidden = true
    quickSearchOverlayContainer.isHidden = true
    quickSearchClickMonitorIgnoreUntil = 0
    quickSearchViewModel.reset()
    removeQuickSearchKeyHandlers()
    removeQuickSearchClickMonitor()
    log.debug("Quick search hidden")
    NotificationCenter.default.post(
      name: .quickSearchVisibilityChanged,
      object: nil,
      userInfo: ["isVisible": false]
    )
  }

  private func updateQuickSearchSize(_ size: NSSize) {
    quickSearchWidthConstraint?.constant = size.width
    quickSearchHeightConstraint?.constant = size.height
    view.layoutSubtreeIfNeeded()
  }

  private func installQuickSearchKeyHandlers() {
    guard quickSearchEscapeUnsubscriber == nil else { return }
    guard let keyMonitor = dependencies.keyMonitor else { return }

    quickSearchEscapeUnsubscriber = keyMonitor.addHandler(
      for: .escape,
      key: "quick_search_overlay_escape"
    ) { [weak self] _ in
      self?.hideQuickSearchOverlay()
    }

    quickSearchArrowUnsubscriber = keyMonitor.addHandler(
      for: .verticalArrowKeys,
      key: "quick_search_overlay_arrows"
    ) { [weak self] event in
      guard let self else { return }
      switch event.keyCode {
        case 126:
          self.quickSearchViewModel.moveSelection(isForward: false)
        case 125:
          self.quickSearchViewModel.moveSelection(isForward: true)
        default:
          break
      }
    }

    quickSearchVimUnsubscriber = keyMonitor.addHandler(
      for: .vimNavigation,
      key: "quick_search_overlay_vim"
    ) { [weak self] event in
      guard let self else { return }
      guard let char = event.charactersIgnoringModifiers?.lowercased() else { return }
      switch char {
        case "k", "p":
          self.quickSearchViewModel.moveSelection(isForward: false)
        case "j", "n":
          self.quickSearchViewModel.moveSelection(isForward: true)
        default:
          break
      }
    }

    quickSearchReturnUnsubscriber = keyMonitor.addHandler(
      for: .returnKey,
      key: "quick_search_overlay_return"
    ) { [weak self] _ in
      guard let self else { return }
      if self.quickSearchViewModel.activateSelection() {
        self.hideQuickSearchOverlay()
      }
    }
  }

  private func removeQuickSearchKeyHandlers() {
    quickSearchEscapeUnsubscriber?()
    quickSearchEscapeUnsubscriber = nil
    quickSearchArrowUnsubscriber?()
    quickSearchArrowUnsubscriber = nil
    quickSearchVimUnsubscriber?()
    quickSearchVimUnsubscriber = nil
    quickSearchReturnUnsubscriber?()
    quickSearchReturnUnsubscriber = nil
  }

  private func installQuickSearchClickMonitor() {
    guard quickSearchClickMonitor == nil else { return }
    quickSearchClickMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
    ) { [weak self] event in
      guard let self, self.isQuickSearchVisible else { return event }
      if event.timestamp < self.quickSearchClickMonitorIgnoreUntil {
        return event
      }
      let pointInContainer = self.quickSearchOverlayContainer.convert(event.locationInWindow, from: nil)
      if self.quickSearchOverlayContainer.bounds.contains(pointInContainer) == false {
        self.log.debug("Dismissing quick search from outside click")
        self.hideQuickSearchOverlay()
      }
      return event
    }
  }

  private func removeQuickSearchClickMonitor() {
    guard let quickSearchClickMonitor else { return }
    NSEvent.removeMonitor(quickSearchClickMonitor)
    self.quickSearchClickMonitor = nil
  }
}

class ContentAreaView: NSView {
  init() {
    super.init(frame: .zero)
    wantsLayer = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func updateLayer() {
    layer?.backgroundColor = Theme.windowContentBackgroundColor
      .resolvedColor(with: effectiveAppearance)
      .cgColor
    super.updateLayer()
  }
}

private final class PassthroughView: NSView {
  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }
}
