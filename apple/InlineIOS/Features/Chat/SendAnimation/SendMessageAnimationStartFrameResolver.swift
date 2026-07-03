import UIKit

struct SendMessageAnimationStartFrameResolution {
  let frame: CGRect
  let verticalAnchorProgress: CGFloat
  let sourceAnchorY: CGFloat
  let targetAnchorYInBubble: CGFloat
}

enum SendMessageAnimationStartFrameResolver {
  static func resolve(
    source: SendMessageAnimationSource,
    target: SendMessageAnimationTarget
  ) -> SendMessageAnimationStartFrameResolution {
    let sourceTextFrame = source.sourceVisibleTextFrameInWindow
    let targetTextFrame = target.textFrameInBubble
    let verticalAnchorProgress = verticalAnchorProgress(
      sourceTextHeight: sourceTextFrame.height,
      targetTextHeight: targetTextFrame.height,
      lineHeight: source.sourceLineHeight
    )
    let sourceAnchorY = interpolate(
      from: source.sourceTextFirstBaselineYInWindow,
      to: sourceTextFrame.maxY,
      progress: verticalAnchorProgress
    )
    let targetAnchorYInBubble = interpolate(
      from: target.textFirstBaselineYInBubble,
      to: targetTextFrame.maxY,
      progress: verticalAnchorProgress
    )
    let startFrame = CGRect(
      x: sourceTextFrame.minX - targetTextFrame.minX,
      y: sourceAnchorY - targetAnchorYInBubble,
      width: target.bubbleFrameInWindow.width,
      height: target.bubbleFrameInWindow.height
    )

    return SendMessageAnimationStartFrameResolution(
      frame: startFrame,
      verticalAnchorProgress: verticalAnchorProgress,
      sourceAnchorY: sourceAnchorY,
      targetAnchorYInBubble: targetAnchorYInBubble
    )
  }

  private static func verticalAnchorProgress(
    sourceTextHeight: CGFloat,
    targetTextHeight: CGFloat,
    lineHeight: CGFloat
  ) -> CGFloat {
    let textHeight = max(sourceTextHeight, targetTextHeight)
    let baselineLimit = lineHeight * 1.45
    let bottomLimit = lineHeight * 2.65
    guard bottomLimit > baselineLimit else { return 0 }

    return min(1, max(0, (textHeight - baselineLimit) / (bottomLimit - baselineLimit)))
  }

  private static func interpolate(
    from start: CGFloat,
    to end: CGFloat,
    progress: CGFloat
  ) -> CGFloat {
    start + (end - start) * min(1, max(0, progress))
  }
}
