import SwiftUI

struct SidebarSearchBar: View {
  @State private var searchText = ""

  var body: some View {
    GrayTextField("Search", text: $searchText, size: .small)
  }
}
