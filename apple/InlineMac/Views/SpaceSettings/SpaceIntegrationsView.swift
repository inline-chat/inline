import Auth
import InlineKit
import Logger
import SwiftUI

struct SpaceIntegrationsView: View {
  let spaceId: Int64

  @State private var isConnectingLinear = false
  @State private var isConnectedLinear = false
  @State private var linearTeamId: String?
  @State private var isConnectingNotion = false
  @State private var isConnectedNotion = false
  @State private var showNotionOptions = false
  @State private var showLinearOptions = false
  @State private var errorMessage: String?
  @State private var isCheckingStatus = false
  @State private var showLinearSetupPrompt = false

  @StateObject private var membershipStatus: SpaceMembershipStatusViewModel

  init(spaceId: Int64) {
    self.spaceId = spaceId
    _membershipStatus = StateObject(wrappedValue: SpaceMembershipStatusViewModel(db: AppDatabase.shared, spaceId: spaceId))
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Text("Integrations")
          .font(.title2)
          .fontWeight(.semibold)

        Text("Connect tools to this space to create issues or tasks from messages. Connecting opens a browser window for authorization.")
          .font(.subheadline)
          .foregroundStyle(.secondary)

        IntegrationCard(
          image: "linear-icon",
          title: "Linear",
          description: "Create Linear issues from messages.",
          provider: "linear",
          spaceId: spaceId,
          isConnected: $isConnectedLinear,
          isConnecting: $isConnectingLinear,
          hasOptions: true,
          optionsTitle: (linearTeamId?.isEmpty == false) ? "Options" : "Select default team",
          optionsIsRequired: isConnectedLinear && (linearTeamId?.isEmpty != false),
          statusText: linearDefaultTeamStatusText,
          statusIsError: linearDefaultTeamIsMissing,
          navigateToOptions: { showLinearOptions = true },
          permissionCheck: { membershipStatus.canManageMembers },
          completion: checkIntegrationConnection
        )

        IntegrationCard(
          image: "notion-logo",
          title: "Notion",
          description: "Create Notion tasks from messages with AI.",
          provider: "notion",
          spaceId: spaceId,
          isConnected: $isConnectedNotion,
          isConnecting: $isConnectingNotion,
          hasOptions: true,
          navigateToOptions: { showNotionOptions = true },
          permissionCheck: { membershipStatus.canManageMembers },
          completion: checkIntegrationConnection
        )

        if membershipStatus.canManageMembers == false {
          Text("Only space admins and owners can connect or manage integrations.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
        }

        if let errorMessage {
          Text(errorMessage)
            .foregroundStyle(.red)
            .font(.footnote)
        }

        if isCheckingStatus {
          HStack(spacing: 8) {
            ProgressView()
              .controlSize(.small)
            Text("Checking integrations...")
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
        }

        Spacer()
      }
      .padding(20)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .task {
      await membershipStatus.refreshIfNeeded()
      checkIntegrationConnection()
    }
    .alert("Finish Linear setup", isPresented: $showLinearSetupPrompt) {
      Button("Select Default Team") { showLinearOptions = true }
      Button("Not now", role: .cancel) {}
    } message: {
      Text("Linear is connected for this space, but no default team is selected yet. Select a team now to enable \"Create Linear Issue\".")
    }
    .sheet(isPresented: $showNotionOptions, onDismiss: checkIntegrationConnection) {
      NavigationStack {
        IntegrationOptionsView(spaceId: spaceId, provider: "notion")
          .padding()
      }
    }
    .sheet(isPresented: $showLinearOptions, onDismiss: checkIntegrationConnection) {
      NavigationStack {
        IntegrationOptionsView(spaceId: spaceId, provider: "linear")
          .padding()
      }
    }
  }

  private var linearDefaultTeamIsMissing: Bool {
    isConnectedLinear && (linearTeamId?.isEmpty != false)
  }

  private var linearDefaultTeamStatusText: String? {
    guard isConnectedLinear else { return nil }
    guard let linearTeamId, !linearTeamId.isEmpty else { return "Default team: required" }

    if let team = cachedLinearTeams.first(where: { $0.id == linearTeamId }) {
      return "Default team: \(team.name) (\(team.key))"
    }
    return "Default team: set"
  }

  private var cachedLinearTeams: [LinearTeam] {
    guard
      let data = UserDefaults.standard.data(forKey: "linear_teams_\(spaceId)"),
      let decoded = try? JSONDecoder().decode([LinearTeam].self, from: data)
    else { return [] }
    return decoded
  }

  private func checkIntegrationConnection() {
    Task {
      await MainActor.run { isCheckingStatus = true }
      do {
        let result = try await ApiClient.shared.getIntegrations(
          userId: Auth.shared.getCurrentUserId() ?? 0,
          spaceId: spaceId
        )
        await MainActor.run {
          errorMessage = nil
          isConnectedLinear = result.hasLinearConnected
          isConnectedNotion = result.hasNotionConnected
          linearTeamId = result.linearTeamId
          isConnectingLinear = false
          isConnectingNotion = false
          isCheckingStatus = false

          if result.hasLinearConnected, (result.linearTeamId?.isEmpty != false), membershipStatus.canManageMembers {
            showLinearSetupPrompt = true
          }
        }
      } catch {
        await MainActor.run {
          errorMessage = "Failed to fetch integrations: \(error.localizedDescription)"
          isConnectingLinear = false
          isConnectingNotion = false
          isCheckingStatus = false
        }
        Log.shared.error("Failed to fetch integrations", error: error)
      }
    }
  }
}

#Preview {
  SpaceIntegrationsView(spaceId: 1)
    .previewsEnvironmentForMac(.populated)
}
