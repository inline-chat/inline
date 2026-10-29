import InlineMessageLayout
import UIKit

/// Metrics of the platform menu the custom menu imitates: Liquid Glass on iOS 26 and later
/// (measured from UIKit's own menu on iOS 27.2), the blurred platter before it.
struct MessageContextMenuStyle {
  enum Platter {
    /// iOS 26: a glass platter, leading icons, rounded row highlight, lines between sections.
    case glass
    /// iOS 18–25: a material platter, trailing icons, hairlines between rows, bands between
    /// sections.
    case material
  }

  var platter: Platter
  var cornerRadius: CGFloat
  var minimumWidth: CGFloat = 250
  var maximumWidth: CGFloat = 290
  /// Room above the first row and below the last.
  var verticalPadding: CGFloat
  var rowSideInset: CGFloat
  var rowVerticalInset: CGFloat
  /// Width of the column the row icon is centered in.
  var iconSlotWidth: CGFloat = 26
  var iconTitleSpacing: CGFloat
  var showsRowSeparators: Bool
  /// Height of the space between sections.
  var sectionSpacing: CGFloat
  /// Horizontal inset of the highlighted row's fill; zero fills the row edge to edge.
  var highlightInset: CGFloat
  var highlightCornerRadius: CGFloat = 20
  var minimumRowHeight: CGFloat = 44
  /// Inset of the line between sections, from both sides.
  var separatorInset: CGFloat = 0
  /// Thickness of the line between sections; nil draws a hairline.
  var separatorThickness: CGFloat?

  var iconsLead: Bool { platter == .glass }

  /// UIKit's menu on iOS 27.2: 250 wide, 42-point rows, 10 above the first row and below the
  /// last, icons centered 40 from the leading edge, titles at 64, 28 to the trailing edge, and
  /// sections 21 apart with a 1-point line inset 24.
  static let glass: MessageContextMenuStyle = {
    var style = MessageContextMenuStyle(
      platter: .glass,
      cornerRadius: 28,
      verticalPadding: 10,
      rowSideInset: 28,
      rowVerticalInset: 10,
      iconTitleSpacing: 12,
      showsRowSeparators: false,
      sectionSpacing: 21,
      highlightInset: 10
    )
    style.iconSlotWidth = 24
    style.minimumRowHeight = 42
    style.separatorInset = 24
    style.separatorThickness = 1
    return style
  }()

  static let material = MessageContextMenuStyle(
    platter: .material,
    cornerRadius: 13,
    verticalPadding: 0,
    rowSideInset: 16,
    rowVerticalInset: 11,
    iconTitleSpacing: 12,
    showsRowSeparators: true,
    sectionSpacing: 8,
    highlightInset: 0
  )

  static var current: MessageContextMenuStyle {
    if #available(iOS 26.0, *) { .glass } else { .material }
  }

  // MARK: - Type and color

  var titleFont: UIFont {
    UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 17), maximumPointSize: 28)
  }

  var headerFont: UIFont {
    UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 17, weight: .semibold), maximumPointSize: 28)
  }

  var subtitleFont: UIFont {
    UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .systemFont(ofSize: 13), maximumPointSize: 22)
  }

  var iconConfiguration: UIImage.SymbolConfiguration {
    UIImage.SymbolConfiguration(font: titleFont, scale: .medium)
  }

  var highlightColor: UIColor {
    UIColor.label.withAlphaComponent(platter == .glass ? 0.1 : 0.12)
  }

  var rowSeparatorColor: UIColor { .separator }

  var sectionSeparatorColor: UIColor {
    UIColor.label.withAlphaComponent(platter == .glass ? 0.08 : 0.07)
  }

  /// The menu's container. On iOS 26 it is interactive glass, so it answers touches the way the
  /// system menu does; its corners come from the glass so its edge highlight isn't clipped.
  func makePlatter() -> UIVisualEffectView {
    if #available(iOS 26.0, *), platter == .glass {
      let glass = UIGlassEffect(style: .regular)
      glass.isInteractive = true
      let view = UIVisualEffectView(effect: glass)
      view.cornerConfiguration = .corners(radius: .fixed(Double(cornerRadius)))
      return view
    }
    let view = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    view.layer.cornerRadius = cornerRadius
    view.layer.cornerCurve = .continuous
    view.clipsToBounds = true
    return view
  }
}

/// Timing of the menu. Defaults are Telegram iOS's context controller.
struct MessageContextMenuMotion {
  /// Hold before the source starts shrinking, then the shrink before the menu opens.
  var pressDelay: Double = 0.12
  var pressDuration: Double = 0.2
  /// The opening spring: Core Animation's mass 5, stiffness 900 spring with `springDamping`,
  /// its settling time compressed into `springDuration`.
  var springDuration: Double = 0.42
  var springDamping: CGFloat = 104
  var backgroundDuration: Double = 0.2
  var dismissDuration: Double = 0.2
  /// Opening a submenu and changing rows: Telegram's 0.45 s page spring, without bounce.
  var pageSpringDuration: Double = 0.45

  static let standard = MessageContextMenuMotion()

  /// The source's scale at the end of the press: 15 points narrower, never below 70%.
  static func pressedScale(forWidth width: CGFloat) -> CGFloat {
    guard width > 0 else { return 1 }
    return max(0.7, (width - 15) / width)
  }
}

/// Everything about one menu that a host may tune; the lab changes it live.
struct MessageContextMenuConfiguration {
  var style = MessageContextMenuStyle.current
  var motion = MessageContextMenuMotion.standard
  /// UIKit puts its menu 16 below the lifted bubble.
  var layoutMetrics = ContextMenuLayout.Metrics(previewMenuSpacing: 16)
  /// Blur behind the menu; nil leaves only the dim.
  var backgroundBlur: UIBlurEffect.Style? = .systemUltraThinMaterial
  var dimColor = UIColor { traits in
    traits.userInterfaceStyle == .dark ? UIColor(white: 0, alpha: 0.4) : UIColor(white: 0, alpha: 0.12)
  }

  static var standard: MessageContextMenuConfiguration { MessageContextMenuConfiguration() }
}

extension CALayer {
  /// Adds Telegram's context-menu spring for `keyPath`. Additive springs run from an offset to
  /// zero on top of the model value, so they compose with any later move.
  func addContextMenuSpring(
    _ keyPath: String,
    from: Any,
    to: Any,
    additive: Bool,
    motion: MessageContextMenuMotion,
    completion: (() -> Void)? = nil
  ) {
    let animation = CASpringAnimation(keyPath: keyPath)
    animation.mass = 5
    animation.stiffness = 900
    animation.damping = motion.springDamping
    animation.initialVelocity = 0
    animation.duration = animation.settlingDuration
    animation.fromValue = from
    animation.toValue = to
    animation.isAdditive = additive
    animation.timingFunction = CAMediaTimingFunction(name: .linear)
    animation.isRemovedOnCompletion = true
    if motion.springDuration > 0 {
      animation.speed = Float(animation.duration / motion.springDuration)
    }
    CATransaction.begin()
    CATransaction.setCompletionBlock(completion)
    add(animation, forKey: additive ? "contextMenu.\(keyPath).\(UUID().uuidString)" : "contextMenu.\(keyPath)")
    CATransaction.commit()
  }

  /// Settles running animations where they are on screen, so a new animation starts there.
  func freezeContextMenuAnimations() {
    if let presentation = presentation() {
      position = presentation.position
      bounds = presentation.bounds
      transform = presentation.transform
      opacity = presentation.opacity
    }
    removeAllAnimations()
  }
}
