import SwiftUI

struct ExperimentalView: View {
  var body: some View {
    List {
      Section {
        LabeledContent {
          Text("Enabled")
            .foregroundStyle(.secondary)
        } label: {
          VStack(alignment: .leading, spacing: 3) {
            Text("New Home")
            Text("Use the new Inbox, All Chats, and Search tabs.")
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
        }
      } footer: {
        Text("New Home is now the standard experience for everyone.")
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
