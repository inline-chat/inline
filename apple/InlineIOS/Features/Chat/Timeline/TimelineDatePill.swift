import UIKit

/// The timeline's small labels (day badges, the unread line, notices) grow with the reader's text size
/// as message text does: 12 pt at the default size, where every row keeps the collection view's height,
/// up to `maximumPointSize`. A row grows by as much as its text's line does; it never shrinks below
/// its default height.
@MainActor
enum TimelineLabelMetrics {
  /// The largest accessibility sizes would make a 40 pt date; these labels stop growing here.
  static let maximumPointSize: CGFloat = 28
  private static let defaultLine = font(traits: UITraitCollection(preferredContentSizeCategory: .large)).lineHeight

  /// `size` is the point size at the default text size.
  static func font(size: CGFloat = 12, weight: UIFont.Weight = .regular, traits: UITraitCollection?) -> UIFont {
    // A view not in a window yet has no text size of its own: the app's is used.
    let traits = traits?.preferredContentSizeCategory == .unspecified ? nil : traits
    return UIFontMetrics(forTextStyle: .caption1).scaledFont(
      for: .systemFont(ofSize: size, weight: weight),
      maximumPointSize: maximumPointSize * size / 12,
      compatibleWith: traits
    )
  }

  /// Asked on every frame of a scroll (the floating date) and for every label row measured.
  private static var growthByCategory: [UIContentSizeCategory: CGFloat] = [:]

  /// How much taller than at the default size the labels' rows are.
  static func growth(_ traits: UITraitCollection) -> CGFloat {
    let category = traits.preferredContentSizeCategory
    if let cached = growthByCategory[category] { return cached }
    let value = growth(line: font(traits: traits).lineHeight)
    // Without a size of its own the app's is used, which can change.
    if category != .unspecified { growthByCategory[category] = value }
    return value
  }

  static func growth(line: CGFloat) -> CGFloat { max(0, ceil(line - defaultLine)) }

  static func dayRowHeight(_ traits: UITraitCollection) -> CGFloat { 44 + growth(traits) }
  static func unreadRowHeight(_ traits: UITraitCollection) -> CGFloat { 34 + growth(traits) }
  static func noticeRowHeight(_ traits: UITraitCollection) -> CGFloat { 30 + growth(traits) }
  static func actionRowHeight(_ traits: UITraitCollection) -> CGFloat { 44 + growth(traits) }
}

/// The day badge of the timeline list, drawn like `DateSeparatorView` (which is built for the
/// inverted collection view): a 12 pt label in a 20 pt capsule at the default text size, growing
/// with it, glass while it floats over the messages, plain text inline. Both take a tap when given
/// one, as every collection view badge did.
@MainActor
final class TimelineDatePill: UIView {
  /// The strip a day badge stands in, floating or as a row.
  static func height(_ traits: UITraitCollection) -> CGFloat { TimelineLabelMetrics.dayRowHeight(traits) }

  private let effectView: UIVisualEffectView
  private let label = UILabel()
  private var title = ""
  var onTap: (() -> Void)? {
    didSet { isUserInteractionEnabled = onTap != nil }
  }

  /// True while the pill should let touches through to the list behind it.
  var passesTouches: (() -> Bool)?

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
    label.font = TimelineLabelMetrics.font(traits: nil)
    label.adjustsFontForContentSizeCategory = true
    label.textColor = floating ? .label : .secondaryLabel
    label.textAlignment = .center
    addSubview(effectView)
    effectView.contentView.addSubview(label)
    addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap)))
    isAccessibilityElement = true
    accessibilityTraits = .button
    isUserInteractionEnabled = false
    // The label takes the new size by itself; its capsule is sized here.
    registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (pill: TimelineDatePill, _) in
      pill.setNeedsLayout()
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
    let capsule = 20 + TimelineLabelMetrics.growth(line: label.font.lineHeight)
    let size = label.sizeThatFits(CGSize(width: bounds.width - 48, height: capsule))
    let width = min(bounds.width - 32, ceil(size.width) + 16)
    // Two points above centre, as the collection view's badge sits.
    effectView.frame = CGRect(
      x: (bounds.width - width) / 2, y: (bounds.height - capsule) / 2 - 2, width: width, height: capsule
    )
    label.frame = effectView.contentView.bounds
    if #unavailable(iOS 26.0) { effectView.layer.cornerRadius = capsule / 2 }
  }

  /// Only the capsule takes touches; the rest of the strip passes them to the list.
  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    guard alpha > 0.01, !isHidden, passesTouches?() != true else { return false }
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
