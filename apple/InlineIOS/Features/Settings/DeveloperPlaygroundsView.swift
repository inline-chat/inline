#if DEBUG || DEBUG_BUILD
import SwiftUI

struct DeveloperPlaygroundsView: View {
  var body: some View {
    List {
      NavigationLink {
        NextMessageViewPlaygroundView()
      } label: {
        SettingsItem(icon: "text.bubble.fill", iconColor: .orange, title: "Next Message View")
      }
    }
    .listStyle(.insetGrouped)
    .navigationTitle("Playgrounds")
    .navigationBarTitleDisplayMode(.inline)
  }
}
#endif
