import AppKit
import SwiftUI

struct KeyPressHandler: NSViewRepresentable {
  let handler: (NSEvent) -> NSEvent?

  func makeNSView(context: Context) -> NSView {
    let view = KeyView()
    view.handler = handler
    view.setupMonitor()
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    (nsView as? KeyView)?.handler = handler
  }

  private class KeyView: NSView {
    var handler: ((NSEvent) -> NSEvent?)?
    var monitor: Any?

    func setupMonitor() {
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        if event.window?.isKeyWindow == true {
          return self?.handler?(event)
        } else {
          return nil
        }
      }
    }

    deinit {
      if let monitor = monitor {
        NSEvent.removeMonitor(monitor)
      }
    }
  }
}
