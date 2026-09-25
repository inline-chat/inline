import UIKit

private final class ScrollGlassButton: UIButton {
  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    bounds.insetBy(dx: -5, dy: -5).contains(point)
  }
}

final class BlurCircleButton: UIView {
  private enum Metrics {
    static let hitTargetSize: CGFloat = 44
    static let visualSize: CGFloat = 34
    static let iconPointSize: CGFloat = 16
    static let hiddenTranslationY: CGFloat = 12
    static let hiddenScale: CGFloat = 0.9
    static let visibilityDuration: TimeInterval = 0.22
    static let reduceMotionDuration: TimeInterval = 0.14
  }

  private lazy var button: UIButton = {
    let button = ScrollGlassButton(type: .custom)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.adjustsImageSizeForAccessibilityContentSizeCategory = true

    let image = UIImage(systemName: "chevron.down")?.withConfiguration(
      UIImage.SymbolConfiguration(textStyle: .body).applying(UIImage.SymbolConfiguration(weight: .semibold))
    )

    if #available(iOS 26.0, *) {
      var configuration = UIButton.Configuration.glass()
      configuration.image = image
      configuration.baseForegroundColor = .label
      configuration.contentInsets = .zero
      configuration.cornerStyle = .capsule
      button.configuration = configuration
    } else {
      var configuration = UIButton.Configuration.plain()
      configuration.image = image
      configuration.baseForegroundColor = .label
      configuration.contentInsets = .zero
      button.configuration = configuration
    }

    button.addTarget(self, action: #selector(buttonTapped), for: .touchUpInside)
    button.accessibilityLabel = "Scroll to Bottom"
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

  private let unreadBadgeView = UIView()
  private var desiredVisibility = false
  private var visibilityAnimationGeneration = 0
  private var visibilityAnimator: UIViewPropertyAnimator?

  var onTap: (() -> Void)?

  private static let hiddenTransform = CGAffineTransform(
    translationX: 0,
    y: Metrics.hiddenTranslationY
  ).scaledBy(x: Metrics.hiddenScale, y: Metrics.hiddenScale)

  override init(frame: CGRect) {
    super.init(frame: frame)
    setup()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setup()
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

  override func layoutSubviews() {
    super.layoutSubviews()
    if #unavailable(iOS 26.0) {
      fallbackBlurView.layer.cornerRadius = fallbackBlurView.bounds.height / 2
    }
    unreadBadgeView.layer.cornerRadius = unreadBadgeView.bounds.height / 2
  }

  private func setup() {
    translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      widthAnchor.constraint(equalToConstant: Metrics.hitTargetSize).scaledForContentSize(),
      heightAnchor.constraint(equalToConstant: Metrics.hitTargetSize).scaledForContentSize(),
    ])

    if #unavailable(iOS 26.0) {
      addSubview(fallbackBlurView)
      NSLayoutConstraint.activate([
        fallbackBlurView.centerXAnchor.constraint(equalTo: centerXAnchor),
        fallbackBlurView.centerYAnchor.constraint(equalTo: centerYAnchor),
        fallbackBlurView.widthAnchor.constraint(equalToConstant: Metrics.visualSize).scaledForContentSize(),
        fallbackBlurView.heightAnchor.constraint(equalToConstant: Metrics.visualSize).scaledForContentSize(),
      ])
    }

    addSubview(button)
    NSLayoutConstraint.activate([
      button.centerXAnchor.constraint(equalTo: centerXAnchor),
      button.centerYAnchor.constraint(equalTo: centerYAnchor),
      button.widthAnchor.constraint(equalToConstant: Metrics.visualSize).scaledForContentSize(),
      button.heightAnchor.constraint(equalToConstant: Metrics.visualSize).scaledForContentSize(),
    ])

    unreadBadgeView.translatesAutoresizingMaskIntoConstraints = false
    unreadBadgeView.backgroundColor = ThemeManager.shared.selected.accent
    unreadBadgeView.layer.cornerRadius = 3
    unreadBadgeView.isUserInteractionEnabled = false
    unreadBadgeView.isHidden = true
    addSubview(unreadBadgeView)

    NSLayoutConstraint.activate([
      unreadBadgeView.widthAnchor.constraint(equalToConstant: 6).scaledForContentSize(),
      unreadBadgeView.heightAnchor.constraint(equalToConstant: 6).scaledForContentSize(),
      unreadBadgeView.topAnchor.constraint(equalTo: button.topAnchor),
      unreadBadgeView.trailingAnchor.constraint(equalTo: button.trailingAnchor),
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

  func setHasUnread(_ hasUnread: Bool) {
    unreadBadgeView.isHidden = !hasUnread
  }
}
