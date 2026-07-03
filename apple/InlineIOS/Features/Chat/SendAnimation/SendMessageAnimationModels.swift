import Foundation
import UIKit

struct SendMessageAnimationIdentity: Hashable {
  let randomId: Int64
  let temporaryMessageId: Int64
}

struct SendMessageAnimationSource {
  let identity: SendMessageAnimationIdentity
  let text: String
  let sourceTextFrameInWindow: CGRect
  let sourceVisibleTextFrameInWindow: CGRect
  let sourceTextFirstBaselineYInWindow: CGFloat
  let sourceLineHeight: CGFloat
  let preparedAt: Date

  var isUsable: Bool {
    sourceTextFrameInWindow.isFiniteAndVisible &&
      sourceVisibleTextFrameInWindow.isFiniteAndVisible &&
      sourceTextFirstBaselineYInWindow.isFinite &&
      sourceLineHeight.isFinite &&
      sourceLineHeight > 0 &&
      !text.isEmpty
  }
}

struct SendMessageAnimationTarget {
  let identity: SendMessageAnimationIdentity
  let messageStableId: Int64
  let bubbleFrameInWindow: CGRect
  let textFrameInWindow: CGRect
  let bubbleSnapshotView: UIView
  let textFrameInBubble: CGRect
  let textFirstBaselineYInWindow: CGFloat
  let textFirstBaselineYInBubble: CGFloat
  let bubbleTailSide: MessageBubbleTailSide
}

struct SendMessageAnimationTargetStart {
  let target: SendMessageAnimationTarget
  let scrollTargetOffset: CGPoint?
  let scrollDuration: TimeInterval?
}

struct SendMessageAnimationTargetPresentation {
  let cellFrame: CGRect
  let bubbleFrame: CGRect
  let textFrame: CGRect
  let bubbleSnapshotView: UIView
  let textFrameInBubble: CGRect
  let textFirstBaselineYInWindow: CGFloat
  let textFirstBaselineYInBubble: CGFloat
}

struct SendMessageAnimationTargetGeometry {
  let cellFrame: CGRect
  let bubbleFrame: CGRect
  let textFrame: CGRect
  let textFrameInBubble: CGRect
  let textFrameInLabel: CGRect
  let textFirstBaselineYInWindow: CGFloat
  let textFirstBaselineYInBubble: CGFloat

  func offsetInWindowBy(y offsetY: CGFloat) -> SendMessageAnimationTargetGeometry {
    guard abs(offsetY) > 0.25 else { return self }
    return SendMessageAnimationTargetGeometry(
      cellFrame: cellFrame.offsetBy(dx: 0, dy: offsetY),
      bubbleFrame: bubbleFrame.offsetBy(dx: 0, dy: offsetY),
      textFrame: textFrame.offsetBy(dx: 0, dy: offsetY),
      textFrameInBubble: textFrameInBubble,
      textFrameInLabel: textFrameInLabel,
      textFirstBaselineYInWindow: textFirstBaselineYInWindow + offsetY,
      textFirstBaselineYInBubble: textFirstBaselineYInBubble
    )
  }
}

extension CGRect {
  var isFiniteAndVisible: Bool {
    !isNull &&
      !isInfinite &&
      origin.x.isFinite &&
      origin.y.isFinite &&
      size.width.isFinite &&
      size.height.isFinite &&
      width > 0 &&
      height > 0
  }
}
