import InlineKit
import RealtimeAPI
import SwiftUI

struct ConnectionStateConfiguration {
  let state: RealtimeAPIState
  let shouldShow: Bool
  let humanReadable: String
}

struct ConnectionStateProvider<Content: View>: View {
  @Environment(\.realtime) var realtime
  let content: (ConnectionStateConfiguration) -> Content

  @State var shouldShow = false
  @State var apiState: RealtimeAPIState = .connecting

  init(@ViewBuilder content: @escaping (ConnectionStateConfiguration) -> Content) {
    self.content = content
  }

  var body: some View {
    let configuration = ConnectionStateConfiguration(
      state: apiState,
      shouldShow: shouldShow,
      humanReadable: getStatusText(apiState)
    )

    content(configuration)
      .task {
        if apiState != .connected {
          shouldShow = true
        }
      }
      .onAppear {
        apiState = realtime.apiState
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

  private func getStatusText(_ state: RealtimeAPIState) -> String {
    switch state {
      case .connected:
        "connected"
      case .connecting:
        "connecting..."
      case .updating:
        "updating..."
      case .waitingForNetwork:
        "waiting for network..."
    }
  }
}
