import AppKit
import SwiftUI

class NotionTaskLoadingWindow: NSPanel {
  init() {
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 280, height: 120),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )

    isFloatingPanel = true
    level = .floating
    titlebarAppearsTransparent = true
    titleVisibility = .hidden
    isMovableByWindowBackground = true

    let hostingView = NSHostingView(rootView: NotionTaskLoadingSheet())
    contentView = hostingView

    center()
  }
}
