enum RealtimeConfigStore {
  /// Live hint grace, in milliseconds. Short enough to stay invisible, long
  /// enough for the socket to deliver the update a hint announces.
  static let liveGapGraceMilliseconds = 300

  static func initialSyncConfig() -> SyncConfig {
    var config = SyncConfig.default
    config.liveGapGraceMilliseconds = liveGapGraceMilliseconds
    return config
  }
}
