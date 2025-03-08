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
  @State var apiState: RealtimeAPIState = Realtime.shared.apiState

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
      .onAppear {
        apiState = realtime.apiState

        if apiState != .connected {
          shouldShow = true
        }
      }
      .onReceive(realtime.apiStatePublisher, perform: { nextApiState in
        if nextApiState == apiState {
          return
        }
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
