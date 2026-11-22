import UIKit

/// The unread line's look, shared by the collection view's cell and the timeline's row: a subtle
/// full-width band behind the text, as the macOS list draws it.
enum MessageListSeparatorStyle {
  /// Space between the row's edges and the band, top and bottom.
  static let bandInset: CGFloat = 4

  static let bandColor = UIColor { traits in
    traits.userInterfaceStyle == .dark
      ? UIColor.white.withAlphaComponent(0.08)
      : UIColor.black.withAlphaComponent(0.05)
  }

  static let textColor = UIColor { traits in
    traits.userInterfaceStyle == .dark
      ? UIColor.white.withAlphaComponent(0.72)
      : UIColor.black.withAlphaComponent(0.6)
  }
}

final class MessageListSeparatorCell: UICollectionViewCell {
  static let reuseIdentifier = "MessageListSeparatorCell"

  private let label = UILabel()
  private let band = UIView()
  private var onTap: (() -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    setup()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(title: String, showsBand: Bool = true, onTap: (() -> Void)? = nil) {
    label.text = title
    band.isHidden = !showsBand
    label.textColor = showsBand ? MessageListSeparatorStyle.textColor : .secondaryLabel
    self.onTap = onTap
    label.isUserInteractionEnabled = onTap != nil
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    label.text = nil
    band.isHidden = false
    label.textColor = MessageListSeparatorStyle.textColor
    label.isUserInteractionEnabled = false
    onTap = nil
  }

  private func setup() {
    contentView.transform = CGAffineTransform(scaleX: 1, y: -1)

    label.font = .systemFont(ofSize: 12, weight: .semibold)
    label.textColor = MessageListSeparatorStyle.textColor
    label.textAlignment = .center
    label.setContentCompressionResistancePriority(.required, for: .horizontal)
    label.translatesAutoresizingMaskIntoConstraints = false

    band.backgroundColor = MessageListSeparatorStyle.bandColor
    band.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(band)
    contentView.addSubview(label)
    label.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(didTapLabel)))

    let inset = MessageListSeparatorStyle.bandInset
    NSLayoutConstraint.activate([
      contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 34),

      band.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      band.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      band.topAnchor.constraint(equalTo: contentView.topAnchor, constant: inset),
      band.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -inset),

      label.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
      label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
      label.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 16),
      label.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -16),
    ])
  }

  @objc private func didTapLabel() {
    onTap?()
  }
}
