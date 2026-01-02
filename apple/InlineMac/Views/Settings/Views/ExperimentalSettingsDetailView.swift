import InlineKit
import RealtimeV2
import SwiftUI

struct ExperimentalSettingsDetailView: View {
  @StateObject private var appSettings = AppSettings.shared
  @Environment(\.realtimeV2) private var realtimeV2
  @State private var enableSyncMessageUpdates = Api.realtime.getEnableSyncMessageUpdates()

  var body: some View {
    Form {
      Section("Experimental") {
        Toggle("Enable new Mac UI", isOn: $appSettings.enableNewMacUI)
        Toggle("Enable sync message updates", isOn: $enableSyncMessageUpdates)
        Text("UI changes may require an app restart. Sync changes apply immediately.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
    .onAppear {
      enableSyncMessageUpdates = Api.realtime.getEnableSyncMessageUpdates()
    }
    .onChange(of: enableSyncMessageUpdates) { _, _ in
      Task { await realtimeV2.setEnableSyncMessageUpdates(enableSyncMessageUpdates) }
    }
  }
}

#Preview {
  ExperimentalSettingsDetailView()
}
