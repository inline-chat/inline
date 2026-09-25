import InlineKit
import UIKit

private let dateFormatter: DateFormatter = {
  let formatter = DateFormatter()
  formatter.dateFormat = "HH:mm"
  return formatter
}()

class MessageTimeAndStatus: UIView {
  private static let statusTransitionDuration: CFTimeInterval = 0.25
  private var symbolSize: CGFloat {
    ChatTypography.font(11, style: .caption2, compatibleWith: traitCollection).pointSize
  }
  private var symbolWidthConstraint: NSLayoutConstraint?
  private var symbolHeightConstraint: NSLayoutConstraint?

  override var intrinsicContentSize: CGSize {
    CGSize(
      width: Self.measuredWidth(for: fullMessage, compatibleWith: traitCollection),
      height: max(symbolSize, ceil(dateLabel.font.lineHeight))
    )
  }

  static func measuredWidth(for message: FullMessage, compatibleWith traits: UITraitCollection? = nil) -> CGFloat {
    let font = ChatTypography.font(11, style: .caption2, compatibleWith: traits)
    let dateText = dateFormatter.string(from: message.message.date)
    let dateWidth = ceil((dateText as NSString).size(withAttributes: [.font: font]).width)
    return message.message.out == true ? dateWidth + 2 + font.pointSize : dateWidth
  }

  private let dateLabel: UILabel = {
    let label = UILabel()
    label.font = ChatTypography.font(11, style: .caption2)
    // The parent refreshes both the font and symbol constraints in the same trait update.
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
    registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: MessageTimeAndStatus, _: UITraitCollection) in
      view.dateLabel.font = ChatTypography.font(11, style: .caption2, compatibleWith: view.traitCollection)
      view.symbolWidthConstraint?.constant = view.symbolSize
      view.symbolHeightConstraint?.constant = view.symbolSize
      view.updateStatusImage(animated: false)
      view.invalidateIntrinsicContentSize()
    }
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
      symbolWidthConstraint = statusImageView.widthAnchor.constraint(equalToConstant: symbolSize)
      symbolHeightConstraint = statusImageView.heightAnchor.constraint(equalToConstant: symbolSize)
      constraints += [
        dateLabel.trailingAnchor.constraint(equalTo: statusImageView.leadingAnchor, constant: -2),
        statusImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
        statusImageView.trailingAnchor.constraint(equalTo: trailingAnchor),
        symbolWidthConstraint!,
        symbolHeightConstraint!,
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
    let symbolConfig = UIImage.SymbolConfiguration(font: ChatTypography.font(
      11, weight: .medium, style: .caption2, compatibleWith: traitCollection
    ))

    switch displayedStatus {
      case .sent:
        imageName = "checkmark"
        statusImageView.preferredSymbolConfiguration = symbolConfig
      case .sending:
        imageName = "clock"
        statusImageView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(font: ChatTypography.font(
          10, weight: .medium, style: .caption2, compatibleWith: traitCollection
        ))
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
