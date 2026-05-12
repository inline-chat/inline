import AppKit
import SwiftUI

extension View {
  /// Runs `action` when a mouse-down event lands outside this view in the same window.
  /// The event is never consumed, so the clicked view still receives it.
  func onClickOutside(
    enabled: Bool = true,
    matching events: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown],
    perform action: @escaping (NSEvent) -> Void
  ) -> some View {
    background {
      ClickOutsideMonitor(enabled: enabled, events: events, action: action)
    }
  }

  func onClickOutside(
    enabled: Bool = true,
    perform action: @escaping () -> Void
  ) -> some View {
    onClickOutside(enabled: enabled) { _ in
      action()
    }
  }
}

private struct ClickOutsideMonitor: NSViewRepresentable {
  let enabled: Bool
  let events: NSEvent.EventTypeMask
  let action: (NSEvent) -> Void

  func makeNSView(context: Context) -> ClickOutsideMonitorView {
    let view = ClickOutsideMonitorView()
    view.update(enabled: enabled, events: events, action: action)
    return view
  }

  func updateNSView(_ view: ClickOutsideMonitorView, context: Context) {
    view.update(enabled: enabled, events: events, action: action)
  }

  static func dismantleNSView(_ view: ClickOutsideMonitorView, coordinator: ()) {
    view.removeMonitor()
  }
}

private final class ClickOutsideMonitorView: NSView {
  private var enabled = false
  private var events: NSEvent.EventTypeMask = []
  private var action: (NSEvent) -> Void = { _ in }
  private var monitor: Any?

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    updateMonitor()
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }

  func update(
    enabled: Bool,
    events: NSEvent.EventTypeMask,
    action: @escaping (NSEvent) -> Void
  ) {
    let needsRestart = self.events.rawValue != events.rawValue
    self.enabled = enabled
    self.events = events
    self.action = action

    if needsRestart {
      removeMonitor()
    }
    updateMonitor()
  }

  func removeMonitor() {
    guard let monitor else { return }
    NSEvent.removeMonitor(monitor)
    self.monitor = nil
  }

  private func updateMonitor() {
    guard enabled, window != nil else {
      removeMonitor()
      return
    }
    guard monitor == nil else { return }

    monitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
      self?.handle(event)
      return event
    }
  }

  private func handle(_ event: NSEvent) {
    guard let window, event.window === window else { return }

    let point = convert(event.locationInWindow, from: nil)
    guard !bounds.contains(point) else { return }

    action(event)
  }

  deinit {
    removeMonitor()
  }
}
