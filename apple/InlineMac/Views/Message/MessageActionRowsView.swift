import AppKit
import struct InlineProtocol.MessageAction
import struct InlineProtocol.MessageActionRow
import InlineMacUI

final class MessageActionRowsView: NSView {
  var onActionTap: ((MessageAction) -> Void)?

  private let rowsStack: NSStackView = {
    let stack = NSStackView()
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.orientation = .vertical
    stack.spacing = 4
    stack.alignment = .leading
    stack.distribution = .fill
    return stack
  }()

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    translatesAutoresizingMaskIntoConstraints = false
    addSubview(rowsStack)

    NSLayoutConstraint.activate([
      rowsStack.topAnchor.constraint(equalTo: topAnchor),
      rowsStack.leadingAnchor.constraint(equalTo: leadingAnchor),
      rowsStack.trailingAnchor.constraint(equalTo: trailingAnchor),
      rowsStack.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(
    rows: [MessageActionRow],
    loadingActionIds: Set<String>,
    outgoing: Bool,
    rowHeight: CGFloat,
    messageFontSize: CGFloat
  ) {
    rowsStack.arrangedSubviews.forEach { row in
      rowsStack.removeArrangedSubview(row)
      row.removeFromSuperview()
    }

    for row in rows {
      let rowStack = NSStackView()
      rowStack.translatesAutoresizingMaskIntoConstraints = false
      rowStack.orientation = .horizontal
      rowStack.spacing = 4
      rowStack.alignment = .centerY
      rowStack.distribution = .fillEqually

      for action in row.actions {
        let buttonView = MessageActionButtonView()
        let actionId = action.actionID.trimmingCharacters(in: .whitespacesAndNewlines)
        buttonView.configure(
          action: action,
          isLoading: loadingActionIds.contains(actionId),
          outgoing: outgoing,
          rowHeight: rowHeight,
          messageFontSize: messageFontSize
        )
        buttonView.onTap = { [weak self] tappedAction in
          self?.onActionTap?(tappedAction)
        }
        rowStack.addArrangedSubview(buttonView)
      }

      rowsStack.addArrangedSubview(rowStack)
    }
  }
}

final class MessageActionButtonView: NSView {
  private struct AppearanceStyle {
    var title: String
    var isLoading: Bool
    var outgoing: Bool
    var rowHeight: CGFloat
    var messageFontSize: CGFloat
  }

  private static let horizontalInset: CGFloat = 10
  private static let pressedScale: CGFloat = 0.95

  private final class ActionButton: NSButton {
    var onPressChange: ((Bool) -> Void)?

    override func mouseDown(with event: NSEvent) {
      onPressChange?(true)
      super.mouseDown(with: event)
      onPressChange?(false)
    }
  }

  var onTap: ((MessageAction) -> Void)?

  private let button: ActionButton = {
    let button = ActionButton(title: "", target: nil, action: nil)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.isBordered = false
    button.cell?.lineBreakMode = .byTruncatingTail
    button.font = .systemFont(ofSize: 12, weight: .medium)
    button.setButtonType(.momentaryChange)
    button.imagePosition = .noImage
    return button
  }()

  private let spinner: NSProgressIndicator = {
    let spinner = NSProgressIndicator()
    spinner.translatesAutoresizingMaskIntoConstraints = false
    spinner.style = .spinning
    spinner.controlSize = .small
    spinner.isDisplayedWhenStopped = false
    return spinner
  }()

  private var heightConstraint: NSLayoutConstraint?
  private var action: MessageAction?
  private var appearanceStyle: AppearanceStyle?
  private var trackingAreaRef: NSTrackingArea?
  private var isHovered = false
  private var isPressed = false

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true

    addSubview(button)
    addSubview(spinner)

    NSLayoutConstraint.activate([
      button.topAnchor.constraint(equalTo: topAnchor),
      button.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalInset),
      button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalInset),
      button.bottomAnchor.constraint(equalTo: bottomAnchor),
      spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
      spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])

    button.target = self
    button.action = #selector(handleTap)
    button.focusRingType = .none
    button.onPressChange = { [weak self] isPressed in
      self?.isPressed = isPressed
      self?.applyAppearance()
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(
    action: MessageAction,
    isLoading: Bool,
    outgoing: Bool,
    rowHeight: CGFloat,
    messageFontSize: CGFloat
  ) {
    self.action = action
    appearanceStyle = AppearanceStyle(
      title: action.text,
      isLoading: isLoading,
      outgoing: outgoing,
      rowHeight: rowHeight,
      messageFontSize: messageFontSize
    )
    applyAppearance()

    if let heightConstraint {
      heightConstraint.constant = rowHeight
    } else {
      let next = heightAnchor.constraint(equalToConstant: rowHeight)
      next.isActive = true
      heightConstraint = next
    }
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    applyAppearance()
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()

    if let trackingAreaRef {
      removeTrackingArea(trackingAreaRef)
    }

    let area = NSTrackingArea(
      rect: bounds,
      options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
      owner: self,
      userInfo: nil
    )
    addTrackingArea(area)
    trackingAreaRef = area
  }

  override func mouseEntered(with event: NSEvent) {
    super.mouseEntered(with: event)
    isHovered = true
    applyAppearance()
  }

  override func mouseExited(with event: NSEvent) {
    super.mouseExited(with: event)
    isHovered = false
    isPressed = false
    applyAppearance()
  }

  private func applyAppearance() {
    guard let appearanceStyle else { return }

    let appearance = effectiveAppearance
    let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    let fontSize = max(11, min(appearanceStyle.messageFontSize, appearanceStyle.rowHeight - 8))
    let textColor: NSColor = (appearanceStyle.outgoing ? .white : .labelColor).resolvedColor(with: appearance)
    let disabledColor = textColor.withAlphaComponent(0.45)

    button.attributedTitle = NSAttributedString(
      string: appearanceStyle.title,
      attributes: [
        .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
        .foregroundColor: appearanceStyle.isLoading ? disabledColor : textColor,
      ]
    )

    if appearanceStyle.isLoading {
      spinner.startAnimation(nil)
      button.alphaValue = 0
      button.isEnabled = false
    } else {
      spinner.stopAnimation(nil)
      button.alphaValue = 1
      button.isEnabled = true
    }

    let backgroundColor: NSColor
    if appearanceStyle.outgoing {
      backgroundColor = .white.withAlphaComponent(isDark ? 0.18 : 0.14)
    } else {
      let incomingBase = Theme.messageBubbleSecondaryBgColor.resolvedColor(with: appearance)
      let incomingAlpha = min(1, max(0.08, incomingBase.alphaComponent * (isDark ? 1.6 : 0.9)))
      backgroundColor = incomingBase.withAlphaComponent(incomingAlpha)
    }

    let hoverOverlay = isHovered ? (isDark ? 0.035 : 0.025) : 0
    let resolvedBackground = backgroundColor.blended(withFraction: hoverOverlay, of: .black) ?? backgroundColor
    let scale = isPressed ? Self.pressedScale : 1
    let alpha: CGFloat = appearanceStyle.isLoading ? 1 : (isPressed ? 0.88 : 1)

    layer?.cornerRadius = max(8, floor(appearanceStyle.rowHeight * 0.36))
    layer?.cornerCurve = .continuous
    layer?.borderWidth = 0
    layer?.backgroundColor = resolvedBackground.cgColor

    NSAnimationContext.runAnimationGroup { ctx in
      ctx.duration = 0.12
      ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      animator().alphaValue = alpha
    }

    layer?.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
  }

  @objc private func handleTap() {
    guard let action else { return }
    onTap?(action)
  }
}
