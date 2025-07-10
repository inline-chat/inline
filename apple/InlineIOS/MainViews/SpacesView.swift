import InlineKit
import InlineUI
import RealtimeAPI
import SwiftUI

struct SpacesView: View {
  @Environment(Router.self) private var router
  @Environment(\.realtime) var realtime

  @EnvironmentObject var homeViewModel: HomeViewModel

  @State var shouldShow = false
  @State var apiState: RealtimeAPIState = .connecting

  var sortedSpaces: [HomeSpaceItem] {
    homeViewModel.spaces.sorted { s1, s2 in
      s1.space.date > s2.space.date
    }
  }

  var body: some View {
    Group {
      if sortedSpaces.isEmpty {
        EmptySpacesView()
      } else {
        List(sortedSpaces) { space in
          Button {
            router.push(.space(id: space.space.id))
          } label: {
            HStack {
              SpaceAvatar(space: space.space, size: 45)
              VStack(alignment: .leading, spacing: 0) {
                Text(space.space.nameWithoutEmoji)
                  .font(.body)
                  .themedPrimaryText()
                Text("\(space.members.count) \(space.members.count == 1 ? "member" : "members")")
                  .font(.subheadline)
                  .fontWeight(.regular)
                  .themedSecondaryText()
              }
            }
          }
          .listRowInsets(EdgeInsets(top: 9, leading: 16, bottom: 9, trailing: 16))
          .themedListRow()
        }
        .themedListStyle()
      }
    }
    .background(ThemeManager.shared.backgroundColorSwiftUI)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      toolbarContent
    }
  }

  @ToolbarContentBuilder
  var toolbarContent: some ToolbarContent {
    Group {
      ToolbarItem(placement: .principal) {
        Text(shouldShow ? getStatusText(apiState) : "Spaces")
          .font(.title3)
          .fontWeight(.semibold)
          .themedPrimaryText()
          .contentTransition(.numericText())
          .animation(.spring(duration: 0.5), value: getStatusText(apiState))
          .animation(.spring(duration: 0.5), value: shouldShow)
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
          router.presentSheet(.createSpace)
        } label: {
          Image(systemName: "plus")
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

      VStack(spacing: 8) {
        Text("No Spaces Yet")
          .font(.title2)
          .fontWeight(.semibold)
          .themedPrimaryText()
          .opacity(isVisible ? 1 : 0)
          .offset(y: isVisible ? 0 : 20)
          .animation(.easeOut(duration: 0.25).delay(0.15), value: isVisible)

        Text("Your spaces will appear here")
          .font(.subheadline)
          .themedSecondaryText()
          .multilineTextAlignment(.center)
          .opacity(isVisible ? 1 : 0)
          .offset(y: isVisible ? 0 : 20)
          .animation(.easeOut(duration: 0.25).delay(0.2), value: isVisible)
      }

      Spacer()
    }
    .padding(.horizontal, 60)
    .background(ThemeManager.shared.backgroundColorSwiftUI)
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
