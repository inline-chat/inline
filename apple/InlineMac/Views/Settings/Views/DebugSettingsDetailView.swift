import SwiftUI

struct DebugSettingsDetailView: View {
  @State private var showSyncStats = false
#if DEBUG
  @EnvironmentObject private var updateInstallState: UpdateInstallState
#endif

  var body: some View {
    Form {
      Section("Sync") {
        Button("Sync Engine Stats") {
          showSyncStats = true
        }
      }
#if DEBUG
      Section("Updates") {
        Toggle("Show Update Button", isOn: $updateInstallState.debugForceReady)
          .toggleStyle(.switch)
      }
#endif
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
    .sheet(isPresented: $showSyncStats) {
      SyncEngineStatsDetailView()
    }
  }
}

#Preview {
  DebugSettingsDetailView()
}
