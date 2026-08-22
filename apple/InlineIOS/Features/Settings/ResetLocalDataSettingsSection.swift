import InlineKit
import Logger
import RealtimeV2
import SwiftUI

struct ResetLocalDataSettingsSection: View {
  @Environment(\.realtimeV2) private var realtimeV2

  @State private var isResetting = false
  @State private var showConfirmation = false
  @State private var resetError: Error?
  @State private var showError = false

  var body: some View {
    Section {
      Button {
        showConfirmation = true
      } label: {
        SettingsItem(
          icon: "arrow.counterclockwise.circle.fill",
          iconColor: .red,
          title: "Reset Local Data"
        ) {
          if isResetting {
            ProgressView()
              .padding(.trailing, 8)
          }
        }
      }
      .disabled(isResetting)
    } header: {
      Text("Recovery")
    } footer: {
      Text(
        "Last resort before reinstalling Inline. Clears this device’s database, sync state, pending actions, and downloads, then reloads your account from the server."
      )
    }
    .confirmationDialog(
      "Reset All Local Data?",
      isPresented: $showConfirmation,
      titleVisibility: .visible
    ) {
      Button("Reset Local Data", role: .destructive, action: resetLocalData)
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "Your Inline account and server data will not be deleted. Pending offline actions and drafts on this device will be discarded."
      )
    }
    .alert("Couldn’t Reset Local Data", isPresented: $showError, presenting: resetError) { _ in
      Button("OK", role: .cancel) {}
    } message: { error in
      Text(error.localizedDescription)
    }
  }

  private func resetLocalData() {
    guard !isResetting else { return }
    isResetting = true

    Task { @MainActor in
      do {
        try await LocalDataResetPerformer.perform(realtimeV2: realtimeV2)
        NotificationCenter.default.post(name: .localDataCleared, object: nil)
        ToastManager.shared.showToast(
          "Local data reset",
          description: "Inline is reloading from the server.",
          type: .success,
          systemImage: "arrow.clockwise"
        )
      } catch {
        resetError = error
        showError = true
      }
      isResetting = false
    }
  }
}

@MainActor
private enum LocalDataResetPerformer {
  private static let log = Log.scoped("LocalDataReset")

  static func perform(realtimeV2: RealtimeV2) async throws {
    await realtimeV2.loggedOut()
    await Realtime.shared.loggedOut()

    do {
      await FileUploader.shared.cancelAll()
      await FileCache.shared.cancelAllDownloads()
      await FileDownloader.shared.resetSession()
      NotionTaskService.shared.resetSession()
      await Drafts2.shared.resetForAccountChange()
      await Transactions.shared.clearAllAndWait()
      ObjectCache.shared.clear()

      do {
        try await FileCache.shared.clearCache()
        await ImagePrefetcher.shared.clearCache()
      } catch {
        log.error("Media cleanup failed during local-data reset", error: error)
      }

      do {
        try await AppDataUpdater.shared.clearSharedData()
      } catch {
        log.error("Shared-data cleanup failed during local-data reset", error: error)
      }

      try AppDatabase.clearDB()
    } catch {
      await resumeAccountWork(realtimeV2: realtimeV2)
      throw error
    }

    await resumeAccountWork(realtimeV2: realtimeV2)
  }

  private static func resumeAccountWork(realtimeV2: RealtimeV2) async {
    await realtimeV2.resumeAfterLocalDataReset()
    await Realtime.shared.start()
  }
}
