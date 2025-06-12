import InlineKit
import UIKit

// MARK: - Button Style Protocols

protocol ComposeButtonStyle {
  func configure(_ button: UIButton)
  func updateForHighlighted(_ button: UIButton, isHighlighted: Bool)
}

protocol ComposeButtonAnimator {
  func animateAppearance(_ button: UIButton, completion: (() -> Void)?)
  func animateDisappearance(_ button: UIButton, completion: (() -> Void)?)
}

// MARK: - Send Button Styles

struct DefaultSendButtonStyle: ComposeButtonStyle {
  let accentColor: UIColor
  let iconSize: CGFloat
  let cornerRadius: CGFloat?

  init(
    accentColor: UIColor = ThemeManager.shared.selected.accent,
    iconSize: CGFloat = 14,
    cornerRadius: CGFloat? = nil
  ) {
    self.accentColor = accentColor
    self.iconSize = iconSize
    self.cornerRadius = cornerRadius
  }

  func configure(_ button: UIButton) {
    var config = UIButton.Configuration.plain()
    config.image = UIImage(systemName: "arrow.up")?.withConfiguration(
      UIImage.SymbolConfiguration(pointSize: iconSize, weight: .bold)
    )
    config.baseForegroundColor = .white
    config.background.backgroundColor = accentColor
    config.cornerStyle = cornerRadius != nil ? .fixed : .capsule

    if let cornerRadius {
      config.background.cornerRadius = cornerRadius
    }

    button.configuration = config
  }

  func updateForHighlighted(_ button: UIButton, isHighlighted: Bool) {
    if isHighlighted {
      UIView.animate(
        withDuration: 0.15,
        delay: 0,
        options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseInOut],
        animations: {
          button.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
        }
      )
    } else {
      UIView.animate(
        withDuration: 0.12,
        delay: 0.05,
        options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseIn],
        animations: {
          button.transform = .identity
        }
      )
    }
  }
}

struct MinimalSendButtonStyle: ComposeButtonStyle {
  let tintColor: UIColor
  let backgroundColor: UIColor

  init(tintColor: UIColor = .systemBlue, backgroundColor: UIColor = .clear) {
    self.tintColor = tintColor
    self.backgroundColor = backgroundColor
  }

  func configure(_ button: UIButton) {
    var config = UIButton.Configuration.plain()
    config.image = UIImage(systemName: "paperplane.fill")?.withConfiguration(
      UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)
    )
    config.baseForegroundColor = tintColor
    config.background.backgroundColor = backgroundColor

    button.configuration = config
  }

  func updateForHighlighted(_ button: UIButton, isHighlighted: Bool) {
    UIView.animate(withDuration: 0.1) {
      button.alpha = isHighlighted ? 0.6 : 1.0
    }
  }
}

struct RoundedSendButtonStyle: ComposeButtonStyle {
  let accentColor: UIColor
  let borderWidth: CGFloat
  let borderColor: UIColor

  init(
    accentColor: UIColor = ThemeManager.shared.selected.accent,
    borderWidth: CGFloat = 2.0,
    borderColor: UIColor = .systemGray4
  ) {
    self.accentColor = accentColor
    self.borderWidth = borderWidth
    self.borderColor = borderColor
  }

  func configure(_ button: UIButton) {
    var config = UIButton.Configuration.plain()
    config.image = UIImage(systemName: "arrow.up.circle.fill")?.withConfiguration(
      UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)
    )
    config.baseForegroundColor = accentColor
    config.background.backgroundColor = .clear

    button.configuration = config
    button.layer.borderWidth = borderWidth
    button.layer.borderColor = borderColor.cgColor
    button.layer.cornerRadius = 16
  }

  func updateForHighlighted(_ button: UIButton, isHighlighted: Bool) {
    UIView.animate(withDuration: 0.15) {
      button.layer.borderColor = isHighlighted ? accentColor.cgColor : borderColor.cgColor
      button.transform = isHighlighted ? CGAffineTransform(scaleX: 0.95, y: 0.95) : .identity
    }
  }
}

// MARK: - Attachment Button Styles

struct DefaultAttachmentButtonStyle: ComposeButtonStyle {
  let backgroundColor: UIColor
  let tintColor: UIColor
  let cornerRadius: CGFloat

  init(
    backgroundColor: UIColor = .secondarySystemBackground,
    tintColor: UIColor = .secondaryLabel,
    cornerRadius: CGFloat = 16
  ) {
    self.backgroundColor = backgroundColor
    self.tintColor = tintColor
    self.cornerRadius = cornerRadius
  }

  func configure(_ button: UIButton) {
    var config = UIButton.Configuration.plain()
    config.image = UIImage(systemName: "plus")?.withConfiguration(
      UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)
    )
    config.baseForegroundColor = tintColor
    config.background.backgroundColor = backgroundColor

    button.configuration = config
    button.layer.cornerRadius = cornerRadius
    button.clipsToBounds = true
  }

  func updateForHighlighted(_ button: UIButton, isHighlighted: Bool) {
    UIView.animate(withDuration: 0.1) {
      button.alpha = isHighlighted ? 0.7 : 1.0
    }
  }
}

struct CircularAttachmentButtonStyle: ComposeButtonStyle {
  let accentColor: UIColor
  let iconName: String

  init(accentColor: UIColor = .systemBlue, iconName: String = "paperclip") {
    self.accentColor = accentColor
    self.iconName = iconName
  }

  func configure(_ button: UIButton) {
    var config = UIButton.Configuration.plain()
    config.image = UIImage(systemName: iconName)?.withConfiguration(
      UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)
    )
    config.baseForegroundColor = .white
    config.background.backgroundColor = accentColor
    config.cornerStyle = .capsule

    button.configuration = config
  }

  func updateForHighlighted(_ button: UIButton, isHighlighted: Bool) {
    UIView.animate(withDuration: 0.15) {
      button.transform = isHighlighted ? CGAffineTransform(scaleX: 0.9, y: 0.9) : .identity
    }
  }
}

struct BorderedAttachmentButtonStyle: ComposeButtonStyle {
  let borderColor: UIColor
  let tintColor: UIColor
  let borderWidth: CGFloat

  init(
    borderColor: UIColor = .systemGray3,
    tintColor: UIColor = .label,
    borderWidth: CGFloat = 1.5
  ) {
    self.borderColor = borderColor
    self.tintColor = tintColor
    self.borderWidth = borderWidth
  }

  func configure(_ button: UIButton) {
    var config = UIButton.Configuration.plain()
    config.image = UIImage(systemName: "plus.circle")?.withConfiguration(
      UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)
    )
    config.baseForegroundColor = tintColor
    config.background.backgroundColor = .clear

    button.configuration = config
    button.layer.borderWidth = borderWidth
    button.layer.borderColor = borderColor.cgColor
    button.layer.cornerRadius = 16
  }

  func updateForHighlighted(_ button: UIButton, isHighlighted: Bool) {
    UIView.animate(withDuration: 0.1) {
      button.layer.borderColor = isHighlighted ? tintColor.cgColor : borderColor.cgColor
    }
  }
}

// MARK: - Button Animators

struct SpringButtonAnimator: ComposeButtonAnimator {
  let damping: CGFloat
  let velocity: CGFloat
  let duration: TimeInterval

  init(damping: CGFloat = 0.8, velocity: CGFloat = 0.5, duration: TimeInterval = 0.21) {
    self.damping = damping
    self.velocity = velocity
    self.duration = duration
  }

  func animateAppearance(_ button: UIButton, completion: (() -> Void)?) {
    button.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)
    button.alpha = 0.0

    UIView.animate(
      withDuration: duration,
      delay: 0,
      usingSpringWithDamping: damping,
      initialSpringVelocity: velocity,
      options: .curveEaseOut
    ) {
      button.transform = .identity
      button.alpha = 1
    } completion: { _ in
      completion?()
    }
  }

  func animateDisappearance(_ button: UIButton, completion: (() -> Void)?) {
    UIView.animate(
      withDuration: 0.12,
      delay: 0.1,
      options: [.curveEaseOut, .allowUserInteraction]
    ) {
      button.transform = CGAffineTransform(scaleX: 1.05, y: 1.05)
      button.alpha = 0
    } completion: { _ in
      completion?()
    }
  }
}

struct FadeButtonAnimator: ComposeButtonAnimator {
  let duration: TimeInterval

  init(duration: TimeInterval = 0.2) {
    self.duration = duration
  }

  func animateAppearance(_ button: UIButton, completion: (() -> Void)?) {
    button.alpha = 0.0
    UIView.animate(withDuration: duration) {
      button.alpha = 1.0
    } completion: { _ in
      completion?()
    }
  }

  func animateDisappearance(_ button: UIButton, completion: (() -> Void)?) {
    UIView.animate(withDuration: duration) {
      button.alpha = 0.0
    } completion: { _ in
      completion?()
    }
  }
}

struct SlideButtonAnimator: ComposeButtonAnimator {
  let direction: SlideDirection
  let distance: CGFloat
  let duration: TimeInterval

  enum SlideDirection {
    case left, right, up, down
  }

  init(direction: SlideDirection = .right, distance: CGFloat = 30, duration: TimeInterval = 0.25) {
    self.direction = direction
    self.distance = distance
    self.duration = duration
  }

  func animateAppearance(_ button: UIButton, completion: (() -> Void)?) {
    let transform = getTransform(for: direction, distance: distance)
    button.transform = transform
    button.alpha = 0.0

    UIView.animate(withDuration: duration, delay: 0, options: .curveEaseOut) {
      button.transform = .identity
      button.alpha = 1.0
    } completion: { _ in
      completion?()
    }
  }

  func animateDisappearance(_ button: UIButton, completion: (() -> Void)?) {
    let transform = getTransform(for: direction, distance: distance)

    UIView.animate(withDuration: duration, delay: 0, options: .curveEaseIn) {
      button.transform = transform
      button.alpha = 0.0
    } completion: { _ in
      completion?()
    }
  }

  private func getTransform(for direction: SlideDirection, distance: CGFloat) -> CGAffineTransform {
    switch direction {
      case .left:
        CGAffineTransform(translationX: -distance, y: 0)
      case .right:
        CGAffineTransform(translationX: distance, y: 0)
      case .up:
        CGAffineTransform(translationX: 0, y: -distance)
      case .down:
        CGAffineTransform(translationX: 0, y: distance)
    }
  }
}

// MARK: - Button Factory

class ComposeButtonFactory {
  static func createSendButton(
    style: ComposeButtonStyle = DefaultSendButtonStyle(),
    animator: ComposeButtonAnimator = SpringButtonAnimator(),
    target: Any?,
    action: Selector
  ) -> UIButton {
    let button = UIButton()
    button.translatesAutoresizingMaskIntoConstraints = false

    style.configure(button)
    button.addTarget(target, action: action, for: .touchUpInside)

    // Store style and animator for later use
    objc_setAssociatedObject(button, &AssociatedKeys.buttonStyle, style, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    objc_setAssociatedObject(button, &AssociatedKeys.buttonAnimator, animator, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

    button.configurationUpdateHandler = { [weak button] _ in
      guard let button else { return }
      if let style = objc_getAssociatedObject(button, &AssociatedKeys.buttonStyle) as? ComposeButtonStyle {
        style.updateForHighlighted(button, isHighlighted: button.isHighlighted)
      }
    }

    return button
  }

  static func createAttachmentButton(
    style: ComposeButtonStyle = DefaultAttachmentButtonStyle(),
    animator: ComposeButtonAnimator = SpringButtonAnimator(),
    menu: UIMenu
  ) -> UIButton {
    let button = UIButton()
    button.translatesAutoresizingMaskIntoConstraints = false

    style.configure(button)
    button.menu = menu
    button.showsMenuAsPrimaryAction = true

    // Store style and animator for later use
    objc_setAssociatedObject(button, &AssociatedKeys.buttonStyle, style, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    objc_setAssociatedObject(button, &AssociatedKeys.buttonAnimator, animator, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

    button.configurationUpdateHandler = { [weak button] _ in
      guard let button else { return }
      if let style = objc_getAssociatedObject(button, &AssociatedKeys.buttonStyle) as? ComposeButtonStyle {
        style.updateForHighlighted(button, isHighlighted: button.isHighlighted)
      }
    }

    return button
  }
}

// MARK: - Associated Object Keys

private enum AssociatedKeys {
  static var buttonStyle = "buttonStyle"
  static var buttonAnimator = "buttonAnimator"
}

// MARK: - UIButton Extensions

extension UIButton {
  var composeButtonAnimator: ComposeButtonAnimator? {
    objc_getAssociatedObject(self, &AssociatedKeys.buttonAnimator) as? ComposeButtonAnimator
  }

  func animateAppearance(completion: (() -> Void)? = nil) {
    composeButtonAnimator?.animateAppearance(self, completion: completion)
  }

  func animateDisappearance(completion: (() -> Void)? = nil) {
    composeButtonAnimator?.animateDisappearance(self, completion: completion)
  }
}
