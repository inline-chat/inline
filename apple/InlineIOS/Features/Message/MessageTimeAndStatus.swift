import InlineKit
import UIKit

private let dateFormatter: DateFormatter = {
  let formatter = DateFormatter()
  formatter.dateFormat = "HH:mm"
  return formatter
}()

class MessageTimeAndStatus: UIView {
  private static let statusTransitionDuration: CFTimeInterval = 0.25
  private let symbolSize: CGFloat = 11

  override var intrinsicContentSize: CGSize {
    CGSize(
      width: Self.measuredWidth(for: fullMessage),
      height: symbolSize
    )
  }

  static func measuredWidth(for message: FullMessage) -> CGFloat {
    let font = UIFont.systemFont(ofSize: 11)
    let dateText = dateFormatter.string(from: message.message.date)
    let dateWidth = ceil((dateText as NSString).size(withAttributes: [.font: font]).width)
    return message.message.out == true ? dateWidth + 2 + 11 : dateWidth
  }

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

  private var fullMessage: FullMessage
  private var displayedStatus: MessageSendingStatus?

  var message: Message {
    fullMessage.message
  }

  var outgoing: Bool {
    message.out ?? false
  }

  var textColor: UIColor {
    outgoing ? UIColor.white.withAlphaComponent(0.7) : ThemeManager.shared.selected.secondaryTextColor ?? .gray
  }

  var imageColor: UIColor {
    message.status == .failed
      ? (outgoing ? UIColor.white.withAlphaComponent(0.7) : .red)
      : (outgoing ? UIColor.white.withAlphaComponent(0.7) : .gray)
  }

  init(
    _ message: FullMessage,
    initiallyDisplaying status: MessageSendingStatus? = nil
  ) {
    fullMessage = message
    displayedStatus = status ?? message.message.status
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
    setupAppearance(animated: false)
  }

  func setupConstraints() {
    var constraints: [NSLayoutConstraint] = [
      dateLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
      dateLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
    ]

    if outgoing {
      constraints += [
        dateLabel.trailingAnchor.constraint(equalTo: statusImageView.leadingAnchor, constant: -2),
        statusImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
        statusImageView.trailingAnchor.constraint(equalTo: trailingAnchor),
        statusImageView.widthAnchor.constraint(equalToConstant: symbolSize),
        statusImageView.heightAnchor.constraint(equalToConstant: symbolSize),
      ]
    } else {
      constraints += [
        dateLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
      ]
    }
    NSLayoutConstraint.activate(constraints)
  }

  func updateMessage(_ fullMessage: FullMessage, animated: Bool) {
    let previousStatus = displayedStatus
    self.fullMessage = fullMessage
    displayedStatus = message.status

    dateLabel.text = dateFormatter.string(from: message.date)
    dateLabel.textColor = textColor
    statusImageView.tintColor = imageColor

    guard previousStatus != displayedStatus else { return }
    updateStatusImage(animated: animated)
  }

  private func setupAppearance(animated: Bool) {
    dateLabel.text = dateFormatter.string(from: message.date)
    dateLabel.textColor = textColor

    updateStatusImage(animated: animated)
    statusImageView.tintColor = imageColor
  }

  private func updateStatusImage(animated: Bool) {
    let imageName: String
    let symbolConfig = UIImage.SymbolConfiguration(pointSize: symbolSize)
      .applying(UIImage.SymbolConfiguration(weight: .medium))

    switch displayedStatus {
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
      if animated, !UIAccessibility.isReduceMotionEnabled, statusImageView.image != nil {
        let transition = CATransition()
        transition.duration = Self.statusTransitionDuration
        transition.timingFunction = CAMediaTimingFunction(name: .default)
        transition.type = .fade
        statusImageView.layer.add(transition, forKey: "contents")
        statusImageView.image = newImage
      } else {
        statusImageView.image = newImage
      }
    } else {
      statusImageView.image = nil
    }
  }
}
