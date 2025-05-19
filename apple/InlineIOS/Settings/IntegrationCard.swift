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
      HStack{
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
        Spacer()

      }
    }
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
        clipped: true
      ) {}
    }
  }
}
