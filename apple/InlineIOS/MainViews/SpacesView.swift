import InlineKit
import InlineUI
import RealtimeV2

import SwiftUI

struct SpacesView: View {
  @Environment(Router.self) private var router
  @EnvironmentObject var realtimeState: RealtimeState

  @EnvironmentObject var homeViewModel: HomeViewModel

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
                  .foregroundColor(.primary)
                Text("\(space.members.count) \(space.members.count == 1 ? "member" : "members")")
                  .font(.subheadline)
                  .fontWeight(.regular)
                  .foregroundColor(.secondary)
              }
            }
          }
          .listRowInsets(EdgeInsets(top: 9, leading: 16, bottom: 9, trailing: 16))
        }
        .listStyle(.plain)
      }
    }
    .navigationBarTitleDisplayMode(.inline)
    .navigationTitle("Spaces")
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
        dotsButton
      }
    }
  }

  @ViewBuilder
  private var dotsButton: some View {
    Menu {
      Button {
        router.push(.createSpace)
      } label: {
        Label("Create Space", systemImage: "building")
      }

      Button {
        router.presentSheet(.settings)
      } label: {
        Label("Settings", systemImage: "gearshape")
      }
    } label: {
      Image(systemName: "line.3.horizontal.decrease")
        .foregroundStyle(.primary)
        .contentShape(Rectangle())
    }
  }

  @ViewBuilder
  private var header: some View {
    let displayedState = realtimeState.displayedConnectionState
    let title = displayedState?.title ?? "Spaces"

    HStack(spacing: 8) {
      if displayedState != nil {
        Spinner(size: 16)
          .padding(.trailing, 4)
      }

      VStack(alignment: .leading, spacing: 0) {
        Text(title)
          .font(.title3)
          .fontWeight(.semibold)
          .contentTransition(.numericText())
          .animation(.spring(duration: 0.5), value: title)
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
          .opacity(isVisible ? 1 : 0)
          .offset(y: isVisible ? 0 : 20)
          .animation(.easeOut(duration: 0.25).delay(0.15), value: isVisible)

        Text("Your spaces will appear here")
          .font(.subheadline)
          .multilineTextAlignment(.center)
          .opacity(isVisible ? 1 : 0)
          .offset(y: isVisible ? 0 : 20)
          .animation(.easeOut(duration: 0.25).delay(0.2), value: isVisible)
      }

      Spacer()
    }
    .padding(.horizontal, 60)
    .background(Color(.systemBackground))
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
