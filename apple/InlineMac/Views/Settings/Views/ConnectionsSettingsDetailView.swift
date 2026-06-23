import AppKit
import InlineProtocol
import RealtimeV2
import SwiftUI

struct ConnectionsSettingsDetailView: View {
  @Environment(\.realtimeV2) private var realtimeV2
  @StateObject private var viewModel = ConnectionsSettingsViewModel()
  @State private var connectionToDisconnect: InlineProtocol.OAuthConnectionInfo?

  var body: some View {
    Form {
      Section {
        if viewModel.isLoading, viewModel.connections.isEmpty {
          HStack(spacing: 8) {
            ProgressView()
              .controlSize(.small)
            Text("Loading connections...")
              .foregroundStyle(.secondary)
          }
        } else if let connection = viewModel.chatGPTConnection {
          ChatGPTConnectionRow(
            connection: connection,
            isDisconnecting: viewModel.disconnectingConnectionID == connection.id,
            onDisconnect: { connectionToDisconnect = connection },
            onReconnect: { startSignIn(openBrowser: true) }
          )
        } else {
          Text("No ChatGPT account connected.")
            .foregroundStyle(.secondary)
        }

        HStack(spacing: 12) {
          Button {
            startSignIn(openBrowser: true)
          } label: {
            Label(viewModel.chatGPTConnection == nil ? "Connect ChatGPT" : "Reconnect", systemImage: "link.badge.plus")
          }
          .disabled(viewModel.isStarting)

          Button("Refresh") {
            Task {
              await viewModel.load(realtimeV2: realtimeV2)
            }
          }
          .disabled(viewModel.isLoading)

          if viewModel.isStarting {
            ProgressView()
              .controlSize(.small)
          }
        }

        if let statusText = viewModel.statusText {
          Text(statusText)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      } header: {
        Text("ChatGPT")
      } footer: {
        Text("@chat, @chatgpt, and @gpt use this connection for your personal account.")
      }

      if let prompt = viewModel.authPrompt {
        Section {
          LabeledContent("Code") {
            HStack(spacing: 10) {
              Text(prompt.userCode)
                .font(.system(.title2, design: .monospaced).weight(.semibold))
                .textSelection(.enabled)
                .frame(minWidth: 110, alignment: .leading)

              Button {
                copy(prompt.userCode)
              } label: {
                Label("Copy Code", systemImage: "doc.on.doc")
                  .labelStyle(.iconOnly)
              }
              .help("Copy Code")
            }
          }

          LabeledContent("Page") {
            Button {
              open(prompt.verificationURL)
            } label: {
              Label("Open", systemImage: "safari")
            }
          }

          if prompt.expiresAt > 0 {
            LabeledContent("Expires") {
              Text(Date(timeIntervalSince1970: TimeInterval(prompt.expiresAt)), style: .time)
            }
          }

          Button("Cancel Sign In", role: .cancel) {
            viewModel.cancelSignIn()
          }
        } header: {
          Text("Authorize")
        }
      }
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
    .task {
      await viewModel.load(realtimeV2: realtimeV2)
    }
    .alert(
      viewModel.errorState?.title ?? "",
      isPresented: .init(
        get: { viewModel.errorState != nil },
        set: { if !$0 { viewModel.errorState = nil } }
      )
    ) {
      Button("OK", role: .cancel) {}
    } message: {
      if let errorState = viewModel.errorState {
        Text(errorState.message)
      }
    }
    .confirmationDialog(
      "Disconnect ChatGPT?",
      isPresented: .init(
        get: { connectionToDisconnect != nil },
        set: { if !$0 { connectionToDisconnect = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("Disconnect", role: .destructive) {
        guard let connection = connectionToDisconnect else { return }
        Task {
          await viewModel.disconnect(connection, realtimeV2: realtimeV2)
          connectionToDisconnect = nil
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("@gpt will ask you to connect again before it can answer.")
    }
  }

  private func startSignIn(openBrowser: Bool) {
    Task {
      await viewModel.startChatGPTConnection(realtimeV2: realtimeV2)
      if openBrowser, let prompt = viewModel.authPrompt {
        open(prompt.verificationURL)
      }
    }
  }

  private func open(_ urlString: String) {
    guard let url = URL(string: urlString) else { return }
    NSWorkspace.shared.open(url)
  }

  private func copy(_ string: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
  }
}

private struct ChatGPTConnectionRow: View {
  let connection: InlineProtocol.OAuthConnectionInfo
  let isDisconnecting: Bool
  let onDisconnect: () -> Void
  let onReconnect: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline, spacing: 12) {
        Label(statusTitle, systemImage: statusIcon)
          .foregroundStyle(statusColor)

        Spacer()

        if connection.status == .oauthConnectionError {
          Button("Reconnect", action: onReconnect)
        }

        Button("Disconnect", role: .destructive, action: onDisconnect)
          .disabled(isDisconnecting)
      }

      Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
        if !displayName.isEmpty {
          GridRow {
            Text("Account")
              .foregroundStyle(.secondary)
            Text(displayName)
          }
        }

        if connection.hasEmail {
          GridRow {
            Text("Email")
              .foregroundStyle(.secondary)
            Text(connection.email)
          }
        }

        if connection.hasPlan {
          GridRow {
            Text("Plan")
              .foregroundStyle(.secondary)
            Text(connection.plan)
          }
        }

        if connection.hasLastUsedAt {
          GridRow {
            Text("Last Used")
              .foregroundStyle(.secondary)
            Text(Date(timeIntervalSince1970: TimeInterval(connection.lastUsedAt)), style: .relative)
          }
        }

        if connection.status == .oauthConnectionError, connection.hasErrorCode {
          GridRow {
            Text("Error")
              .foregroundStyle(.secondary)
            Text(connection.errorCode)
          }
        }
      }
      .font(.callout)

      if isDisconnecting {
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          Text("Disconnecting...")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  private var displayName: String {
    if connection.hasDisplayName {
      return connection.displayName
    }
    if connection.hasEmail {
      return connection.email
    }
    return ""
  }

  private var statusTitle: String {
    switch connection.status {
      case .oauthConnectionActive:
        return "Connected"
      case .oauthConnectionError:
        return "Needs Reconnect"
      case .oauthConnectionRevoked:
        return "Disconnected"
      case .unspecified, .UNRECOGNIZED(_):
        return "Unknown"
    }
  }

  private var statusIcon: String {
    switch connection.status {
      case .oauthConnectionActive:
        return "checkmark.circle.fill"
      case .oauthConnectionError:
        return "exclamationmark.triangle.fill"
      case .oauthConnectionRevoked:
        return "xmark.circle.fill"
      case .unspecified, .UNRECOGNIZED(_):
        return "questionmark.circle"
    }
  }

  private var statusColor: Color {
    switch connection.status {
      case .oauthConnectionActive:
        return .green
      case .oauthConnectionError:
        return .orange
      case .oauthConnectionRevoked:
        return .secondary
      case .unspecified, .UNRECOGNIZED(_):
        return .secondary
    }
  }
}
