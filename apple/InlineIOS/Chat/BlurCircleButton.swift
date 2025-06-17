import UIKit

class BlurCircleButton: UIButton {
  lazy var blurView: UIVisualEffectView = {
    if #available(iOS 26.0, *) {
      let glassEffect = UIGlassEffect()
      let view = UIVisualEffectView()
      UIView.animate {
        view.effect = glassEffect
      }
      view.translatesAutoresizingMaskIntoConstraints = false

      return view
    } else {
      let effect = UIBlurEffect(style: .regular)
      let view = UIVisualEffectView(effect: effect)
      view.backgroundColor = ThemeManager.shared.selected.backgroundColor.withAlphaComponent(0.6)
      view.translatesAutoresizingMaskIntoConstraints = false

      view.layer.shadowColor = UIColor.black.cgColor
      view.layer.shadowOpacity = 0.1
      view.layer.shadowOffset = CGSize(width: 0, height: 2)
      view.layer.shadowRadius = 4

      return view
    }
  }()

  private let iconImageView = UIImageView()
  private let backgroundView = UIView()

  override init(frame: CGRect) {
    super.init(frame: frame)
    setup()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setup()
  }

  private func setup() {
    translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      widthAnchor.constraint(equalToConstant: 42),
      heightAnchor.constraint(equalToConstant: 42),
    ])

    backgroundView.backgroundColor = .systemBackground.withAlphaComponent(0.3)
    backgroundView.translatesAutoresizingMaskIntoConstraints = false
    backgroundView.layer.cornerRadius = 22
    backgroundView.isUserInteractionEnabled = false
    blurView.isUserInteractionEnabled = false
    iconImageView.isUserInteractionEnabled = false
    iconImageView.tintColor = ThemeManager.shared.selected.accent
    isUserInteractionEnabled = true
    addSubview(backgroundView)

    blurView.layer.cornerRadius = 22
    blurView.clipsToBounds = true
    blurView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(blurView)

    let chevronImage = UIImage(systemName: "chevron.down")?
      .withConfiguration(UIImage.SymbolConfiguration(pointSize: 20, weight: .medium))
    iconImageView.image = chevronImage

    iconImageView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(iconImageView)

    NSLayoutConstraint.activate([
      backgroundView.topAnchor.constraint(equalTo: topAnchor),
      backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
      backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
      backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),

      blurView.topAnchor.constraint(equalTo: topAnchor),
      blurView.leadingAnchor.constraint(equalTo: leadingAnchor),
      blurView.trailingAnchor.constraint(equalTo: trailingAnchor),
      blurView.bottomAnchor.constraint(equalTo: bottomAnchor),

      iconImageView.centerXAnchor.constraint(equalTo: centerXAnchor),
      iconImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])

    addTarget(self, action: #selector(buttonTapped), for: .touchUpInside)
  }

  @objc private func buttonTapped() {
    NotificationCenter.default.post(name: .scrollToBottom, object: nil)
  }
}

extension Notification.Name {
  static let scrollToBottom = Notification.Name("scrollToBottom")
}
