import Auth
import InlineConfig
import InlineKit
import InlineUI
import Logger
import SwiftUI

struct IntegrationCard: View {
  var image: String
  var title: String
  var description: String
  @Binding var isConnected: Bool
  @Binding var isConnecting: Bool
  var provider: String
  var clipped: Bool
  var spaceId: Int64?
  var completion: () -> Void
  var hasOptions: Bool = false
  var navigateToOptions: (() -> Void)? = nil
  var permissionCheck: (() -> Bool)? = nil

  @Environment(\.openURL) private var openURL

  let baseURL: String = ApiClient.serverURL

  var body: some View {
    Section {
      HStack(alignment: .center, spacing: 12) {
        Image(image)
          .resizable()
          .frame(width: 55, height: 55)
          .clipShape(RoundedRectangle(cornerRadius: clipped ? 18 : 0))

        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .fontWeight(.medium)
            .themedPrimaryText()
          Text(description)
            .themedSecondaryText()
            .font(.caption)
        }

        Spacer()
      }
      .padding(.vertical, 4)

      Button(action: {
        guard let token = Auth.shared.getToken() else {
          return
        }
        if let spaceId {
          if let url =
            URL(string: "\(baseURL)/integrations/\(provider)/integrate?token=\(token)&spaceId=\(spaceId)")
          {
            Log.shared.debug("Opening URL: \(url)")
            openURL(url)
          }
        } else {
          if let url = URL(string: "\(baseURL)/integrations/\(provider)/integrate?token=\(token)") {
            Log.shared.debug("Opening URL: \(url)")
            openURL(url)
          }
        }
      }) {
        HStack {
          Text(isConnecting ? "Connecting..." : isConnected ? "Connected" : "Connect")
            .themedPrimaryText()
          Spacer()
          if isConnected {
            Image(systemName: "checkmark.circle.fill")
              .foregroundColor(.green)
          } else if isConnecting {
            ProgressView()
              .scaleEffect(0.8)
          }
        }
      }
      .disabled(isConnecting || isConnected || (permissionCheck?() == false))

      if isConnected, hasOptions, let navigateToOptions {
        Button("Options") {
          navigateToOptions()
        }
        .themedPrimaryText()
        .disabled(permissionCheck?() == false)
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
    .animation(.easeInOut(duration: 0.2), value: isConnected)
  }
}

#Preview {
  NavigationView {
    Form {
      IntegrationCard(
        image: "notion-logo",
        title: "Notion",
        description: "Connect your Notion workspace to Inline",
        isConnected: .constant(false),
        isConnecting: .constant(false),
        provider: "notion",
        clipped: true,
        spaceId: 123,
        completion: {},
        navigateToOptions: {},
        permissionCheck: { true }
      )
    }
    .navigationTitle("Integration")
  }
}
