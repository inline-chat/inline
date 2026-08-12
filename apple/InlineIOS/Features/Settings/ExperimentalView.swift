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

      if #available(iOS 27.0, *) {
        ChatToolbarBackgroundExperimentSection()
      }
    }
    .listStyle(.insetGrouped)
    .navigationTitle("Experimental")
    .navigationBarTitleDisplayMode(.inline)
  }
}

@available(iOS 27.0, *)
private struct ChatToolbarBackgroundExperimentSection: View {
  @AppStorage(ChatToolbarBackgroundExperiment.key)
  private var isEnabled = ChatToolbarBackgroundExperiment.defaultValue

  var body: some View {
    Section {
      Toggle(isOn: $isEnabled) {
        VStack(alignment: .leading, spacing: 3) {
          Text("iOS 27 Chat Toolbar Background")
          Text("Replace Inline’s variable top blur with an app-drawn toolbar background.")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }
    } footer: {
      Text("Experimental. Recreates the iOS 27 toolbar treatment above Inline’s inverted message list.")
    }
  }
}

#Preview("Experimental") {
  NavigationStack {
    ExperimentalView()
  }
}
