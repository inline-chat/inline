import InlineKit
import InlineUI
import SwiftUI

struct ConnectorsView: View {
  @State private var model = ConnectorSettingsModel()
  @Environment(Router.self) private var router
  let initialOAuthCallbackURL: URL?

  init(initialOAuthCallbackURL: URL? = nil) {
    self.initialOAuthCallbackURL = initialOAuthCallbackURL
  }

  var body: some View {
    ConnectorsSettingsView(
      model: model,
      openAuthorizationURL: { InAppBrowser.shared.open($0) },
      didReceiveOAuthCallback: { InAppBrowser.shared.dismissIfPresented() },
      configure: { provider, spaceID in
        router.push(.integrationOptions(spaceId: spaceID, provider: provider.rawValue))
      },
      initialOAuthCallbackURL: initialOAuthCallbackURL
    )
    .navigationTitle("Connectors")
    .navigationBarTitleDisplayMode(.inline)
    .toolbarRole(.editor)
  }
}

#Preview {
  NavigationView {
    ConnectorsView()
  }
}
