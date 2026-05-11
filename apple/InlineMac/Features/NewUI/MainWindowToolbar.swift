import SwiftUI

struct MainWindowToolbar: ToolbarContent {
  let nav: Nav3

  var body: some ToolbarContent {
    ToolbarItem(placement: .navigation) {
      HStack(spacing: 0) {
        Button(action: nav.goBack) {
          Image(systemName: "chevron.left")
        }
        .buttonStyle(.automatic)
        .disabled(nav.canGoBack == false)

        Button(action: nav.goForward) {
          Image(systemName: "chevron.right")
        }
        .buttonStyle(.automatic)
        .disabled(nav.canGoForward == false)
      }
      .toolbarVisibilityPriority(.low, label: "Back/Forward")
    }
  }
}
