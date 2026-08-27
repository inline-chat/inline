import CoreGraphics

public enum MessageAvatarSwipeOverlap {
  public static func firstOverlappingIndex(
    messageFrame: CGRect,
    avatarFrames: [CGRect]
  ) -> Int? {
    guard isValid(messageFrame) else { return nil }

    return avatarFrames.firstIndex { avatarFrame in
      guard isValid(avatarFrame) else { return false }
      let intersection = messageFrame.intersection(avatarFrame)
      return !intersection.isNull && intersection.width > 0 && intersection.height > 0
    }
  }

  private static func isValid(_ frame: CGRect) -> Bool {
    frame.origin.x.isFinite &&
      frame.origin.y.isFinite &&
      frame.width.isFinite &&
      frame.height.isFinite &&
      frame.width > 0 &&
      frame.height > 0
  }
}
