import AppKit
import InlineRTC

@MainActor
final class GridScreenShareOutlineCoordinator {
  static let shared = GridScreenShareOutlineCoordinator()

  private var panel: NSPanel?
  private var source: InlineRTCScreenCaptureSource?
  private var screenParametersTask: Task<Void, Never>?

  private init() {
    screenParametersTask = Task { @MainActor [weak self] in
      for await _ in NotificationCenter.default.notifications(
        named: NSApplication.didChangeScreenParametersNotification
      ) {
        guard !Task.isCancelled else { return }
        self?.reposition()
      }
    }
  }

  func show(for source: InlineRTCScreenCaptureSource) {
    self.source = source
    reposition()
  }

  func hide() {
    source = nil
    panel?.orderOut(nil)
  }

  private func reposition() {
    guard let source,
          source.kind == .display,
          let displayID = source.displayID,
          let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[
              NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber)?.uint32Value == displayID
          })
    else {
      hide()
      return
    }

    let panel = panel ?? makePanel()
    panel.setFrame(screen.frame, display: true)
    panel.orderFrontRegardless()
  }

  private func makePanel() -> NSPanel {
    let panel = NSPanel(
      contentRect: .zero,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = false
    panel.ignoresMouseEvents = true
    panel.hidesOnDeactivate = false
    panel.level = NSWindow.Level(
      rawValue: Int(CGWindowLevelForKey(.screenSaverWindow))
    )
    panel.collectionBehavior = [
      .canJoinAllSpaces,
      .fullScreenAuxiliary,
      .ignoresCycle,
      .stationary,
    ]
    panel.isReleasedWhenClosed = false
    panel.contentView = GridScreenShareOutlineView(frame: .zero)
    self.panel = panel
    return panel
  }
}

private final class GridScreenShareOutlineView: NSView {
  override var isOpaque: Bool { false }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    let path = NSBezierPath(
      roundedRect: bounds.insetBy(dx: 2, dy: 2),
      xRadius: 5,
      yRadius: 5
    )
    path.lineWidth = 3
    NSColor.systemRed.withAlphaComponent(0.72).setStroke()
    path.stroke()
  }
}
