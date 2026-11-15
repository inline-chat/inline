import UIKit

/// The day badge of the timeline list, drawn like `DateSeparatorView` (which is built for the
/// inverted collection view): a 12 pt label in a 20 pt capsule, glass while it floats over the
/// messages, plain text inline. The floating one is tappable.
@MainActor
final class TimelineDatePill: UIView {
  static let height: CGFloat = 44

  private let effectView: UIVisualEffectView
  private let label = UILabel()
  private var title = ""
  var onTap: (() -> Void)?

  init(floating: Bool) {
    if #available(iOS 26.0, *) {
      effectView = UIVisualEffectView(effect: nil)
      effectView.cornerConfiguration = .capsule()
      if floating {
        let glass = UIGlassEffect(style: .regular)
        glass.isInteractive = true
        effectView.effect = glass
      }
    } else {
      effectView = UIVisualEffectView(effect: floating ? UIBlurEffect(style: .systemThinMaterial) : nil)
      effectView.layer.cornerCurve = .continuous
      effectView.clipsToBounds = true
    }
    super.init(frame: .zero)
    label.font = .systemFont(ofSize: 12, weight: .regular)
    label.textColor = floating ? .label : .secondaryLabel
    label.textAlignment = .center
    addSubview(effectView)
    effectView.contentView.addSubview(label)
    if floating {
      addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap)))
      isAccessibilityElement = true
      accessibilityTraits = .button
    } else {
      isUserInteractionEnabled = false
    }
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func configure(title: String) {
    guard title != self.title else { return }
    self.title = title
    label.text = title
    accessibilityLabel = "Show first message from \(title)"
    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let size = label.sizeThatFits(CGSize(width: bounds.width - 48, height: 20))
    let width = min(bounds.width - 32, ceil(size.width) + 16)
    // Two points above centre, as the collection view's badge sits.
    effectView.frame = CGRect(x: (bounds.width - width) / 2, y: (bounds.height - 20) / 2 - 2, width: width, height: 20)
    label.frame = effectView.contentView.bounds
    if #unavailable(iOS 26.0) { effectView.layer.cornerRadius = 10 }
  }

  /// Only the capsule takes touches; the rest of the strip passes them to the list.
  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    guard alpha > 0.01, !isHidden else { return false }
    return effectView.frame.insetBy(dx: -8, dy: -12).contains(point)
  }

  func setVisible(_ visible: Bool, animated: Bool) {
    let target: CGFloat = visible ? 1 : 0
    guard alpha != target else { return }
    guard animated else {
      layer.removeAllAnimations()
      alpha = target
      return
    }
    UIView.animate(withDuration: 0.2, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
      self.alpha = target
    }
  }

  @objc private func handleTap() {
    onTap?()
  }
}
