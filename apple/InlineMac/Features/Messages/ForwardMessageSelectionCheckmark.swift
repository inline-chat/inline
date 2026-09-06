import AppKit

/// Telegram-style selection indicator; only the small circle carries accent color.
final class ForwardMessageSelectionCheckmark: NSButton {
  var onToggle: (() -> Void)?

  init() {
    super.init(frame: .zero)
    setButtonType(.switch)
    isBordered = false
    title = ""
    target = self
    action = #selector(toggleSelection)
    setAccessibilityLabel("Select message")
  }

  required init?(coder: NSCoder) { nil }

  @objc private func toggleSelection() {
    onToggle?()
  }

  override func draw(_ dirtyRect: NSRect) {
    let selected = state == .on
    let diameter: CGFloat = selected ? 22 : 18
    let rect = NSRect(
      x: (bounds.width - diameter) / 2,
      y: (bounds.height - diameter) / 2,
      width: diameter, height: diameter
    )
    let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
    if selected {
      Theme.accentColor.setFill()
      circle.fill()
      let check = NSBezierPath()
      // NSButton uses flipped coordinates; the tick's elbow must point down.
      let down: CGFloat = isFlipped ? 1 : -1
      check.move(to: NSPoint(x: bounds.midX - 4, y: bounds.midY))
      check.line(to: NSPoint(x: bounds.midX - 1, y: bounds.midY + 3 * down))
      check.line(to: NSPoint(x: bounds.midX + 5, y: bounds.midY - 4 * down))
      check.lineWidth = 1.8
      check.lineCapStyle = .round
      check.lineJoinStyle = .round
      NSColor.white.setStroke()
      check.stroke()
    } else {
      NSColor.tertiaryLabelColor.setStroke()
      circle.lineWidth = 1.5
      circle.stroke()
    }
  }
}
