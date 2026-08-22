import Auth
import GRDB
import InlineKit
import InlineProtocol
import InlineUI
import Logger
import SwiftUI
import UIKit

final class MessageBubbleView: UIView {
  static let cornerRadius = MessageBubbleGeometry.cornerRadius
  static let minimumBodyHeight = MessageBubbleGeometry.minimumBodyHeight

  static func tailWidth(for side: MessageBubbleTailSide) -> CGFloat {
    MessageBubbleGeometry.tailWidth(for: side)
  }

  let contentView = UIView()

  private let fillLayer = CAShapeLayer()
  private let lightingLayer = CAGradientLayer()
  private var lightingAlphas: (top: CGFloat, bottom: CGFloat)?
  private var lightingVector: (startY: CGFloat, endY: CGFloat)?
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
    fillLayer.fillColor = UIColor.black.cgColor

    lightingLayer.type = .axial
    lightingLayer.locations = [0, 1]
    lightingLayer.isHidden = true
    lightingLayer.mask = fillLayer
    layer.insertSublayer(lightingLayer, at: 0)

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
    let removedTailPath = animated && side == .none
      ? MessageBubbleGeometry.tailPathOnly(for: self.side, in: bounds)
      : nil
    self.side = side
    updateContentInsets()
    updateShape()

    if let removedTailPath {
      animateRemovedTail(path: removedTailPath)
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func visiblePath() -> UIBezierPath {
    MessageBubbleGeometry.path(in: bounds, side: side)
  }

  func configureContinuousGradient(topAlpha: CGFloat, bottomAlpha: CGFloat) {
    if let lightingAlphas,
       abs(lightingAlphas.top - topAlpha) <= 0.0001,
       abs(lightingAlphas.bottom - bottomAlpha) <= 0.0001 {
      return
    }

    lightingAlphas = (topAlpha, bottomAlpha)
    updateGradientColors()
  }

  func updateContinuousGradient(startY: CGFloat, endY: CGFloat) {
    guard lightingAlphas != nil else { return }
    if let lightingVector,
       abs(lightingVector.startY - startY) <= 0.0001,
       abs(lightingVector.endY - endY) <= 0.0001 {
      return
    }

    lightingVector = (startY, endY)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    lightingLayer.startPoint = CGPoint(x: 0.5, y: startY)
    lightingLayer.endPoint = CGPoint(x: 0.5, y: endY)
    lightingLayer.isHidden = resolvedFillColor.cgColor.alpha <= 0.01
    CATransaction.commit()
  }

  func clearContinuousGradient() {
    guard lightingAlphas != nil || lightingVector != nil else { return }
    lightingAlphas = nil
    lightingVector = nil
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    lightingLayer.startPoint = CGPoint(x: 0.5, y: 0)
    lightingLayer.endPoint = CGPoint(x: 0.5, y: 1)
    CATransaction.commit()
    updateGradientColors()
  }

  private var resolvedFillColor: UIColor {
    fillColor.resolvedColor(with: traitCollection)
  }

  private var tailWidth: CGFloat {
    Self.tailWidth(for: side)
  }

  private var contentRect: CGRect {
    MessageBubbleGeometry.contentRect(for: side, in: bounds)
  }

  private func updateContentInsets() {
    contentLeadingConstraint?.constant = side == .leading ? tailWidth : 0
    contentTrailingConstraint?.constant = side == .trailing ? -tailWidth : 0
  }

  private func updateShape() {
    let color = resolvedFillColor
    let path = visiblePath().cgPath

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    lightingLayer.frame = bounds
    fillLayer.frame = bounds
    fillLayer.path = path
    lightingLayer.isHidden = color.cgColor.alpha <= 0.01
    CATransaction.commit()
    updateGradientColors()
  }

  private func updateGradientColors() {
    let color = resolvedFillColor
    let top = color.mixedWithWhite(alpha: lightingAlphas?.top ?? 0)
    let bottom = color.mixedWithWhite(alpha: lightingAlphas?.bottom ?? 0)

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    lightingLayer.colors = [top.cgColor, bottom.cgColor]
    lightingLayer.isHidden = color.cgColor.alpha <= 0.01
    CATransaction.commit()
  }

  private func animateRemovedTail(path: UIBezierPath) {
    let color = resolvedFillColor
    guard color.cgColor.alpha > 0.01 else { return }

    let fadeLayer: CALayer
    if lightingAlphas != nil {
      let gradient = CAGradientLayer()
      gradient.type = .axial
      gradient.colors = lightingLayer.colors
      gradient.locations = lightingLayer.locations
      gradient.startPoint = lightingLayer.startPoint
      gradient.endPoint = lightingLayer.endPoint

      let tailMask = CAShapeLayer()
      tailMask.contentsScale = UIScreen.main.scale
      tailMask.fillColor = UIColor.black.cgColor
      tailMask.frame = bounds
      tailMask.path = path.cgPath
      gradient.mask = tailMask
      fadeLayer = gradient
    } else {
      let shape = CAShapeLayer()
      shape.contentsScale = UIScreen.main.scale
      shape.fillColor = color.cgColor
      shape.path = path.cgPath
      fadeLayer = shape
    }
    fadeLayer.opacity = 1

    if let superview {
      let origin = convert(bounds.origin, to: superview)
      fadeLayer.frame = CGRect(origin: origin, size: bounds.size)
      superview.layer.insertSublayer(fadeLayer, above: layer)
    } else {
      fadeLayer.frame = bounds
      layer.insertSublayer(fadeLayer, above: lightingLayer)
    }

    let animation = CABasicAnimation(keyPath: "opacity")
    animation.fromValue = 1
    animation.toValue = 0
    animation.duration = 0.16
    animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
    fadeLayer.add(animation, forKey: "bubbleTailRemoval")

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    fadeLayer.opacity = 0
    CATransaction.commit()

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak fadeLayer] in
      fadeLayer?.removeFromSuperlayer()
    }
  }
}

private extension UIColor {
  func mixedWithWhite(alpha: CGFloat) -> UIColor {
    let fraction = min(max(alpha, 0), 1)
    guard fraction > 0 else { return self }
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var colorAlpha: CGFloat = 0
    guard getRed(&red, green: &green, blue: &blue, alpha: &colorAlpha) else { return self }
    return UIColor(
      red: red + (1 - red) * fraction,
      green: green + (1 - green) * fraction,
      blue: blue + (1 - blue) * fraction,
      alpha: colorAlpha
    )
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
    stack.spacing = StackPadding.inlineTextMetadataSpacing
    stack.alignment = .center
    stack.distribution = .fill
    stack.isUserInteractionEnabled = true
    stack.translatesAutoresizingMaskIntoConstraints = false
    return stack
  }

  func createMultiLineStack() -> UIStackView {
    let stack = UIStackView()
    stack.axis = .vertical
    stack.spacing = 10
    stack.alignment = .fill
    stack.distribution = .fill
    stack.isUserInteractionEnabled = true
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
    label.textColor = theme.primary.uiColor
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
    let view = FloatingMetadataView(
      fullMessage: fullMessage,
      initiallyDisplaying: initialMetadataStatus
    )
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

    // Propose the standalone width without preventing the parent stack from
    // stretching the voice surface to match a wider text or preview child.
    let preferredWidth = controller.view.widthAnchor.constraint(equalToConstant: 240)
    preferredWidth.priority = .defaultLow

    NSLayoutConstraint.activate([
      controller.view.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
      preferredWidth,
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
    let view = MessageTimeAndStatus(
      fullMessage,
      initiallyDisplaying: initialMetadataStatus
    )
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
