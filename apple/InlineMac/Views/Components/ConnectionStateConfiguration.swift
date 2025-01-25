import InlineKit
import SwiftUI

struct ConnectionStateConfiguration {
  let state: ConnectionState
  let shouldShow: Bool
  let humanReadable: String
}

struct ConnectionStateProvider<Content: View>: View {
  @EnvironmentObject var ws: WebSocketManager
  let content: (ConnectionStateConfiguration) -> Content

  @State var shouldShow = false

  init(@ViewBuilder content: @escaping (ConnectionStateConfiguration) -> Content) {
    self.content = content
  }

  var body: some View {
    let configuration = ConnectionStateConfiguration(
      state: ws.connectionState,
      shouldShow: shouldShow,
      humanReadable: getStatusText(ws.connectionState)
    )

    content(configuration)
      .task {
        if ws.connectionState != .normal {
          shouldShow = true
        }
      }
      .onChange(of: ws.connectionState) { newValue in
        if newValue == .normal {
          Task { @MainActor in
            try await Task.sleep(for: .seconds(1))
            if ws.connectionState == .normal {
              // second check
              shouldShow = false
            }
          }
        } else {
          shouldShow = true
        }
      }
  }

  private func getStatusText(_ state: ConnectionState) -> String {
    switch state {
      case .normal:
        "connected"
      case .connecting:
        "connecting..."
      case .updating:
        "updating..."
    }
  }
}
