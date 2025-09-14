import UIKit

final class DateSeparatorView: UICollectionReusableView {
  static let reuseIdentifier = "DateSeparatorView"
  static let height: CGFloat = 44

  // Performance optimization: Cache the current date string to avoid unnecessary updates
  private var currentDateString: String = ""

  private let label: UILabel = {
    let label = UILabel()
    label.font = UIFont.systemFont(ofSize: 12, weight: .regular)
    label.textColor = UIColor.label
    label.textAlignment = .center
    label.translatesAutoresizingMaskIntoConstraints = false
    return label
  }()

  private let blurEffectView: UIVisualEffectView = {
    let blurEffect = UIBlurEffect(style: .systemThinMaterial)
    let effectView = UIVisualEffectView(effect: blurEffect)
    effectView.translatesAutoresizingMaskIntoConstraints = false
    return effectView
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
    ])
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    // Make it a perfect pill shape by setting corner radius to half the height
    blurEffectView.layer.cornerRadius = blurEffectView.bounds.height / 2
    blurEffectView.layer.cornerCurve = .continuous
    blurEffectView.clipsToBounds = true
  }

  func configure(with dateString: String) {
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

  override func prepareForReuse() {
    super.prepareForReuse()
    currentDateString = ""
    label.text = ""
    alpha = 1
  }
}
