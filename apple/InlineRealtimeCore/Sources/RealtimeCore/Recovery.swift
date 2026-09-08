/// Discovery checkpoints cannot pass the exact child targets they introduced.
struct Discovery: Sendable {
  var after: Int64
  var requested = true
  var pending: OperationID?
  var checkpoint: Int64?
  var targets: [BucketID: Int64] = [:]
  var retryAt: Tick?
}
