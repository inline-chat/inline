import InlineKit
import Logger
import UIKit

// MARK: - Height Management

struct ComposeHeightChangeAnimation {
  let isAnimated: Bool
  let duration: TimeInterval
  let timingParameters: UITimingCurveProvider?

  static let immediate = ComposeHeightChangeAnimation(
    isAnimated: false,
    duration: 0,
    timingParameters: nil
  )

  static func animated(
    duration: TimeInterval,
    timingParameters: UITimingCurveProvider?
  ) -> ComposeHeightChangeAnimation {
    ComposeHeightChangeAnimation(
      isAnimated: true,
      duration: duration,
      timingParameters: timingParameters
    )
  }
}

extension ComposeView {
  func textViewHeightByContentHeight(_ contentHeight: CGFloat) -> CGFloat {
    let newHeight = min(maxHeight, max(Self.minHeight, contentHeight + Self.textViewVerticalPadding * 2))
    return newHeight
  }

  func updateHeight(
    animated: Bool = false,
    duration: TimeInterval = 0.2,
    timingParameters: UITimingCurveProvider? = nil,
    completion: (() -> Void)? = nil
  ) {
    // If textView doesn't have proper bounds yet, force a layout pass before bailing.
    if textView.bounds.width == 0 {
      superview?.layoutIfNeeded()
    }
    guard textView.bounds.width > 0 else { return }

    let size = textView.sizeThatFits(CGSize(
      width: textView.bounds.width,
      height: .greatestFiniteMagnitude
    ))

    let contentHeight = size.height
    let inputHeight = textView.isHidden ? Self.minHeight : textViewHeightByContentHeight(contentHeight)
    let embedHeight = embedContainerHeightConstraint?.constant ?? 0
    let attachmentHeight = attachmentContainerHeightConstraint?.constant ?? 0
    let newHeight = inputHeight + embedHeight + attachmentHeight
    guard abs(composeHeightConstraint.constant - newHeight) > 1 else { return }

    composeHeightConstraint.constant = newHeight
    onHeightChange?(
      newHeight,
      animated
        ? .animated(duration: duration, timingParameters: timingParameters)
        : .immediate
    )

    if animated {
      if let timingParameters {
        let animator = UIViewPropertyAnimator(duration: duration, timingParameters: timingParameters)
        animator.addAnimations {
          self.superview?.layoutIfNeeded()
        }
        animator.addCompletion { _ in
          completion?()
        }
        animator.startAnimation()
      } else {
        UIView.animate(withDuration: duration) {
          self.superview?.layoutIfNeeded()
        } completion: { _ in
          completion?()
        }
      }
    } else {
      superview?.layoutIfNeeded()
      completion?()
    }

    DispatchQueue.main.async {
      let bottomRange = NSRange(location: self.textView.text.count, length: 0)
      self.textView.scrollRangeToVisible(bottomRange)
    }

  }

  func resetHeight(animated: Bool = true) {
    if animated {
      UIView.animate(withDuration: 0.2) {
        self.composeHeightConstraint.constant = Self.minHeight
        self.superview?.layoutIfNeeded()
      }
    } else {
      composeHeightConstraint.constant = Self.minHeight
      superview?.layoutIfNeeded()
    }
    onHeightChange?(
      Self.minHeight,
      animated
        ? .animated(duration: 0.2, timingParameters: nil)
        : .immediate
    )
  }
}
