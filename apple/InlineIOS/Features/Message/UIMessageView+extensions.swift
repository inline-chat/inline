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
  // Cropped from the trailing-side full-bubble SVG. `sourceBubbleEdgeX` is the
  // bubble edge the visible tail tucks under before mirroring for leading tails.
  private static let sourceSize = CGSize(width: 37, height: 52.4)
  private static let sourceBubbleEdgeX: CGFloat = 19.5183
  private static let sourceTailBottomY: CGFloat = 51.2853
  static let cornerRadius: CGFloat = 18

  private static var tailDrawScale: CGFloat {
    cornerRadius / sourceTailBottomY
  }

  private static var exposedTailWidth: CGFloat {
    (sourceSize.width - sourceBubbleEdgeX) * tailDrawScale
  }

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

  func configure(side: MessageBubbleTailSide, animated: Bool = false) {
    guard self.side != side else { return }
    let removedShapePath = animated ? removedShapePath(from: self.side, to: side, in: bounds) : nil
    self.side = side
    updateContentInsets()
    updateShape()

    if let removedShapePath {
      animateRemovedShape(path: removedShapePath)
    }
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
    contentRect(for: side, in: bounds)
  }

  private func contentRect(for side: MessageBubbleTailSide, in rect: CGRect) -> CGRect {
    let tailWidth = Self.tailWidth(for: side)
    return rect.inset(by: UIEdgeInsets(
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

  private func animateRemovedShape(path: UIBezierPath) {
    let color = resolvedFillColor
    guard color.cgColor.alpha > 0.01 else { return }

    let fadeLayer = CAShapeLayer()
    fadeLayer.contentsScale = UIScreen.main.scale
    fadeLayer.fillRule = path.usesEvenOddFillRule ? .evenOdd : .nonZero
    fadeLayer.fillColor = color.cgColor
    fadeLayer.opacity = 1

    if let superview {
      let origin = convert(bounds.origin, to: superview)
      let translatedPath = UIBezierPath(cgPath: path.cgPath)
      translatedPath.apply(CGAffineTransform(translationX: origin.x, y: origin.y))
      fadeLayer.frame = superview.layer.bounds
      fadeLayer.path = translatedPath.cgPath
      superview.layer.insertSublayer(fadeLayer, above: layer)
    } else {
      fadeLayer.frame = bounds
      fadeLayer.path = path.cgPath
      layer.insertSublayer(fadeLayer, above: fillLayer)
    }

    let animation = CABasicAnimation(keyPath: "opacity")
    animation.fromValue = 1
    animation.toValue = 0
    animation.duration = 0.16
    animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
    fadeLayer.add(animation, forKey: "bubbleShapeRemoval")

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    fadeLayer.opacity = 0
    CATransaction.commit()

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak fadeLayer] in
      fadeLayer?.removeFromSuperlayer()
    }
  }

  private func bubblePath(in rect: CGRect) -> UIBezierPath {
    bubblePath(for: side, in: rect)
  }

  private func bubblePath(for side: MessageBubbleTailSide, in rect: CGRect) -> UIBezierPath {
    let contentRect = contentRect(for: side, in: bounds).intersection(rect)
    guard !contentRect.isNull, contentRect.width > 0, contentRect.height > 0 else {
      return UIBezierPath()
    }

    let path = UIBezierPath(roundedRect: contentRect, cornerRadius: Self.cornerRadius)
    if let tailPath = tailOnlyPath(for: side, contentRect: contentRect) {
      path.append(tailPath)
    }

    return path
  }

  private func removedShapePath(
    from oldSide: MessageBubbleTailSide,
    to newSide: MessageBubbleTailSide,
    in rect: CGRect
  ) -> UIBezierPath? {
    guard oldSide != .none, !rect.isEmpty else { return nil }

    if newSide == .none {
      let path = UIBezierPath()
      path.append(bubblePath(for: oldSide, in: rect))
      path.append(bubblePath(for: newSide, in: rect))
      path.usesEvenOddFillRule = true
      return path
    }

    return tailOnlyPath(for: oldSide, in: rect)
  }

  private func tailOnlyPath(for side: MessageBubbleTailSide, in rect: CGRect) -> UIBezierPath? {
    let contentRect = contentRect(for: side, in: rect)
    guard !contentRect.isNull, contentRect.width > 0, contentRect.height > 0 else {
      return nil
    }
    return tailOnlyPath(for: side, contentRect: contentRect)
  }

  private func tailOnlyPath(for side: MessageBubbleTailSide, contentRect: CGRect) -> UIBezierPath? {
    guard side != .none else { return nil }

    let drawSize = CGSize(
      width: Self.sourceSize.width * Self.tailDrawScale,
      height: Self.sourceSize.height * Self.tailDrawScale
    )
    let tailY = contentRect.maxY - Self.sourceTailBottomY * Self.tailDrawScale

    let tailRect: CGRect
    switch side {
    case .none:
      return nil
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

    return tailPath(for: side, in: tailRect)
  }

  private func tailPath(for side: MessageBubbleTailSide, in rect: CGRect) -> UIBezierPath {
    let scaleX = rect.width / Self.sourceSize.width
    let scaleY = rect.height / Self.sourceSize.height

    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
      let resolvedX: CGFloat = switch side {
      case .leading:
        rect.maxX - x * scaleX
      case .none, .trailing:
        rect.minX + x * scaleX
      }
      return CGPoint(x: resolvedX, y: rect.minY + y * scaleY)
    }

    let path = UIBezierPath()
    path.move(to: point(19.4761, 6.9846))
    path.addCurve(
      to: point(19.5183, 0),
      controlPoint1: point(19.5041, 6.3302),
      controlPoint2: point(19.5183, 0.6611)
    )
    path.addLine(to: point(0, 0))
    path.addLine(to: point(0, 39.8152))
    path.addCurve(
      to: point(36.1476, 50.9938),
      controlPoint1: point(8.3867, 48.2023),
      controlPoint2: point(22.1067, 52.3205)
    )
    path.addCurve(
      to: point(36.5785, 50.7275),
      controlPoint1: point(36.3267, 50.9769),
      controlPoint2: point(36.4868, 50.878)
    )
    path.addCurve(
      to: point(36.3805, 49.9764),
      controlPoint1: point(36.7373, 50.4669),
      controlPoint2: point(36.6487, 50.1307)
    )
    path.addLine(to: point(35.3668, 49.3821))
    path.addCurve(
      to: point(22.3321, 37.0489),
      controlPoint1: point(28.7234, 45.413),
      controlPoint2: point(24.3785, 41.3021)
    )
    path.addCurve(
      to: point(19.4761, 6.9846),
      controlPoint1: point(20.1278, 32.4675),
      controlPoint2: point(19.1757, 22.4468)
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

  func createServiceContainerView() -> UIView {
    let view = UIView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.backgroundColor = .tertiarySystemFill
    view.layer.cornerRadius = 11
    view.layer.masksToBounds = true
    return view
  }

  func createServiceLabel() -> UILabel {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = .preferredFont(forTextStyle: .caption1)
    label.textColor = .secondaryLabel
    label.textAlignment = .center
    label.numberOfLines = 0
    label.lineBreakMode = .byWordWrapping
    label.adjustsFontForContentSizeCategory = true
    return label
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
