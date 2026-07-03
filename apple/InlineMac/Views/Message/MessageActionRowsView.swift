import AppKit
import struct InlineProtocol.MessageAction
import struct InlineProtocol.MessageActionRow
import InlineMacUI

final class MessageActionRowsView: NSView {
  var onActionTap: ((MessageAction) -> Void)?

  private enum Metrics {
    static let rowSpacing: CGFloat = 4
    static let buttonSpacing: CGFloat = 4
  }

  private var buttonRows: [[MessageActionButtonView]] = []
  private var rowHeight: CGFloat = 28

  override var isFlipped: Bool {
    true
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    translatesAutoresizingMaskIntoConstraints = false
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
    self.rowHeight = rowHeight

    let buttonCounts = rows.map(\.actions.count)
    if buttonRows.map(\.count) != buttonCounts {
      rebuildButtonRows(buttonCounts: buttonCounts)
    }

    for (rowIndex, row) in rows.enumerated() {
      for (buttonIndex, action) in row.actions.enumerated() {
        let buttonView = buttonRows[rowIndex][buttonIndex]
        let actionId = action.actionID.trimmingCharacters(in: .whitespacesAndNewlines)
        buttonView.configure(
          action: action,
          isLoading: loadingActionIds.contains(actionId),
          outgoing: outgoing,
          rowHeight: rowHeight,
          messageFontSize: messageFontSize
        )
      }
    }

    needsLayout = true
  }

  private func rebuildButtonRows(buttonCounts: [Int]) {
    buttonRows.flatMap(\.self).forEach { $0.removeFromSuperview() }
    buttonRows = buttonCounts.map { buttonCount in
      (0 ..< buttonCount).map { _ in
        let buttonView = MessageActionButtonView()
        buttonView.onTap = { [weak self] tappedAction in
          self?.onActionTap?(tappedAction)
        }
        addSubview(buttonView)
        return buttonView
      }
    }
  }

  override func layout() {
    super.layout()

    var y: CGFloat = 0
    for row in buttonRows {
      let buttonCount = row.count
      guard buttonCount > 0 else { continue }

      let totalSpacing = CGFloat(buttonCount - 1) * Metrics.buttonSpacing
      let buttonWidth = max(0, (bounds.width - totalSpacing) / CGFloat(buttonCount))
      var x: CGFloat = 0

      for (index, button) in row.enumerated() {
        let width: CGFloat
        if index == buttonCount - 1 {
          width = max(0, bounds.width - x)
        } else {
          width = buttonWidth
        }

        button.frame = NSRect(x: x, y: y, width: width, height: rowHeight)
        x += width + Metrics.buttonSpacing
      }

      y += rowHeight + Metrics.rowSpacing
    }
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard !isHidden, alphaValue > 0, bounds.contains(point) else { return nil }

    for row in buttonRows.reversed() {
      for button in row.reversed() {
        let pointInButton = button.convert(point, from: self)
        if let hit = button.hitTest(pointInButton) {
          return hit
        }
      }
    }

    return nil
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

  var onTap: ((MessageAction) -> Void)?

  private let titleField: NSTextField = {
    let field = NSTextField(labelWithString: "")
    field.alignment = .center
    field.cell?.lineBreakMode = .byTruncatingTail
    field.maximumNumberOfLines = 1
    field.backgroundColor = .clear
    field.drawsBackground = false
    field.isBordered = false
    field.isEditable = false
    field.isSelectable = false
    return field
  }()

  private let spinner: NSProgressIndicator = {
    let spinner = NSProgressIndicator()
    spinner.style = .spinning
    spinner.controlSize = .small
    spinner.isDisplayedWhenStopped = false
    return spinner
  }()

  private var action: MessageAction?
  private var appearanceStyle: AppearanceStyle?
  private var trackingAreaRef: NSTrackingArea?
  private var isHovered = false
  private var isPressed = false

  private var isLoading: Bool {
    appearanceStyle?.isLoading == true
  }

  override var isFlipped: Bool {
    true
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true

    addSubview(titleField)
    addSubview(spinner)
    PressScaleAnimator.prepare(self)
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
    let previousActionId = self.action?.actionID
    self.action = action
    appearanceStyle = AppearanceStyle(
      title: action.text,
      isLoading: isLoading,
      outgoing: outgoing,
      rowHeight: rowHeight,
      messageFontSize: messageFontSize
    )

    if isLoading || previousActionId != action.actionID {
      isPressed = false
      PressScaleAnimator.setPressed(false, on: self)
    }

    applyAppearance()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    applyAppearance()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil {
      setPressed(false)
    } else {
      layer?.rasterizationScale = window?.backingScaleFactor ?? 2.0
      PressScaleAnimator.prepare(self)
    }
  }

  override func viewDidMoveToSuperview() {
    super.viewDidMoveToSuperview()
    if superview == nil {
      setPressed(false)
    }
  }

  override func layout() {
    super.layout()

    let titleHeight = min(bounds.height, max(0, ceil(titleField.intrinsicContentSize.height)))
    titleField.frame = NSRect(
      x: 8,
      y: floor((bounds.height - titleHeight) / 2),
      width: max(0, bounds.width - 16),
      height: titleHeight
    )

    var spinnerSize = spinner.fittingSize
    if spinnerSize.width <= 0 || spinnerSize.height <= 0 {
      spinnerSize = NSSize(width: 16, height: 16)
    }
    spinner.frame = NSRect(
      x: floor((bounds.width - spinnerSize.width) / 2),
      y: floor((bounds.height - spinnerSize.height) / 2),
      width: spinnerSize.width,
      height: spinnerSize.height
    )
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
    setPressed(false)
    applyAppearance()
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard !isHidden, bounds.contains(point) else { return nil }
    return self
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    true
  }

  override func mouseDown(with event: NSEvent) {
    MessageGestureTrace.debug(
      "MessageActionButtonView.mouseDown type=\(event.type.rawValue) clicks=\(event.clickCount)"
    )

    guard event.type == .leftMouseDown else {
      super.mouseDown(with: event)
      return
    }

    guard !isLoading, action != nil else {
      MessageGestureTrace.debug("MessageActionButtonView.mouseDown ignored reason=loadingOrMissingAction")
      return
    }

    setPressed(true)
    guard let window else {
      setPressed(false)
      return
    }

    while let next = window.nextEvent(
      matching: [.leftMouseDragged, .leftMouseUp],
      until: .distantFuture,
      inMode: .eventTracking,
      dequeue: true
    ) {
      let point = convert(next.locationInWindow, from: nil)
      let isInside = bounds.contains(point)

      switch next.type {
      case .leftMouseDragged:
        setPressed(isInside)
      case .leftMouseUp:
        setPressed(false)
        if isInside {
          handleTap()
        } else {
          MessageGestureTrace.debug("MessageActionButtonView.mouseUp cancelledOutside")
        }
        return
      default:
        break
      }
    }

    setPressed(false)
  }

  private func applyAppearance() {
    guard let appearanceStyle else { return }

    let appearance = effectiveAppearance
    let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    let fontSize = max(11, min(appearanceStyle.messageFontSize, appearanceStyle.rowHeight - 8))
    let textColor: NSColor = (appearanceStyle.outgoing ? NSColor.white : NSColor.labelColor)
      .resolvedColor(with: appearance)
    let disabledColor = textColor.withAlphaComponent(0.45)
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.alignment = .center
    paragraphStyle.lineBreakMode = .byTruncatingTail

    titleField.attributedStringValue = NSAttributedString(
      string: appearanceStyle.title,
      attributes: [
        .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
        .foregroundColor: appearanceStyle.isLoading ? disabledColor : textColor,
        .paragraphStyle: paragraphStyle,
      ]
    )
    titleField.toolTip = appearanceStyle.title
    toolTip = appearanceStyle.title

    if appearanceStyle.isLoading {
      spinner.startAnimation(nil)
      titleField.alphaValue = 0
    } else {
      spinner.stopAnimation(nil)
      titleField.alphaValue = 1
    }

    let backgroundColor: NSColor
    if appearanceStyle.outgoing {
      backgroundColor = .white.withAlphaComponent(isDark ? 0.18 : 0.14)
    } else {
      let incomingBase = Theme.messageBubbleSecondaryBgColor.resolvedColor(with: appearance)
      if isDark {
        backgroundColor = incomingBase.blended(withFraction: 0.16, of: .white) ?? incomingBase
      } else {
        let incomingAlpha = min(1, max(0.08, incomingBase.alphaComponent * 0.9))
        backgroundColor = incomingBase.withAlphaComponent(incomingAlpha)
      }
    }

    let hoverOverlay = isHovered ? (isDark ? 0.035 : 0.025) : 0
    let resolvedBackground = backgroundColor.blended(withFraction: hoverOverlay, of: .black) ?? backgroundColor
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

    PressScaleAnimator.prepare(self)
  }

  private func setPressed(_ pressed: Bool) {
    guard isPressed != pressed else { return }
    isPressed = pressed
    PressScaleAnimator.setPressed(pressed, on: self)
    applyAppearance()
  }

  private func handleTap() {
    guard let action else {
      MessageGestureTrace.debug("MessageActionButtonView.handleTap result=noAction")
      return
    }
    MessageGestureTrace.debug("MessageActionButtonView.handleTap actionId=\(action.actionID)")
    onTap?(action)
  }

  override func isAccessibilityElement() -> Bool {
    true
  }

  override func accessibilityRole() -> NSAccessibility.Role? {
    .button
  }

  override func accessibilityLabel() -> String? {
    appearanceStyle?.title
  }

  override func accessibilityPerformPress() -> Bool {
    guard !isLoading, action != nil else { return false }
    handleTap()
    return true
  }
}
