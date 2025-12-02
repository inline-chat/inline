import InlineKit
import InlineUI
import RealtimeV2

import SwiftUI

struct HomeToolbarContent: ToolbarContent {
  @Environment(Router.self) private var router
  @Environment(\.realtime) var realtime
  @EnvironmentObject var realtimeState: RealtimeState

  @State var shouldShow = false

  var body: some ToolbarContent {
    ToolbarItem(placement: .topBarLeading) {
      notificationsButton
    }

    if #available(iOS 26.0, *) {
      ToolbarItem(placement: .principal) {
        header
      }
      .sharedBackgroundVisibility(.hidden)
    } else {
      ToolbarItem(placement: .principal) {
        header
      }
    }

    ToolbarItem(placement: .topBarTrailing) {
      dotsButton
    }
  }

  @ViewBuilder
  private var title: some View {
    Text(shouldShow ? realtimeState.connectionState.title : "Chats")
      .font(.title3)
      .fontWeight(.semibold)
        
      .contentTransition(.numericText())
      .animation(.spring(duration: 0.5), value: realtimeState.connectionState.title)
      .animation(.spring(duration: 0.5), value: shouldShow)
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

  @ViewBuilder
  private var dotsButton: some View {
    Menu {
      Button {
        router.push(.createSpace)
      } label: {
        Label("Create Space", systemImage: "building")
      }

      Button {
        router.push(.createSpaceChat)
      } label: {
        Label("New Group Chat", systemImage: "plus.message")
      }

      Button {
        router.presentSheet(.settings)
      } label: {
        Label("Settings", systemImage: "gearshape")
      }
    } label: {
      Image(systemName: "ellipsis")
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
      router.push(.createSpace)
    } label: {
      Image(systemName: "plus")
        .tint(Color.secondary)
        .contentShape(Rectangle())
    }
  }

  @ViewBuilder
  private var settingsButton: some View {
    Button {
      router.presentSheet(.settings)
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
