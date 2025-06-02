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
    if let activeSpaceId = tabsManager.getActiveSpaceId(), activeSpaceId != 0, homeViewModel.spaces.count > 0 {
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
  @EnvironmentObject private var nav: Navigation
  @State private var isVisible = false

  var body: some View {
    VStack(spacing: 20) {
      Spacer()

      // Icon with subtle animation
      Image(systemName: "building.2.fill")
        .font(.system(size: 56, weight: .light))
        .foregroundColor(.secondary)
        .opacity(isVisible ? 1 : 0)
        .scaleEffect(isVisible ? 1 : 0.8)
        .animation(.spring(response: 0.3, dampingFraction: 0.8).delay(0.1), value: isVisible)

      VStack(spacing: 12) {
        Text("No Spaces Yet")
          .font(.title2)
          .fontWeight(.semibold)
          .opacity(isVisible ? 1 : 0)
          .offset(y: isVisible ? 0 : 20)
          .animation(.easeOut(duration: 0.25).delay(0.15), value: isVisible)

        Text("Create a space to get started")
          .font(.subheadline)
          .foregroundColor(.secondary)
          .multilineTextAlignment(.center)
          .opacity(isVisible ? 1 : 0)
          .offset(y: isVisible ? 0 : 20)
          .animation(.easeOut(duration: 0.25).delay(0.2), value: isVisible)
      }

      // Action button
      HStack(spacing: 8) {
        Button(action: {
          nav.push(.createSpace)
        }) {
          Text("Create Space")
            .font(.callout)
            .fontWeight(.medium)
            .foregroundColor(.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(ScaleButtonStyle())
      }
      .opacity(isVisible ? 1 : 0)
      .offset(y: isVisible ? 0 : 30)
      .animation(.easeOut(duration: 0.3).delay(0.25), value: isVisible)

      Spacer()
    }
    .onAppear {
      withAnimation(.easeOut(duration: 0.3).delay(0.05)) {
        isVisible = true
      }
    }
  }
}

#Preview {
  SpacesView()
    .environmentObject(Navigation.shared)
}
