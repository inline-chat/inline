import UIKit

class BlurCircleButton: UIButton {
  private let blurEffect = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
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
      widthAnchor.constraint(equalToConstant: 44),
      heightAnchor.constraint(equalToConstant: 44),
    ])

    backgroundView.backgroundColor = .systemBackground.withAlphaComponent(0.3)
    backgroundView.translatesAutoresizingMaskIntoConstraints = false
    backgroundView.layer.cornerRadius = 22
    backgroundView.isUserInteractionEnabled = false
    blurEffect.isUserInteractionEnabled = false
    iconImageView.isUserInteractionEnabled = false
    iconImageView.tintColor = ColorManager.shared.selectedColor
    isUserInteractionEnabled = true
    addSubview(backgroundView)

    blurEffect.layer.cornerRadius = 22
    blurEffect.clipsToBounds = true
    blurEffect.translatesAutoresizingMaskIntoConstraints = false
    addSubview(blurEffect)

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

      blurEffect.topAnchor.constraint(equalTo: topAnchor),
      blurEffect.leadingAnchor.constraint(equalTo: leadingAnchor),
      blurEffect.trailingAnchor.constraint(equalTo: trailingAnchor),
      blurEffect.bottomAnchor.constraint(equalTo: bottomAnchor),

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
