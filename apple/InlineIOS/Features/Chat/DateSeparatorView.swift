import UIKit

final class DateSeparatorView: UICollectionReusableView {
  static let reuseIdentifier = "DateSeparatorView"
  static let height: CGFloat = 44

  // Performance optimization: Cache the current date string to avoid unnecessary updates
  private var currentDateString: String = ""
  private var onTap: (() -> Void)?

  private let label: UILabel = {
    let label = UILabel()
    label.font = UIFont.systemFont(ofSize: 12, weight: .regular)
    label.textColor = UIColor.label
    label.textAlignment = .center
    label.isAccessibilityElement = false
    label.translatesAutoresizingMaskIntoConstraints = false
    return label
  }()

  private let blurEffectView: UIVisualEffectView = {
    let blurEffect = UIBlurEffect(style: .systemThinMaterial)
    let effectView = UIVisualEffectView(effect: blurEffect)
    effectView.translatesAutoresizingMaskIntoConstraints = false
    return effectView
  }()

  private lazy var button: UIButton = {
    let button = UIButton(type: .custom)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.accessibilityTraits = .button
    button.addTarget(self, action: #selector(didTap), for: .touchUpInside)
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
    addSubview(blurEffectView)
    blurEffectView.contentView.addSubview(label)
    addSubview(button)

    // Counter the collection view's inversion to appear right-side up
    blurEffectView.transform = CGAffineTransform(scaleX: 1, y: -1)

    NSLayoutConstraint.activate([
      blurEffectView.centerXAnchor.constraint(equalTo: centerXAnchor),
      blurEffectView.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -2),
      // blurEffectView.bottomAnchor.constraint(equalTo: bottomAnchor),
      blurEffectView.heightAnchor.constraint(equalToConstant: 20),
      blurEffectView.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
      blurEffectView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),

      label.leadingAnchor.constraint(equalTo: blurEffectView.contentView.leadingAnchor, constant: 8),
      label.trailingAnchor.constraint(equalTo: blurEffectView.contentView.trailingAnchor, constant: -8),
      label.centerYAnchor.constraint(equalTo: blurEffectView.contentView.centerYAnchor),

      button.leadingAnchor.constraint(equalTo: blurEffectView.leadingAnchor),
      button.trailingAnchor.constraint(equalTo: blurEffectView.trailingAnchor),
      button.topAnchor.constraint(equalTo: topAnchor),
      button.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    // Make it a perfect pill shape by setting corner radius to half the height
    blurEffectView.layer.cornerRadius = blurEffectView.bounds.height / 2
    blurEffectView.layer.cornerCurve = .continuous
    blurEffectView.clipsToBounds = true
  }

  func configure(with dateString: String, onTap: (() -> Void)? = nil) {
    self.onTap = onTap
    button.isEnabled = onTap != nil
    button.accessibilityLabel = onTap == nil ? nil : "Show first message from \(dateString)"

    // Performance optimization: Only update if the date string actually changed
    guard currentDateString != dateString else { return }

    let shouldAnimate = !currentDateString.isEmpty && !dateString.isEmpty
    currentDateString = dateString
    label.text = dateString

    if shouldAnimate {
      // Fade in animation
      alpha = 0
      UIView.animate(withDuration: 0.2, delay: 0, options: [.allowUserInteraction]) {
        self.alpha = 1
      }
    } else {
      alpha = 1
    }
  }

  @objc private func didTap() {
    onTap?()
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    currentDateString = ""
    onTap = nil
    button.isEnabled = false
    button.accessibilityLabel = nil
    label.text = ""
    alpha = 1
  }
}
