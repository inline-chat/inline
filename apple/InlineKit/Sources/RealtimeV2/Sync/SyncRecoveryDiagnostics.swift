import Logger

/// Only locally classified, payload-free failure categories may enter this value.
struct SyncRecoveryFailure: Error, PrivacySafeErrorCategoryProviding {
  let bucketKind: String
  let phase: String

  var privacySafeErrorCategory: String {
    "sync_recovery:\(bucketKind):\(phase)"
  }
}
