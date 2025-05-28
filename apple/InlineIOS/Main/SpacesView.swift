import InlineKit
import InlineUI
import SwiftUI

struct SpacesView: View {
  @EnvironmentObject private var nav: Navigation
  @EnvironmentObject private var homeViewModel: HomeViewModel

  @EnvironmentObject private var tabsManager: TabsManager

  var body: some View {
    if let activeSpaceId = tabsManager.getActiveSpaceId() {
      SpaceView(spaceId: activeSpaceId)
    } else {
      List(homeViewModel.spaces.sorted { s1, s2 in
        s1.space.date > s2.space.date
      }) { space in
        Button {
          tabsManager.setActiveSpaceId(space.space.id)
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
        ToolbarItem(placement: .topBarLeading) {
          Text("Spaces")
            .font(.title3)
            .fontWeight(.semibold)
        }

        ToolbarItem(placement: .topBarTrailing) {
          Button {
            nav.push(.createSpace)
          } label: {
            Image(systemName: "plus")
          }
          .tint(.secondary)
        }
      }
    }
  }
}

#Preview {
  SpacesView()
    .environmentObject(Navigation.shared)
}
