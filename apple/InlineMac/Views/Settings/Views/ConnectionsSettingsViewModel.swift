import Foundation
import InlineProtocol
import RealtimeV2

@MainActor
final class ConnectionsSettingsViewModel: ObservableObject {
  @Published private(set) var connections: [InlineProtocol.OAuthConnectionInfo] = []
  @Published private(set) var authPrompt: InlineProtocol.OpenAICodexDeviceAuthPrompt?
  @Published private(set) var isLoading = false
  @Published private(set) var isStarting = false
  @Published private(set) var disconnectingConnectionID: Int64?
  @Published private(set) var statusText: String?
  @Published var errorState: ConnectionsErrorState?

  private var pollTask: Task<Void, Never>?

  var chatGPTConnection: InlineProtocol.OAuthConnectionInfo? {
    connections.first { $0.provider == "openai_codex" }
  }

  deinit {
    pollTask?.cancel()
  }

  func load(realtimeV2: RealtimeV2) async {
    guard !isLoading else { return }
    isLoading = true
    defer { isLoading = false }

    do {
      let result = try await realtimeV2.connectionsList()
      connections = result.connections
      statusText = nil
    } catch {
      showError(title: "Could Not Load Connections", error: error)
    }
  }

  func startChatGPTConnection(realtimeV2: RealtimeV2) async {
    guard !isStarting else { return }
    pollTask?.cancel()
    isStarting = true
    statusText = nil
    defer { isStarting = false }

    do {
      let result = try await realtimeV2.openAICodexStartDeviceAuth()
      guard result.hasAuth else {
        errorState = ConnectionsErrorState(
          title: "Could Not Start Sign In",
          message: "The server did not return a sign-in code."
        )
        return
      }

      authPrompt = result.auth
      statusText = "Waiting for authorization..."
      pollTask = Task { [weak self] in
        await self?.poll(prompt: result.auth, realtimeV2: realtimeV2)
      }
    } catch {
      showError(title: "Could Not Start Sign In", error: error)
    }
  }

  func disconnect(_ connection: InlineProtocol.OAuthConnectionInfo, realtimeV2: RealtimeV2) async {
    guard disconnectingConnectionID == nil else { return }
    disconnectingConnectionID = connection.id
    defer { disconnectingConnectionID = nil }

    do {
      let result = try await realtimeV2.connectionsDisconnect(connection.id)
      if result.disconnected {
        connections.removeAll { $0.id == connection.id }
        authPrompt = nil
        statusText = nil
      } else {
        errorState = ConnectionsErrorState(title: "Could Not Disconnect", message: "The connection was not found.")
      }
    } catch {
      showError(title: "Could Not Disconnect", error: error)
    }
  }

  func cancelSignIn() {
    pollTask?.cancel()
    pollTask = nil
    authPrompt = nil
    statusText = nil
  }

  private func poll(
    prompt: InlineProtocol.OpenAICodexDeviceAuthPrompt,
    realtimeV2: RealtimeV2
  ) async {
    let interval = max(1, Int(prompt.intervalSeconds))

    while !Task.isCancelled {
      do {
        try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
        let result = try await realtimeV2.openAICodexPollDeviceAuth(pendingID: prompt.pendingID)
        guard !Task.isCancelled else { return }

        switch result.status {
          case .openaiCodexDeviceAuthPending:
            statusText = "Waiting for authorization..."
          case .openaiCodexDeviceAuthConnected:
            if result.hasConnection {
              upsert(result.connection)
            } else {
              await load(realtimeV2: realtimeV2)
            }
            authPrompt = nil
            statusText = "Connected."
            pollTask = nil
            return
          case .openaiCodexDeviceAuthExpired:
            authPrompt = nil
            statusText = nil
            errorState = ConnectionsErrorState(title: "Sign In Expired", message: "Start again to get a new code.")
            pollTask = nil
            return
          case .openaiCodexDeviceAuthDenied:
            authPrompt = nil
            statusText = nil
            errorState = ConnectionsErrorState(title: "Sign In Denied", message: "The ChatGPT authorization was denied.")
            pollTask = nil
            return
          case .openaiCodexDeviceAuthError, .unspecified, .UNRECOGNIZED(_):
            authPrompt = nil
            statusText = nil
            errorState = ConnectionsErrorState(
              title: "Could Not Finish Sign In",
              message: result.hasErrorMessage ? result.errorMessage : "Try connecting again."
            )
            pollTask = nil
            return
        }
      } catch is CancellationError {
        return
      } catch {
        guard !Task.isCancelled else { return }
        authPrompt = nil
        statusText = nil
        showError(title: "Could Not Finish Sign In", error: error)
        pollTask = nil
        return
      }
    }
  }

  private func upsert(_ connection: InlineProtocol.OAuthConnectionInfo) {
    connections.removeAll { $0.provider == connection.provider && $0.id != connection.id }
    if let index = connections.firstIndex(where: { $0.id == connection.id }) {
      connections[index] = connection
    } else {
      connections.insert(connection, at: 0)
    }
  }

  private func showError(title: String, error: Error) {
    errorState = ConnectionsErrorState(title: title, message: String(describing: error))
  }
}

struct ConnectionsErrorState {
  let title: String
  let message: String
}
