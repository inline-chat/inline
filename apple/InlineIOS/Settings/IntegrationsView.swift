import Auth
import AuthenticationServices
import InlineConfig
import InlineKit
import SwiftUI

struct IntegrationsView: View {
  @State private var isConnectingLinear = false
  @State private var isConnectedLinear = false
  @State private var isConnectingNotion = false
  @State private var isConnectedNotion = false

  var body: some View {
    List {
      Section {
        IntegrationCard(
          image: "linear-icon",
          title: "Linear",
          description: "Connect your Linear to create issues from messages with AI",
          isConnected: $isConnectedLinear,
          isConnecting: $isConnectingLinear,
          provider: "linear",
          clipped: true,
          completion: checkIntegrationConnection
        )
      }
      Section {
        IntegrationCard(
          image: "notion-logo",
          title: "Notion",
          description: "Connect your Notion to create issues from messages with AI",
          isConnected: $isConnectedNotion,
          isConnecting: $isConnectingNotion,
          provider: "notion",
          clipped: false,
          completion: checkIntegrationConnection
        )
      }
    }
    .onAppear {
      checkIntegrationConnection()
    }

    .navigationBarTitleDisplayMode(.inline)
    .toolbarRole(.editor)
    .toolbar {
      ToolbarItem(id: "integrations", placement: .principal) {
        HStack {
          Image(systemName: "app.connected.to.app.below.fill")
            .foregroundColor(.secondary)
            .font(.callout)
            .padding(.trailing, 4)
          VStack(alignment: .leading) {
            Text("Integrations")
              .font(.body)
              .fontWeight(.semibold)
          }
        }
      }
    }
  }

  func checkIntegrationConnection() {
    Task {
      do {
        let result = try await ApiClient.shared.getIntegrations(userId: Auth.shared.getCurrentUserId() ?? 0)
        if result.hasLinearConnected {
          isConnectedLinear = true
        } else {
          isConnectedLinear = false
        }
        if result.hasNotionConnected {
          isConnectedNotion = true
        } else {
          isConnectedNotion = false
        }
      } catch {
        print("Failed to get integrations \(error)")
      }
    }
  }
}

struct IntegrationCard: View {
  var image: String
  var title: String
  var description: String
  @Binding var isConnected: Bool
  @Binding var isConnecting: Bool
  var provider: String
  var clipped: Bool
  var completion: () -> Void

  @Environment(\.openURL) private var openURL

  let baseURL: String = {
    if ProjectConfig.useProductionApi {
      return "https://api.inline.chat"
    }

    #if DEBUG
    return "http://localhost:8000"
    #else
    return "https://api.inline.chat"
    #endif
  }()

  var body: some View {
    HStack(alignment: .top) {
      Image(image)
        .resizable()
        .frame(width: 55, height: 55)
        .clipShape(RoundedRectangle(cornerRadius: clipped ? 18 : 0))
        .padding(.trailing, 6)
      VStack(alignment: .leading) {
        HStack {
          Text(title)
            .fontWeight(.medium)

          Spacer()

          Button(isConnecting ? "Connecting..." : isConnected ? "Connected" : "Connect") {
            guard let token = Auth.shared.getToken() else {
              return
            }
            if let url = URL(string: "\(baseURL)/integrations/\(provider)/integrate?token=\(token)") {
              openURL(url)
            }
          }
          .buttonStyle(.borderless)
          .disabled(isConnecting || isConnected)
          .tint(Color(ThemeManager.shared.selected.accent))
          .font(.callout)
          .padding(.trailing, 8)
        }
        Text(description)
          .foregroundColor(.secondary)
          .font(.caption)
      }
    }
    .onOpenURL { url in
      if url.scheme == "in", url.host == "integrations", url.path == "/\(provider)",
         let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
         components.queryItems?.first(where: { $0.name == "success" })?.value == "true"
      {
        isConnected = true
      }

      completion()
    }
  }
}

class WebAuthenticationSession: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
  private var webAuthSession: ASWebAuthenticationSession?

  func webAuthenticationSession(
    _ session: ASWebAuthenticationSession,

    didCompleteWithCallbackURL callbackURL: URL
  ) {}

  func webAuthenticationSession(
    _ session: ASWebAuthenticationSession,

    didFailWithError error: Error
  ) {}

  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    UIApplication.shared.windows.first ?? ASPresentationAnchor()
  }

  func authenticate(
    url: URL,

    callbackScheme: String,

    completion: @escaping (URL?, Error?) -> Void
  ) {
    webAuthSession = ASWebAuthenticationSession(
      url: url,
      callbackURLScheme: callbackScheme,
      completionHandler: completion
    )

    webAuthSession?.presentationContextProvider = self
    webAuthSession?.prefersEphemeralWebBrowserSession = true
    webAuthSession?.start()
  }
}

#Preview {
  NavigationView {
    IntegrationsView()
  }
}
