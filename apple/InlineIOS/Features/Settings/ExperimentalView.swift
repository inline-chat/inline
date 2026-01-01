import RealtimeV2
import SwiftUI

struct ExperimentalView: View {
  @Environment(\.realtimeV2) private var realtimeV2
  @AppStorage("enableSyncMessageUpdates") private var enableSyncMessageUpdates = false

  var body: some View {
    List {
      Section("Experimental") {
        Toggle("Enable sync message updates", isOn: $enableSyncMessageUpdates)
        Text("Applies immediately. Use to sync new/edit/attachment updates via bucket fetches.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .listStyle(.insetGrouped)
    .navigationTitle("Experimental")
    .navigationBarTitleDisplayMode(.inline)
    .onAppear {
      applySyncConfig()
    }
    .onChange(of: enableSyncMessageUpdates) { _, _ in
      applySyncConfig()
    }
  }

  private func applySyncConfig() {
    let config = SyncConfig(
      enableMessageUpdates: enableSyncMessageUpdates,
      lastSyncSafetyGapSeconds: SyncConfig.default.lastSyncSafetyGapSeconds
    )
    realtimeV2.updateSyncConfig(config)
  }
}

#Preview("Experimental") {
  NavigationView {
    ExperimentalView()
  }
}
