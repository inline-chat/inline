import SwiftUI

struct SidebarSearchBar: View {
  var text: Binding<String>

  var body: some View {
    GrayTextField("Search", text: text, size: .small)
      .submitLabel(.search)
      .autocorrectionDisabled()
  }
}
