import AppKit
import InlineKit
import SwiftUI

struct DebugSettingsDetailView: View {
  @State private var showSyncStats = false
  @State private var confirmDeleteDatabase = false
  @State private var isDeletingDatabase = false
  @State private var databaseErrorMessage = ""
  @State private var showDatabaseError = false
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
#if DEBUG || DEBUG_BUILD
      Section("Database") {
        Button(role: .destructive) {
          confirmDeleteDatabase = true
        } label: {
          Text(isDeletingDatabase ? "Deleting Database..." : "Delete DB File and Restart")
        }
        .disabled(isDeletingDatabase)
      }
#endif
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
#if DEBUG || DEBUG_BUILD
    .confirmationDialog(
      "Delete database file?",
      isPresented: $confirmDeleteDatabase,
      titleVisibility: .visible
    ) {
      Button("Delete and Restart", role: .destructive) {
        deleteDatabaseAndRestart()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This deletes the on-disk SQLite database for the current build profile and restarts Inline.")
    }
    .alert("Database Reset Failed", isPresented: $showDatabaseError) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(databaseErrorMessage)
    }
#endif
  }

#if DEBUG || DEBUG_BUILD
  private func deleteDatabaseAndRestart() {
    guard !isDeletingDatabase else { return }
    isDeletingDatabase = true

    do {
      try AppDatabase.deleteDatabaseFilesOnDisk()
      relaunchApp()
    } catch {
      isDeletingDatabase = false
      databaseErrorMessage = error.localizedDescription
      showDatabaseError = true
    }
  }

  private func relaunchApp() {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    configuration.createsNewApplicationInstance = true

    NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
      Task { @MainActor in
        if let error {
          isDeletingDatabase = false
          databaseErrorMessage = "Database file was deleted, but Inline could not restart: \(error.localizedDescription)"
          showDatabaseError = true
          return
        }

        NSApp.terminate(nil)
      }
    }
  }
#endif
}

#Preview {
  DebugSettingsDetailView()
#if DEBUG
    .environmentObject(UpdateInstallState())
#endif
}
