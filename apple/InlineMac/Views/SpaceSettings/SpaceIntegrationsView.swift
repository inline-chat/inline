import AppKit
import InlineKit
import InlineUI
import SwiftUI

struct SpaceIntegrationsView: View {
  let spaceId: Int64
  @State private var model: ConnectorSettingsModel
  @State private var configuration: SpaceConnectorConfiguration?

  init(spaceId: Int64) {
    self.spaceId = spaceId
    _model = State(initialValue: ConnectorSettingsModel(initialScopeID: .space(spaceId)))
  }

  var body: some View {
    ConnectorsSettingsView(
      model: model,
      openAuthorizationURL: { NSWorkspace.shared.open($0) },
      configure: { provider, spaceID in
        configuration = SpaceConnectorConfiguration(provider: provider, spaceID: spaceID)
      }
    )
    .sheet(item: $configuration) { configuration in
      NavigationStack {
        IntegrationOptionsView(
          spaceId: configuration.spaceID,
          provider: configuration.provider.rawValue
        )
          .padding()
      }
    }
  }
}

private struct SpaceConnectorConfiguration: Identifiable {
  let provider: ConnectorKind
  let spaceID: Int64

  var id: String { "\(provider.rawValue):\(spaceID)" }
}

#Preview {
  SpaceIntegrationsView(spaceId: 1)
    .previewsEnvironmentForMac(.populated)
}
