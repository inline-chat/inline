import SwiftUI

struct ExperimentalView: View {
  @AppStorage(ExperimentalHomePreferenceKeys.isEnabled)
  private var isNewHomeEnabled = false

  var body: some View {
    List {
      Section {
        Toggle(isOn: $isNewHomeEnabled) {
          VStack(alignment: .leading, spacing: 3) {
            Text("New Home")
            Text("Use the experimental Inbox, All Chats, and Search tabs.")
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
        }
      } footer: {
        Text("The app switches Home experiences immediately. You can return here to switch back.")
      }
    }
    .listStyle(.insetGrouped)
    .navigationTitle("Experimental")
    .navigationBarTitleDisplayMode(.inline)
  }
}

#Preview("Experimental") {
  NavigationStack {
    ExperimentalView()
  }
}
