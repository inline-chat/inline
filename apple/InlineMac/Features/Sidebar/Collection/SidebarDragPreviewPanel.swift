import AppKit
import QuartzCore
import SwiftUI

/// App-owned, shadowless lifted-row preview. It is a child window of the
/// sidebar's owner so cursor tracking is independent of collection relayout.
@MainActor
final class SidebarDragPreviewPanel {
  private let panel: NSPanel
  private weak var ownerWindow: NSWindow?
  private var hostingView: NSHostingView<AnyView>?
  private var nativeView: SidebarNativeDragPreviewView?
  private var nativeContent: ((SidebarCollectionRow) -> SidebarNativeRowConfiguration)?

  init() {
    panel = NSPanel(
      contentRect: .zero,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.ignoresMouseEvents = true
    panel.level = .floating
    panel.collectionBehavior = [.transient, .fullScreenAuxiliary]
  }

  func show(
    rows: [SidebarCollectionRow],
    content: @escaping (SidebarCollectionRow) -> AnyView,
    nativeContent: ((SidebarCollectionRow) -> SidebarNativeRowConfiguration)?,
    horizontalBleed: CGFloat,
    ownerWindow: NSWindow,
    frame: CGRect
  ) {
    let panelFrame = frame.insetBy(dx: -horizontalBleed, dy: 0)
    if let nativeContent {
      let nativeView = SidebarNativeDragPreviewView()
      nativeView.frame = CGRect(origin: .zero, size: panelFrame.size)
      nativeView.autoresizingMask = [.width, .height]
      nativeView.appearance = ownerWindow.appearance
      nativeView.configure(
        rows: rows,
        content: nativeContent,
        horizontalBleed: horizontalBleed
      )
      panel.contentView = nativeView
      self.nativeView = nativeView
      hostingView = nil
    } else {
      let preview = preview(
        rows: rows,
        content: content,
        horizontalBleed: horizontalBleed,
        frame: frame
      )
      let hostingView = NSHostingView(rootView: preview)
      hostingView.frame = CGRect(origin: .zero, size: panelFrame.size)
      hostingView.autoresizingMask = [.width, .height]
      hostingView.appearance = ownerWindow.appearance
      panel.contentView = hostingView
      self.hostingView = hostingView
      nativeView = nil
    }
    panel.appearance = ownerWindow.appearance
    self.nativeContent = nativeContent
    self.ownerWindow = ownerWindow
    panel.setFrame(panelFrame, display: true)
    ownerWindow.addChildWindow(panel, ordered: .above)
    panel.orderFront(nil)
  }

  /// Narrows a lifted group to its source row when a pin/unpin transfer changes
  /// only that dialog's section membership. The top edge stays fixed so the
  /// source row never jumps under the pointer at mouse-up.
  func showSourceOnly(
    row: SidebarCollectionRow,
    content: @escaping (SidebarCollectionRow) -> AnyView,
    horizontalBleed: CGFloat,
    width: CGFloat
  ) {
    let contentFrame = CGRect(x: 0, y: 0, width: width, height: row.height)
    let panelSize = CGSize(width: width + horizontalBleed * 2, height: row.height)
    let oldFrame = panel.frame
    let nextFrame = CGRect(
      x: oldFrame.minX,
      y: oldFrame.maxY - panelSize.height,
      width: panelSize.width,
      height: panelSize.height
    )
    if let nativeView, let nativeContent {
      nativeView.frame = CGRect(origin: .zero, size: panelSize)
      nativeView.configure(
        rows: [row],
        content: nativeContent,
        horizontalBleed: horizontalBleed
      )
    } else if let hostingView {
      hostingView.rootView = preview(
        rows: [row],
        content: content,
        horizontalBleed: horizontalBleed,
        frame: contentFrame
      )
      hostingView.frame = CGRect(origin: .zero, size: panelSize)
    } else {
      return
    }
    panel.setFrame(nextFrame, display: true)
  }

  func move(to origin: CGPoint, horizontalBleed: CGFloat) {
    panel.setFrameOrigin(CGPoint(x: origin.x - horizontalBleed, y: origin.y))
  }

  /// Retains the lifted preview's stable row views while its semantic target
  /// changes between root and nested placement.
  func update(
    rows: [SidebarCollectionRow],
    content: @escaping (SidebarCollectionRow) -> AnyView,
    nativeContent: ((SidebarCollectionRow) -> SidebarNativeRowConfiguration)?,
    horizontalBleed: CGFloat
  ) {
    let contentSize = CGSize(
      width: max(panel.frame.width - horizontalBleed * 2, 0),
      height: rows.reduce(CGFloat.zero) { $0 + $1.height }
    )
    let contentFrame = CGRect(origin: .zero, size: contentSize)
    if let nativeView, let nativeContent {
      nativeView.update(
        rows: rows,
        content: nativeContent,
        horizontalBleed: horizontalBleed
      )
    } else if let hostingView {
      hostingView.rootView = preview(
        rows: rows,
        content: content,
        horizontalBleed: horizontalBleed,
        frame: contentFrame
      )
    }
  }

  func settle(
    to frame: CGRect,
    horizontalBleed: CGFloat,
    completion: @escaping @MainActor () -> Void
  ) {
    let panelFrame = frame.insetBy(dx: -horizontalBleed, dy: 0)
    if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      panel.setFrame(panelFrame, display: true)
      completion()
      return
    }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.16
      context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      panel.animator().setFrame(panelFrame, display: true)
    } completionHandler: {
      Task { @MainActor in completion() }
    }
  }

  func hide() {
    panel.orderOut(nil)
    ownerWindow?.removeChildWindow(panel)
    ownerWindow = nil
    hostingView = nil
    nativeView = nil
    nativeContent = nil
    panel.contentView = nil
  }

  private func preview(
    rows: [SidebarCollectionRow],
    content: @escaping (SidebarCollectionRow) -> AnyView,
    horizontalBleed: CGFloat,
    frame: CGRect
  ) -> AnyView {
    let panelFrame = frame.insetBy(dx: -horizontalBleed, dy: 0)
    return AnyView(
      VStack(spacing: 0) {
        ForEach(rows) { row in
          content(row)
            .frame(width: frame.width)
            .frame(height: row.height)
        }
      }
      .frame(width: frame.width, height: frame.height, alignment: .top)
      .padding(.horizontal, horizontalBleed)
      .frame(width: panelFrame.width, height: panelFrame.height)
      .environment(\.controlActiveState, .key)
    )
  }
}

/// Frozen lifted rows use the same AppKit renderer as live collection items,
/// without becoming a second semantic or interaction owner.
@MainActor
private final class SidebarNativeDragPreviewView: NSView {
  private var rows: [SidebarCollectionRow] = []
  private var rowViews: [SidebarNativeRowView] = []
  private var horizontalBleed: CGFloat = 0

  override var isFlipped: Bool { true }

  func configure(
    rows: [SidebarCollectionRow],
    content: (SidebarCollectionRow) -> SidebarNativeRowConfiguration,
    horizontalBleed: CGFloat
  ) {
    rowViews.forEach { view in
      view.prepareForReuse()
      view.removeFromSuperview()
    }
    self.rows = rows
    self.horizontalBleed = horizontalBleed
    rowViews = rows.map { row in
      let view = SidebarNativeRowView()
      view.configure(content(row))
      view.setLayoutVisibility(true)
      addSubview(view)
      return view
    }
    needsLayout = true
  }

  func update(
    rows: [SidebarCollectionRow],
    content: (SidebarCollectionRow) -> SidebarNativeRowConfiguration,
    horizontalBleed: CGFloat
  ) {
    guard rows.map(\.id) == self.rows.map(\.id),
          rows.count == rowViews.count
    else {
      configure(rows: rows, content: content, horizontalBleed: horizontalBleed)
      return
    }

    self.rows = rows
    self.horizontalBleed = horizontalBleed
    for (row, view) in zip(rows, rowViews) {
      view.configure(content(row))
      view.setLayoutVisibility(true)
    }
    needsLayout = true
  }

  override func layout() {
    super.layout()
    var y: CGFloat = 0
    let width = max(bounds.width - horizontalBleed * 2, 0)
    for (row, view) in zip(rows, rowViews) {
      view.frame = CGRect(
        x: horizontalBleed,
        y: y,
        width: width,
        height: row.height
      )
      y += row.height
    }
  }
}
