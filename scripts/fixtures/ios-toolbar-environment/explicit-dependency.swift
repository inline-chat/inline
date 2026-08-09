import Observation
import SwiftUI

struct ChatToolbarLeadingView: View {
  // Alternative A: the normal navigation subtree resolves Router once and passes it directly.
  let router: Router

  init(router: Router) {
    self.router = router
  }

  var body: some View {
    Text(router.title)
  }
}

struct ChatView: View {
  @Environment(Router.self) private var router

  var body: some View {
    Text("Chat")
      .toolbar {
        ToolbarItem(placement: .principal) {
          ChatToolbarLeadingView(router: router)
        }
      }
  }
}
