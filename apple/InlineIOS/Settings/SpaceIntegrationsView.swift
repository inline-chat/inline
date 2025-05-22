import Auth
import AuthenticationServices
import InlineConfig
import InlineKit
import SwiftUI

struct SpaceIntegrationsView: View {
  @State private var isConnectingNotion = false
  @State private var isConnectedNotion = false
  var spaceId: Int64?
  @EnvironmentObject var nav: Navigation

  var body: some View {
    List {
      Section {
        IntegrationCard(
          image: "notion-logo",
          title: "Notion",
          description: "Connect your Notion to create issues from messages with AI",
          isConnected: $isConnectedNotion,
          isConnecting: $isConnectingNotion,
          provider: "notion",
          clipped: false,
          spaceId: spaceId,
          completion: checkIntegrationConnection,
          hasOptions: true,
          navigateToOptions: {
            nav.push(.integrationOptions(spaceId: spaceId ?? 0, provider: "notion"))
          }
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

#Preview {
  NavigationView {
    IntegrationsView()
  }
}
