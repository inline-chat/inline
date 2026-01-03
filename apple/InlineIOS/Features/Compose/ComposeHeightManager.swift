import InlineKit
import Logger
import UIKit

// MARK: - Height Management

extension ComposeView {
  func textViewHeightByContentHeight(_ contentHeight: CGFloat) -> CGFloat {
    let newHeight = min(maxHeight, max(Self.minHeight, contentHeight + Self.textViewVerticalPadding * 2))
    return newHeight
  }

  func updateHeight(animated: Bool = false, completion: (() -> Void)? = nil) {
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
    let embedHeight = embedContainerHeightConstraint?.constant ?? 0
    let newHeight = textViewHeightByContentHeight(contentHeight) + embedHeight
    guard abs(composeHeightConstraint.constant - newHeight) > 1 else { return }

    composeHeightConstraint.constant = newHeight
    if animated {
      UIView.animate(withDuration: 0.2) {
        self.superview?.layoutIfNeeded()
      } completion: { _ in
        completion?()
      }
    } else {
      superview?.layoutIfNeeded()
      completion?()
    }

    DispatchQueue.main.async {
      let bottomRange = NSRange(location: self.textView.text.count, length: 0)
      self.textView.scrollRangeToVisible(bottomRange)
    }

    onHeightChange?(newHeight)
  }

  func resetHeight() {
    UIView.animate(withDuration: 0.2) {
      self.composeHeightConstraint.constant = Self.minHeight
      self.superview?.layoutIfNeeded()
    }
    onHeightChange?(Self.minHeight)
  }
}
