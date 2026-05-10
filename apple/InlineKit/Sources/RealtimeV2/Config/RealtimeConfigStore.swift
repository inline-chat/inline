import Foundation

enum RealtimeConfigStore {
  private static let enableSyncMessageUpdatesKey = "realtime.enableSyncMessageUpdates"

  static func getEnableSyncMessageUpdates() -> Bool {
    SyncConfig.default.enableMessageUpdates
  }

  static func setEnableSyncMessageUpdates(_: Bool) {
    UserDefaults.standard.removeObject(forKey: enableSyncMessageUpdatesKey)
  }

  static func initialSyncConfig() -> SyncConfig {
    SyncConfig.default
  }
}
