import InlineKit
import InlineUI
import SwiftUI

struct SpacesView: View {
  @EnvironmentObject private var nav: Navigation
  @EnvironmentObject private var homeViewModel: HomeViewModel

  var body: some View {
    List(homeViewModel.spaces.sorted { s1, s2 in
      s1.space.date > s2.space.date
    }) { space in
      Button {
        nav.push(.space(id: space.space.id))
      } label: {
        HStack {
          SpaceAvatar(space: space.space, size: 34)
          Text(space.space.nameWithoutEmoji)
        }
      }
      .padding(.vertical, 1)
    }
    .listStyle(.plain)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .principal) {
        Text("Spaces")
          .font(.title3)
          .fontWeight(.semibold)
      }
    }
  }
}

#Preview {
  SpacesView()
    .environmentObject(Navigation.shared)
}
