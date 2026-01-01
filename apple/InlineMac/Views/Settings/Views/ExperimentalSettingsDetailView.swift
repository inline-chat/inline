import RealtimeV2
import SwiftUI

struct ExperimentalSettingsDetailView: View {
  @StateObject private var appSettings = AppSettings.shared
  @Environment(\.realtimeV2) private var realtimeV2

  var body: some View {
    Form {
      Section("Experimental") {
        Toggle("Enable new Mac UI", isOn: $appSettings.enableNewMacUI)
        Toggle("Enable sync message updates", isOn: $appSettings.enableSyncMessageUpdates)
        Text("UI changes may require an app restart. Sync changes apply immediately.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
    .onAppear {
      applySyncConfig()
    }
    .onChange(of: appSettings.enableSyncMessageUpdates) { _, _ in
      applySyncConfig()
    }
  }

  private func applySyncConfig() {
    let config = SyncConfig(
      enableMessageUpdates: appSettings.enableSyncMessageUpdates,
      lastSyncSafetyGapSeconds: SyncConfig.default.lastSyncSafetyGapSeconds
    )
    Task { await realtimeV2.updateSyncConfig(config) }
  }
}

#Preview {
  ExperimentalSettingsDetailView()
}
