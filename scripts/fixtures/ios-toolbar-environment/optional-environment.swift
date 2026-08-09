import Observation
import SwiftUI

struct ChatToolbarLeadingView: View {
  // Alternative B: absence is nonfatal, but toolbar actions must degrade or no-op.
  @Environment(Router.self) private var router: Router?

  var body: some View {
    Text(router?.title ?? "Chat")
  }
}

struct ChatView: View {
  var body: some View {
    Text("Chat")
      .toolbar {
        ToolbarItem(placement: .principal) {
          ChatToolbarLeadingView()
        }
      }
  }
}
