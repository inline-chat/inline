import InlineKit
import UIKit

class EmbedMessageView: UIView {
  lazy var messageLabel: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = .systemFont(ofSize: 14)
    label.textColor = .gray
    label.numberOfLines = 1
    label.text = "Replying to a message"
    return label
  }()

  override init(frame: CGRect) {
    super.init(frame: frame)

    setupViews()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
  }

  private func setupViews() {
    backgroundColor = .red
    addSubview(messageLabel)
    NSLayoutConstraint.activate([
      messageLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
      messageLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
      messageLabel.topAnchor.constraint(equalTo: topAnchor),
      messageLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }
}
