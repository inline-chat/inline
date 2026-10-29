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
      NavigationLink {
        MessageContextMenuLabView()
      } label: {
        SettingsItem(icon: "contextualmenu.and.cursorarrow", iconColor: .indigo, title: "Context Menu")
      }
    }
    .listStyle(.insetGrouped)
    .navigationTitle("Playgrounds")
    .navigationBarTitleDisplayMode(.inline)
  }
}
#endif
