import InlineKit
import InlineUI
import RealtimeAPI
import SwiftUI

struct SpacesView: View {
  @EnvironmentObject private var nav: Navigation
  @EnvironmentObject private var homeViewModel: HomeViewModel
  @EnvironmentObject private var tabsManager: TabsManager
  @Environment(\.realtime) var realtime

  @State var shouldShow = false
  @State var apiState: RealtimeAPIState = .connecting

  var body: some View {
    if let activeSpaceId = tabsManager.getActiveSpaceId() {
      SpaceView(spaceId: activeSpaceId)
    } else {
      let sortedSpaces = homeViewModel.spaces.sorted { s1, s2 in
        s1.space.date > s2.space.date
      }

      Group {
        if sortedSpaces.isEmpty {
          EmptySpacesView()
        } else {
          List(sortedSpaces) { space in
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
        }
      }
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          VStack(alignment: .leading, spacing: 0) {
            Text(shouldShow ? getStatusText(apiState) : "Spaces")
              .font(.title3)
              .fontWeight(.semibold)
              .contentTransition(.numericText())
              .animation(.spring(duration: 0.5), value: getStatusText(apiState))
              .animation(.spring(duration: 0.5), value: shouldShow)
          }
          .onAppear {
            apiState = realtime.apiState

            if apiState != .connected {
              shouldShow = true
            }
          }
          .onReceive(realtime.apiStatePublisher, perform: { nextApiState in
            apiState = nextApiState
            if nextApiState == .connected {
              Task { @MainActor in
                try await Task.sleep(for: .seconds(1))
                if nextApiState == .connected {
                  // second check
                  shouldShow = false
                }
              }
            } else {
              shouldShow = true
            }
          })
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

struct EmptySpacesView: View {
  var body: some View {
    VStack {
      Spacer()
      Image(systemName: "building.2.fill")
        .foregroundColor(.secondary)
        .font(.title)
        .padding(.bottom, 6)
      Text("No spaces")
        .font(.title3)
      Text("Create a space to get started")
        .font(.subheadline)
        .foregroundColor(.secondary)
      Spacer()
    }
  }
}

#Preview {
  SpacesView()
    .environmentObject(Navigation.shared)
}
