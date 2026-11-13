import UIKit

/// A quiet line under the newest message, such as "Sam has notifications silenced".
final class StatusNoticeCell: UICollectionViewCell {
  static let height: CGFloat = 30

  private let iconView = UIImageView()
  private let label = UILabel()

  override init(frame: CGRect) {
    super.init(frame: frame)
    setup()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(title: String) {
    label.text = title
    accessibilityLabel = title
  }

  private func setup() {
    // The list is inverted; cells flip back.
    contentView.transform = CGAffineTransform(scaleX: 1, y: -1)
    isAccessibilityElement = true

    iconView.image = UIImage(
      systemName: "moon.fill",
      withConfiguration: UIImage.SymbolConfiguration(font: .systemFont(ofSize: 10))
    )
    iconView.tintColor = .secondaryLabel
    iconView.setContentHuggingPriority(.required, for: .horizontal)

    label.font = .systemFont(ofSize: 12)
    label.textColor = .secondaryLabel
    label.adjustsFontForContentSizeCategory = false

    let stack = UIStackView(arrangedSubviews: [iconView, label])
    stack.axis = .horizontal
    stack.spacing = 4
    stack.alignment = .center
    stack.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(stack)

    NSLayoutConstraint.activate([
      contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.height),
      stack.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
      stack.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 16),
      stack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -16),
    ])
  }
}
