import InlineKit
import SwiftUI
import UIKit

class UIMessageView: UIView {
  // MARK: - Properties

  private let messageLabel: UILabel = {
    let label = UILabel()
    label.numberOfLines = 0
    label.font = .systemFont(ofSize: 16, weight: .medium)
    label.textAlignment = .natural
    label.translatesAutoresizingMaskIntoConstraints = false

    return label
  }()

  private let bubbleView: UIView = {
    let view = UIView()
    view.layer.cornerRadius = 18
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private let metadataHostingController: UIHostingController<MessageMetadataView>

  private var leadingConstraint: NSLayoutConstraint?
  private var trailingConstraint: NSLayoutConstraint?
  private var fullMessage: FullMessage

  // Cache for layout calculations
  private var cachedMessageLayout: MessageLayout?

  // MARK: - Message Layout Enum

  private enum MessageLayout {
    case empty
    case singleLine
    case multiline(lineCount: Int)
  }

  // MARK: - Layout Detection

  private var messageLayout: MessageLayout {
    // Return cached layout if bounds are valid and cache exists
    if bounds.width > 0, let cached = cachedMessageLayout {
      return cached
    }

    guard let text = messageLabel.text, !text.isEmpty else { return .empty }

    // Calculate available width considering bubble constraints and padding
    let maxWidth = bounds.width * 0.85 - 24
    guard maxWidth > 0 else { return .singleLine }  // Guard against invalid width

    // Use sizeThatFits for more accurate measurement
    let size = messageLabel.sizeThatFits(CGSize(width: maxWidth, height: .greatestFiniteMagnitude))
    let singleLineSize = messageLabel.sizeThatFits(
      CGSize(width: .greatestFiniteMagnitude, height: messageLabel.font.lineHeight))

    let layout: MessageLayout
    if size.height > (singleLineSize.height + 1) {
      let lineCount = Int(ceil(size.height / messageLabel.font.lineHeight))
      layout = .multiline(lineCount: lineCount)
    } else {
      layout = .singleLine
    }

    // Cache the result
    cachedMessageLayout = layout
    return layout
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    // Invalidate cache when bounds change
    cachedMessageLayout = nil
    // Reconfigure message after layout
    configureForMessage()
    updateMetadataConstraints()
  }

  // MARK: - Initialization

  init(fullMessage: FullMessage) {
    self.fullMessage = fullMessage

    self.metadataHostingController = UIHostingController(
      rootView: MessageMetadataView(
        date: fullMessage.message.date,
        status: fullMessage.message.status,
        isOutgoing: fullMessage.message.out ?? false
      )
    )

    super.init(frame: .zero)

    metadataHostingController.view.backgroundColor = .clear
    metadataHostingController.view.translatesAutoresizingMaskIntoConstraints = false

    setupViews()
    configureForMessage()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - Setup

  private func setupViews() {
    addSubview(bubbleView)
    bubbleView.addSubview(messageLabel)
    bubbleView.addSubview(metadataHostingController.view)

    let leading = bubbleView.leadingAnchor.constraint(equalTo: leadingAnchor)
    let trailing = bubbleView.trailingAnchor.constraint(equalTo: trailingAnchor)

    leadingConstraint = leading
    trailingConstraint = trailing

    NSLayoutConstraint.activate([
      bubbleView.topAnchor.constraint(equalTo: topAnchor),
      bubbleView.bottomAnchor.constraint(equalTo: bottomAnchor),
      bubbleView.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.85),

      messageLabel.topAnchor.constraint(equalTo: bubbleView.topAnchor, constant: 8),
      messageLabel.leadingAnchor.constraint(equalTo: bubbleView.leadingAnchor, constant: 12),
      messageLabel.trailingAnchor.constraint(equalTo: bubbleView.trailingAnchor, constant: -12),
      messageLabel.bottomAnchor.constraint(equalTo: bubbleView.bottomAnchor, constant: -8),
    ])

    updateMetadataConstraints()

    let interaction = UIContextMenuInteraction(delegate: self)
    bubbleView.addInteraction(interaction)
  }

  private func updateMetadataConstraints() {
    // Remove existing constraints
    metadataHostingController.view.removeFromSuperview()
    bubbleView.addSubview(metadataHostingController.view)

    switch messageLayout {
    case .empty, .singleLine:
      // Inline alignment for single line
      NSLayoutConstraint.activate([
        messageLabel.trailingAnchor.constraint(
          equalTo: bubbleView.trailingAnchor,
          constant: -12
        ),
        messageLabel.bottomAnchor.constraint(
          equalTo: metadataHostingController.view.topAnchor,
          constant: 8
        ),

        metadataHostingController.view.trailingAnchor.constraint(
          equalTo: bubbleView.trailingAnchor,
          constant: -12
        ),
        metadataHostingController.view.bottomAnchor.constraint(
          equalTo: bubbleView.bottomAnchor,
          constant: -16
        ),
      ])

    case .multiline:
      // Bottom alignment for multiline
      NSLayoutConstraint.activate([
        messageLabel.trailingAnchor.constraint(
          equalTo: bubbleView.trailingAnchor,
          constant: -12
        ),
        messageLabel.bottomAnchor.constraint(
          equalTo: metadataHostingController.view.topAnchor,
          constant: 8
        ),

        metadataHostingController.view.trailingAnchor.constraint(
          equalTo: bubbleView.trailingAnchor,
          constant: -12
        ),
        metadataHostingController.view.bottomAnchor.constraint(
          equalTo: bubbleView.bottomAnchor,
          constant: -16
        ),
      ])
    }
  }

  private func configureForMessage() {
    messageLabel.text = fullMessage.message.text

    // Configure bubble alignment first
    if fullMessage.message.out == true {
      bubbleView.backgroundColor = BubbleColorManager.shared.selectedColor
      leadingConstraint?.isActive = false
      trailingConstraint?.isActive = true
    } else {
      bubbleView.backgroundColor = BubbleColorManager.shared.selectedSecondaryColor
      leadingConstraint?.isActive = true
      trailingConstraint?.isActive = false
    }

    // Configure text color based on layout
    switch messageLayout {
    case .empty:
      messageLabel.textColor = fullMessage.message.out == true ? .white : .label

    case .singleLine:
      messageLabel.textColor = fullMessage.message.out == true ? .white : .label
      let widthConstraint = messageLabel.widthAnchor.constraint(
        equalToConstant: messageLabel.intrinsicContentSize.width + 65.0
      )
      widthConstraint.isActive = true
    case .multiline:
      messageLabel.textColor = fullMessage.message.out == true ? .white : .label
    }
  }

  func updateLayout() {
    setNeedsLayout()
    layoutIfNeeded()
  }

  func updateMetadata() {
    metadataHostingController.rootView = MessageMetadataView(
      date: fullMessage.message.date,
      status: fullMessage.message.status,
      isOutgoing: fullMessage.message.out ?? false
    )
  }
}

// MARK: - Context Menu

extension UIMessageView: UIContextMenuInteractionDelegate {
  func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    configurationForMenuAtLocation location: CGPoint
  ) -> UIContextMenuConfiguration? {
    return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
      let copyAction = UIAction(title: "Copy") { [weak self] _ in
        UIPasteboard.general.string = self?.fullMessage.message.text
      }
      return UIMenu(children: [copyAction])
    }
  }
}

extension String {
  var isRTL: Bool {
    guard let firstChar = first else { return false }
    let earlyRTL =
      firstChar.unicodeScalars.first?.properties.generalCategory == .otherLetter
      && firstChar.unicodeScalars.first != nil && firstChar.unicodeScalars.first!.value >= 0x0590
      && firstChar.unicodeScalars.first!.value <= 0x08FF

    if earlyRTL { return true }

    let language = CFStringTokenizerCopyBestStringLanguage(
      self as CFString, CFRange(location: 0, length: count)
    )
    if let language = language {
      return NSLocale.characterDirection(forLanguage: language as String) == .rightToLeft
    }
    return false
  }
}
