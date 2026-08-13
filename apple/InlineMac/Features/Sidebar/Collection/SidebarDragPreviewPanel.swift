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
    horizontalBleed: CGFloat,
    ownerWindow: NSWindow,
    frame: CGRect
  ) {
    let panelFrame = frame.insetBy(dx: -horizontalBleed, dy: 0)
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
    panel.appearance = ownerWindow.appearance
    panel.contentView = hostingView
    self.hostingView = hostingView
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
    guard let hostingView else { return }
    let contentFrame = CGRect(x: 0, y: 0, width: width, height: row.height)
    let panelSize = CGSize(width: width + horizontalBleed * 2, height: row.height)
    let oldFrame = panel.frame
    let nextFrame = CGRect(
      x: oldFrame.minX,
      y: oldFrame.maxY - panelSize.height,
      width: panelSize.width,
      height: panelSize.height
    )
    hostingView.rootView = preview(
      rows: [row],
      content: content,
      horizontalBleed: horizontalBleed,
      frame: contentFrame
    )
    hostingView.frame = CGRect(origin: .zero, size: panelSize)
    panel.setFrame(nextFrame, display: true)
  }

  func move(to origin: CGPoint, horizontalBleed: CGFloat) {
    panel.setFrameOrigin(CGPoint(x: origin.x - horizontalBleed, y: origin.y))
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
      context.duration = 0.14
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
