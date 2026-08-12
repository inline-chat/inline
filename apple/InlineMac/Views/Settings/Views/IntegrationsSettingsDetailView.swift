import AppKit
import InlineKit
import InlineUI
import SwiftUI

struct ConnectorsSettingsDetailView: View {
  @State private var model = ConnectorSettingsModel()
  @State private var configuration: ConnectorConfiguration?

  var body: some View {
    ConnectorsSettingsView(
      model: model,
      openAuthorizationURL: { NSWorkspace.shared.open($0) },
      configure: { provider, spaceID in
        configuration = ConnectorConfiguration(provider: provider, spaceID: spaceID)
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

private struct ConnectorConfiguration: Identifiable {
  let provider: ConnectorKind
  let spaceID: Int64

  var id: String { "\(provider.rawValue):\(spaceID)" }
}
