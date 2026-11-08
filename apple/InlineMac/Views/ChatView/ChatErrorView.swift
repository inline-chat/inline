import InlineKit
import SwiftUI

/// Shown in place of the message list when the chat can't be opened. The
/// server answers the same way for "not yours" and "gone", so the copy leads
/// with the common case, a private thread, without reading like a failure.
struct ChatLoadErrorView: View {
  let peer: Peer
  let retryAction: () -> Void

  var body: some View {
    ContentUnavailableView {
      Label(ChatUnavailableCopy.title(for: peer), systemImage: peer.isThread ? "lock" : "bubble.left")
    } description: {
      Text(description)
    } actions: {
      Button("Check Again", action: retryAction)
        .buttonStyle(.link)
        .controlSize(.small)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var description: String {
    peer.isThread
      ? "You don't have access to this thread.\nAsk someone in it to add you."
      : "This conversation isn't available to you."
  }
}

#Preview("Thread") {
  ChatLoadErrorView(peer: .thread(id: 1), retryAction: {})
    .frame(width: 520, height: 420)
}

#Preview("DM") {
  ChatLoadErrorView(peer: .user(id: 1), retryAction: {})
    .frame(width: 520, height: 420)
}
