import InlineKit
import UIKit

private final class ScrollGlassButton: UIButton {
  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    bounds.insetBy(dx: -5, dy: -5).contains(point)
  }
}

/// Floating chat button (scroll-to-bottom, @, ♥). Matches the compose plus button: a 42pt glass
/// circle with a 16pt medium glyph, with an optional count capsule on its top trailing edge.
final class BlurCircleButton: UIView {
  /// The visible circle, the compose plus button's size.
  static let visualSize: CGFloat = 42
  static let hitTargetSize: CGFloat = 44
  /// How far the hit target extends past the circle on each side.
  static let hitOutset: CGFloat = (hitTargetSize - visualSize) / 2
  /// Gap between stacked buttons, and between the bottom one and compose.
  static let stackSpacing: CGFloat = 8

  private enum Metrics {
    static let hitTargetSize = BlurCircleButton.hitTargetSize
    static let visualSize = BlurCircleButton.visualSize
    static let iconPointSize: CGFloat = 16
    static let hiddenTranslationY: CGFloat = 12
    static let hiddenScale: CGFloat = 0.86
    static let visibilityDuration: TimeInterval = 0.3
    static let reduceMotionDuration: TimeInterval = 0.14
  }

  private lazy var button: UIButton = {
    let button = ScrollGlassButton(type: .custom)
    button.translatesAutoresizingMaskIntoConstraints = false

    let image = UIImage(systemName: symbolName)?.withConfiguration(
      UIImage.SymbolConfiguration(pointSize: Metrics.iconPointSize, weight: .medium)
    )

    if #available(iOS 26.0, *) {
      var configuration = UIButton.Configuration.glass()
      configuration.image = image
      configuration.baseForegroundColor = symbolTint
      configuration.contentInsets = .zero
      configuration.cornerStyle = .capsule
      button.configuration = configuration
    } else {
      var configuration = UIButton.Configuration.plain()
      configuration.image = image
      configuration.baseForegroundColor = symbolTint
      configuration.contentInsets = .zero
      button.configuration = configuration
    }

    button.addTarget(self, action: #selector(buttonTapped), for: .touchUpInside)
    button.accessibilityLabel = accessibilityTitle
    button.isPointerInteractionEnabled = true
    return button
  }()

  private lazy var fallbackBlurView: UIVisualEffectView = {
    let view = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
    view.translatesAutoresizingMaskIntoConstraints = false
    view.isUserInteractionEnabled = false
    view.backgroundColor = ThemeManager.shared.selected.backgroundColor.withAlphaComponent(0.6)
    view.layer.cornerRadius = Metrics.visualSize / 2
    view.layer.cornerCurve = .continuous
    view.clipsToBounds = true
    return view
  }()

  private lazy var countBadge = FloatingButtonCountBadge(
    // The count matches a colored symbol (heart); the default chevron button uses the accent.
    tint: symbolTint == .label ? ThemeManager.shared.selected.accent : symbolTint
  )
  private let symbolName: String
  private let symbolTint: UIColor
  private let accessibilityTitle: String
  private var desiredVisibility = false
  private var visibilityAnimationGeneration = 0
  private var visibilityAnimator: UIViewPropertyAnimator?

  var onTap: (() -> Void)?

  private static let hiddenTransform = CGAffineTransform(
    translationX: 0,
    y: Metrics.hiddenTranslationY
  ).scaledBy(x: Metrics.hiddenScale, y: Metrics.hiddenScale)

  init(
    symbolName: String = "chevron.down",
    tint: UIColor = .label,
    accessibilityTitle: String = "Scroll to Bottom"
  ) {
    self.symbolName = symbolName
    symbolTint = tint
    self.accessibilityTitle = accessibilityTitle
    super.init(frame: .zero)
    setup()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    visibilityAnimationGeneration += 1
    let generation = visibilityAnimationGeneration
    stopVisibilityAnimationAtCurrentState()

    guard window != nil else {
      applyVisibility(false, includesMotion: true)
      return
    }

    guard desiredVisibility else {
      applyVisibility(false, includesMotion: true)
      return
    }

    // Visibility is commonly resolved while the chat hierarchy is still offscreen.
    // Keep the hidden presentation through the first commit, then animate it in.
    applyVisibility(false, includesMotion: true)
    DispatchQueue.main.async { [weak self] in
      guard let self,
            self.window != nil,
            self.desiredVisibility,
            self.visibilityAnimationGeneration == generation
      else { return }
      self.startVisibilityAnimation(true, generation: generation)
    }
  }

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    guard !isHidden,
          alpha > 0.01,
          isUserInteractionEnabled,
          bounds.contains(point)
    else { return nil }
    return button.hitTest(convert(point, to: button), with: event)
  }

  private func setup() {
    translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      widthAnchor.constraint(equalToConstant: Metrics.hitTargetSize),
      heightAnchor.constraint(equalToConstant: Metrics.hitTargetSize),
    ])

    if #unavailable(iOS 26.0) {
      addSubview(fallbackBlurView)
      NSLayoutConstraint.activate([
        fallbackBlurView.centerXAnchor.constraint(equalTo: centerXAnchor),
        fallbackBlurView.centerYAnchor.constraint(equalTo: centerYAnchor),
        fallbackBlurView.widthAnchor.constraint(equalToConstant: Metrics.visualSize),
        fallbackBlurView.heightAnchor.constraint(equalToConstant: Metrics.visualSize),
      ])
    }

    addSubview(button)
    NSLayoutConstraint.activate([
      button.centerXAnchor.constraint(equalTo: centerXAnchor),
      button.centerYAnchor.constraint(equalTo: centerYAnchor),
      button.widthAnchor.constraint(equalToConstant: Metrics.visualSize),
      button.heightAnchor.constraint(equalToConstant: Metrics.visualSize),
    ])

    addSubview(countBadge)
    NSLayoutConstraint.activate([
      countBadge.centerYAnchor.constraint(equalTo: button.topAnchor, constant: 3),
      countBadge.centerXAnchor.constraint(equalTo: button.trailingAnchor, constant: -4),
    ])

    isHidden = false
    alpha = 0
    transform = Self.hiddenTransform
    isUserInteractionEnabled = false
    accessibilityElementsHidden = true
  }

  @objc private func buttonTapped() {
    onTap?()
  }

  func setVisible(_ visible: Bool, animated: Bool = true) {
    guard desiredVisibility != visible else { return }

    desiredVisibility = visible
    visibilityAnimationGeneration += 1
    let generation = visibilityAnimationGeneration
    stopVisibilityAnimationAtCurrentState()
    isUserInteractionEnabled = visible
    accessibilityElementsHidden = !visible

    // Preserve the hidden presentation until didMoveToWindow can start an
    // observable transition. Applying the target here made first appearance snap.
    guard window != nil else {
      applyVisibility(false, includesMotion: true)
      return
    }

    guard animated else {
      UIView.performWithoutAnimation {
        applyVisibility(visible, includesMotion: true)
      }
      return
    }

    startVisibilityAnimation(visible, generation: generation)
  }

  private func startVisibilityAnimation(_ visible: Bool, generation: Int) {
    stopVisibilityAnimationAtCurrentState()

    let reduceMotion = UIAccessibility.isReduceMotionEnabled
    let animator: UIViewPropertyAnimator
    if reduceMotion {
      transform = .identity
      animator = UIViewPropertyAnimator(duration: Metrics.reduceMotionDuration, curve: .easeInOut)
    } else {
      let timing = UISpringTimingParameters(
        dampingRatio: 0.84,
        initialVelocity: .zero
      )
      animator = UIViewPropertyAnimator(duration: Metrics.visibilityDuration, timingParameters: timing)
    }

    visibilityAnimator = animator
    animator.addAnimations { [weak self] in
      guard let self else { return }
      if reduceMotion {
        self.alpha = visible ? 1 : 0
      } else {
        self.applyVisibility(visible, includesMotion: true)
      }
    }
    animator.addCompletion { [weak self, weak animator] _ in
      guard let self,
            let animator,
            self.visibilityAnimator === animator,
            self.visibilityAnimationGeneration == generation
      else { return }
      self.visibilityAnimator = nil
    }
    animator.startAnimation()
  }

  private func stopVisibilityAnimationAtCurrentState() {
    guard let animator = visibilityAnimator else { return }
    visibilityAnimator = nil
    guard animator.state == .active else { return }

    let presentationAlpha = layer.presentation()?.opacity
    let presentationTransform = layer.presentation()?.affineTransform()
    animator.stopAnimation(true)

    if let presentationAlpha {
      alpha = CGFloat(presentationAlpha)
    }
    if let presentationTransform {
      transform = presentationTransform
    }
  }

  private func applyVisibility(_ visible: Bool, includesMotion: Bool) {
    alpha = visible ? 1 : 0
    if includesMotion {
      transform = visible ? .identity : Self.hiddenTransform
    } else {
      transform = .identity
    }
  }

  /// Count capsule on the top trailing edge; zero hides it.
  func setCount(_ count: Int) {
    countBadge.setCount(count, animated: window != nil && alpha > 0.01)
    button.accessibilityValue = count > 0 ? "\(count)" : nil
  }

  /// Shown on long-press; the tap still runs `onTap`.
  func setMenu(_ menu: UIMenu?) {
    button.menu = menu
    button.showsMenuAsPrimaryAction = false
  }
}

/// Count capsule for a floating button. Digits cross-fade as the count changes; it scales in
/// and out when the count reaches or leaves zero.
private final class FloatingButtonCountBadge: UIView {
  private enum Metrics {
    static let height: CGFloat = 18
    static let horizontalPadding: CGFloat = 5
    static let hiddenScale: CGFloat = 0.5
  }

  private let label = UILabel()
  private var count = 0

  init(tint: UIColor) {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    isUserInteractionEnabled = false
    backgroundColor = tint
    layer.cornerRadius = Metrics.height / 2
    layer.cornerCurve = .continuous

    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
    label.textColor = .white
    label.textAlignment = .center
    label.adjustsFontForContentSizeCategory = false
    addSubview(label)
    NSLayoutConstraint.activate([
      heightAnchor.constraint(equalToConstant: Metrics.height),
      widthAnchor.constraint(greaterThanOrEqualToConstant: Metrics.height),
      label.centerYAnchor.constraint(equalTo: centerYAnchor),
      label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.horizontalPadding),
      label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.horizontalPadding),
    ])

    alpha = 0
    transform = CGAffineTransform(scaleX: Metrics.hiddenScale, y: Metrics.hiddenScale)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func setCount(_ newCount: Int, animated: Bool) {
    let newCount = max(0, newCount)
    guard newCount != count else { return }
    let wasVisible = count > 0
    let isVisible = newCount > 0
    count = newCount

    let animated = animated && !UIAccessibility.isReduceMotionEnabled
    if isVisible {
      let text = ChatUnreadBadgeCount.format(newCount)
      if animated, wasVisible, label.text != text {
        UIView.transition(with: label, duration: 0.15, options: [.transitionCrossDissolve, .beginFromCurrentState]) {
          self.label.text = text
        }
      } else {
        label.text = text
      }
    }
    guard wasVisible != isVisible else { return }

    let apply = {
      self.alpha = isVisible ? 1 : 0
      self.transform = isVisible ? .identity : CGAffineTransform(scaleX: Metrics.hiddenScale, y: Metrics.hiddenScale)
    }
    guard animated else {
      UIView.performWithoutAnimation(apply)
      return
    }
    UIView.animate(
      withDuration: 0.25,
      delay: 0,
      usingSpringWithDamping: 0.8,
      initialSpringVelocity: 0,
      options: [.beginFromCurrentState, .allowUserInteraction],
      animations: apply
    )
  }
}
