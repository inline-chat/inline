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

final class MessageBubbleTailView: UIView {
  static let size = CGSize(width: 16, height: 15)
  static let bubbleOverlap: CGFloat = 9
  static let bottomOffset: CGFloat = 0

  private var colorTraitRegistration: UITraitChangeRegistration?

  private(set) var side: MessageBubbleTailSide = .none

  private var fillColor: UIColor = .clear

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false
    isUserInteractionEnabled = false
    colorTraitRegistration = registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
      (view: MessageBubbleTailView, _: UITraitCollection) in
      view.updateVisibility()
    }
    updateVisibility()
  }

  override func draw(_ rect: CGRect) {
    guard side != .none else { return }

    resolvedFillColor.setFill()
    path(in: bounds).fill()
  }

  func configure(side: MessageBubbleTailSide, color: UIColor) {
    guard self.side != side || !fillColor.isEqual(color) else { return }
    self.side = side
    fillColor = color
    updateVisibility()
  }

  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    false
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func updateVisibility() {
    let alpha = resolvedFillColor.cgColor.alpha
    isHidden = side == .none || alpha <= 0.01
    setNeedsDisplay()
  }

  private var resolvedFillColor: UIColor {
    fillColor.resolvedColor(with: traitCollection)
  }

  private func path(in rect: CGRect) -> UIBezierPath {
    let width = rect.width
    let height = rect.height
    let sideEdge = width
    let visibleJoinX = max(0, width - Self.bubbleOverlap)
    let footX: CGFloat = 1.1
    let footY = rect.maxY - 1.2
    let lowerJoinX = max(0, visibleJoinX - 0.4)
    let lowerControlX = max(0, lowerJoinX - 0.8)
    let lowerJoinY = rect.maxY - 0.7
    let bottomJoin = rect.maxY - 4.4

    func x(_ value: CGFloat) -> CGFloat {
      switch side {
      case .none, .leading:
        return rect.minX + value
      case .trailing:
        return rect.maxX - value
      }
    }

    let path = UIBezierPath()
    path.move(to: CGPoint(x: x(sideEdge), y: rect.minY + 1.0))
    path.addCurve(
      to: CGPoint(x: x(visibleJoinX + 1.1), y: rect.minY + height * 0.48),
      controlPoint1: CGPoint(x: x(sideEdge), y: rect.minY + height * 0.26),
      controlPoint2: CGPoint(x: x(visibleJoinX + 3.8), y: rect.minY + height * 0.42)
    )
    path.addCurve(
      to: CGPoint(x: x(footX + 1.4), y: footY - 0.65),
      controlPoint1: CGPoint(x: x(visibleJoinX + 0.2), y: rect.minY + height * 0.68),
      controlPoint2: CGPoint(x: x(footX + 2.6), y: footY - 1.15)
    )
    path.addCurve(
      to: CGPoint(x: x(footX), y: footY),
      controlPoint1: CGPoint(x: x(footX + 0.8), y: footY - 0.15),
      controlPoint2: CGPoint(x: x(footX + 0.25), y: footY)
    )
    path.addCurve(
      to: CGPoint(x: x(lowerJoinX), y: lowerJoinY),
      controlPoint1: CGPoint(x: x(footX + 0.8), y: rect.maxY + 0.4),
      controlPoint2: CGPoint(x: x(lowerControlX), y: lowerJoinY + 0.15)
    )
    path.addCurve(
      to: CGPoint(x: x(sideEdge), y: bottomJoin),
      controlPoint1: CGPoint(x: x(visibleJoinX + 0.8), y: lowerJoinY - 0.15),
      controlPoint2: CGPoint(x: x(sideEdge - 1.2), y: bottomJoin + 0.25)
    )
    path.close()
    return path
  }
}

// MARK: - UI

extension UIMessageView {
  static func createBubbleView() -> UIView {
    let view = UIView()
    UIView.performWithoutAnimation {
      view.layer.cornerRadius = 18
    }
    view.clipsToBounds = true
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }

  static func createBubbleTailView() -> MessageBubbleTailView {
    let view = MessageBubbleTailView()
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
