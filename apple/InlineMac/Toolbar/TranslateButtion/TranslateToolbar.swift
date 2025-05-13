import AppKit
import Combine
import InlineKit
import InlineUI
import RealtimeAPI
import SwiftUI

class TranslateToolbar: NSToolbarItem {
  private var peer: Peer
  private var dependencies: AppDependencies

  init(peer: Peer, dependencies: AppDependencies) {
    self.peer = peer
    self.dependencies = dependencies
    super.init(itemIdentifier: .translate)

    visibilityPriority = .low

    // Create a hosting view for the SwiftUI button
    let hostingView = NSHostingView(rootView: TranslationButton(peer: peer))
    view = hostingView
  }
}
