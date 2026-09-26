import Logger
import UIKit

final class DateSeparatorView: UICollectionReusableView {
  static let reuseIdentifier = "DateSeparatorView"
  static let height: CGFloat = 44
  private static let backgroundVerticalOffset: CGFloat = -2

  // Performance optimization: Cache the current date string to avoid unnecessary updates
  private var currentDateString: String = ""
  private var onTap: (() -> Void)?
  private var onInteractionChanged: ((Bool) -> Void)?

  private let label: UILabel = {
    let label = UILabel()
    label.font = UIFont.systemFont(ofSize: 12, weight: .regular)
    label.textColor = UIColor.label
    label.textAlignment = .center
    label.isAccessibilityElement = false
    label.translatesAutoresizingMaskIntoConstraints = false
    return label
  }()

  private let backgroundEffectView: UIVisualEffectView = {
    let effectView: UIVisualEffectView
    if #available(iOS 26.0, *) {
      let glassEffect = UIGlassEffect(style: .regular)
      glassEffect.isInteractive = true
      effectView = UIVisualEffectView(effect: glassEffect)
      effectView.cornerConfiguration = .capsule()
    } else {
      effectView = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
      effectView.layer.cornerCurve = .continuous
      effectView.clipsToBounds = true
    }
    effectView.isUserInteractionEnabled = false
    effectView.translatesAutoresizingMaskIntoConstraints = false
    return effectView
  }()

  private lazy var button: UIButton = {
    let button = UIButton(type: .custom)
    button.isEnabled = false
    button.translatesAutoresizingMaskIntoConstraints = false
    button.accessibilityTraits = .button
    button.addTarget(self, action: #selector(didBeginInteraction), for: .touchDown)
    button.addTarget(self, action: #selector(didTap), for: .touchUpInside)
    button.addTarget(self, action: #selector(didEndInteraction), for: [.touchUpOutside, .touchCancel])
    return button
  }()

  override init(frame: CGRect) {
    super.init(frame: frame)
    setupViews()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setupViews()
  }

  private func setupViews() {
    addSubview(backgroundEffectView)
    backgroundEffectView.contentView.addSubview(label)
    backgroundEffectView.contentView.addSubview(button)

    // Counter the collection view's inversion to appear right-side up
    backgroundEffectView.transform = CGAffineTransform(scaleX: 1, y: -1)

    NSLayoutConstraint.activate([
      backgroundEffectView.centerXAnchor.constraint(equalTo: centerXAnchor),
      backgroundEffectView.centerYAnchor.constraint(equalTo: centerYAnchor, constant: Self.backgroundVerticalOffset),
      backgroundEffectView.heightAnchor.constraint(equalToConstant: 20),
      backgroundEffectView.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
      backgroundEffectView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),

      label.leadingAnchor.constraint(equalTo: backgroundEffectView.contentView.leadingAnchor, constant: 8),
      label.trailingAnchor.constraint(equalTo: backgroundEffectView.contentView.trailingAnchor, constant: -8),
      label.centerYAnchor.constraint(equalTo: backgroundEffectView.contentView.centerYAnchor),

      button.leadingAnchor.constraint(equalTo: backgroundEffectView.contentView.leadingAnchor),
      button.trailingAnchor.constraint(equalTo: backgroundEffectView.contentView.trailingAnchor),
      button.heightAnchor.constraint(equalTo: heightAnchor),
      // Counter the glass view's Y flip and offset so the touch area stays centered in the row.
      button.centerYAnchor.constraint(
        equalTo: backgroundEffectView.contentView.centerYAnchor,
        constant: Self.backgroundVerticalOffset
      ),
    ])
  }

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    guard !isHidden,
          alpha > 0.01,
          isUserInteractionEnabled,
          bounds.contains(point),
          button.isEnabled
    else { return nil }

    // Only the badge's full-height button intercepts touches; the rest of the footer passes through.
    guard let hitView = button.hitTest(convert(point, to: button), with: event) else { return nil }
    if event?.allTouches?.contains(where: { $0.phase == .began }) == true {
      // Pause hiding before UIScrollView can delay delivery of the button's touchDown.
      traceInteraction("hit")
      beginInteraction()
    }
    return hitView
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    if #unavailable(iOS 26.0) {
      backgroundEffectView.layer.cornerRadius = backgroundEffectView.bounds.height / 2
    }
  }

  func configure(
    with dateString: String,
    onTap: (() -> Void)? = nil,
    onInteractionChanged: ((Bool) -> Void)? = nil
  ) {
    self.onTap = onTap
    self.onInteractionChanged = onInteractionChanged
    button.isEnabled = onTap != nil
    backgroundEffectView.isUserInteractionEnabled = onTap != nil
    button.accessibilityLabel = onTap == nil ? nil : "Show first message from \(dateString)"

    // Performance optimization: Only update if the date string actually changed
    guard currentDateString != dateString else { return }

    let shouldAnimate = !currentDateString.isEmpty && !dateString.isEmpty
    currentDateString = dateString
    label.text = dateString

    if shouldAnimate {
      setVisible(false, animated: false)
      setVisible(true, animated: true)
    } else {
      setVisible(true, animated: false)
    }
  }

  func setVisible(_ visible: Bool, animated: Bool) {
    guard visible || !button.isTracking else { return }

    if visible {
      isUserInteractionEnabled = true
      accessibilityElementsHidden = false
    }

    let targetAlpha: CGFloat = visible ? 1 : 0
    guard animated else {
      backgroundEffectView.layer.removeAnimation(forKey: "opacity")
      backgroundEffectView.alpha = targetAlpha
      isUserInteractionEnabled = visible
      accessibilityElementsHidden = !visible
      return
    }

    // Fade the artwork, keeping the button reachable until the visible fade finishes.
    UIView.animate(
      withDuration: 0.2,
      delay: 0,
      options: [.allowUserInteraction, .beginFromCurrentState]
    ) {
      self.backgroundEffectView.alpha = targetAlpha
    } completion: { [weak self] finished in
      guard let self, finished, !visible, self.backgroundEffectView.alpha == 0 else { return }
      self.isUserInteractionEnabled = false
      self.accessibilityElementsHidden = true
    }
  }

  @objc private func didBeginInteraction() {
    traceInteraction("touch-down")
    beginInteraction()
  }

  private func beginInteraction() {
    setVisible(true, animated: false)
    onInteractionChanged?(true)
  }

  @objc private func didEndInteraction() {
    traceInteraction("end")
    onInteractionChanged?(false)
  }

  @objc private func didTap() {
    traceInteraction("activate")
    didEndInteraction()
    onTap?()
  }

  private func traceInteraction(_ event: String) {
    #if DEBUG || DEBUG_BUILD
    Log.shared.debug(
      "date-navigation event=\(event) tracking=\(button.isTracking) inside=\(button.isTouchInside) visible=\(backgroundEffectView.alpha > 0)"
    )
    #endif
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    currentDateString = ""
    onTap = nil
    onInteractionChanged = nil
    button.isEnabled = false
    backgroundEffectView.isUserInteractionEnabled = false
    button.accessibilityLabel = nil
    label.text = ""
    setVisible(true, animated: false)
  }
}
