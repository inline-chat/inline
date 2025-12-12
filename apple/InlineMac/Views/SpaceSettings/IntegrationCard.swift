import AppKit
import Auth
import InlineConfig
import InlineKit
import Logger
import SwiftUI

/// Reusable integration connect card for macOS.
struct IntegrationCard: View {
  let image: String
  let title: String
  let description: String
  let provider: String
  let spaceId: Int64?
  @Binding var isConnected: Bool
  @Binding var isConnecting: Bool
  var hasOptions: Bool = false
  var optionsTitle: String = "Options"
  var optionsIsRequired: Bool = false
  var statusText: String? = nil
  var statusIsError: Bool = false
  var navigateToOptions: (() -> Void)?
  var permissionCheck: (() -> Bool)?
  var completion: () -> Void

  @State private var lastError: String?

  private let baseURL: String = InlineConfig.integrationsServerURL

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .center, spacing: 12) {
        Image(image)
          .resizable()
          .frame(width: 36, height: 36)
          .clipShape(RoundedRectangle(cornerRadius: 12))

        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .font(.headline)
          Text(description)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer()
      }

      HStack {
        Button(action: connect) {
          HStack(spacing: 6) {
            Text(buttonTitle)
            if isConnected {
              Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            } else if isConnecting {
              ProgressView()
                .controlSize(.small)
            }
          }
        }
        .buttonStyle(.bordered)
        .disabled(isConnecting || isConnected || permissionCheck?() == false)

        if isConnected, hasOptions, let navigateToOptions {
          Button(optionsTitle, action: navigateToOptions)
            .disabled(permissionCheck?() == false)
            .overlay(alignment: .topTrailing) {
              if optionsIsRequired {
                Text("Required")
                  .font(.caption2)
                  .padding(.horizontal, 6)
                  .padding(.vertical, 2)
                  .background(Color.red.opacity(0.15))
                  .foregroundStyle(.red)
                  .clipShape(Capsule())
                  .offset(x: 12, y: -12)
              }
            }
        }

        if isConnected {
          Button("Disconnect", role: .destructive, action: disconnect)
            .disabled(isConnecting || permissionCheck?() == false)
        }
      }

      if let statusText, !statusText.isEmpty {
        Text(statusText)
          .font(.footnote)
          .foregroundStyle(statusIsError ? .red : .secondary)
          .lineLimit(1)
          .truncationMode(.tail)
      }

      if let lastError {
        Text(lastError)
          .font(.footnote)
          .foregroundStyle(.red)
      }
    }
    .padding(14)
    .background(
      RoundedRectangle(cornerRadius: 12)
        .fill(Color(nsColor: .windowBackgroundColor))
        .shadow(color: .black.opacity(0.05), radius: 6, x: 0, y: 2)
    )
    .onReceive(NotificationCenter.default.publisher(for: .integrationCallback)) { notification in
      guard
        let url = notification.object as? URL,
        url.host == "integrations",
        url.pathComponents.dropFirst().first == provider
      else { return }

      handleCallback(url: url)
    }
  }

  private var buttonTitle: String {
    if isConnected { return "Connected" }
    if isConnecting { return "Connecting..." }
    return "Connect"
  }

  private func connect() {
    guard let token = Auth.shared.getToken() else {
      lastError = "You need to be signed in to connect \(title)."
      return
    }

    guard permissionCheck?() != false else {
      lastError = "You need admin access to manage integrations."
      return
    }

    var components = URLComponents(string: "\(baseURL)/integrations/\(provider)/integrate")
    var queryItems: [URLQueryItem] = [
      URLQueryItem(name: "token", value: token),
    ]
    if let spaceId {
      queryItems.append(URLQueryItem(name: "spaceId", value: "\(spaceId)"))
    }
    components?.queryItems = queryItems

    guard let url = components?.url else {
      lastError = "Failed to prepare integration URL."
      return
    }

    Log.shared.debug("Opening integration URL: \(url.absoluteString)")
    isConnecting = true
    lastError = nil
    _ = NSWorkspace.shared.open(url)
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: 400_000_000)
      isConnecting = false
    }
  }

  private func handleCallback(url: URL) {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
    let success = components.queryItems?.first(where: { $0.name == "success" })?.value == "true"
    let errorMessage = components.queryItems?.first(where: { $0.name == "error" })?.value

    isConnecting = false
    if success {
      isConnected = true
      lastError = nil
    } else if let errorMessage, !errorMessage.isEmpty {
      lastError = errorMessage
    } else {
      lastError = "Failed to connect \(title). Please try again."
    }

    completion()
  }

  private func disconnect() {
    guard let spaceId else { return }
    guard permissionCheck?() != false else {
      lastError = "You need admin access to manage integrations."
      return
    }

    isConnecting = true
    lastError = nil

    Task {
      do {
        _ = try await ApiClient.shared.disconnectIntegration(spaceId: spaceId, provider: provider)
        await MainActor.run {
          isConnected = false
          isConnecting = false
        }
        completion()
      } catch {
        await MainActor.run {
          isConnecting = false
          lastError = "Failed to disconnect: \(error.localizedDescription)"
        }
      }
    }
  }
}

extension Notification.Name {
  static let integrationCallback = Notification.Name("integrationCallback")
}
