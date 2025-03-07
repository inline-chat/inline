import InlineKit
import InlineUI
import RealtimeAPI
import SwiftUI

struct HomeToolbarContent: ToolbarContent {
  @EnvironmentObject private var nav: Navigation
  @Environment(\.realtime) var realtime

  @State var shouldShow = false
  @State var apiState: RealtimeAPIState = .connecting

  var body: some ToolbarContent {
    ToolbarItem(placement: .topBarLeading) {
      header
    }

    ToolbarItemGroup(placement: .topBarTrailing) {
      Button(action: {
        nav.push(.alphaSheet)
      }, label: {
        Text("ALPHA")
          .monospaced()
          .foregroundStyle(Color(.systemBackground))
          .font(.caption)
          .fontWeight(.bold)
          .padding(.horizontal, 6)
          .padding(.vertical, 3)
          .background(
            Capsule()
              .fill(.primary)
          )
      })
      .buttonStyle(.plain)
      settingsButton
      createSpaceButton
    }
  }

  @ViewBuilder
  private var header: some View {
    HStack(spacing: 8) {
      if apiState != .connected {
        AnimatedDots(dotSize: 6)
      } else {
        Image(systemName: "house.fill")
          .font(.caption)
      }

      VStack(alignment: .leading, spacing: 0) {
        Text(shouldShow ? getStatusText(apiState) : "Home")
          .font(.title3)
          .fontWeight(.semibold)
          .contentTransition(.numericText())
          .animation(.spring(duration: 0.5), value: getStatusText(apiState))
          .animation(.spring(duration: 0.5), value: shouldShow)
      }
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

  @ViewBuilder
  private var createSpaceButton: some View {
    Button {
      nav.push(.createSpace)
    } label: {
      Image(systemName: "plus")
        .tint(Color.secondary)
        .contentShape(Rectangle())
    }
  }

  @ViewBuilder
  private var settingsButton: some View {
    Button {
      nav.push(.settings)
    } label: {
      Image(systemName: "gearshape")
        .tint(Color.secondary)
        .contentShape(Rectangle())
    }
  }
}
