import InlineKit
import SwiftUI
import UIKit

class UIMessageView: UIView {
  // MARK: - Properties

  enum MessageLayout {
    case singleLine
    case multiline
  }

  private var cachedSize: CGSize = .zero
  private var cachedText: String = ""
  private var cachedWidth: CGFloat = 0

  private enum LayoutCache {
    static var textSizes: NSCache<NSString, NSValue> = {
      let cache = NSCache<NSString, NSValue>()
      cache.countLimit = 1000
      return cache
    }()
  }

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

  private let metadataView: MessageMetadata = {
    let metadata = MessageMetadata(date: Date(), status: nil, isOutgoing: false)
    metadata.translatesAutoresizingMaskIntoConstraints = false
    return metadata
  }()

  private var leadingConstraint: NSLayoutConstraint?
  private var trailingConstraint: NSLayoutConstraint?
  private var fullMessage: FullMessage

  private let horizontalPadding: CGFloat = 12
  private let verticalPadding: CGFloat = 8

  private var messageLayout: MessageLayout = .singleLine

  private var maximumTextWidth: CGFloat {
    let totalWidth = bounds.width * 0.9 // 90% of parent width
    let horizontalInsets = horizontalPadding * 2
    let metadataWidth = metadataView.intrinsicContentSize.width
    return totalWidth - horizontalInsets - (metadataWidth > 0 ? metadataWidth + 8 : 0)
  }

  // MARK: - Initialization

  init(fullMessage: FullMessage) {
    self.fullMessage = fullMessage
    super.init(frame: .zero)
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
    bubbleView.addSubview(metadataView)

    let leading = bubbleView.leadingAnchor.constraint(equalTo: leadingAnchor)
    let trailing = bubbleView.trailingAnchor.constraint(equalTo: trailingAnchor)

    leadingConstraint = leading
    trailingConstraint = trailing

    var constraints = [
      bubbleView.topAnchor.constraint(equalTo: topAnchor),
      bubbleView.bottomAnchor.constraint(equalTo: bottomAnchor),
      bubbleView.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.9),

      messageLabel.topAnchor.constraint(equalTo: bubbleView.topAnchor, constant: verticalPadding),
      messageLabel.leadingAnchor.constraint(
        equalTo: bubbleView.leadingAnchor, constant: horizontalPadding
      ),
      messageLabel.bottomAnchor.constraint(
        equalTo: bubbleView.bottomAnchor, constant: -verticalPadding
      ),
    ]

    constraints.append(contentsOf: metadataConstrains())

    NSLayoutConstraint.activate(constraints)

    // Set proper content hugging and compression resistance
    messageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    messageLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

    metadataView.setContentCompressionResistancePriority(.required, for: .horizontal)
    metadataView.setContentHuggingPriority(.required, for: .horizontal)

    let interaction = UIContextMenuInteraction(delegate: self)
    bubbleView.addInteraction(interaction)
  }

  private func calculateMessageLayout() {
    guard messageLabel.text != nil, bounds.width > 0 else { return }

    // Check for explicit line breaks first
    if messageLabel.text?.contains("\n") == true {
      messageLayout = .multiline
      return
    }

    let currentWidth = bounds.width
    let text = messageLabel.text ?? ""

    // Return cached result if nothing changed
    if cachedText == text && abs(cachedWidth - currentWidth) < 0.001 {
      return
    }

    // Create cache key
    let cacheKey = "\(text):\(currentWidth)" as NSString

    // Try to get cached size
    if let cachedValue = LayoutCache.textSizes.object(forKey: cacheKey) {
      let size = cachedValue.cgSizeValue
      messageLayout = size.height > messageLabel.font.lineHeight * 1.5 ? .multiline : .singleLine
      cachedSize = size
      cachedText = text
      cachedWidth = currentWidth
      return
    }

    // Calculate size if not cached
    let maxWidth = maximumTextWidth
    let size = calculateTextSize(text: text, maxWidth: maxWidth)

    // Cache the result
    LayoutCache.textSizes.setObject(NSValue(cgSize: size), forKey: cacheKey)

    // Update state
    messageLayout = size.height > messageLabel.font.lineHeight * 1.5 ? .multiline : .singleLine
    cachedSize = size
    cachedText = text
    cachedWidth = currentWidth
  }

  private func calculateTextSize(text: String, maxWidth: CGFloat) -> CGSize {
    let attributes: [NSAttributedString.Key: Any] = [
      .font: messageLabel.font as Any,
    ]

    let constraintRect = CGSize(width: maxWidth, height: .greatestFiniteMagnitude)
    let boundingBox = text.boundingRect(
      with: constraintRect,
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      attributes: attributes,
      context: nil
    )

    return CGSize(
      width: ceil(boundingBox.width),
      height: ceil(boundingBox.height)
    )
  }

  func metadataConstrains() -> [NSLayoutConstraint] {
    switch messageLayout {
    case .singleLine:
      return [
        metadataView.bottomAnchor.constraint(
          equalTo: bubbleView.bottomAnchor, constant: -verticalPadding
        ),
        metadataView.leadingAnchor.constraint(equalTo: messageLabel.trailingAnchor, constant: 8),
        metadataView.trailingAnchor.constraint(
          equalTo: bubbleView.trailingAnchor, constant: -horizontalPadding
        ),
        metadataView.centerYAnchor.constraint(equalTo: messageLabel.centerYAnchor),
      ]

    case .multiline:
      return [
        metadataView.bottomAnchor.constraint(equalTo: bubbleView.bottomAnchor, constant: -16),
        metadataView.leadingAnchor.constraint(
          equalTo: bubbleView.leadingAnchor, constant: horizontalPadding
        ),
      ]
    }
  }

  private func configureForMessage() {
    messageLabel.text = fullMessage.message.text
    calculateMessageLayout()
    print("Configuring message layout: \(messageLayout) \(messageLabel.text)")

    bubbleView.layer.cornerRadius = 18

    if fullMessage.message.out == true {
      bubbleView.backgroundColor = ColorManager.shared.selectedColor
      leadingConstraint?.isActive = false
      trailingConstraint?.isActive = true
      messageLabel.textColor = .white
      metadataView.configure(
        date: fullMessage.message.date,
        status: fullMessage.message.status,
        isOutgoing: true
      )
    } else {
      bubbleView.backgroundColor = UIColor.systemGray6.withAlphaComponent(0.7)
      leadingConstraint?.isActive = true
      trailingConstraint?.isActive = false
      messageLabel.textColor = .label
      metadataView.configure(
        date: fullMessage.message.date,
        status: nil,
        isOutgoing: false
      )
    }
    updateLayout()
  }

  func updateLayout() {
    setNeedsLayout()
    layoutIfNeeded()
  }

  // MARK: - Layout

  override func layoutSubviews() {
    super.layoutSubviews()
    calculateMessageLayout()
    print("Layout subviews with message layout: \(messageLayout) \(fullMessage.message.text)")
  }

  static func clearCache() {
    LayoutCache.textSizes.removeAllObjects()
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)

    if previousTraitCollection?.preferredContentSizeCategory
      != traitCollection.preferredContentSizeCategory
    {
      UIMessageView.clearCache()
      setNeedsLayout()
    }
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window == nil {
      if let text = messageLabel.text {
        let cacheKey = "\(text):\(bounds.width)" as NSString
        LayoutCache.textSizes.removeObject(forKey: cacheKey)
      }
    }
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
