import InlineKit
import RealtimeV2
import SwiftUI

struct ExperimentalView: View {
  @Environment(\.realtimeV2) private var realtimeV2
  @State private var enableSyncMessageUpdates = Api.realtime.getEnableSyncMessageUpdates()

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
