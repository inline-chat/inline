import InlineKit
import RealtimeV2
import SwiftUI

struct ExperimentalView: View {
  @AppStorage("enableExperimentalView") private var enableExperimentalView = true
  @Environment(\.realtimeV2) private var realtimeV2
  @State private var enableSyncMessageUpdates = Api.realtime.getEnableSyncMessageUpdates()

  var body: some View {
    List {
      Section("Experimental") {
        SettingsItem(
          icon: "sparkles",
          iconColor: .purple,
          title: "Enable experimental view"
        ) {
          Toggle("", isOn: $enableExperimentalView)
            .labelsHidden()
            .accessibilityLabel("Enable experimental view")
        }

        SettingsItem(
          icon: "arrow.triangle.2.circlepath",
          iconColor: .orange,
          title: "Enable sync message updates"
        ) {
          Toggle("", isOn: $enableSyncMessageUpdates)
            .labelsHidden()
            .accessibilityLabel("Enable sync message updates")
        }

        Text("UI changes may require an app restart. Sync changes apply immediately.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .listStyle(.insetGrouped)
    .navigationTitle("Experimental")
    .navigationBarTitleDisplayMode(.inline)
    .onAppear {
      enableSyncMessageUpdates = Api.realtime.getEnableSyncMessageUpdates()
    }
    .onChange(of: enableSyncMessageUpdates) { _, _ in
      Task { await realtimeV2.setEnableSyncMessageUpdates(enableSyncMessageUpdates) }
    }
  }
}

#Preview("Experimental") {
  NavigationView {
    ExperimentalView()
  }
}
