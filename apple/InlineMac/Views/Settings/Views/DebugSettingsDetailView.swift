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
#if DEBUG || DEBUG_BUILD
  @State private var showThemeWorkshop = false
#endif
#if (DEBUG || DEBUG_BUILD) && SPARKLE
  @State private var updatePreview = DebugSoftwareUpdatePreview.updateAvailable
  @Environment(UpdateController.self) private var updates
#endif

  var body: some View {
#if (DEBUG || DEBUG_BUILD) && SPARKLE
    @Bindable var updates = updates
#endif
    Form {
      Section {
        LabeledContent {
          Button("Open") {
            showSyncStats = true
          }
        } label: {
          SettingsRowLabel(
            "Sync Engine",
            description: "Inspect local RealtimeV2 state and run sync debug scenarios."
          )
        }

        LabeledContent {
          Button("Open") {
            showPermissions = true
          }
        } label: {
          SettingsRowLabel(
            "App Permissions",
            description: "Check notification, microphone, and local permission state."
          )
        }

        LabeledContent {
          Button("Open") {
            MacDevtoolsWindowController.show()
          }
        } label: {
          SettingsRowLabel(
            "MacDevtools",
            description: "Open the internal macOS developer tools window."
          )
        }
      } header: {
        SettingsSectionHeader("Tools")
      }
#if DEBUG || DEBUG_BUILD
      Section {
        LabeledContent {
          Button("Open") {
            showThemeWorkshop = true
          }
        } label: {
          SettingsRowLabel(
            "Theme Workshop",
            description: "Tune preset colors live and copy a palette export for production polish."
          )
        }
      } header: {
        SettingsSectionHeader("Appearance")
      }

      Section {
        LabeledContent {
          Button(role: .destructive) {
            confirmDeleteDatabase = true
          } label: {
            if isDeletingDatabase {
              Text("Deleting...")
            } else {
              Text("Delete and Restart...")
            }
          }
          .disabled(isDeletingDatabase)
        } label: {
          SettingsRowLabel(
            "Local Database",
            description: "Delete this build profile's local SQLite database, then restart Inline."
          )
        }
      } header: {
        SettingsSectionHeader("Database")
      }
#endif
#if (DEBUG || DEBUG_BUILD) && SPARKLE
      Section {
        LabeledContent {
          HStack(spacing: 8) {
            Picker("Updater State", selection: $updatePreview) {
              ForEach(DebugSoftwareUpdatePreview.allCases) { preview in
                Text(preview.title)
                  .tag(preview)
              }
            }
            .labelsHidden()
            .frame(width: 170)

            Button("Show") {
              updates.presentDebugPreview(updatePreview)
            }
            .disabled(!updates.canPresentDebugPreview)
          }
        } label: {
          SettingsRowLabel(
            "Updater Dialog",
            description: "Preview updater states without contacting the update server."
          )
        }

        Toggle(isOn: $updates.debugForceReady) {
          SettingsRowLabel(
            "Show Update Button",
            description: "Force the update UI into a ready state in debug builds."
          )
        }
          .toggleStyle(.switch)
      } header: {
        SettingsSectionHeader("Updates")
      }
#endif
    }
    .settingsFormStyle()
    .sheet(isPresented: $showSyncStats) {
      SyncEngineStatsDetailView()
    }
    .sheet(isPresented: $showPermissions) {
      PermissionsDebugSheet()
    }
#if DEBUG || DEBUG_BUILD
    .sheet(isPresented: $showThemeWorkshop) {
      ThemeWorkshopView()
    }
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
#if (DEBUG || DEBUG_BUILD) && SPARKLE
    .environment(UpdateController())
#endif
}
