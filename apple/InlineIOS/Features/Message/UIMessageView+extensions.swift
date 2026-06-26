import Auth
import GRDB
import InlineKit
import InlineProtocol
import InlineUI
import Logger
import SwiftUI
import UIKit

enum MessageBubbleTailSide: Equatable {
  case none
  case leading
  case trailing
}

final class MessageBubbleView: UIView {
  private static let sourceSize = CGSize(width: 42, height: 36)
  private static let sourceTailBottomY: CGFloat = 35
  private static let tailDrawScale: CGFloat = 1.08
  private static let exposedTailWidth: CGFloat = 6.3
  static let cornerRadius: CGFloat = 18

  static func tailWidth(for side: MessageBubbleTailSide) -> CGFloat {
    side == .none ? 0 : exposedTailWidth
  }

  let contentView = UIView()

  private let fillLayer = CAShapeLayer()
  private var colorTraitRegistration: UITraitChangeRegistration?
  private var contentLeadingConstraint: NSLayoutConstraint?
  private var contentTrailingConstraint: NSLayoutConstraint?

  private(set) var side: MessageBubbleTailSide = .none

  private var fillColor: UIColor = .clear

  override var backgroundColor: UIColor? {
    get { fillColor }
    set {
      fillColor = newValue ?? .clear
      super.backgroundColor = .clear
      updateShape()
    }
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    super.backgroundColor = .clear
    isOpaque = false
    layer.cornerRadius = Self.cornerRadius
    fillLayer.contentsScale = UIScreen.main.scale
    fillLayer.fillRule = .nonZero
    layer.insertSublayer(fillLayer, at: 0)

    contentView.translatesAutoresizingMaskIntoConstraints = false
    contentView.backgroundColor = .clear
    contentView.clipsToBounds = true
    contentView.layer.cornerRadius = Self.cornerRadius
    addSubview(contentView)

    let leading = contentView.leadingAnchor.constraint(equalTo: leadingAnchor)
    let trailing = contentView.trailingAnchor.constraint(equalTo: trailingAnchor)
    contentLeadingConstraint = leading
    contentTrailingConstraint = trailing
    NSLayoutConstraint.activate([
      contentView.topAnchor.constraint(equalTo: topAnchor),
      leading,
      trailing,
      contentView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])

    colorTraitRegistration = registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
      (view: MessageBubbleView, _: UITraitCollection) in
      view.updateShape()
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    updateShape()
  }

  func configure(side: MessageBubbleTailSide) {
    guard self.side != side else { return }
    self.side = side
    updateContentInsets()
    updateShape()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func visiblePath() -> UIBezierPath {
    bubblePath(in: bounds)
  }

  private var resolvedFillColor: UIColor {
    fillColor.resolvedColor(with: traitCollection)
  }

  private var tailWidth: CGFloat {
    Self.tailWidth(for: side)
  }

  private var contentRect: CGRect {
    bounds.inset(by: UIEdgeInsets(
      top: 0,
      left: side == .leading ? tailWidth : 0,
      bottom: 0,
      right: side == .trailing ? tailWidth : 0
    ))
  }

  private func updateContentInsets() {
    contentLeadingConstraint?.constant = side == .leading ? tailWidth : 0
    contentTrailingConstraint?.constant = side == .trailing ? -tailWidth : 0
  }

  private func updateShape() {
    let color = resolvedFillColor
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    fillLayer.frame = bounds
    fillLayer.fillColor = color.cgColor
    fillLayer.path = visiblePath().cgPath
    fillLayer.isHidden = color.cgColor.alpha <= 0.01
    CATransaction.commit()
  }

  private func bubblePath(in rect: CGRect) -> UIBezierPath {
    let contentRect = contentRect.intersection(rect)
    guard !contentRect.isNull, contentRect.width > 0, contentRect.height > 0 else {
      return UIBezierPath()
    }

    let path = UIBezierPath(roundedRect: contentRect, cornerRadius: Self.cornerRadius)
    guard side != .none else { return path }

    let drawSize = CGSize(
      width: Self.sourceSize.width * Self.tailDrawScale,
      height: Self.sourceSize.height * Self.tailDrawScale
    )
    let tailY = contentRect.maxY - Self.sourceTailBottomY * Self.tailDrawScale

    let tailRect: CGRect
    switch side {
    case .none:
      return path
    case .leading:
      tailRect = CGRect(
        x: contentRect.minX - Self.exposedTailWidth,
        y: tailY,
        width: drawSize.width,
        height: drawSize.height
      )
    case .trailing:
      tailRect = CGRect(
        x: contentRect.maxX + Self.exposedTailWidth - drawSize.width,
        y: tailY,
        width: drawSize.width,
        height: drawSize.height
      )
    }

    path.append(tailPath(in: tailRect))
    return path
  }

  private func tailPath(in rect: CGRect) -> UIBezierPath {
    let scaleX = rect.width / Self.sourceSize.width
    let scaleY = rect.height / Self.sourceSize.height

    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
      let resolvedX: CGFloat = switch side {
      case .none, .leading:
        rect.minX + x * scaleX
      case .trailing:
        rect.maxX - x * scaleX
      }
      return CGPoint(x: resolvedX, y: rect.minY + y * scaleY)
    }

    let path = UIBezierPath()
    path.move(to: point(6, 17.5))
    path.addCurve(
      to: point(23.5, 0.2),
      controlPoint1: point(6, 7.9),
      controlPoint2: point(13.85, 0.2)
    )
    path.addCurve(
      to: point(40.8, 17.5),
      controlPoint1: point(33.05, 0.2),
      controlPoint2: point(40.8, 7.95)
    )
    path.addCurve(
      to: point(23.5, 34.8),
      controlPoint1: point(40.8, 27.05),
      controlPoint2: point(33.05, 34.8)
    )
    path.addCurve(
      to: point(12.4, 31.05),
      controlPoint1: point(19.3, 34.8),
      controlPoint2: point(15.45, 33.35)
    )
    path.addCurve(
      to: point(0.15, 35),
      controlPoint1: point(9.15, 34.75),
      controlPoint2: point(0.45, 35)
    )
    path.addCurve(
      to: point(6, 26.9),
      controlPoint1: point(5.8, 31.7),
      controlPoint2: point(6, 26.9)
    )
    path.close()
    return side == .trailing ? path.reversing() : path
  }
}

// MARK: - UI

extension UIMessageView {
  static func createBubbleView() -> MessageBubbleView {
    let view = MessageBubbleView()
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }

  func createContainerStack() -> UIStackView {
    let stack = UIStackView()
    stack.axis = .vertical
    stack.spacing = 4
    stack.alignment = .fill
    stack.distribution = .fill
    stack.translatesAutoresizingMaskIntoConstraints = false
    return stack
  }

  func createSingleLineStack() -> UIStackView {
    let stack = UIStackView()
    stack.axis = .horizontal
    stack.spacing = 6
    stack.alignment = .center
    stack.distribution = .fill
    stack.translatesAutoresizingMaskIntoConstraints = false
    return stack
  }

  func createMultiLineStack() -> UIStackView {
    let stack = UIStackView()
    stack.axis = .vertical
    stack.spacing = 10
    stack.alignment = .fill
    stack.distribution = .fill
    stack.translatesAutoresizingMaskIntoConstraints = false
    return stack
  }

  func createMessageLabel() -> UITextView {
    let textView = CodeBlockTextView()
    textView.backgroundColor = .clear
    textView.textAlignment = .natural
    textView.font = .systemFont(ofSize: 17)
    textView.textColor = textColor
    textView.isEditable = false
    textView.isSelectable = false
    textView.isScrollEnabled = false
    textView.dataDetectorTypes = []
    textView.textContainer.lineFragmentPadding = 0
    textView.textContainerInset = .zero
    textView.linkTextAttributes = [:]
    return textView
  }

  func createUnsupportedLabel() -> UILabel {
    let label = UILabel()
    label.text = "Unsupported message"
    label.backgroundColor = .clear
    label.textAlignment = .natural
    label.font = .italicSystemFont(ofSize: 18)
    label.textColor = textColor.withAlphaComponent(0.9)
    label.numberOfLines = 0

    return label
  }

  func createEmbedView() -> EmbedMessageView {
    let view = EmbedMessageView()
    return view
  }

  func createForwardHeaderLabel() -> UILabel {
    let label = UILabel()
    label.font = .preferredFont(forTextStyle: .caption1)
    label.textColor = ThemeManager.shared.selected.accent
    label.numberOfLines = 1
    label.lineBreakMode = .byTruncatingTail
    label.setContentCompressionResistancePriority(.required, for: .vertical)
    label.isUserInteractionEnabled = true
    let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleForwardHeaderTap))
    label.addGestureRecognizer(tapGesture)
    return label
  }

  func createPhotoView() -> PhotoView {
    let view = PhotoView(fullMessage)
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }

  func createNewPhotoView() -> NewPhotoView {
    let view = NewPhotoView(fullMessage)
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }

  func createVideoView() -> NewVideoView {
    let view = NewVideoView(fullMessage)
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }

  func createFloatingMetadataView() -> FloatingMetadataView {
    let view = FloatingMetadataView(fullMessage: fullMessage)
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }

  func createDocumentView() -> DocumentView {
    let view = DocumentView(fullMessage: fullMessage, outgoing: outgoing)
    view.translatesAutoresizingMaskIntoConstraints = false

    return view
  }

  func createVoiceMessageViewController() -> UIHostingController<VoiceMessageBubble> {
    let controller = UIHostingController(
      rootView: VoiceMessageBubble(message: fullMessage.message, outgoing: outgoing)
    )
    controller.safeAreaRegions = []
    controller.view.translatesAutoresizingMaskIntoConstraints = false
    controller.view.backgroundColor = .clear
    NSLayoutConstraint.activate([
      controller.view.widthAnchor.constraint(equalToConstant: 240),
      controller.view.heightAnchor.constraint(equalToConstant: 54),
    ])
    return controller
  }

  func createMessageAttachmentEmbed() -> MessageAttachmentEmbed {
    let view = MessageAttachmentEmbed()
    view.translatesAutoresizingMaskIntoConstraints = false

    return view
  }

  func createMessageTimeAndStatus() -> MessageTimeAndStatus {
    let view = MessageTimeAndStatus(fullMessage)
    view.translatesAutoresizingMaskIntoConstraints = false

    return view
  }

  func createMessageActionsContainer() -> UIStackView {
    let stack = UIStackView()
    stack.axis = .vertical
    stack.spacing = 4
    stack.alignment = .fill
    stack.distribution = .fill
    stack.translatesAutoresizingMaskIntoConstraints = false
    return stack
  }

  func createReplyThreadSummaryView() -> ReplyThreadSummaryView {
    let view = ReplyThreadSummaryView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.setContentCompressionResistancePriority(.required, for: .vertical)
    return view
  }

  func createMessageActionRowStack() -> UIStackView {
    let stack = UIStackView()
    stack.axis = .horizontal
    stack.spacing = 4
    stack.alignment = .fill
    stack.distribution = .fillEqually
    stack.translatesAutoresizingMaskIntoConstraints = false
    return stack
  }

  func createMessageActionButton(for action: InlineProtocol.MessageAction) -> MessageActionButton {
    let button = MessageActionButton(type: .system)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.configure(action: action, outgoing: outgoing)
    button.addTarget(self, action: #selector(handleMessageActionButtonTap), for: .touchUpInside)
    return button
  }
}

// MARK: - UIGestureRecognizerDelegate

extension UIMessageView: UIGestureRecognizerDelegate {
  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
  ) -> Bool {
    // Allow simultaneous recognition with context menu interaction
    if otherGestureRecognizer is UILongPressGestureRecognizer, gestureRecognizer is UITapGestureRecognizer {
      let tapGesture = gestureRecognizer as! UITapGestureRecognizer
      return tapGesture.numberOfTapsRequired == 2
    }
    return false
  }
}

// MARK: - UIColor

extension UIColor {
  static let adaptiveBackground = UIColor { traitCollection in
    traitCollection.userInterfaceStyle == .dark ?
      UIColor(hex: "#6E242D")! : UIColor(hex: "#FFC4CB")!
  }

  static let adaptiveTitle = UIColor { traitCollection in
    traitCollection.userInterfaceStyle == .dark ?
      UIColor(hex: "#FFC2C0")! : UIColor(hex: "#D5312B")!
  }
}

// MARK: - Emoji detection

extension String {
  var containsEmoji: Bool {
    contains { $0.isEmoji }
  }

  var containsOnlyEmojis: Bool {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return !trimmed.isEmpty && trimmed.allSatisfy(\.isEmoji)
  }
}

extension Character {
  /// A simple emoji is one scalar and presented to the user as an Emoji
  var isSimpleEmoji: Bool {
    guard let firstScalar = unicodeScalars.first else { return false }
    return firstScalar.properties.isEmoji && firstScalar.value > 0x238C
  }

  /// Checks if the scalars will be merged into an emoji
  var isCombinedIntoEmoji: Bool { unicodeScalars.count > 1 && unicodeScalars.first?.properties.isEmoji ?? false }

  var isEmoji: Bool { isSimpleEmoji || isCombinedIntoEmoji }
}

// MARK: - Other

extension NSLayoutConstraint {
  func withPriority(_ priority: UILayoutPriority) -> NSLayoutConstraint {
    self.priority = priority
    return self
  }
}
