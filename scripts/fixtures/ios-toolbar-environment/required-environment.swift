import Observation
import SwiftUI

struct ChatToolbarLeadingView: View {
  // Build-1178 shape: a detached UIKit toolbar host must resolve this object by type.
  @Environment(Router.self) private var router

  var body: some View {
    Text(router.title)
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
