import InlineIntents
import InlineKit
import RealtimeV2
import SwiftUI

struct DebugView: View {
  @State private var isClearing = false
  @State private var showClearAlert = false
  @State private var clearError: Error?
  @State private var showClearError = false

  var body: some View {
    List {
      Section("Sync") {
        NavigationLink(destination: SyncEngineStatsView()) {
          SettingsItem(
            icon: "waveform.path.ecg",
            iconColor: .blue,
            title: "Sync Engine"
          )
        }
      }

      Section("Shared Data") {
        Button {
          showClearAlert = true
        } label: {
          SettingsItem(
            icon: "trash.fill",
            iconColor: .red,
            title: "Clear Shared Data"
          ) {
            if isClearing {
              ProgressView()
                .padding(.trailing, 8)
            }
          }
        }
        .disabled(isClearing)
      }

      ClearCacheSettingsSection()

      ResetLocalDataDebugSection()

      IntentDonationDebugSection()
    }
    .listStyle(.insetGrouped)
    .navigationTitle("Debug")
    .navigationBarTitleDisplayMode(.inline)
    .alert("Clear Shared Data", isPresented: $showClearAlert) {
      Button("Cancel", role: .cancel) {}
      Button("Clear", role: .destructive) {
        clearSharedData()
      }
    } message: {
      Text("This will clear all shared data used by the share extension. The data will be regenerated when needed.")
    }
    .alert("Error Clearing Data", isPresented: $showClearError) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(clearError?.localizedDescription ?? "An unknown error occurred")
    }
  }

  private func clearSharedData() {
    isClearing = true

    Task {
      do {
        try BridgeManager.shared.clearSharedData()
        await MainActor.run {
          isClearing = false
        }
      } catch {
        await MainActor.run {
          clearError = error
          showClearError = true
          isClearing = false
        }
      }
    }
  }

}

private struct ResetLocalDataDebugSection: View {
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
      Text("Clears Inline’s local database, sync state, pending actions, and downloads on this device. Your account and server data are not deleted.")
    }
    .confirmationDialog(
      "Reset Local Data?",
      isPresented: $showConfirmation,
      titleVisibility: .visible
    ) {
      Button("Reset", role: .destructive, action: resetLocalData)
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Inline will reload your chats and messages from the server. Pending offline actions on this device will be discarded.")
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
        try await FileCache.shared.clearCache()
        await ImagePrefetcher.shared.clearCache()
        Transactions.shared.clearAll()
        await realtimeV2.clearSyncState()
        try AppDatabase.clearDB()
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

private struct IntentDonationDebugSection: View {
  @State private var isClearing = false
  @State private var showConfirmation = false
  @State private var showSuccess = false
  @State private var clearError: Error?
  @State private var showError = false

  var body: some View {
    Section {
      Button {
        showConfirmation = true
      } label: {
        SettingsItem(
          icon: "person.crop.circle.badge.xmark",
          iconColor: .red,
          title: "Clear Share Suggestions"
        ) {
          if isClearing {
            ProgressView()
              .padding(.trailing, 8)
          }
        }
      }
      .disabled(isClearing)
    } header: {
      Text("Share Sheet")
    } footer: {
      Text("Clears the people and conversations Inline donated to iOS. Chats and messages are not deleted.")
    }
    .confirmationDialog(
      "Clear Share Suggestions?",
      isPresented: $showConfirmation,
      titleVisibility: .visible
    ) {
      Button("Clear", role: .destructive) {
        clearIntentDonations()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This removes every message interaction Inline donated to iOS for share-sheet suggestions.")
    }
    .alert("Share Suggestions Cleared", isPresented: $showSuccess) {
      Button("OK", role: .cancel) {}
    } message: {
      Text("iOS may take a moment to refresh the share sheet.")
    }
    .alert("Couldn’t Clear Share Suggestions", isPresented: $showError, presenting: clearError) { _ in
      Button("OK", role: .cancel) {}
    } message: { error in
      Text(error.localizedDescription)
    }
  }

  private func clearIntentDonations() {
    isClearing = true

    Task { @MainActor in
      do {
        try await InlineMessageIntentDonation.deleteAll()
        isClearing = false
        showSuccess = true
      } catch {
        clearError = error
        isClearing = false
        showError = true
      }
    }
  }
}

#Preview("Debug") {
  NavigationView {
    DebugView()
  }
}
