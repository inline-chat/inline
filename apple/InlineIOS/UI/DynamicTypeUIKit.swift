import UIKit

extension NSLayoutConstraint {
  /// Fixed control dimensions must grow with their symbols, including while the screen is open.
  func scaledForContentSize(relativeTo style: UIFont.TextStyle = .body) -> NSLayoutConstraint {
    guard secondItem == nil, let view = firstItem as? UIView else { return self }
    let base = constant
    constant = UIFontMetrics(forTextStyle: style).scaledValue(for: base, compatibleWith: view.traitCollection)
    view.registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { [weak self] (view: UIView, _: UITraitCollection) in
      self?.constant = UIFontMetrics(forTextStyle: style).scaledValue(for: base, compatibleWith: view.traitCollection)
      view.invalidateIntrinsicContentSize()
      view.setNeedsLayout()
    }
    return self
  }
}
