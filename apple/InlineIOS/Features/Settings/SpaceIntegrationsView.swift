import InlineKit
import InlineUI
import SwiftUI

struct SpaceIntegrationsView: View {
  let spaceId: Int64
  @State private var model: ConnectorSettingsModel
  @Environment(Router.self) private var router

  init(spaceId: Int64) {
    self.spaceId = spaceId
    _model = State(initialValue: ConnectorSettingsModel(initialScopeID: .space(spaceId)))
  }

  var body: some View {
    ConnectorsSettingsView(
      model: model,
      openAuthorizationURL: { InAppBrowser.shared.open($0) },
      didReceiveOAuthCallback: { InAppBrowser.shared.dismissIfPresented() },
      configure: { provider, spaceID in
        router.push(.integrationOptions(spaceId: spaceID, provider: provider.rawValue))
      }
    )
    .navigationTitle("Connectors")
    .navigationBarTitleDisplayMode(.inline)
    .toolbarRole(.editor)
  }
}

#Preview {
  NavigationView {
    SpaceIntegrationsView(spaceId: 1)
  }
}
