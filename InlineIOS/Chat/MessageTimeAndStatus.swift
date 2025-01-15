import InlineKit
import UIKit

private let dateFormatter: DateFormatter = {
  let formatter = DateFormatter()
  formatter.dateFormat = "HH:mm"
  return formatter
}()

class MessageTimeAndStatus: UIView {
  private let symbolSize: CGFloat = 9

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

  let fullMessage: FullMessage

  var message: Message {
    fullMessage.message
  }

  var outgoing: Bool {
    message.out ?? false
  }

  var textColor: UIColor {
    outgoing ? UIColor.white.withAlphaComponent(0.7) : .gray
  }

  var imageColor: UIColor {
    message.status == .failed
      ? (outgoing ? UIColor.white.withAlphaComponent(0.7) : .red)
      : (outgoing ? UIColor.white.withAlphaComponent(0.7) : .gray)
  }

  init(_ message: FullMessage) {
    fullMessage = message
    super.init(frame: .zero)
    setupViews()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupViews() {
    addSubview(dateLabel)
    addSubview(statusImageView)

    setupConstraints()
    setupAppearance()
  }

  func setupConstraints() {
    if outgoing {
      NSLayoutConstraint.activate([
        dateLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        dateLabel.leadingAnchor.constraint(equalTo: leadingAnchor),

        statusImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
        statusImageView.leadingAnchor.constraint(equalTo: dateLabel.trailingAnchor, constant: 4),
        statusImageView.trailingAnchor.constraint(equalTo: trailingAnchor),
        statusImageView.widthAnchor.constraint(equalToConstant: symbolSize),
        statusImageView.heightAnchor.constraint(equalToConstant: symbolSize),
      ])
    } else {
      NSLayoutConstraint.activate([
        dateLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        dateLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
        dateLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
      ])
    }
  }

  func setupAppearance() {
    dateLabel.text = dateFormatter.string(from: message.date)
    dateLabel.textColor = textColor

    let imageName: String
    let symbolConfig = UIImage.SymbolConfiguration(pointSize: symbolSize)
      .applying(UIImage.SymbolConfiguration(weight: .medium))

    switch message.status {
    case .sent:
      imageName = "checkmark"
      statusImageView.preferredSymbolConfiguration = symbolConfig
    case .sending:
      imageName = "clock"
      statusImageView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: symbolSize - 1)
        .applying(UIImage.SymbolConfiguration(weight: .medium))
    case .failed:
      imageName = "exclamationmark"
      statusImageView.preferredSymbolConfiguration = symbolConfig
    case .none:
      imageName = ""
    }

    if let newImage = UIImage(systemName: imageName) {
      statusImageView.setSymbolImage(newImage, contentTransition: .replace)
    }

    statusImageView.tintColor = imageColor
  }
}
