import Auth
import InlineConfig
import InlineKit
import InlineUI
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
    VStack(alignment: .leading) {
      HStack(alignment: .center) {
        Image(image)
          .resizable()
          .frame(width: 55, height: 55)
          .clipShape(RoundedRectangle(cornerRadius: clipped ? 18 : 0))
          .padding(.trailing, 6)
        VStack(alignment: .leading) {
          Text(title)
            .fontWeight(.medium)
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
      Divider()
      if isConnected, hasOptions, let navigateToOptions {
        HStack {
          Spacer()

          Button("Options") {
            navigateToOptions()
          }
          .buttonStyle(.borderless)
          .disabled(permissionCheck?() == false)
          .tint(Color(ThemeManager.shared.selected.accent))
          Spacer()
        }

        Divider()
      }
      HStack {
        Spacer()

        Button(isConnecting ? "Connecting..." : isConnected ? "Connected" : "Connect") {
          guard let token = Auth.shared.getToken() else {
            return
          }
          if let spaceId {
            if let url =
              URL(string: "\(baseURL)/integrations/\(provider)/integrate?token=\(token)&spaceId=\(spaceId)")
            {
              print("URL with spaceId: \(url)")
              openURL(url)
            }
          } else {
            if let url = URL(string: "\(baseURL)/integrations/\(provider)/integrate?token=\(token)") {
              print("URL: \(url)")
              openURL(url)
            }
          }
        }
        .buttonStyle(.borderless)
        .disabled(isConnecting || isConnected || (permissionCheck?() == false))
        .tint(Color(ThemeManager.shared.selected.accent))
        Spacer()
      }
    }
    .animation(.easeInOut(duration: 0.1), value: isConnected)
  }
}

#Preview {
  List {
    Section {
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
  }
}
