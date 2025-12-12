import Auth
import InlineKit
import SwiftUI

// Inline only supports space-scoped integrations (Linear/Notion).
// Global settings integrations are intentionally disabled; use Space Settings -> Integrations instead.
#if false
struct IntegrationsSettingsDetailView: View {
  var body: some View { EmptyView() }
}
#endif
