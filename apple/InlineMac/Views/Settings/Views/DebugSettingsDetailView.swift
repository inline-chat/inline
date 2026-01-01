import SwiftUI

struct DebugSettingsDetailView: View {
  @State private var showSyncStats = false

  var body: some View {
    Form {
      Section("Sync") {
        Button("Sync Engine Stats") {
          showSyncStats = true
        }
      }
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
