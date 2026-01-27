import AppKit
import InlineKit
import InlineUI
import SwiftUI

class NudgeToolbar: NSToolbarItem {
  private var peer: Peer
  private var dependencies: AppDependencies

  init(peer: Peer, dependencies: AppDependencies) {
    self.peer = peer
    self.dependencies = dependencies
    super.init(itemIdentifier: .nudge)

    visibilityPriority = .low

    let hostingView = NSHostingView(
      rootView: NudgeButton(peer: peer)
        .buttonStyle(ToolbarButtonStyle())
    )
    view = hostingView
  }
}
