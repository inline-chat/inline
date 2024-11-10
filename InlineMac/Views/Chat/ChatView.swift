import InlineKit
import SwiftUI

struct ChatView: View {
  let peerId: Peer

  public init(peerId: Peer) {
    self.peerId = peerId
  }

  var body: some View {
    Text("Chat with \(peerId)")
      .navigationTitle("Chat \(peerId)")
  }
}
