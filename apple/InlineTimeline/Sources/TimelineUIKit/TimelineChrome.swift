#if canImport(UIKit)
import UIKit

/// The list's scroll indicator: a thin capsule drawn as UIScrollView's default style draws its own.
/// The list places it; it never takes touches.
final class TimelineScrollIndicatorView: UIView {
  static let width: CGFloat = 3
  /// From the list's trailing edge, and from each end of the usable area.
  static let inset: CGFloat = 3
  static let minimumLength: CGFloat = 36

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    isAccessibilityElement = false
    accessibilityElementsHidden = true
    layer.anchorPoint = CGPoint(x: 0, y: 0)
    layer.cornerRadius = Self.width / 2
    layer.cornerCurve = .circular
    // UIScrollView's `.default` style as iOS 27 draws it: black at 0.35 on light (pixel for pixel
    // against the collection view's), white at 0.5 on dark (its fill view's colour, read at run time).
    // Minimum length 36 pt, as UIKit's indicators on short scroll views.
    backgroundColor = UIColor { traits in
      traits.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.5) : UIColor(white: 0, alpha: 0.35)
    }
    alpha = 0
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// The status bar's tap reaches only a UIScrollView with `scrollsToTop`. The list has none, so this
/// one stands in: never shown, never touched (the content covers it), always "scrolled" so UIKit
/// asks it, and it answers by calling `action` instead of scrolling. Telegram's `ScrollToTopView`.
final class TimelineScrollToTopProxy: UIScrollView, UIScrollViewDelegate {
  var action: (() -> Void)? {
    didSet { scrollsToTop = action != nil }
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    delegate = self
    scrollsToTop = false
    contentInsetAdjustmentBehavior = .never
    showsVerticalScrollIndicator = false
    showsHorizontalScrollIndicator = false
    isOpaque = false
    isAccessibilityElement = false
    accessibilityElementsHidden = true
    if #available(iOS 17.0, *) { allowsKeyboardScrolling = false }
    if #available(iOS 26.0, *) {
      // Never visible, so it must not blur what passes under the bars either.
      topEdgeEffect.isHidden = true
      bottomEdgeEffect.isHidden = true
      leftEdgeEffect.isHidden = true
      rightEdgeEffect.isHidden = true
    }
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override var frame: CGRect {
    didSet {
      guard frame.size != oldValue.size else { return }
      contentSize = CGSize(width: frame.width, height: frame.height + 1000)
      contentOffset = CGPoint(x: 0, y: 1000)
    }
  }

  func scrollViewShouldScrollToTop(_: UIScrollView) -> Bool {
    action?()
    return false
  }
}
#endif
