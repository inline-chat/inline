import UIKit

final class MessageListSeparatorCell: UICollectionViewCell {
  static let reuseIdentifier = "MessageListSeparatorCell"

  private let label = UILabel()
  private let leadingLine = UIView()
  private let trailingLine = UIView()
  private var clearedHistoryAction: (() -> Void)?

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
    clearedHistoryAction = nil
    label.isUserInteractionEnabled = false
    label.isAccessibilityElement = false
    label.accessibilityLabel = nil
    label.accessibilityHint = nil
    label.accessibilityTraits = []
  }

  func configureAsClearedHistory(title: String, action: @escaping () -> Void) {
    label.text = title
    clearedHistoryAction = action
    label.isUserInteractionEnabled = true
    label.isAccessibilityElement = true
    label.accessibilityLabel = title
    label.accessibilityHint = "Shows all messages"
    label.accessibilityTraits = .button
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    label.text = nil
    clearedHistoryAction = nil
    label.isUserInteractionEnabled = false
    label.isAccessibilityElement = false
    label.accessibilityLabel = nil
    label.accessibilityHint = nil
    label.accessibilityTraits = []
  }

  private func setup() {
    contentView.transform = CGAffineTransform(scaleX: 1, y: -1)

    label.font = .systemFont(ofSize: 12, weight: .semibold)
    label.textColor = .secondaryLabel
    label.textAlignment = .center
    label.setContentCompressionResistancePriority(.required, for: .horizontal)
    label.translatesAutoresizingMaskIntoConstraints = false
    label.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(didTapLabel)))

    for line in [leadingLine, trailingLine] {
      line.backgroundColor = .separator
      line.translatesAutoresizingMaskIntoConstraints = false
      contentView.addSubview(line)
    }
    contentView.addSubview(label)

    NSLayoutConstraint.activate([
      contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 34),

      label.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
      label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),

      leadingLine.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
      leadingLine.trailingAnchor.constraint(equalTo: label.leadingAnchor, constant: -10),
      leadingLine.centerYAnchor.constraint(equalTo: label.centerYAnchor),
      leadingLine.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),

      trailingLine.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 10),
      trailingLine.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
      trailingLine.centerYAnchor.constraint(equalTo: label.centerYAnchor),
      trailingLine.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),
    ])
  }

  @objc private func didTapLabel() {
    clearedHistoryAction?()
  }
}
