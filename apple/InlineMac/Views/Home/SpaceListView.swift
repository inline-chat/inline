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

  init() {
    _home = EnvironmentStateObject { env in
      HomeViewModel(db: env.appDatabase)
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      topBar
      // searchBar
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
        nav.selectedSpaceId = spaceId
      }
      .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
    }
    .listStyle(.sidebar)
    .overlay(alignment: .center) {
      if home.spaces.isEmpty {
        VStack(spacing: 10) {
          Image(systemName: "building.2.crop.circle")
            .font(.system(size: 24, weight: .medium))
            .foregroundStyle(Color.accent)

          Text("Spaces are collections of chats and users.")
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, Theme.sidebarItemOuterSpacing)

          Text("Use for teams, companies, or groups.")
            .font(.system(size: 12, weight: .regular))
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, Theme.sidebarItemOuterSpacing)

          Button {
            nav.open(.createSpace)
          } label: {
            Text("New Space")
          }
        }
        .padding(.horizontal, 8)
      }
    }
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
  SpaceListView()
    .previewsEnvironmentForMac(.populated)
}
