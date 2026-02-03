import InlineKit
import SwiftUI

struct InlineRootView: View {
  @AppStorage("enableExperimentalView") private var enableExperimentalView = false
  @Environment(Router.self) private var router

  var body: some View {
    Group {
      if enableExperimentalView {
        ExperimentalRootView()
      } else {
        ContentView2()
      }
    }
    .onChange(of: enableExperimentalView) { _, _ in
      router.dismissSheet()
    }
  }
}
