import CoreGraphics
import Foundation

struct SendMessageAnimationProjectedTarget {
  let mode: String
  let originalCellFrame: CGRect
  let originalBubbleFrame: CGRect
  let originalTextFrame: CGRect
  let cellFrame: CGRect
  let bubbleFrame: CGRect
  let textFrame: CGRect
  let textFirstBaselineYInWindow: CGFloat

  init(
    presentation: SendMessageAnimationTargetPresentation,
    scrollWindowY: CGFloat
  ) {
    originalCellFrame = presentation.cellFrame
    originalBubbleFrame = presentation.bubbleFrame
    originalTextFrame = presentation.textFrame

    cellFrame = SendMessageAnimationGeometry.project(
      presentation.cellFrame,
      byWindowY: scrollWindowY
    )
    bubbleFrame = SendMessageAnimationGeometry.project(
      presentation.bubbleFrame,
      byWindowY: scrollWindowY
    )
    textFrame = SendMessageAnimationGeometry.project(
      presentation.textFrame,
      byWindowY: scrollWindowY
    )
    textFirstBaselineYInWindow = presentation.textFirstBaselineYInWindow + scrollWindowY
    mode = abs(scrollWindowY) > 0.5
      ? "real-cell-projected-to-scroll-target"
      : "real-cell-model"
  }
}

enum SendMessageAnimationGeometry {
  static func project(_ rect: CGRect, byWindowY windowY: CGFloat) -> CGRect {
    guard abs(windowY) > 0.5 else { return rect }
    return rect.offsetBy(dx: 0, dy: windowY)
  }

  static func rectDelta(from expected: CGRect, to actual: CGRect) -> String {
    "dx=\(String(format: "%.1f", actual.minX - expected.minX)) dy=\(String(format: "%.1f", actual.minY - expected.minY)) dw=\(String(format: "%.1f", actual.width - expected.width)) dh=\(String(format: "%.1f", actual.height - expected.height))"
  }
}
