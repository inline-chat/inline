import InlineProtocol
import UIKit

private final class ComposeGlassGroupView: UIView {
  private let rootView: UIView
  let contentView: UIView

  override init(frame: CGRect) {
    if #available(iOS 26.0, *) {
      let effect = UIGlassContainerEffect()
      effect.spacing = 8
      let visualEffectView = UIVisualEffectView(effect: effect)
      rootView = visualEffectView
      contentView = visualEffectView.contentView
    } else {
      let view = UIView()
      rootView = view
      contentView = view
    }

    super.init(frame: frame)

    translatesAutoresizingMaskIntoConstraints = false
    backgroundColor = .clear
    rootView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(rootView)

    NSLayoutConstraint.activate([
      rootView.topAnchor.constraint(equalTo: topAnchor),
      rootView.leadingAnchor.constraint(equalTo: leadingAnchor),
      rootView.trailingAnchor.constraint(equalTo: trailingAnchor),
      rootView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    guard !isHidden, alpha > 0, isUserInteractionEnabled else { return nil }

    for view in contentView.subviews.reversed() {
      let convertedPoint = convert(point, to: view)
      guard view.point(inside: convertedPoint, with: event) else { continue }

      if let plusButton = view as? ComposePlusGlassButton {
        return plusButton.hitTest(convertedPoint, with: event)
      }

      if let effectView = view as? UIVisualEffectView {
        let contentPoint = convert(point, to: effectView.contentView)
        if let result = effectView.contentView.hitTest(contentPoint, with: event),
           result !== effectView.contentView
        {
          return result
        }
        continue
      }

      if let result = view.hitTest(convertedPoint, with: event) {
        return result
      }
    }

    return nil
  }
}

private final class ComposePlusGlassButton: UIVisualEffectView {
  var onTouchDown: (() -> Void)?
  var onTap: (() -> Void)?

  private let imageView = UIImageView()
  private var isPressed = false {
    didSet {
      guard oldValue != isPressed else { return }
      UIView.animate(
        withDuration: 0.12,
        delay: 0,
        options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseInOut]
      ) {
        self.alpha = self.isPressed ? 0.58 : 1
      }
    }
  }

  init() {
    if #available(iOS 26.0, *) {
      let glassEffect = UIGlassEffect(style: .regular)
      glassEffect.isInteractive = true
      super.init(effect: glassEffect)
    } else {
      super.init(effect: nil)
      backgroundColor = .secondarySystemBackground
    }

    setup()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    guard !isHidden, alpha > 0.01, isUserInteractionEnabled, self.point(inside: point, with: event) else {
      return nil
    }

    return self
  }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
    isPressed = true
    onTouchDown?()
    super.touchesBegan(touches, with: event)
  }

  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
    let shouldTap = touches.contains { touch in
      bounds.contains(touch.location(in: self))
    }
    isPressed = false
    if shouldTap {
      onTap?()
    }
    super.touchesEnded(touches, with: event)
  }

  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
    isPressed = false
    super.touchesCancelled(touches, with: event)
  }

  private func setup() {
    translatesAutoresizingMaskIntoConstraints = false
    isUserInteractionEnabled = true
    layer.cornerRadius = 21
    layer.cornerCurve = .continuous
    layer.masksToBounds = true
    isAccessibilityElement = true
    accessibilityLabel = "Add attachment"
    accessibilityTraits = .button

    imageView.translatesAutoresizingMaskIntoConstraints = false
    imageView.image = UIImage(systemName: "plus")?.withConfiguration(
      UIImage.SymbolConfiguration(pointSize: 20.5, weight: .medium)
    )
    imageView.tintColor = .secondaryLabel
    imageView.contentMode = .center
    contentView.addSubview(imageView)

    NSLayoutConstraint.activate([
      imageView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
      imageView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
    ])
  }
}

extension ComposeView {
  func makeTextView() -> ComposeTextView {
    let view = ComposeTextView(composeView: self)
    view.translatesAutoresizingMaskIntoConstraints = false
    view.delegate = self
    return view
  }

  func makeSendButton() -> UIButton {
    let button = UIButton()
    button.translatesAutoresizingMaskIntoConstraints = false
    button.frame = CGRect(origin: .zero, size: buttonSize)

    var config = UIButton.Configuration.plain()
    config.image = UIImage(systemName: "arrow.up")?.withConfiguration(
      UIImage.SymbolConfiguration(pointSize: 14, weight: .bold)
    )
    config.baseForegroundColor = .white
    config.background.backgroundColor = ThemeManager.shared.selected.accent
    config.cornerStyle = .capsule

    button.addTarget(self, action: #selector(buttonTouchDown), for: .touchDown)
    button.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)

    let silentAction = UIAction(
      title: "Send without notification",
      image: UIImage(systemName: "bell.slash"),
      handler: { [weak self] _ in
        self?.sendMessage(sendMode: .modeSilent)
      }
    )
    button.menu = UIMenu(children: [silentAction])
    button.showsMenuAsPrimaryAction = false

    button.configurationUpdateHandler = { [weak button] _ in
      guard let button else { return }
      if !button.isUserInteractionEnabled || button.alpha <= 0.01 {
        button.layer.removeAllAnimations()
        button.transform = .identity
        return
      }

      if button.isHighlighted {
        UIView.animate(
          withDuration: 0.4,
          delay: 0,
          options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseInOut]
        ) {
          button.transform = CGAffineTransform(scaleX: 0.75, y: 0.75)
        }
      } else {
        let currentScale =
          CGFloat((button.layer.presentation()?.value(forKeyPath: "transform.scale.y") as? NSNumber)?.floatValue ?? Float(button.transform.a))
        button.transform = CGAffineTransform(scaleX: currentScale, y: currentScale)

        UIView.animate(
          withDuration: 0.25,
          delay: 0,
          options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseInOut]
        ) {
          button.transform = .identity
        }
      }
    }

    button.configuration = config
    button.isUserInteractionEnabled = true

    // Hide initially
    button.alpha = 0.0

    return button
  }

  func makeVoiceButton() -> ComposeVoiceButton {
    let button = ComposeVoiceButton()
    button.addTarget(self, action: #selector(buttonTouchDown), for: .touchDown)
    button.addTarget(self, action: #selector(startVoiceRecordingTapped), for: .touchUpInside)
    return button
  }

  func makeComposeGlassContainer() -> UIView {
    ComposeGlassGroupView()
  }

  func composeGlassContentView() -> UIView {
    (composeGlassContainer as? ComposeGlassGroupView)?.contentView ?? composeGlassContainer
  }

  func composeContentView() -> UIView {
    (composeAndButtonContainer as? UIVisualEffectView)?.contentView ?? composeAndButtonContainer
  }

  func makePlusButton() -> UIView {
    let button = ComposePlusGlassButton()
    button.onTouchDown = { [weak self] in
      self?.buttonTouchDown()
    }
    button.onTap = { [weak self] in
      self?.plusTapped()
    }
    return button
  }

  @objc func buttonTouchDown() {
    let feedbackGenerator = UIImpactFeedbackGenerator(style: .light)
    feedbackGenerator.prepare()
    feedbackGenerator.impactOccurred(intensity: 1.0)
  }

  func makeComposeAndButtonContainer() -> UIView {
    if #available(iOS 26.0, *) {
      let glassEffect = UIGlassEffect(style: .regular)
      glassEffect.isInteractive = true
      let view = UIVisualEffectView(effect: glassEffect)
      view.translatesAutoresizingMaskIntoConstraints = false
      view.isUserInteractionEnabled = true
      view.layer.cornerRadius = 20
      view.layer.cornerCurve = .continuous
      view.layer.masksToBounds = true
      return view
    }

    let view = UIView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.isUserInteractionEnabled = true
    view.backgroundColor = .secondarySystemBackground.withAlphaComponent(0.8)
    view.layer.cornerRadius = 20
    view.layer.cornerCurve = .continuous
    view.clipsToBounds = true
    return view
  }

  func makeEmbedContainerView() -> UIView {
    let view = UIView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.isUserInteractionEnabled = true
    view.backgroundColor = .clear
    view.clipsToBounds = true
    view.isHidden = true
    return view
  }

  func makeAttachmentScrollView() -> UIScrollView {
    let view = UIScrollView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.showsHorizontalScrollIndicator = false
    view.showsVerticalScrollIndicator = false
    view.alwaysBounceHorizontal = true
    view.alwaysBounceVertical = false
    view.delaysContentTouches = false
    view.isHidden = true
    return view
  }

  func makeAttachmentStackView() -> UIStackView {
    let view = UIStackView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.axis = .horizontal
    view.alignment = .center
    view.spacing = 8
    return view
  }
}
