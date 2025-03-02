import AuthenticationServices
import InlineConfig
import InlineKit
import SwiftUI
import Auth

struct IntegrationsView: View {
  @State private var isConnectingLinear = false
  @State private var isConnected = false
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
    List {
      HStack(alignment: .center) {
        Image("linear-icon")
          .resizable()
          .frame(width: 55, height: 55)
          .clipShape(RoundedRectangle(cornerRadius: 18))
          .padding(.trailing, 6)
        VStack(alignment: .leading) {
          Text("Linear")
            .fontWeight(.semibold)
          Text("Connect your Linear to create issues from messages with AI")
            .foregroundColor(.secondary)
            .font(.caption)
        }
        Spacer()
        Button(isConnectingLinear ? "Connecting..." : isConnected ? "Connected" : "Connect") {
          guard let token = Auth.shared.getToken() else {
            return
          }
          if let url = URL(string: "\(baseURL)/integrations/linear/integrate?token=\(token)") {
            openURL(url)
          }
        }
        .buttonStyle(.borderless)
        .disabled(isConnectingLinear || isConnected)
      }
    }
    .onAppear {
      checkIntegrationConnection()
    }
    .onOpenURL { url in
      if url.scheme == "in", url.host == "integrations", url.path == "/linear",
         let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
         components.queryItems?.first(where: { $0.name == "success" })?.value == "true"
      {
        isConnected = true
      }

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
          isConnected = true
        } else {
          isConnected = false
        }
      } catch {
        print("Failed to get integrations \(error)")
      }
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
