import AppKit
import SwiftUI

extension View {
  func onHostingWindowChange(_ action: @escaping (NSWindow?) -> Void) -> some View {
    background {
      HostingWindowAccessor(onWindowChange: action)
        .frame(width: 0, height: 0)
    }
  }
}

private struct HostingWindowAccessor: NSViewRepresentable {
  let onWindowChange: (NSWindow?) -> Void

  func makeNSView(context: Context) -> HostingWindowAccessorView {
    let view = HostingWindowAccessorView()
    view.onWindowChange = onWindowChange
    return view
  }

  func updateNSView(_ view: HostingWindowAccessorView, context: Context) {
    view.onWindowChange = onWindowChange
  }

  static func dismantleNSView(_ view: HostingWindowAccessorView, coordinator: ()) {
    view.notify(window: nil)
  }
}

private final class HostingWindowAccessorView: NSView {
  var onWindowChange: (NSWindow?) -> Void = { _ in }
  private weak var currentWindow: NSWindow?

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard currentWindow !== window else { return }
    currentWindow = window
    notify(window: window)
  }

  func notify(window: NSWindow?) {
    DispatchQueue.main.async { [weak self, weak window] in
      self?.onWindowChange(window)
    }
  }
}
