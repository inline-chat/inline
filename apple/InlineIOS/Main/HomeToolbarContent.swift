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
      notificationsButton
      dotsButton
    }
  }

  @ViewBuilder
  private var header: some View {
    HStack(spacing: 8) {
      // if apiState != .connected {
      //   Spinner(size: 16)
      //     .padding(.trailing, 4)
      // } else {
      //   Image(systemName: "house.fill")
      //     .font(.caption)
      // }

      VStack(alignment: .leading, spacing: 0) {
        Text(shouldShow ? getStatusText(apiState) : "Chats")
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
  private var dotsButton: some View {
    Menu {
      Button {
        nav.push(.createSpace)
      } label: {
        Label("Create Space", systemImage: "plus")
      }

      Button {
        nav.push(.settings)
      } label: {
        Label("Settings", systemImage: "gearshape")
      }
    } label: {
      Image(systemName: "ellipsis.circle")
        .tint(Color.secondary)
        .contentShape(Rectangle())
    }
  }

  @ViewBuilder
  private var notificationsButton: some View {
    NotificationSettingsButton()
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

struct Spinner: View {
  @State private var isRotating = false
  @State private var trimEnd = 0.75

  var color: Color = ColorManager.shared.swiftUIColor
  var secondaryColor: Color? = nil
  var lineWidth: CGFloat = 3
  var size: CGFloat = 50

  var gradient: LinearGradient {
    if let secondaryColor {
      LinearGradient(
        gradient: Gradient(colors: [color, secondaryColor]),
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
    } else {
      LinearGradient(
        gradient: Gradient(colors: [color, color.opacity(0.7)]),
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
    }
  }

  var body: some View {
    ZStack {
      Circle()
        .stroke(
          gradient.opacity(0.3),
          lineWidth: lineWidth
        )

      Circle()
        .trim(from: 0, to: trimEnd)
        .stroke(
          gradient,
          style: StrokeStyle(
            lineWidth: lineWidth,
            lineCap: .round
          )
        )
        .rotationEffect(Angle(degrees: isRotating ? 360 : 0))
    }
    .frame(width: size, height: size)
    .onAppear {
      withAnimation(
        Animation.linear(duration: 0.8)
          .repeatForever(autoreverses: false)
      ) {
        isRotating = true
      }

      withAnimation(
        Animation.easeInOut(duration: 0.9)
          .repeatForever(autoreverses: true)
      ) {
        trimEnd = 0.6
      }
    }
  }
}
