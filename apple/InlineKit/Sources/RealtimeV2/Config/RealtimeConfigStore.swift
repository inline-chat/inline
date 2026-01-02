import Foundation

enum RealtimeConfigStore {
  private static let enableSyncMessageUpdatesKey = "realtime.enableSyncMessageUpdates"

  static func getEnableSyncMessageUpdates() -> Bool {
    UserDefaults.standard.bool(forKey: enableSyncMessageUpdatesKey)
  }

  static func setEnableSyncMessageUpdates(_ value: Bool) {
    UserDefaults.standard.set(value, forKey: enableSyncMessageUpdatesKey)
  }

  static func initialSyncConfig() -> SyncConfig {
    SyncConfig(
      enableMessageUpdates: getEnableSyncMessageUpdates(),
      lastSyncSafetyGapSeconds: SyncConfig.default.lastSyncSafetyGapSeconds
    )
  }
}
