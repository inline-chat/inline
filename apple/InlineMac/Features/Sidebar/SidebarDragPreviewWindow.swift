import AppKit
import SwiftUI

@MainActor
final class SidebarDragPreviewWindow {
  static let shared = SidebarDragPreviewWindow()

  private static let shadowPadding: CGFloat = 18

  private var window: NSPanel?
  private var hostingView: SidebarDragPreviewHostingView?

  private init() {}

  func show(state: SidebarDragPreviewState) {
    let panel = window ?? makeWindow()
    let hostingView = hostingView ?? makeHostingView(state: state)

    hostingView.rootView = preview(state)

    panel.contentView = hostingView
    panel.setFrame(windowFrame(for: state), display: true)
    panel.orderFront(nil)

    window = panel
    self.hostingView = hostingView
  }

  func update(state: SidebarDragPreviewState) {
    guard let window, let hostingView else {
      show(state: state)
      return
    }

    hostingView.rootView = preview(state)
    window.setFrame(windowFrame(for: state), display: true)
  }

  func hide() {
    window?.orderOut(nil)
  }

  private func makeWindow() -> NSPanel {
    let panel = NSPanel(
      contentRect: .zero,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = false
    panel.hidesOnDeactivate = false
    panel.ignoresMouseEvents = true
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    return panel
  }

  private func makeHostingView(state: SidebarDragPreviewState) -> SidebarDragPreviewHostingView {
    SidebarDragPreviewHostingView(rootView: preview(state))
  }

  private func windowFrame(for state: SidebarDragPreviewState) -> NSRect {
    let padding = Self.shadowPadding
    return NSRect(
      x: state.origin.x - padding,
      y: state.origin.y - padding,
      width: state.rowSize.width + padding * 2,
      height: state.rowSize.height + padding * 2
    )
  }

  private func preview(_ state: SidebarDragPreviewState) -> AnyView {
    AnyView(
      SidebarDragPreviewView(item: state.item, rowSize: state.rowSize)
        .padding(Self.shadowPadding)
        .environment(\.colorScheme, state.colorScheme)
    )
  }
}

private final class SidebarDragPreviewHostingView: NSHostingView<AnyView> {
  override var isOpaque: Bool { false }

  @MainActor @preconcurrency required init(rootView: AnyView) {
    super.init(rootView: rootView)
    configure()
  }

  @MainActor @preconcurrency required dynamic init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    configure()
  }

  private func configure() {
    wantsLayer = true
    layer?.backgroundColor = NSColor.clear.cgColor
    layer?.isOpaque = false
  }
}
