import InlineKit
import UIKit

private let dateFormatter: DateFormatter = {
  let formatter = DateFormatter()
  formatter.dateFormat = "HH:mm"
  return formatter
}()

class MessageMetadata: UIView {
  private let symbolSize: CGFloat = 12

  private let dateLabel: UILabel = {
    let label = UILabel()
    label.font = .systemFont(ofSize: 11)
    label.translatesAutoresizingMaskIntoConstraints = false
    return label
  }()

  private let statusImageView: UIImageView = {
    let imageView = UIImageView()
    imageView.contentMode = .scaleAspectFit
    imageView.translatesAutoresizingMaskIntoConstraints = false
    imageView.setContentHuggingPriority(.required, for: .horizontal)
    imageView.setContentCompressionResistancePriority(.required, for: .horizontal)
    return imageView
  }()

  private let stackView: UIStackView = {
    let stack = UIStackView()
    stack.axis = .horizontal
    stack.spacing = 4
    stack.alignment = .center
    stack.translatesAutoresizingMaskIntoConstraints = false
    return stack
  }()

  init(_ message: FullMessage) {
    super.init(frame: .zero)
    setupViews()
    configure(
      date: message.message.date, status: message.message.status,
      isOutgoing: message.message.out ?? false)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupViews() {
    addSubview(stackView)
    stackView.addArrangedSubview(dateLabel)
    stackView.addArrangedSubview(statusImageView)

    NSLayoutConstraint.activate([
      stackView.topAnchor.constraint(equalTo: topAnchor),
      stackView.bottomAnchor.constraint(equalTo: bottomAnchor),
      stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
      stackView.trailingAnchor.constraint(equalTo: trailingAnchor),

      statusImageView.widthAnchor.constraint(equalToConstant: symbolSize),
      statusImageView.heightAnchor.constraint(equalToConstant: symbolSize),
    ])
  }

  func configure(date: Date, status: MessageSendingStatus?, isOutgoing: Bool) {
    dateLabel.text = dateFormatter.string(from: date)
    dateLabel.textColor = isOutgoing ? UIColor.white.withAlphaComponent(0.7) : .gray

    if isOutgoing && status != nil {
      statusImageView.isHidden = false

      let imageName: String
      let symbolConfig = UIImage.SymbolConfiguration(pointSize: symbolSize)
        .applying(UIImage.SymbolConfiguration(weight: .medium))

      switch status {
      case .sent: imageName = "checkmark"
      case .sending: imageName = "clock"
      case .failed: imageName = "exclamationmark"
      case .none: imageName = ""
      }

      statusImageView.image = UIImage(systemName: imageName)?
        .withConfiguration(symbolConfig)
        .withAlignmentRectInsets(.init(top: 0, left: -2, bottom: 0, right: -2))

      statusImageView.tintColor =
        status == .failed
          ? (isOutgoing ? UIColor.white.withAlphaComponent(0.7) : .red)
          : (isOutgoing ? UIColor.white.withAlphaComponent(0.7) : .gray)
    } else {
      statusImageView.isHidden = true
    }
  }
}
