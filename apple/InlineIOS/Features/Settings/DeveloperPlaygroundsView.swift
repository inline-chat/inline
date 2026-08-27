#if DEBUG || DEBUG_BUILD
import SwiftUI

struct DeveloperPlaygroundsView: View {
  var body: some View {
    List {
      NavigationLink {
        MessageView2PlaygroundView()
      } label: {
        SettingsItem(
          icon: "text.bubble.fill",
          iconColor: .orange,
          title: "Message View 2"
        )
      }
    }
    .listStyle(.insetGrouped)
    .navigationTitle("Playgrounds")
    .navigationBarTitleDisplayMode(.inline)
  }
}
#endif
