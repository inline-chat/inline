import Auth
import AuthenticationServices
import InlineConfig
import InlineKit
import SwiftUI

struct SpaceIntegrationsView: View {
  @State private var isConnectingNotion = false
  @State private var isConnectedNotion = false
  @State private var isAdminOrOwner = false
  @EnvironmentStateObject private var viewModel: FullSpaceViewModel
  let spaceId: Int64
  @EnvironmentObject var nav: Navigation

  init(spaceId: Int64) {
    self.spaceId = spaceId
    _viewModel = EnvironmentStateObject { env in
      FullSpaceViewModel(db: env.appDatabase, spaceId: spaceId)
    }
  }

  private var currentUserMember: FullMemberItem? {
    viewModel.members.first { $0.userInfo.user.id == Auth.shared.getCurrentUserId() }
  }

  var body: some View {
    Form {
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
          nav.push(.integrationOptions(spaceId: spaceId, provider: "notion"))
        },
        permissionCheck: {
          let role = currentUserMember?.member.role
          return role == .owner || role == .admin
        }
      )

      // TODO: add footerText
    }
    .onAppear {
      checkIntegrationConnection()
      updatePermissions()
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

  private var footerText: Text? {
    let role = currentUserMember?.member.role
    let isAdminOrOwner = role == .owner || role == .admin

    if !isAdminOrOwner {
      return Text("Only space admins and owners can connect and manage integrations.")
    }
    return nil
  }

  func checkIntegrationConnection() {
    Task {
      do {
        let result = try await ApiClient.shared.getIntegrations(
          userId: Auth.shared.getCurrentUserId() ?? 0,
          spaceId: spaceId
        )
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

  func updatePermissions() {
    let role = currentUserMember?.member.role
    isAdminOrOwner = role == .owner || role == .admin
  }
}

#Preview {
  NavigationView {
    SpaceIntegrationsView(spaceId: 1)
  }
}
