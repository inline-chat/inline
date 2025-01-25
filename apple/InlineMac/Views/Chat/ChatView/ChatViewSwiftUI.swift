import AppKit
import InlineKit
import SwiftUI

struct ChatViewSwiftUI: NSViewRepresentable {
  @EnvironmentObject private var viewModel: FullChatViewModel

  var peerId: Peer

  func makeNSView(context: Context) -> ChatViewAppKit {
    let chatView = ChatViewAppKit(peerId: peerId)
    chatView.update(viewModel: viewModel)
    return chatView
  }

  func updateNSView(_ chatView: ChatViewAppKit, context: Context) {
    chatView.peerId = peerId
    chatView.update(viewModel: viewModel)
  }
}
