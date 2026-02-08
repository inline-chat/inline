import AppKit
import SwiftUI

/// Presents the space picker as an in-window overlay (not a separate `NSPanel`).
/// This keeps Liquid Glass sampling/compositing consistent and avoids child-window edge cases.
final class SpacePickerOverlayPresenter {
  private enum Metrics {
    static let gapFromAnchor: CGFloat = 6
  }

  private let preferredWidth: CGFloat
  private var xOffset: CGFloat = 0

  private let containerView = NSView()
  private let hostingView: NSHostingView<SpacePickerOverlayView>

  private weak var hostView: NSView?
  private weak var anchorView: NSView?

  init(rootView: SpacePickerOverlayView, preferredWidth: CGFloat) {
    self.preferredWidth = preferredWidth

    hostingView = NSHostingView(rootView: rootView)
    hostingView.wantsLayer = true
    hostingView.layer?.backgroundColor = NSColor.clear.cgColor
    hostingView.layer?.masksToBounds = false

    containerView.wantsLayer = true
    containerView.layer?.backgroundColor = NSColor.clear.cgColor
    containerView.layer?.masksToBounds = false
    containerView.addSubview(hostingView)
  }

  var isVisible: Bool {
    containerView.superview != nil
  }

  func update(rootView: SpacePickerOverlayView) {
    hostingView.rootView = rootView
    updateSizing()
    repositionIfPossible()
  }

  func show(in hostView: NSView, anchorView: NSView, xOffset: CGFloat = 0) {
    self.hostView = hostView
    self.anchorView = anchorView
    self.xOffset = xOffset

    if containerView.superview !== hostView {
      hostView.addSubview(containerView, positioned: .above, relativeTo: nil)
    }

    updateSizing()
    repositionIfPossible()
  }

  func hide() {
    containerView.removeFromSuperview()
    hostView = nil
    anchorView = nil
  }

  /// Repositions the overlay relative to the current anchor view, clamped to the host view bounds.
  func repositionIfPossible() {
    guard let hostView, let anchorView else { return }
    let insetX = SpacePickerOverlayStyle.shadowInsetX
    let insetY = SpacePickerOverlayStyle.shadowInsetY

    // Do the math in window coordinates (always unflipped), then convert to host coordinates.
    // This avoids subtle positioning bugs when `hostView` is flipped.
    let anchorRectInWindow = anchorView.convert(anchorView.bounds, to: nil)
    let hostRectInWindow = hostView.convert(hostView.bounds, to: nil)

    let containerSize = containerView.frame.size
    var originInWindow = NSPoint(
      x: anchorRectInWindow.minX - insetX + xOffset,
      y: anchorRectInWindow.minY - containerSize.height - Metrics.gapFromAnchor + insetY
    )

    // Clamp to host view rect so we don't go off-screen when window is small.
    if containerSize.width >= hostRectInWindow.width {
      originInWindow.x = hostRectInWindow.minX
    } else {
      originInWindow.x = min(
        max(originInWindow.x, hostRectInWindow.minX),
        hostRectInWindow.maxX - containerSize.width
      )
    }

    if containerSize.height >= hostRectInWindow.height {
      originInWindow.y = hostRectInWindow.minY
    } else {
      originInWindow.y = max(originInWindow.y, hostRectInWindow.minY)
      if originInWindow.y + containerSize.height > hostRectInWindow.maxY {
        originInWindow.y = hostRectInWindow.maxY - containerSize.height
      }
    }

    containerView.setFrameOrigin(hostView.convert(originInWindow, from: nil))
  }

  func containsPointInHostView(_ point: NSPoint) -> Bool {
    guard containerView.superview != nil else { return false }
    guard let hostView else { return false }
    let localInContainer = containerView.convert(point, from: hostView)
    // Treat the shadow inset as "outside" so clicking the shadow dismisses the picker,
    // matching typical menu/popover behavior.
    return hostingView.frame.contains(localInContainer)
  }

  private func updateSizing() {
    let insetX = SpacePickerOverlayStyle.shadowInsetX
    let insetY = SpacePickerOverlayStyle.shadowInsetY

    hostingView.layoutSubtreeIfNeeded()
    let size = hostingView.fittingSize
    let contentSize = NSSize(width: preferredWidth, height: size.height)

    // Give the SwiftUI shadow room so it isn't clipped near the edges.
    containerView.setFrameSize(
      NSSize(
        width: contentSize.width + (insetX * 2),
        height: contentSize.height + (insetY * 2)
      )
    )

    hostingView.frame = NSRect(
      x: insetX,
      y: insetY,
      width: contentSize.width,
      height: contentSize.height
    )
  }
}
