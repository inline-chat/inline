import AppKit
import SwiftUI

@MainActor
final class CommandBarPanelController: NSObject, NSWindowDelegate {
  private enum Metrics {
    static let screenPadding: CGFloat = 24
    static let ownerTopInset: CGFloat = 56
    static let minimumHeight: CGFloat = 220
    static let preferredHeight: CGFloat = 340
  }

  private let viewModel: QuickSearchViewModel
  private let nav: Nav3
  private let dependencies: AppDependencies
  private let panel: CommandBarPanel

  private weak var ownerWindow: NSWindow?
  private var hostingController: NSHostingController<AnyView>?
  private var ownerObservers: [NSObjectProtocol] = []
  private var localKeyMonitor: Any?
  private var isPresented = false
  private var isHiding = false
  private var hasAppliedDefaultGeometry = false

  init(viewModel: QuickSearchViewModel, nav: Nav3, dependencies: AppDependencies) {
    self.viewModel = viewModel
    self.nav = nav
    self.dependencies = dependencies
    panel = CommandBarPanel(
      contentRect: .zero,
      styleMask: [.borderless, .resizable, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    super.init()
    configurePanel()
    configureContentIfNeeded()
  }

  deinit {
    for observer in ownerObservers {
      NotificationCenter.default.removeObserver(observer)
    }
    if let localKeyMonitor {
      NSEvent.removeMonitor(localKeyMonitor)
    }
  }

  func setOwnerWindow(_ window: NSWindow?) {
    guard ownerWindow !== window else { return }

    let shouldRestorePresentation = isPresented
    hide(reset: false)
    removeOwnerObservers()
    ownerWindow = window
    installOwnerObservers()

    if shouldRestorePresentation {
      show()
    }
  }

  func setPresented(_ presented: Bool) {
    guard isPresented != presented else { return }

    isPresented = presented
    if presented {
      show()
    } else {
      hide(reset: true)
    }
  }

  func invalidate() {
    isPresented = false
    hide(reset: false)
    removeOwnerObservers()
    ownerWindow = nil
    panel.delegate = nil
  }

  func windowDidResignKey(_ notification: Notification) {
    guard isPresented, isHiding == false, panel.isVisible else { return }
    dismiss()
  }

  func windowDidChangeScreen(_ notification: Notification) {
    constrainCurrentFrameToScreen()
  }

  private func configurePanel() {
    panel.delegate = self
    panel.isReleasedWhenClosed = false
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.hidesOnDeactivate = true
    panel.isFloatingPanel = true
    panel.isMovableByWindowBackground = true
    panel.level = .floating
    panel.animationBehavior = .none
    panel.collectionBehavior = [.transient, .fullScreenAuxiliary, .ignoresCycle]
  }

  private func configureContentIfNeeded() {
    guard hostingController == nil else { return }

    let root = QuickSearchOverlayView(
      viewModel: viewModel,
      onDismiss: { [weak self] in
        self?.dismiss()
      }
    )
    .environment(dependencies: dependencies)

    let hostingController = NSHostingController(rootView: AnyView(root))
    hostingController.sizingOptions = []
    hostingController.view.autoresizingMask = [.width, .height]
    hostingController.view.frame = NSRect(
      origin: .zero,
      size: NSSize(width: QuickSearchLayout.defaultWidth, height: Metrics.preferredHeight)
    )
    hostingController.view.wantsLayer = true
    hostingController.view.layer?.cornerRadius = QuickSearchLayout.cornerRadius
    hostingController.view.layer?.cornerCurve = .continuous
    hostingController.view.layer?.masksToBounds = true
    panel.contentViewController = hostingController
    hostingController.view.layoutSubtreeIfNeeded()
    self.hostingController = hostingController
  }

  private func show() {
    guard let ownerWindow else { return }
    configureContentIfNeeded()
    panel.appearance = ownerWindow.appearance
    hostingController?.view.appearance = ownerWindow.appearance

    if panel.parent !== ownerWindow {
      panel.parent?.removeChildWindow(panel)
      ownerWindow.addChildWindow(panel, ordered: .above)
    }

    applyPresentationGeometry(useDefaultSize: hasAppliedDefaultGeometry == false)
    hasAppliedDefaultGeometry = true
    installKeyMonitor()
    panel.makeKeyAndOrderFront(nil)
    panel.invalidateShadow()
    requestInputFocus()
  }

  private func hide(reset: Bool) {
    guard isHiding == false else { return }
    isHiding = true
    removeKeyMonitor()

    let ownerWindow = ownerWindow
    if panel.isVisible {
      panel.orderOut(nil)
    }
    panel.parent?.removeChildWindow(panel)

    if NSApp.isActive, ownerWindow?.isVisible == true {
      ownerWindow?.makeKey()
    }
    if reset {
      viewModel.reset()
    }
    isHiding = false
  }

  private func dismiss() {
    guard isPresented else { return }
    nav.closeCommandBar()
    setPresented(false)
  }

  private func requestInputFocus() {
    DispatchQueue.main.async { [weak self] in
      guard let self, isPresented, panel.isVisible else { return }
      viewModel.requestFocus()
    }
  }

  private func applyPresentationGeometry(useDefaultSize: Bool) {
    guard let ownerWindow,
          let screen = ownerWindow.screen ?? NSScreen.main
    else { return }

    let visibleFrame = screen.visibleFrame
    let (maximumWidth, maximumHeight) = updateResizeLimits(for: visibleFrame)
    let minimumWidth = min(320, maximumWidth)
    let requestedWidth = useDefaultSize ? QuickSearchLayout.defaultWidth : panel.frame.width
    let width = max(minimumWidth, min(requestedWidth, maximumWidth))
    let minimumHeight = min(Metrics.minimumHeight, maximumHeight)
    let requestedHeight = useDefaultSize ? Metrics.preferredHeight : panel.frame.height
    let height = max(minimumHeight, min(requestedHeight, maximumHeight))

    let centeredX = ownerWindow.frame.midX - (width / 2)
    let x = min(
      max(centeredX, visibleFrame.minX + Metrics.screenPadding),
      visibleFrame.maxX - Metrics.screenPadding - width
    )

    let preferredTop = ownerWindow.frame.maxY - Metrics.ownerTopInset
    let minimumTop = visibleFrame.minY + Metrics.screenPadding + height
    let maximumTop = visibleFrame.maxY - Metrics.screenPadding
    let top = min(max(preferredTop, minimumTop), maximumTop)
    let frame = NSRect(x: x, y: top - height, width: width, height: height)
    panel.setFrame(frame, display: true)
    panel.invalidateShadow()
  }

  private func constrainCurrentFrameToScreen() {
    guard isPresented,
          let screen = panel.screen ?? ownerWindow?.screen ?? NSScreen.main
    else { return }

    let visibleFrame = screen.visibleFrame
    let (maximumWidth, maximumHeight) = updateResizeLimits(for: visibleFrame)
    var frame = panel.frame
    frame.size.width = min(frame.width, maximumWidth)
    frame.size.height = min(frame.height, maximumHeight)
    frame.origin.x = min(
      max(frame.minX, visibleFrame.minX + Metrics.screenPadding),
      visibleFrame.maxX - Metrics.screenPadding - frame.width
    )
    frame.origin.y = min(
      max(frame.minY, visibleFrame.minY + Metrics.screenPadding),
      visibleFrame.maxY - Metrics.screenPadding - frame.height
    )
    panel.setFrame(frame, display: true)
  }

  @discardableResult
  private func updateResizeLimits(for visibleFrame: NSRect) -> (width: CGFloat, height: CGFloat) {
    let availableWidth = max(0, visibleFrame.width - (Metrics.screenPadding * 2))
    let maximumWidth = min(QuickSearchLayout.maximumWidth, availableWidth)
    let maximumHeight = max(0, visibleFrame.height - (Metrics.screenPadding * 2))
    panel.minSize = NSSize(
      width: min(320, maximumWidth),
      height: min(Metrics.minimumHeight, maximumHeight)
    )
    panel.maxSize = NSSize(width: maximumWidth, height: maximumHeight)
    return (maximumWidth, maximumHeight)
  }

  private func installKeyMonitor() {
    guard localKeyMonitor == nil else { return }
    localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self, panel.isKeyWindow else { return event }
      return handleKeyDown(event) ? nil : event
    }
  }

  private func removeKeyMonitor() {
    guard let localKeyMonitor else { return }
    NSEvent.removeMonitor(localKeyMonitor)
    self.localKeyMonitor = nil
  }

  private func handleKeyDown(_ event: NSEvent) -> Bool {
    switch event.keyCode {
    case 126:
      viewModel.moveSelection(isForward: false)
      return true
    case 125:
      viewModel.moveSelection(isForward: true)
      return true
    case 36, 76:
      if viewModel.activateSelection() {
        dismiss()
      }
      return true
    case 53:
      dismiss()
      return true
    default:
      break
    }

    if event.modifierFlags.contains(.control),
       let character = event.charactersIgnoringModifiers?.lowercased() {
      switch character {
      case "k", "p":
        viewModel.moveSelection(isForward: false)
        return true
      case "j", "n":
        viewModel.moveSelection(isForward: true)
        return true
      default:
        break
      }
    }

    return false
  }

  private func installOwnerObservers() {
    guard let ownerWindow else { return }
    let center = NotificationCenter.default
    ownerObservers.append(center.addObserver(
      forName: NSWindow.willCloseNotification,
      object: ownerWindow,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.nav.closeCommandBar()
        self.setPresented(false)
      }
    })

    ownerObservers.append(center.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.constrainCurrentFrameToScreen()
      }
    })
  }

  private func removeOwnerObservers() {
    for observer in ownerObservers {
      NotificationCenter.default.removeObserver(observer)
    }
    ownerObservers.removeAll()
  }
}

private final class CommandBarPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}
