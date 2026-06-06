import InlineProtocol

public extension Dialog {
  var isFollowingReplyThread: Bool {
    followMode == .following
  }
}
