import AppKit
import SwiftUI
import Quartz

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
        guard let self else { return event }

        // Check if window is key window
        guard event.window?.isKeyWindow == true else { return event }

        // Check if Quick Look is active
        if isQuickLookActive() {
          return event
        }

        // Check if the first responder is a text input field
//        if let firstResponder = event.window?.firstResponder as? NSTextInputClient {
//          return event
//        }

        // Check if the event has already been handled by the responder chain
//        let handled = event.window?.firstResponder?.tryToPerform(
//          #selector(NSResponder.keyDown(with:)),
//          with: event
//        ) ?? false

//        if handled {
//          return event
//        }

        return handler?(event)
      }
    }

    private func isQuickLookActive() -> Bool {
      // Check all windows for Quick Look panel
      for window in NSApplication.shared.windows {
        if window.isKind(of: QLPreviewPanel.self), window.isVisible {
          return true
        }
      }
      return false
    }

    deinit {
      if let monitor {
        NSEvent.removeMonitor(monitor)
      }
    }
  }
}
