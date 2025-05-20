import InlineKit
import InlineUI
import Logger
import SwiftUI

struct SpaceListView: View {
  @Environment(\.appDatabase) var db
  @EnvironmentObject var nav: Nav
  @EnvironmentObject var data: DataManager
  @EnvironmentObject var overlay: OverlayManager
  @EnvironmentStateObject var home: HomeViewModel

  @State private var searchQuery: String = ""
  @Binding var selectedSpaceId: Int64?

  init(selectedSpaceId: Binding<Int64?>) {
    _selectedSpaceId = selectedSpaceId
    _home = EnvironmentStateObject { env in
      HomeViewModel(db: env.appDatabase)
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      topBar
      searchBar
      spacesList
    }
    .task {
      do {
        try await data.getSpaces()
      } catch {
        Log.shared.error("Failed to get spaces", error: error)
      }
    }
  }

  @ViewBuilder
  private var topBar: some View {
    HStack(spacing: 0) {
      // Home icon
      Circle()
        .fill(
          LinearGradient(
            colors: [
              .accent.adjustLuminosity(by: 0.05),
              .accent,
            ],
            startPoint: .top,
            endPoint: .bottom
          )
        )
        .overlay {
          Image(systemName: "building.2.fill")
            .foregroundColor(.white)
            .font(.system(size: 13, weight: .regular))
        }
        .frame(width: Theme.sidebarTitleIconSize, height: Theme.sidebarTitleIconSize)
        .fixedSize()
        .padding(.trailing, Theme.sidebarIconSpacing)

      Text("Spaces")

      Spacer()

      plusButton
    }
    .padding(.top, -6)
    .padding(.bottom, 8)
    .padding(.horizontal, Theme.sidebarItemOuterSpacing)
    .padding(.leading, Theme.sidebarItemInnerSpacing)
    .padding(.trailing, 4)
  }

  private var searchBar: some View {
    SidebarSearchBar(text: $searchQuery)
      .padding(.horizontal, Theme.sidebarItemOuterSpacing)
      .padding(.bottom, 8)
  }

  private var spacesList: some View {
    List(home.spaces, id: \.id) { spaceItem in
      SpaceItem(space: spaceItem.space) { spaceId in
        selectedSpaceId = spaceId
      }
    }
    .listStyle(.sidebar)
  }

  @ViewBuilder
  var plusButton: some View {
    Menu {
      Button {
        nav.open(.createSpace)
      } label: {
        Label("New Space (Team)", systemImage: "plus")
          .font(.system(size: 14, weight: .medium))
          .foregroundStyle(Color.accent)
      }
    } label: {
      Image(systemName: "plus")
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(.tertiary)
        .contentShape(.circle)
        .frame(width: Theme.sidebarTitleIconSize, height: Theme.sidebarTitleIconSize, alignment: .center)
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
  }
}

#Preview {
  SpaceListView(selectedSpaceId: .constant(nil))
    .previewsEnvironmentForMac(.populated)
}
