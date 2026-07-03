import UIKit

struct SendMessageAnimationTextFrame {
  let textFrame: CGRect
  let visibleTextFrame: CGRect
  let firstBaselineY: CGFloat

  var visibleOffsetInText: CGPoint {
    CGPoint(
      x: visibleTextFrame.minX - textFrame.minX,
      y: visibleTextFrame.minY - textFrame.minY
    )
  }

  var isFullyVisible: Bool {
    let tolerance: CGFloat = 1
    return abs(visibleTextFrame.minX - textFrame.minX) <= tolerance &&
      abs(visibleTextFrame.minY - textFrame.minY) <= tolerance &&
      visibleTextFrame.width >= textFrame.width - tolerance &&
      visibleTextFrame.height >= textFrame.height - tolerance
  }
}

extension UITextView {
  func sendAnimationTextFrame() -> SendMessageAnimationTextFrame? {
    layoutIfNeeded()
    layoutManager.ensureLayout(for: textContainer)

    let glyphRange = layoutManager.glyphRange(for: textContainer)
    let glyphBounds: CGRect
    if glyphRange.length > 0 {
      glyphBounds = layoutManager.boundingRect(
        forGlyphRange: glyphRange,
        in: textContainer
      )
    } else {
      glyphBounds = CGRect(origin: .zero, size: bounds.size)
    }
    let firstBaselineY: CGFloat
    if glyphRange.length > 0 {
      firstBaselineY = textContainerInset.top +
        layoutManager.location(forGlyphAt: glyphRange.location).y -
        contentOffset.y
    } else {
      firstBaselineY = textContainerInset.top - contentOffset.y
    }

    let paddedGlyphBounds = glyphBounds
      .insetBy(dx: -Self.sendAnimationTextCropPadding, dy: -Self.sendAnimationTextCropPadding)
      .integral
    let textFrame = CGRect(
      x: textContainerInset.left + paddedGlyphBounds.minX - contentOffset.x,
      y: textContainerInset.top + paddedGlyphBounds.minY - contentOffset.y,
      width: paddedGlyphBounds.width,
      height: paddedGlyphBounds.height
    )
    let visibleTextFrame = textFrame.intersection(bounds)

    guard textFrame.isFiniteAndVisible,
          visibleTextFrame.isFiniteAndVisible
    else {
      return nil
    }

    return SendMessageAnimationTextFrame(
      textFrame: textFrame,
      visibleTextFrame: visibleTextFrame,
      firstBaselineY: firstBaselineY
    )
  }

  func sendAnimationVisibleTextFrame() -> CGRect? {
    sendAnimationTextFrame()?.visibleTextFrame
  }

  func sendAnimationVisibleTextFrameInWindow() -> CGRect? {
    guard let window else { return nil }
    guard let localFrame = sendAnimationVisibleTextFrame() else { return nil }
    let windowFrame = convert(localFrame, to: window)
    guard windowFrame.isFiniteAndVisible else { return nil }
    return windowFrame
  }

  private static var sendAnimationTextCropPadding: CGFloat {
    1.5
  }
}
