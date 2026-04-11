import struct InlineProtocol.MessageAction
import UIKit

final class MessageActionButton: UIButton {
  private static let pressedScale: CGFloat = 0.96
  private static let pressedAlpha: CGFloat = 0.88

  var messageAction: MessageAction?
  var actionId: String = ""
  let spinner = UIActivityIndicatorView(style: .medium)

  private var outgoing = false

  override var isHighlighted: Bool {
    didSet {
      updatePressAppearance(animated: true)
    }
  }

  override var isEnabled: Bool {
    didSet {
      if !isEnabled {
        updatePressAppearance(animated: false)
      }
    }
  }

  override init(frame: CGRect) {
    super.init(frame: frame)

    titleLabel?.font = .systemFont(ofSize: 13, weight: .medium)
    titleLabel?.lineBreakMode = .byTruncatingTail
    contentEdgeInsets = UIEdgeInsets(top: 7, left: 14, bottom: 7, right: 14)
    layer.cornerRadius = 10
    layer.borderWidth = 1 / UIScreen.main.scale
    clipsToBounds = true

    spinner.translatesAutoresizingMaskIntoConstraints = false
    spinner.hidesWhenStopped = true
    spinner.transform = CGAffineTransform(scaleX: 0.82, y: 0.82)
    addSubview(spinner)

    NSLayoutConstraint.activate([
      spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
      spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])

    updatePressAppearance(animated: false)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    guard previousTraitCollection?.hasDifferentColorAppearance(comparedTo: traitCollection) == true else { return }
    refreshStyle()
  }

  func configure(action: MessageAction, outgoing: Bool) {
    self.outgoing = outgoing
    messageAction = action
    actionId = action.actionID.trimmingCharacters(in: .whitespacesAndNewlines)
    setTitle(action.text, for: .normal)
    refreshStyle()
    setLoading(false)
  }

  func refreshStyle() {
    let isDark = traitCollection.userInterfaceStyle == .dark
    let textColor = outgoing ? UIColor.white : (ThemeManager.shared.selected.primaryTextColor ?? .label)
    setTitleColor(textColor, for: .normal)
    setTitleColor(textColor.withAlphaComponent(0.45), for: .disabled)

    if outgoing {
      backgroundColor = UIColor.white.withAlphaComponent(isDark ? 0.2 : 0.13)
      layer.borderColor = UIColor.white.withAlphaComponent(isDark ? 0.34 : 0.28).cgColor
      return
    }

    backgroundColor = ThemeManager.shared.selected.incomingBubbleBackground.withAlphaComponent(isDark ? 0.88 : 0.75)
    layer.borderColor = UIColor.separator.withAlphaComponent(isDark ? 0.55 : 0.45).cgColor
  }

  func setLoading(_ isLoading: Bool) {
    isEnabled = !isLoading
    titleLabel?.alpha = isLoading ? 0 : 1

    if isLoading {
      spinner.color = outgoing ? .white : ThemeManager.shared.selected.accent
      spinner.startAnimating()
    } else {
      spinner.stopAnimating()
    }
  }

  private func updatePressAppearance(animated: Bool) {
    let isPressed = isEnabled && isHighlighted
    let alpha = isPressed ? Self.pressedAlpha : 1.0
    let transform = isPressed ? CGAffineTransform(scaleX: Self.pressedScale, y: Self.pressedScale) : .identity

    guard animated else {
      self.alpha = alpha
      self.transform = transform
      return
    }

    UIView.animate(
      withDuration: 0.14,
      delay: 0,
      options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseInOut]
    ) {
      self.alpha = alpha
      self.transform = transform
    }
  }
}
