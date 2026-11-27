import AppKit
import InlineContextMenu

/// A row of quick reactions plus a "more" button, made to sit beside a `ContextMenu` as its accessory
/// view (as the reaction picker does over the iOS context menu). It knows nothing about messages: the
/// caller gives it emoji, the ones already chosen, and what to do on a pick.
///
/// Input it supports while the menu is open: hover, click, press-drag-release from the right click
/// that opened the menu, keyboard focus from the menu (↑ from the first row, ← → along, Return picks),
/// and VoiceOver buttons.
@MainActor
public final class ReactionBarAccessoryView: NSView, ContextMenuAccessoryInteraction {
  public var onPick: ((String) -> Void)?
  public var onMore: (() -> Void)?

  private let emoji: [String]
  private let chosen: Set<String>
  private var hovered: Int? { didSet { if oldValue != hovered { needsDisplay = true } } }
  private var pressed: Int?
  private var keyboardIndex: Int? {
    didSet {
      guard oldValue != keyboardIndex else { return }
      needsDisplay = true
      if let keyboardIndex, elements.indices.contains(keyboardIndex) {
        NSAccessibility.post(element: elements[keyboardIndex], notification: .focusedUIElementChanged)
      }
    }
  }

  private static let cell: CGFloat = 36
  private static let inset: CGFloat = 5
  private static let emojiSize: CGFloat = 22

  private lazy var elements: [ReactionBarElement] = (0 ... emoji.count).map { index in
    let label: String
    if index == emoji.count {
      label = "More reactions"
    } else {
      label = chosen.contains(emoji[index]) ? "Remove \(emoji[index])" : "React with \(emoji[index])"
    }
    return ReactionBarElement(label: label, parent: self, frame: { [weak self] in self?.cellRect(index) ?? .zero }) { [weak self] in
      self?.pick(index)
    }
  }

  /// - Parameters:
  ///   - emoji: quick reactions, in order.
  ///   - chosen: the ones the user already reacted with; picking one again removes it.
  public init(emoji: [String], chosen: Set<String> = []) {
    self.emoji = emoji
    self.chosen = chosen
    super.init(frame: .zero)
    setFrameSize(fittingSize)
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel("Reactions")
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override public var isFlipped: Bool { true }
  override public var fittingSize: NSSize {
    NSSize(width: CGFloat(emoji.count + 1) * Self.cell + 2 * Self.inset, height: Self.cell + 8)
  }

  override public func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override public func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self))
  }

  fileprivate func cellRect(_ index: Int) -> NSRect {
    NSRect(x: Self.inset + CGFloat(index) * Self.cell, y: (bounds.height - Self.cell) / 2, width: Self.cell, height: Self.cell)
  }

  private func index(at point: NSPoint) -> Int? {
    (0 ... emoji.count).first { cellRect($0).contains(point) }
  }

  // MARK: Drawing

  override public func draw(_ dirtyRect: NSRect) {
    let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    for index in 0 ... emoji.count {
      let rect = cellRect(index)
      let active = hovered == index || keyboardIndex == index
      let isChosen = index < emoji.count && chosen.contains(emoji[index])
      if isChosen {
        NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
        NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2)).fill()
      } else if active {
        NSColor.labelColor.withAlphaComponent(0.1).setFill()
        NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
      }
      if keyboardIndex == index {
        NSColor.keyboardFocusIndicatorColor.setStroke()
        let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5))
        ring.lineWidth = 2
        ring.stroke()
      }
      if index == emoji.count {
        drawMore(in: rect, active: active)
        continue
      }
      let scale: CGFloat = active && !reduceMotion ? 1.18 : 1
      let font = NSFont.systemFont(ofSize: Self.emojiSize * scale)
      let text = emoji[index] as NSString
      let size = text.size(withAttributes: [.font: font])
      text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: [.font: font])
    }
  }

  private func drawMore(in rect: NSRect, active: Bool) {
    guard let plus = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: 14, weight: .semibold)) else { return }
    let size = plus.size
    let color = active ? NSColor.labelColor : NSColor.secondaryLabelColor
    let tinted = NSImage(size: size, flipped: false) { bounds in
      plus.draw(in: bounds)
      color.set()
      bounds.fill(using: .sourceAtop)
      return true
    }
    tinted.draw(
      in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height),
      from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil
    )
  }

  // MARK: Mouse

  override public func mouseMoved(with event: NSEvent) {
    hovered = index(at: convert(event.locationInWindow, from: nil))
  }

  override public func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
  override public func mouseExited(with event: NSEvent) { hovered = nil }

  override public func mouseDown(with event: NSEvent) {
    pressed = index(at: convert(event.locationInWindow, from: nil))
  }

  override public func mouseUp(with event: NSEvent) {
    let index = index(at: convert(event.locationInWindow, from: nil))
    defer { pressed = nil }
    guard let index, index == pressed else { return }
    pick(index)
  }

  fileprivate func pick(_ index: Int) {
    if index == emoji.count {
      onMore?()
    } else {
      onPick?(emoji[index])
    }
  }

  // MARK: ContextMenuAccessoryInteraction

  public func contextMenuTrackPointer(atScreen point: NSPoint?) {
    guard let point, let window else { hovered = nil; return }
    hovered = index(at: convert(window.convertPoint(fromScreen: point), from: nil))
  }

  public func contextMenuRelease(atScreen point: NSPoint) -> Bool {
    guard let window, let index = index(at: convert(window.convertPoint(fromScreen: point), from: nil)) else { return false }
    pick(index)
    return true
  }

  public func contextMenuSetKeyboardFocus(_ focused: Bool) -> Bool {
    keyboardIndex = focused ? 0 : nil
    hovered = nil
    return true
  }

  public func contextMenuMoveKeyboardFocus(by step: Int) {
    guard let keyboardIndex else { return }
    self.keyboardIndex = min(max(keyboardIndex + step, 0), emoji.count)
  }

  public func contextMenuActivateKeyboardFocus() -> Bool {
    guard let keyboardIndex else { return false }
    pick(keyboardIndex)
    return true
  }

  // MARK: Accessibility

  override public func accessibilityChildren() -> [Any]? { elements }
}

/// One reaction as VoiceOver sees it: a button that reacts when pressed.
@MainActor
private final class ReactionBarElement: NSAccessibilityElement {
  private let frameInParent: () -> NSRect
  private let press: () -> Void
  private weak var parentView: NSView?

  init(label: String, parent: NSView, frame: @escaping () -> NSRect, press: @escaping () -> Void) {
    frameInParent = frame
    self.press = press
    parentView = parent
    super.init()
    setAccessibilityRole(.button)
    setAccessibilityLabel(label)
    setAccessibilityParent(parent)
  }

  override func accessibilityFrame() -> NSRect {
    guard let parentView, let window = parentView.window else { return .zero }
    return window.convertToScreen(parentView.convert(frameInParent(), to: nil))
  }

  override func accessibilityPerformPress() -> Bool {
    press()
    return true
  }
}
