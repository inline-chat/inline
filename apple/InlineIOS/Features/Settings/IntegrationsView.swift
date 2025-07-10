import Auth
import AuthenticationServices
import InlineConfig
import InlineKit
import SwiftUI

struct IntegrationsView: View {
  @State private var isConnectingLinear = false
  @State private var isConnectedLinear = false

  var body: some View {
    Form {
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
      .themedListRow()
    }
    .listStyle(.insetGrouped)
    .onAppear {
      checkIntegrationConnection()
    }

    .navigationBarTitleDisplayMode(.inline)
    .toolbarRole(.editor)
    .toolbar {
      ToolbarItem(id: "integrations", placement: .principal) {
        HStack {
          Image(systemName: "app.connected.to.app.below.fill")
            .themedSecondaryText()
            .font(.callout)
            .padding(.trailing, 4)
          VStack(alignment: .leading) {
            Text("Integrations")
              .font(.body)
              .fontWeight(.semibold)
              .themedPrimaryText()
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
