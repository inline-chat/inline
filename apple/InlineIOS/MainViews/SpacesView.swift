import InlineKit
import InlineUI
import RealtimeV2

import SwiftUI

struct SpacesView: View {
  @Environment(Router.self) private var router
  @Environment(\.realtime) var realtime
  @EnvironmentObject var realtimeState: RealtimeState

  @EnvironmentObject var homeViewModel: HomeViewModel

  @State var shouldShow = false

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
        header
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

  @ViewBuilder
  private var header: some View {
    HStack(spacing: 8) {
      if realtimeState.connectionState != .connected {
        Spinner(size: 16)
          .padding(.trailing, 4)
      }

      VStack(alignment: .leading, spacing: 0) {
        Text(shouldShow ? realtimeState.connectionState.title : "Chats")
          .font(.title3)
          .fontWeight(.semibold)
          .themedPrimaryText()
          .contentTransition(.numericText())
          .animation(.spring(duration: 0.5), value: realtimeState.connectionState.title)
          .animation(.spring(duration: 0.5), value: shouldShow)
      }
    }

    .onAppear {
      if realtimeState.connectionState != .connected {
        shouldShow = true
      }
    }
    .onReceive(realtimeState.connectionStatePublisher, perform: { nextConnectionState in
      if nextConnectionState == .connected {
        Task { @MainActor in
          try await Task.sleep(for: .seconds(1))
          if nextConnectionState == .connected {
            // second check
            shouldShow = false
          }
        }
      } else {
        shouldShow = true
      }
    })
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
