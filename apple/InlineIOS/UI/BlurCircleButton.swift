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

/// Count capsule for a floating button. Changed digits roll as the count changes, and the capsule
/// follows a count that gains or loses a digit; it scales in and out when the count reaches or
/// leaves zero.
private final class FloatingButtonCountBadge: UIView {
  private enum Metrics {
    static let height: CGFloat = 18
    static let horizontalPadding: CGFloat = 5
    static let hiddenScale: CGFloat = 0.5
  }

  private let label = RollingCountLabel(
    font: .monospacedDigitSystemFont(ofSize: 11, weight: .semibold), textColor: .white
  )
  /// The count shown.
  private var count = 0
  /// Rolls start at most this often: a fast scroll through unread lowers the count every frame, and each
  /// roll makes a label or two. A number that comes sooner waits for the next slot; the last one always shows.
  private static let minimumRollInterval: CFTimeInterval = 0.08
  private var lastRollAt: CFTimeInterval = 0
  /// Bumped by every change, so a roll waiting for its slot is dropped once a newer number comes.
  private var changeGeneration = 0

  init(tint: UIColor) {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    isUserInteractionEnabled = false
    backgroundColor = tint
    layer.cornerRadius = Metrics.height / 2
    layer.cornerCurve = .continuous
    // Digits roll inside the capsule, not over the glass around it.
    clipsToBounds = true

    label.translatesAutoresizingMaskIntoConstraints = false
    // The digits keep their own width, centered: a single digit sits in the middle of the round capsule.
    label.setContentHuggingPriority(.required, for: .horizontal)
    label.setContentCompressionResistancePriority(.required, for: .horizontal)
    addSubview(label)
    let hugsLabel = widthAnchor.constraint(equalTo: label.widthAnchor, constant: 2 * Metrics.horizontalPadding)
    hugsLabel.priority = .defaultHigh
    NSLayoutConstraint.activate([
      heightAnchor.constraint(equalToConstant: Metrics.height),
      widthAnchor.constraint(greaterThanOrEqualToConstant: Metrics.height),
      widthAnchor.constraint(greaterThanOrEqualTo: label.widthAnchor, constant: 2 * Metrics.horizontalPadding),
      hugsLabel,
      label.centerYAnchor.constraint(equalTo: centerYAnchor),
      label.centerXAnchor.constraint(equalTo: centerXAnchor),
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
    changeGeneration &+= 1
    guard newCount != count else { return }
    let wasVisible = count > 0
    let isVisible = newCount > 0
    if animated, wasVisible, isVisible {
      let now = CACurrentMediaTime()
      let wait = lastRollAt + Self.minimumRollInterval - now
      if wait > 0 {
        let generation = changeGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
          guard let self, changeGeneration == generation else { return }
          setCount(newCount, animated: animated)
        }
        return
      }
      lastRollAt = now
    }
    let falls = newCount < count
    count = newCount

    let reduceMotion = UIAccessibility.isReduceMotionEnabled
    if isVisible {
      // A capsule coming in shows its number at once; one already showing rolls the digits that
      // changed (cross-fades them with Reduce Motion), taking a digit still rolling from where it is.
      let rolls = animated && wasVisible
      let resized = label.setText(ChatUnreadBadgeCount.format(newCount), falling: falls, animated: rolls)
      if rolls, resized, !reduceMotion, let superview {
        UIView.animate(
          withDuration: RollingCountLabel.duration,
          delay: 0,
          options: [.beginFromCurrentState, .curveEaseInOut, .allowUserInteraction]
        ) {
          superview.layoutIfNeeded()
        }
      }
    }
    guard wasVisible != isVisible else { return }

    let apply = {
      self.alpha = isVisible ? 1 : 0
      self.transform = isVisible || reduceMotion
        ? .identity : CGAffineTransform(scaleX: Metrics.hiddenScale, y: Metrics.hiddenScale)
    }
    guard animated else {
      UIView.performWithoutAnimation(apply)
      return
    }
    guard !reduceMotion else {
      // Reduce Motion: the capsule fades, without the scale.
      transform = .identity
      UIView.animate(
        withDuration: 0.15, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: apply
      )
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

/// A count whose characters are each their own label, laid out from the right so the units digit
/// keeps its place as the count gains or loses digits. A changed character rolls as Telegram's
/// count does: as the count falls the old one leaves upward and the new one rises in from below
/// (the other way as it grows), both shrinking and fading over 0.2 s; a character that comes or
/// goes scales in or out. With Reduce Motion they cross-fade in place.
private final class RollingCountLabel: UIView {
  static let duration: TimeInterval = 0.2
  /// Labels still fading out. A fast scroll through unread changes the count every frame, so the
  /// oldest go at once beyond this.
  private static let maxLeaving = 8

  private let font: UIFont
  private let textColor: UIColor
  /// Right to left: the last character first.
  private var glyphs: [(character: Character, label: UILabel)] = []
  private var leaving: [UILabel] = []
  private var widths: [Character: CGFloat] = [:]
  private var contentWidth: CGFloat = 0
  private var text = ""

  init(font: UIFont, textColor: UIColor) {
    self.font = font
    self.textColor = textColor
    super.init(frame: .zero)
    isUserInteractionEnabled = false
    // The button carries the count as its accessibility value.
    accessibilityElementsHidden = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var intrinsicContentSize: CGSize {
    CGSize(width: contentWidth, height: lineHeight)
  }

  private var lineHeight: CGFloat { ceil(font.lineHeight) }

  /// Shows `newText`; true when its width changed, so the caller can move the capsule with the digits.
  @discardableResult
  func setText(_ newText: String, falling: Bool, animated: Bool) -> Bool {
    guard newText != text else { return false }
    text = newText
    let characters = Array(newText.reversed())
    let width = ceil(characters.reduce(0) { $0 + glyphWidth($1) })
    let resized = width != contentWidth
    if resized {
      contentWidth = width
      invalidateIntrinsicContentSize()
    }
    let reduceMotion = UIAccessibility.isReduceMotionEnabled
    let height = lineHeight
    // How far a leaving character travels; its replacement comes from as far the other way.
    let shift = floor(height * 0.6) * (falling ? -1 : 1)
    if !animated {
      for label in leaving { label.removeFromSuperview() }
      leaving.removeAll()
    }

    var next: [(character: Character, label: UILabel)] = []
    var right = width
    for index in 0 ..< max(characters.count, glyphs.count) {
      let old = index < glyphs.count ? glyphs[index] : nil
      guard index < characters.count else {
        // The count lost a digit.
        if let old {
          retire(old.label, to: CGAffineTransform(scaleX: 0.1, y: 0.1), animated: animated, reduceMotion: reduceMotion)
        }
        continue
      }
      let character = characters[index]
      let characterWidth = glyphWidth(character)
      right -= characterWidth
      let center = CGPoint(x: right + characterWidth / 2, y: height / 2)
      if let old, old.character == character {
        if animated, !reduceMotion {
          UIView.animate(withDuration: Self.duration, delay: 0, options: [.beginFromCurrentState, .curveEaseInOut]) {
            old.label.center = center
          }
        } else {
          old.label.layer.removeAllAnimations()
          old.label.transform = .identity
          old.label.alpha = 1
          old.label.center = center
        }
        next.append(old)
        continue
      }
      let label = UILabel()
      label.font = font
      label.textColor = textColor
      label.textAlignment = .center
      label.text = String(character)
      label.isAccessibilityElement = false
      label.bounds = CGRect(x: 0, y: 0, width: characterWidth, height: height)
      label.center = center
      addSubview(label)
      next.append((character, label))
      if let old {
        retire(
          old.label, to: CGAffineTransform(translationX: 0, y: shift).scaledBy(x: 0.3, y: 0.3), animated: animated,
          reduceMotion: reduceMotion
        )
      }
      guard animated else { continue }
      label.alpha = 0
      if !reduceMotion {
        label.transform = old == nil
          ? CGAffineTransform(scaleX: 0.1, y: 0.1)
          : CGAffineTransform(translationX: 0, y: -shift).scaledBy(x: 0.3, y: 0.3)
      }
      UIView.animate(withDuration: Self.duration, delay: 0, options: [.beginFromCurrentState, .curveEaseInOut]) {
        label.alpha = 1
        label.transform = .identity
      }
    }
    glyphs = next
    return resized
  }

  private func retire(_ label: UILabel, to transform: CGAffineTransform, animated: Bool, reduceMotion: Bool) {
    guard animated else {
      label.removeFromSuperview()
      return
    }
    leaving.append(label)
    if leaving.count > Self.maxLeaving { leaving.removeFirst().removeFromSuperview() }
    UIView.animate(
      withDuration: Self.duration, delay: 0, options: [.beginFromCurrentState, .curveEaseInOut],
      animations: {
        label.alpha = 0
        if !reduceMotion { label.transform = transform }
      },
      completion: { [weak self, weak label] _ in
        guard let label else { return }
        label.removeFromSuperview()
        self?.leaving.removeAll { $0 === label }
      }
    )
  }

  private func glyphWidth(_ character: Character) -> CGFloat {
    if let width = widths[character] { return width }
    let width = (String(character) as NSString).size(withAttributes: [.font: font]).width
    widths[character] = width
    return width
  }
}
