import InlineKit
import Logger
import UIKit

// MARK: - Height Management

extension ComposeView {
  func textViewHeightByContentHeight(_ contentHeight: CGFloat) -> CGFloat {
    let newHeight = min(maxHeight, max(Self.minHeight, contentHeight + Self.textViewVerticalPadding * 2))
    return newHeight
  }

  func updateHeight() {
    let size = textView.sizeThatFits(CGSize(
      width: textView.bounds.width,
      height: .greatestFiniteMagnitude
    ))

    let contentHeight = size.height
    let newHeight = textViewHeightByContentHeight(contentHeight)
    guard abs(composeHeightConstraint.constant - newHeight) > 1 else { return }

    composeHeightConstraint.constant = newHeight
    superview?.layoutIfNeeded()

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
