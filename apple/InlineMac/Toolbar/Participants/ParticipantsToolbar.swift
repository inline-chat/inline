import AppKit
import Combine
import InlineKit
import InlineUI
import SwiftUI

class ParticipantsToolbar: NSToolbarItem {
  private var peer: Peer
  private var dependencies: AppDependencies

  init(peer: Peer, dependencies: AppDependencies) {
    self.peer = peer
    self.dependencies = dependencies
    super.init(itemIdentifier: .participants)

    visibilityPriority = .low

    // Create a hosting view for the SwiftUI button
    let hostingView = NSHostingView(rootView: ParticipantsToolbarButton(peer: peer, dependencies: dependencies))
    view = hostingView
  }
}