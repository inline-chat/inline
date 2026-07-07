import InlineProtocol

public extension Dialog {
  var isFollowingThread: Bool {
    followMode == .following
  }

  var isUnfollowedThread: Bool {
    followMode == .unfollowed
  }

  var isFollowingReplyThread: Bool {
    isFollowingThread
  }
}
