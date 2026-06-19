import AppKit
import InlineKit
import MacDevtools
import SwiftUI

struct DebugSettingsDetailView: View {
  @State private var showSyncStats = false
  @State private var showPermissions = false
  @State private var confirmDeleteDatabase = false
  @State private var isDeletingDatabase = false
  @State private var databaseErrorMessage = ""
  @State private var showDatabaseError = false
#if DEBUG
  @EnvironmentObject private var updateInstallState: UpdateInstallState
#endif

  var body: some View {
    Form {
      Section {
        LabeledContent("Sync Engine") {
          Button("Open") {
            showSyncStats = true
          }
        }
      } header: {
        Text("Sync")
      } footer: {
        Text("Inspect local RealtimeV2 sync state and run sync debug scenarios.")
      }

      Section {
        LabeledContent("App Permissions") {
          Button("Open") {
            showPermissions = true
          }
        }
      } header: {
        Text("Permissions")
      } footer: {
        Text("Check notification, microphone, and local permission state used by this build.")
      }

      Section {
        LabeledContent("MacDevtools") {
          Button("Open") {
            MacDevtoolsWindowController.show()
          }
        }
      } header: {
        Text("Developer Tools")
      } footer: {
        Text("Open the internal macOS developer tools window.")
      }
#if DEBUG || DEBUG_BUILD
      Section {
        LabeledContent("Local Database") {
          Button(isDeletingDatabase ? "Deleting..." : "Delete and Restart...", role: .destructive) {
            confirmDeleteDatabase = true
          }
          .disabled(isDeletingDatabase)
        }
      } header: {
        Text("Database")
      } footer: {
        Text("Deletes the on-disk SQLite database for the current build profile, then restarts Inline.")
      }
#endif
#if DEBUG
      Section {
        Toggle("Show Update Button", isOn: $updateInstallState.debugForceReady)
          .toggleStyle(.switch)
      } header: {
        Text("Updates")
      } footer: {
        Text("Forces update UI into a ready state in debug builds.")
      }
#endif
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
    .sheet(isPresented: $showSyncStats) {
      SyncEngineStatsDetailView()
    }
    .sheet(isPresented: $showPermissions) {
      PermissionsDebugSheet()
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
